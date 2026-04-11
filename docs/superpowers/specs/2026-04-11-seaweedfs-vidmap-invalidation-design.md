# SeaweedFS vidMap stale-entry invalidation — design

**Date:** 2026-04-11
**Status:** Draft — pending implementation plan
**Scope:** Upstream `seaweedfs/seaweedfs` fork shipped via `go.mod replace` directive from `drivers/seaweedfs-csi-driver/`. No in-tree CSI driver logic changes.

## Problem

Long-lived SeaweedFS clients cache volume-server pod IPs indefinitely in their `wdclient.vidMap`. When a volume pod restarts — normal lifecycle event in a Kubernetes DaemonSet — the master's topology updates but client caches do not invalidate. Reads to rarely-touched volumes hang forever against dead IPs.

Two incidents of record:

- **2026-04-10** — `seaweedfs-s3` gateway's vidMap held a stale entry for volume 39 pointing at `10.42.2.183` (a 33-hour-old heracles pod IP). Overseerr litestream-restore init container hung for >10 min with `decode header: EOF`. `kubectl rollout restart deployment/seaweedfs-s3` cleared the cache; recovery was instant.
- **2026-04-11** — `plex-config` weed mount FUSE subprocess on `seaweedfs-mount-jknf4` held two 4-hour-old dead volume-server IPs. Stat/ReadDir worked (filer reachable) so the CSI `isStagingPathHealthy` probe passed and self-heal never triggered. Plex in CrashLoopBackOff 20h because `40-plex-first-run` hung reading `Preferences.xml`. Recovery required exec-into-mount-pod + SIGKILL of the specific weed mount PID + consumer pod delete.

Root cause: `wdclient.vidMap` has no TTL and does not invalidate on read failure in most client code paths.

## Existing upstream infrastructure (partial)

Upstream (`v0.0.0-20260402004241-6213daf11812`) already provides:

- **`vidMapClient.InvalidateCache(fileId string)`** in `weed/wdclient/vidmap_client.go` — thread-safe, handles cache-history recursion via `deleteVid` (tested in `vidmap_invalidation_test.go`). Solid primitive.
- **`filer.CacheInvalidator` interface** in `weed/filer/stream.go:108-111`. `vidMapClient` satisfies it.
- **One wired call site** in `filer/stream.go:200-228` (`PrepareStreamContent` inner loop) calls `InvalidateCache` + re-lookup on read failure — but gated on `written == 0` *and* a `urlSlicesEqual` bail-out, which together miss the common case where master hasn't yet propagated the topology update.

## Call sites requiring invalidation plumbing

All 5 read paths share the same shape: `lookupFileIdFn(fileId)` → retry loop across `urlStrings` → give up.

| Call site | Retry func | Consumer | Invalidation today |
|---|---|---|---|
| `filer/stream.go:194` | `retriedStreamFetchChunkData` | filer stream / s3 via filer | Partial (buggy gating) |
| `filer/filechunk_manifest.go:113` | `retriedStreamFetchChunkData` | weed mount `fetchWholeChunk` | None |
| `filer/filechunk_manifest.go:126` | `RetriedFetchChunkData` | weed mount `fetchChunkRange` | None |
| `filer/reader_cache.go:206` | `RetriedFetchChunkData` | weed mount cached reads | None |
| `filer/stream.go:297` | `RetriedFetchChunkData` | filer `ReadAll` | None |

## Non-goals

- **Upstream PR** — deferred as optional post-hoc work. Delivery is via `go.mod replace` directive against a personal fork; the PR can be opened after user review of the implementation.
- **`hostNetwork: true` on volume DaemonSet** — explicitly ruled out. Pod network is the correct place for intra-cluster communication; stable identity should not be achieved by colonising host ports.
- **In-tree CSI driver changes** — this is an upstream seaweedfs library bug. The CSI fork is a consumer only. No `drivers/seaweedfs-csi-driver/` code changes except a `go.mod replace` directive + version bump.
- **Backoff / retry-count tuning** — single-shot re-lookup per read operation, no loops. Higher layers (FUSE, kubelet, s3 gateway callers) own their own retry cadence.

## Design

### Architecture

Introduce a single helper in the seaweedfs fork at `weed/filer/read_with_relookup.go`:

```go
// ReadChunkWithReLookup looks up volume-server URLs for fileId, invokes
// fetchFn with them, and on failure invalidates the vidMap entry and
// re-looks-up exactly once. If the re-lookup returns the same URLs
// (master hasn't rotated yet) it returns the original error instead of
// retrying. Bounded — exactly one re-lookup per call, never loops.
//
// fetchFn is called with the current slice of urlStrings and returns
// (bytesWritten, err). If bytesWritten > 0 and err != nil, the cache
// is invalidated for the NEXT reader but no retry is attempted (the
// caller's output is already tainted).
func ReadChunkWithReLookup(
    ctx context.Context,
    masterClient wdclient.HasLookupFileIdFunction,
    fileId string,
    fetchFn func(urlStrings []string) (written int, err error),
) (int, error)
```

All 5 call sites become:

```go
var out int
err := filer.ReadChunkWithReLookup(ctx, masterClient, fileId,
    func(urls []string) (int, error) {
        return retriedStreamFetchChunkData(ctx, writer, urls, ...)
    })
```

The existing `retriedStreamFetchChunkData` / `util_http.RetriedFetchChunkData` keep their signatures — still used internally, still own their own inner retry loops. We do not touch their retry semantics. We wrap them.

The bespoke invalidation block currently in `filer/stream.go:200-228` is deleted; it becomes redundant once `PrepareStreamContent`'s inner loop uses the helper.

**Why a single helper rather than threading a "re-lookup variant" `lookupFn` through each caller:** the helper owns the invalidation-and-retry semantic as one unit. Future changes (bounded retry count, metrics, trace spans, per-error-class invalidation policy) happen in one place. The current upstream state — invalidation only wired up in one call site with brittle gating — is exactly the bug this design refactors away.

### Components

1. **`ReadChunkWithReLookup`** — new pure function in `weed/filer/read_with_relookup.go`.
2. **`CacheInvalidator` interface** — already exists, kept as-is. Asserted off `masterClient` inside the helper.
3. **`masterClient` threading** — two call sites (`fetchWholeChunk`, `fetchChunkRange`) currently receive only `lookupFileIdFn`. Their signatures gain a `masterClient wdclient.HasLookupFileIdFunction` parameter. Callers already have the master client in scope. `reader_cache.go` gains `masterClient` as a struct field, initialised at construction.
4. **Prometheus counter** — `seaweedfs_filer_vidmap_relookups_total{result="success|same_urls|lookup_failed|no_invalidator|partial_write"}`, registered via the existing `stats` package pattern in upstream.

### Data flow

**Evaluation order on any failure:** ctx check first → partial-write check → no-invalidator check → invalidate + re-lookup. Ctx is always checked before invalidation so cancellation can never trigger master queries.

**Happy path:**

```
caller -> ReadChunkWithReLookup(ctx, mc, fileId, fetchFn)
  1. urls, err := mc.GetLookupFileIdFunction()(ctx, fileId)
     if err != nil -> return 0, err                    (master unreachable, nothing to do)
  2. written, err := fetchFn(urls)
  3. if err == nil -> return written, nil              // 99.9% path
```

**Failure path — ordered evaluation:**

```
  3. err != nil
  4. if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded):
       return written, err                             // never mask ctx.Err as stale-vidMap
  5. inv, ok := mc.(CacheInvalidator)
     if !ok -> return written, err                     // non-invalidator master, bail
  6. inv.InvalidateCache(fileId)                       // delete vid from cache + history
                                                       // (happens for written > 0 AND written == 0)
  7. if written > 0 -> return written, err             // caller's output tainted, no retry
  8. newUrls, lookupErr := mc.GetLookupFileIdFunction()(ctx, fileId)
     if lookupErr != nil -> return 0, err              // return ORIGINAL err, log lookupErr
  9. if urlSlicesEqual(urls, newUrls) -> return 0, err // master unchanged, bail
  10. return fetchFn(newUrls)                          // one-shot retry with fresh URLs
```

### Design decisions

**Return original error on lookup-retry failure.** If the re-lookup in step 8 itself fails, the caller's telemetry should show the read error they care about, not a cascade symptom. `lookupErr` gets logged but not propagated.

**Bail instead of retry on `urlSlicesEqual`.** Master hasn't yet propagated the topology update. Retrying the same URLs will fail the same way. Return error → higher layer retries at its own cadence. Matches upstream `filer/stream.go`'s existing `urlSlicesEqual` behaviour and avoids tight-loop infinite-retry pathologies when master is briefly unavailable or slow.

**Always invalidate on failure, even when not retrying.** Partial-write failures still drop the stale entry so the next read on this fileId gets fresh URLs. Strictly better than status quo where `StreamContent` invalidates only on `written == 0`, leaving stale entries in place across partial-write failures.

**Single-shot re-lookup — no loops, no backoff.** Higher layers already have retry logic at timescales appropriate to their contracts (FUSE kernel retries, kubelet exponential backoff, s3 client retries). A busy-loop inside the helper would fight them.

### Concurrency

`InvalidateCache` is already thread-safe in `vidmap_client.go` (uses `vidMap.Lock()`). No new locks needed. If two goroutines race on the same stale fileId:

- Both may call `InvalidateCache` — idempotent, harmless.
- Both may then see the same `newUrls` from master — one or both succeed, no correctness issue.
- Prometheus counter bumps may over-count the recovery event — acceptable.

### Error handling — the partial-write nuance

`retriedStreamFetchChunkData` can flush bytes to the output writer before failing mid-chunk — retrying after that would double-write. Upstream's existing `written == 0` gate in `filer/stream.go:201` is conceptually right but brittle in its current form (too narrow). The helper handles this cleanly by inspecting `fetchFn`'s `written` return value:

- **Always invalidate** the vidMap entry on any failure.
- **Retry only when `written == 0`.** If bytes already flowed, the caller's output is tainted — return the error, let the higher layer own recovery.
- **Return `ctx.Err()` unchanged** whenever context was cancelled — never mask cancellation as a stale-vidMap issue.

Partial-write failures in `StreamContent` still get invalidated so the next s3 GET succeeds on fresh URLs, even though the current one fails. Strictly better than status quo.

## Testing

Unit tests in `weed/filer/read_with_relookup_test.go` using a stub `masterClient` implementing `HasLookupFileIdFunction + CacheInvalidator`:

1. **Happy path** — `fetchFn` succeeds first try. Assert: no invalidation called, counter `result="success"` not bumped.
2. **Stale-then-fresh** — `fetchFn` fails with initial URLs, invalidation called, re-lookup returns different URLs, `fetchFn` succeeds with fresh URLs. Assert: counter `result="success"` bumped.
3. **Stale-then-same** — re-lookup returns identical slice, return original error, no retry. Assert: counter `result="same_urls"` bumped.
4. **Stale-then-lookupErr** — master re-lookup errors, return original fetch error (not lookup error), invalidation still called. Assert: counter `result="lookup_failed"` bumped.
5. **Partial-write failure** — `fetchFn` returns `(written > 0, err)`, invalidation called, no retry, original error returned. Assert: counter `result="partial_write"` bumped.
6. **Context cancellation** — `fetchFn` returns `ctx.Err()`, no invalidation, no re-lookup, propagate as-is. Assert: no counter bumps.
7. **Non-invalidator master** — `masterClient` doesn't satisfy `CacheInvalidator`, return error without retry. Assert: counter `result="no_invalidator"` bumped.
8. **Concurrent invalidation** — two goroutines hit stale vid simultaneously, both invalidate idempotently, both eventually succeed with fresh URLs. Assert: no data races under `go test -race`.

Call-site coverage: each of the 5 updated call sites gets a small wiring test asserting `masterClient` is threaded through correctly (guards against future regressions where someone drops the plumbing).

No new test harness. All 8 tests use the same stubbing pattern as the existing `vidmap_invalidation_test.go`.

## Delivery

### Prerequisites

None — the seaweedfs fork already exists at `github.com/neBM/seaweedfs`.

### Sequence

1. Clone `github.com/neBM/seaweedfs` locally. Cut branch `fix/vidmap-stale-relookup` off the commit our `go.mod` currently pins: `20260402004241-6213daf11812`.
2. Implement:
   - `weed/filer/read_with_relookup.go` — helper + counter registration.
   - `weed/filer/read_with_relookup_test.go` — 8 unit tests.
   - 5 call-site edits (3 in `weed/filer/filechunk_manifest.go` + `reader_cache.go`, 2 in `weed/filer/stream.go`).
   - Deletion of the bespoke block in `filer/stream.go:200-228`.
3. `go test -race ./weed/filer/... ./weed/wdclient/...` in the fork. Must pass clean.
4. Commit, push, record commit hash.
5. In `drivers/seaweedfs-csi-driver/go.mod`: add
   `replace github.com/seaweedfs/seaweedfs => github.com/neBM/seaweedfs <commit-hash>`
6. `go mod tidy` in the CSI driver. Commit resulting `go.mod` / `go.sum` diff.
7. Bump CSI driver `VERSION` → `0.1.9`. `make test` — all 78 existing tests must still pass.
8. Build + sideload all three images per existing Makefile flow. All three tags (`csi_driver_image_tag`, `csi_mount_image_tag`, `consumer_recycler_image_tag`) bump to `v0.1.9` in lockstep per `modules-k8s/seaweedfs/variables.tf`.
9. `tofu apply`. `seaweedfs-csi-node` + `seaweedfs-consumer-recycler` DaemonSets roll automatically (`RollingUpdate` strategy). `seaweedfs-mount` is `OnDelete` — explicit `kubectl delete pod` per node, staggered, to cycle.

## Verification — must-pass before declaring work complete

1. **Unit tests:** 8 new cases pass in the fork under `-race`. CSI driver `make test` passes (no regressions in the 78 existing tests).
2. **Live test A — currently-broken mounts are a natural test case.** Per stale-vidmap memory, `[/buckets/pvc-4ce820a6-2ade-4a08-9fe9-712532b4eabf]` (vault audit) and `[/buckets]` (restic readonly) weed mounts on hestia are *currently* logging stale-IP errors. After rolling `v0.1.9` on hestia, observe: do the existing `seaweedfs-mount-jknf4` weed mount subprocesses self-heal without manual SIGKILL + consumer pod delete? If yes, the fix works end-to-end on pre-existing stale state.
3. **Live test B — deliberate volume pod rotation.** Pick a low-stakes PVC on nyx. `kubectl delete pod -l component=volume -n seaweedfs` against nyx's volume pod. Wait 30s for restart. `kubectl exec` into a consumer pod and `cat` a file on the PVC. Should succeed within the inner retry loop, no crashloop, no manual recovery.
4. **Metrics check:** `seaweedfs_filer_vidmap_relookups_total{result="success"}` in grafana has a bump after live test B. `result="same_urls"` staying flat confirms master is propagating topology changes fast enough.

## Risks and mitigations

- **Fork maintenance debt.** Every upstream bump requires rebasing the branch. *Mitigation:* the patch is localised (1 new file, 5 edited, 1 block deleted), so rebase conflicts should be rare and contained. When upstream PR eventually lands, the `replace` directive deletes cleanly.
- **Widened blast radius in upstream code.** The change affects all upstream seaweedfs consumers, not just weed mount (e.g. `filer cat`, `filer ReadAll`, `shell fs.cat`). *Mitigation:* the change is pure improvement (no behavioural regression for the happy path) and has explicit unit tests for the non-stale case. Non-production shell commands already go through the same `StreamContent` path today.
- **Non-invalidating `masterClient` path.** Some upstream consumers may pass a `masterClient` that doesn't implement `CacheInvalidator` (tests, non-production shell commands). *Mitigation:* helper gracefully falls through to the non-invalidating path, identical to today's behaviour. No regressions possible — this is existing code's behaviour preserved as a fallback.
- **Partial-write invalidation side effects.** Current `StreamContent` leaves stale entries in place across partial-write failures; after this change, those entries get invalidated. Theoretically, aggressive invalidation could increase master query volume under high failure rates. *Mitigation:* master query volume scales with failure count, not success count — failure rate spikes already indicate a topology event where master *should* be queried. Strictly better outcome.

## Open questions

None remaining. User has approved scope (option C: factor into shared helper), delivery (go.mod replace to personal fork, upstream PR deferred), and all three design sections.
