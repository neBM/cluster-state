# SeaweedFS CSI Socket Retry — Design Spec

**Status:** Design approved 2026-04-09. Not yet implemented.
**Addresses:** Gap #5 in `docs/superpowers/plans/2026-04-08-seaweedfs-production-readiness-notes.md`.
**Success criterion:** On node reboot, `NodePublishVolume` calls for pre-existing PVCs recover in single-digit seconds in the normal case (mount service becomes reachable within the 30-second retry window) without surfacing an error to kubelet, so consumer pods do not enter kubelet's minute-scale exponential backoff. The retry is observable via metrics and logs, and a k8s Event fires on the rare case where the 30-second budget is exhausted.

## Problem

The notes doc hypothesised that `csi-seaweedfs` crashes at startup when it dials the `seaweedfs-mount` unix socket before the mount service is ready. Reading the actual code shows the real failure mode is subtler but still worth fixing:

- `mountmanager.NewClient()` (`drivers/seaweedfs-csi-driver/pkg/mountmanager/client.go:22-45`) does **not** dial. It constructs an `http.Client` with a lazy `DialContext`. No startup crash is possible.
- The first real dial happens inside `doPost()` → `c.httpClient.Do(req)`, which is only called when kubelet invokes `NodePublishVolume` / `NodeUnpublishVolume`.
- The `http.Client` has a **30-second timeout** (`client.go:40`). On a missing socket, each failed attempt blocks kubelet for up to 30s.
- There is **zero retry logic** in `doPost()` — a single dial failure returns a gRPC error straight to kubelet.
- `driver.Run()` (`drivers/seaweedfs-csi-driver/pkg/driver/driver.go:108-142`) starts the gRPC server immediately with no mount-service readiness check.

So on a node reboot: csi-node registers with kubelet, kubelet immediately calls `NodePublishVolume` for every pre-existing PVC, each call blocks 30s waiting on a missing socket, errors back to kubelet, kubelet retries with exponential backoff (capped at ~2 min/volume). Eventually it resolves — but during the window, consumer pods can flap into CrashLoopBackOff waiting for volumes, logs are noisy, and recovery time is minutes rather than seconds.

Kubelet's own backoff is a safety net, not a fix. The driver should retry transport-level failures close to the source so the hot path recovers in single-digit seconds.

## Scope

In scope:

- Add a bounded retry loop inside `pkg/mountmanager/client.go`'s `doPost()` that retries transport-level dial failures (ENOENT, ECONNREFUSED) for up to 30 seconds with a 1-second interval.
- Apply retry to **all** RPC calls (`Mount` and `Unmount`) by placing the loop at the `doPost()` level, not at each caller.
- Emit structured logs, Prometheus metrics, and a Kubernetes Event on retry-budget exhaustion.
- Add a `/metrics` HTTP endpoint to the csi-node binary (currently absent) using the same `controller-runtime/pkg/metrics.Registry` pattern as the existing consumer-recycler.
- Expose the metrics port on the csi-node DaemonSet via terraform (`modules-k8s/seaweedfs/csi.tf`), including scrape annotations and the downward-API env vars needed for event emission.
- Unit-test the classifier and retry loop; manually smoke-test the Event path in production.

Out of scope:

- FUSE session recovery (Gap #1).
- Mount-restart consumer cycling (Gap #2 — already shipped as `seaweedfs-consumer-recycler`).
- Crash-loop alerting (Gap #3).
- Cache GC (Gap #4).
- Canary probe / full observability stack (Gap #6).
- Upgrade runbook (Gap #7).
- Any fix to the 30-second `http.Client.Timeout` itself — that's a separate concern; the retry loop sits above it.
- Upstreaming the change. The fork is a hard fork (see `memory/project_seaweedfs_driver_monorepo_layout.md`).

## Non-goals

- Not a general-purpose retry framework. The logic lives in `pkg/mountmanager/` and does not attempt to be reusable by the filer gRPC path in `pkg/driver/driver.go`, which already has its own `util.Retry` with different semantics.
- Not a fix for mount-service crashes during normal operation. If the mount service dies mid-request, the retry loop will either recover (if the service restarts within 30s) or surface the failure — both correct behaviours, but recovery of a running-system mount failure is the recycler's job, not this one.

## Architecture

Seven files in `drivers/seaweedfs-csi-driver/` and up to three in `modules-k8s/seaweedfs/` (the RBAC file is only touched if the events permission is missing):

```
drivers/seaweedfs-csi-driver/
├── pkg/mountmanager/
│   ├── client.go              ← modified: doPost wraps call in retry loop,
│   │                             signature gains context.Context parameter
│   ├── client_retry.go        ← NEW: shouldRetryDial classifier, retry constants
│   ├── client_metrics.go      ← NEW: prometheus counters + histogram
│   ├── client_events.go       ← NEW: k8s Event recorder (nilable, graceful-degrade)
│   └── client_retry_test.go   ← NEW: unit tests for classifier + retry loop
├── pkg/driver/
│   └── mounter.go             ← modified: thread ctx from caller into client.Mount/Unmount
├── cmd/seaweedfs-csi-driver/
│   └── main.go                ← modified: --metricsPort flag + metrics http server

modules-k8s/seaweedfs/
├── csi.tf                     ← modified: csi-node DS gains metrics containerPort,
│                                 POD_NAME/POD_NAMESPACE downward-API env,
│                                 prometheus scrape annotations
├── csi-rbac.tf                ← modified (if needed): grant create on events.k8s.io
│                                 in the csi-node's namespace
└── variables.tf               ← modified: bump csi_driver_image_tag,
                                 csi_mount_image_tag, AND consumer_recycler_image_tag
                                 in lockstep to v0.1.2 (unified monorepo version)
```

### Components

**1. Retry classifier (`client_retry.go`)**

Pure functions, zero I/O.

- `shouldRetryDial(err error) bool` — returns true for `syscall.ENOENT`, `syscall.ECONNREFUSED`, `net.OpError` with `Op == "dial"`, and unwraps `url.Error` recursively. Returns false for HTTP status errors (4xx/5xx from a running mount service), `context.Canceled`, `context.DeadlineExceeded`, and any other error.
- Package constants: `dialRetryBudget = 30 * time.Second`, `dialRetryInterval = 1 * time.Second`.
- Unexported `clientRetryConfig` struct with `budget` and `interval` fields for test injection. Defaults to the package constants; tests override to `100ms / 10ms`.

**2. Metrics (`client_metrics.go`)**

Mirrors `pkg/recycler/metrics.go` exactly. Registered in `init()` against `controller-runtime/pkg/metrics.Registry` so both the recycler and the csi-driver share one registry.

- `seaweedfs_csi_dial_retries_total{outcome}` — counter, labels `recovered` or `exhausted`. Cardinality ≤ 2.
- `seaweedfs_csi_dial_retry_duration_seconds` — histogram, default prometheus buckets. Observed on both successful recovery and exhaustion so we can build recovery-time SLOs.

**3. K8s Event recorder (`client_events.go`)**

Nilable, graceful-degrade.

- `NewEventRecorder() *EventRecorder` — reads `POD_NAME` and `POD_NAMESPACE` from env. If either is missing, or if `rest.InClusterConfig()` fails, returns `nil` — **not an error**. A nil recorder means event emission is silently skipped; metrics and logs still work. This is the "driver must start even if k8s API or RBAC is misconfigured" rule.
- `(*EventRecorder).RecordMountServiceUnreachable(err error, elapsed time.Duration)` — emits a `kind=Warning reason=MountServiceUnreachable` event on the csi-node Pod (resolved from the env vars), using the `client-go` `EventsV1Interface`. Message format: `"mount service at %s unreachable after %s during RPC: %v"`.

**4. Modified client (`client.go`)**

- `Client` struct gains two fields: `retry clientRetryConfig` and `events *EventRecorder` (nilable).
- `NewClient()` constructs the retry config from package defaults and calls `NewEventRecorder()` best-effort.
- `doPost()` signature changes from `doPost(path string, payload, out any) error` to `doPost(ctx context.Context, path string, payload, out any) error`.
- The body of `doPost()` wraps the existing `c.httpClient.Do(req)` in `wait.PollUntilContextTimeout(ctx, c.retry.interval, c.retry.budget, true, fn)`:
  - On retryable error, the poll function returns `(false, nil)` to keep polling.
  - On non-retryable error, returns `(false, err)` to fail fast.
  - On success, returns `(true, nil)`.
  - Budget-exhaustion surfaces as `wait.ErrWaitTimeout`, which is wrapped: `fmt.Errorf("mount service at %s unreachable after %s: %w", c.baseURL, elapsed, err)`.
- After the poll:
  - Zero retries used (first-attempt success): no metrics touch, no logs.
  - One or more retries, recovered: emit WARN log on first retry, INFO log on recovery, increment `recovered` counter, observe duration.
  - Exhausted: emit ERROR log, increment `exhausted` counter, observe duration, call `events.RecordMountServiceUnreachable(err, elapsed)` if recorder is non-nil.

**5. Modified `mounter.go`**

- `Mounter.Mount(target)` → `Mounter.Mount(ctx context.Context, target string)`.
- `mountServiceUnmounter.Unmount()` → `Unmount(ctx context.Context)`.
- Callers in `pkg/driver/nodeserver.go` pass the gRPC request's context through.

**6. Modified `main.go` (csi-driver)**

- New flag `--metricsPort int` (default `9808`, CSI convention).
- Before `drv.Run()`, starts `http.Server{Addr: ":9808", Handler: promhttp.HandlerFor(metrics.Registry, promhttp.HandlerOpts{})}` on a goroutine.
- Registers a SIGTERM handler to `srv.Shutdown(ctx)` gracefully.
- Zero-port (`--metricsPort=0`) disables the metrics server entirely — useful for tests and for the controller component that doesn't need metrics.

**7. Terraform (`csi.tf`)**

On the csi-node DaemonSet only (controller doesn't run `doPost`):

- Add `container_port { name = "metrics", container_port = 9808 }` on the `csi-seaweedfs` container.
- Add downward-API env vars:
  ```hcl
  env { name = "POD_NAME"      value_from { field_ref { field_path = "metadata.name"      } } }
  env { name = "POD_NAMESPACE" value_from { field_ref { field_path = "metadata.namespace" } } }
  ```
- Add pod-template annotations:
  ```hcl
  "prometheus.io/scrape" = "true"
  "prometheus.io/port"   = "9808"
  "prometheus.io/path"   = "/metrics"
  ```
- Bump **all three** image-tag variables in `variables.tf` to `v0.1.2` in lockstep — `csi_driver_image_tag`, `csi_mount_image_tag`, and `consumer_recycler_image_tag`. The monorepo uses a unified semver-from-zero version stream (`Makefile` already encodes this with a single `VERSION` variable). This release moves the driver and mount off the legacy `v1.4.8-split` tag; the recycler also bumps from `v0.1.1` to `v0.1.2` even though no code changes for it, because the convention is "all three move together". See `memory/project_seaweedfs_monorepo_versioning.md`.

**8. RBAC (`csi-rbac.tf`)**

Audit during plan-writing. The csi-node ServiceAccount needs `create` on `events` in `events.k8s.io/v1` in the csi-node's namespace. Add a rule if missing. This is a no-op for the graceful-degrade path — if the rule is absent, the nilable recorder logs but doesn't crash — but the rule should be present so the Event actually fires in production.

### Boundaries and testability

- **`client_retry.go`** — pure, trivially unit-testable.
- **`client_metrics.go`** — package-level vars, no per-instance state.
- **`client_events.go`** — isolated behind `NewEventRecorder` constructor; the nil-return-on-missing-env path is unit-tested; the actual `Create()` call is pass-through and validated by manual smoke test.
- **`client.go`** — `doPost` is the only non-trivial function and its retry loop is covered by the integration test in `client_retry_test.go` using `httptest` + a controllable `net.Listener`.

## Data flow

### Happy path on node reboot

```
kubelet → csi-node gRPC → NodePublishVolume(ctx, req)
  → Mounter.Mount(ctx, target)
    → client.Mount(ctx, req)
      → doPost(ctx, "/mount", req, &resp)
        → wait.PollUntilContextTimeout(ctx, 1s, 30s, true, fn)
            t=0.0s  httpClient.Do → dial unix:///var/lib/seaweedfs-mount/sw-mount.sock
                    → syscall.ENOENT          (socket not yet created)
                    → shouldRetryDial = true
                    → log WARN once: "mount service unreachable, retrying (budget=30s)"
                    → return (false, nil)
            t=1.0s  dial → ENOENT           → return (false, nil)
            t=2.0s  dial → ECONNREFUSED     → return (false, nil)
            t=3.0s  dial → 200 OK           → return (true, nil)
        → wait returns nil
        → metrics: seaweedfs_csi_dial_retries_total{outcome="recovered"}++
        → metrics: seaweedfs_csi_dial_retry_duration_seconds.Observe(3.0)
        → log INFO: "mount service reachable after 3.0s (4 attempts)"
        → parse response, return
      → MountResponse{...}
```

### Error outcomes

| Scenario | Classifier | Loop exit | Returned error | Metrics | Event |
|---|---|---|---|---|---|
| First attempt succeeds | n/a | success | nil | not touched | none |
| Socket appears within 30s | retryable | success | nil | `recovered` + duration | none |
| Socket never appears in 30s | retryable | exhausted | wrapped `wait.ErrWaitTimeout` | `exhausted` + duration | `MountServiceUnreachable` |
| HTTP 500 from live service | **not retryable** | immediate | pass through | not touched | none |
| Request context cancelled | not retryable | immediate | `context.Canceled` | not touched | none |

### Classifier logic

```go
func shouldRetryDial(err error) bool {
    if err == nil {
        return false
    }
    if errors.Is(err, syscall.ENOENT) {
        return true
    }
    if errors.Is(err, syscall.ECONNREFUSED) {
        return true
    }
    var opErr *net.OpError
    if errors.As(err, &opErr) && opErr.Op == "dial" {
        return true
    }
    var urlErr *url.Error
    if errors.As(err, &urlErr) {
        return shouldRetryDial(urlErr.Err)
    }
    return false
}
```

**Critical:** HTTP 4xx/5xx responses are NOT retried. A status-code error means the service is up and responded — the dial succeeded. Only transport-level dial failures qualify. This prevents masking real bugs (e.g., a malformed request) behind retry noise.

### Context propagation

`doPost` gains a `context.Context` parameter sourced from the caller's gRPC request context, which already flows in from `NodePublishVolume`. This ensures:

- Kubelet can cancel a stuck call via gRPC cancellation (e.g., on its own RPC deadline).
- The retry loop respects cancellation through `wait.PollUntilContextTimeout`.
- No goroutine leaks on kubelet-driven cancellation.

### Logging policy

- **WARN (once per loop)**: on the first retry, `"mount service unreachable at <endpoint>, retrying (budget=30s)"`. Subsequent retries are silent to avoid log spam.
- **INFO (once on recovery)**: `"mount service reachable after %.1fs (%d attempts)"`.
- **ERROR (once on exhaustion)**: `"mount service unreachable after 30s, giving up; kubelet will retry"`.
- Log package: `github.com/seaweedfs/seaweedfs/weed/glog` to match the rest of the driver.

## Testing

### Unit tests (`client_retry_test.go`)

Fast, hermetic, no Kubernetes. Three test files using standard library + `httptest` + `prometheus/client_golang/prometheus/testutil`.

**Test 1 — Classifier table test (`TestShouldRetryDial`)**

| Case | Input | Expected |
|---|---|---|
| nil error | `nil` | `false` |
| raw ENOENT | `syscall.ENOENT` | `true` |
| raw ECONNREFUSED | `syscall.ECONNREFUSED` | `true` |
| net.OpError dial ENOENT | `&net.OpError{Op:"dial", Err:syscall.ENOENT}` | `true` |
| net.OpError read (non-dial) | `&net.OpError{Op:"read", Err:io.EOF}` | `false` |
| url.Error wrapping dial failure | `&url.Error{Err:&net.OpError{Op:"dial", Err:syscall.ENOENT}}` | `true` |
| HTTP 500 error (not a net error) | `fmt.Errorf("500 Internal Server Error")` | `false` |
| context.Canceled | `context.Canceled` | `false` |
| context.DeadlineExceeded | `context.DeadlineExceeded` | `false` |

**Test 2 — Retry loop integration test (`TestDoPostRetries`)**

Uses `httptest.NewUnstartedServer` to get a handler whose backing `net.Listener` the test controls. Retry config overridden to `budget=100ms, interval=10ms` so all subtests run in <500ms. Four subtests:

- `happy_path`: listener up immediately, single dial succeeds. Assert no retries counter increment, no histogram observation.
- `recovers_after_delay`: listener closed initially; goroutine re-binds it after 30ms. Assert `doPost` returns success, `recovered` counter +1, histogram has one observation ≈30ms.
- `budget_exhausted`: listener never comes up. Assert error wraps `wait.ErrWaitTimeout`, message contains `"mount service"` and `"unreachable"`, `exhausted` counter +1.
- `non_retryable_500`: listener up but returns HTTP 500. Assert error returned within 10ms (no retry occurred), counters unchanged.

**Test 3 — Context cancellation (`TestDoPostContextCancelled`)**

Start a loop with a 1-second budget. Spawn a goroutine that cancels the context after 50ms. Assert `doPost` returns with `context.Canceled` (not `wait.ErrWaitTimeout`) within 100ms of cancellation.

**Test 4 — Event recorder env fallback (`TestNewEventRecorder_NoEnv`)**

With `POD_NAME` unset, assert `NewEventRecorder()` returns `(nil, nil)` — no error, no panic. A nil recorder is a valid runtime state.

### Metrics assertions

Use `testutil.ToFloat64(counter.WithLabelValues("recovered"))` from `prometheus/client_golang/prometheus/testutil` to read counter values in-process. Avoids scraping `/metrics` in tests.

### What is NOT unit-tested

- The k8s Event recorder's actual `Create()` call against an API server. That's a client-go pass-through; mocking client-go for this is boilerplate-heavy for trivial code. Validated manually in production.
- The metrics HTTP endpoint in `main.go`. Standard `promhttp.HandlerFor` — re-testing the prom library adds nothing.

### TDD order

The `superpowers:test-driven-development` discipline applies. Write tests before the code they cover:

1. `TestShouldRetryDial` — fails (function doesn't exist).
2. Write `shouldRetryDial` — classifier test passes.
3. `TestDoPostRetries/happy_path` — passes trivially (existing behaviour).
4. `TestDoPostRetries/recovers_after_delay` — fails (no retry loop yet).
5. Write retry loop in `doPost` using `wait.PollUntilContextTimeout` — test passes.
6. `TestDoPostRetries/budget_exhausted` — passes once loop is in place.
7. `TestDoPostRetries/non_retryable_500` — passes if classifier is correct.
8. `TestDoPostContextCancelled` — may fail; fix by ensuring the poll's context is correctly threaded.
9. Add metrics, one counter at a time, each covered by an assertion in the existing subtests.
10. Add event recorder last, with only the env-fallback test.

### Manual validation (post-sideload smoke test)

1. **Normal reboot recovery.** On nyx (arm64, lightest load): `sudo systemctl restart k3s`. Watch csi-node logs — expect zero 30-second blocks, at most one WARN + one INFO per NodePublishVolume during the reboot window. Consumer pods should not enter CrashLoopBackOff.
2. **Forced retry-exhaustion.** Patch the `seaweedfs-mount` DaemonSet with a nonexistent node selector to make it unschedulable, then delete a consumer pod on the target node to force a NodePublishVolume. Expect: csi-node log shows WARN then ERROR after 30s, `kubectl get events --field-selector reason=MountServiceUnreachable` shows one Warning event.
3. **Recovery after unblock.** Remove the node selector patch. Expect consumer pod to recover on kubelet's next retry; metrics show the eventual `recovered` increment.
4. **Metrics scrape.** `kubectl port-forward` to the csi-node pod and `curl localhost:9808/metrics | grep seaweedfs_csi_dial` — confirm both counters and histogram are exposed.

## Rollout

1. **Implement on a feature branch** in the iac/cluster-state repo (driver is in-tree; no external repo involved).
2. **Unit tests pass** — `go test ./drivers/seaweedfs-csi-driver/pkg/mountmanager/...` green.
3. **Build multi-arch images** from the Makefile with `VERSION=v0.1.2`. This produces three image tags in lockstep: `seaweedfs-csi-driver:v0.1.2`, `seaweedfs-mount:v0.1.2`, and `seaweedfs-consumer-recycler:v0.1.2` (the recycler image is identical to v0.1.1 in content but re-tagged so all three components move together — the unified-monorepo-version convention). Because the Makefile is host-arch only today, this means running `docker buildx` manually or on each node. Plan will spell out exact commands.
4. **Sideload** to all three nodes (registry is backed by SeaweedFS — chicken-egg; see `memory/feedback_always_sideload_seaweedfs_images.md`).
5. **Terraform apply** with all three image-tag variables bumped to `v0.1.2`. This updates the csi-node DaemonSet spec, the controller Deployment, and the recycler DaemonSet. Controller rolls on its own; csi-node uses `OnDelete` strategy (inherited from the split), so it does not cycle until step 6. The recycler DaemonSet has a normal rolling update, so it cycles immediately — that is acceptable because the recycler image content is unchanged and the recycler itself tolerates restarts.
6. **Cycle csi-node pods one at a time**, per the Gap #7 upgrade procedure (which doesn't exist yet — during this rollout, the procedure is ad-hoc: delete the csi-node pod on one node, wait for it to come back, confirm `NodePublishVolume` still works by re-mounting a test PVC, move to next node).
7. **Manual smoke test** as above on nyx first, then hestia and heracles.
8. **Commit the tag bump** and the terraform changes atomically.

## Risks

- **Changing `doPost` signature** is a ripple change through all callers in `pkg/driver/`. Must update `Mount`/`Unmount` signatures in `mounter.go` and every invocation in `nodeserver.go` consistently. Compiler catches any miss.
- **Metrics port collision.** Port `9808` is the de-facto CSI metrics convention but not mandated — need to verify nothing else on the csi-node pod is already bound to it. Low risk (the csi-seaweedfs container currently exposes no HTTP port).
- **RBAC regression.** If `csi-rbac.tf` doesn't already grant `create` on events, the event emission fails silently (graceful degrade). The driver still works. Worst case is missing diagnostics, not an outage.
- **Context cancellation semantics.** Kubelet may cancel a gRPC call at its own RPC deadline (default 2 minutes for CSI). With a 30-second retry budget, this is not a concern — the retry will have either succeeded or exhausted well before kubelet's deadline. Confirmed by `TestDoPostContextCancelled`.
- **Unit tests rely on time-based scheduling** (`100ms/10ms` config). Flakiness risk on overloaded CI. Mitigation: generous margins (histogram assertion uses `≥25ms` not `==30ms`), no hard `sleep` comparisons.

## Open questions

None blocking. A couple resolved during brainstorming:

- **Belt-and-suspenders terraform startup probe?** Rejected — the driver fix is sufficient and a probe would mask the retry loop from running at all on cold boot, defeating the metrics signal.
- **Upstream the fix?** No — the fork is a hard fork (`memory/project_seaweedfs_driver_monorepo_layout.md`).
- **Per-call retry vs. shared retry at client level?** Decided at `doPost()` level so all RPC calls benefit automatically without each caller needing to opt in.

## References

- Problem statement: `docs/superpowers/plans/2026-04-08-seaweedfs-production-readiness-notes.md` §Gap 5.
- Prior art: `docs/superpowers/specs/2026-04-08-seaweedfs-consumer-recycler-design.md` — same spec style, same metrics/RBAC conventions.
- Memory: `project_seaweedfs_driver_monorepo_layout.md`, `project_seaweedfs_monorepo_versioning.md`, `feedback_always_sideload_seaweedfs_images.md`, `feedback_reputable_libraries.md`, `feedback_prefer_resilience_over_minimal_diff.md`.
- Code read:
  - `drivers/seaweedfs-csi-driver/pkg/mountmanager/client.go` (current doPost, no retry)
  - `drivers/seaweedfs-csi-driver/pkg/mountmanager/socket.go` (socket path derivation)
  - `drivers/seaweedfs-csi-driver/pkg/driver/mounter.go` (Mount/Unmount callers)
  - `drivers/seaweedfs-csi-driver/pkg/driver/driver.go` (Run loop, no startup probe)
  - `drivers/seaweedfs-csi-driver/pkg/recycler/metrics.go` (metrics pattern to mirror)
  - `drivers/seaweedfs-csi-driver/cmd/seaweedfs-csi-driver/main.go` (no metrics server today)
