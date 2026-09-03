# Hermes Agent migration to Kubernetes

This is a singleton-authority migration from `/home/ben/.hermes` on Hestia to the retained `default/hermes-agent-state` PVC. Never run the Hestia gateway and Kubernetes gateway concurrently.

## State allowlist and exclusions

The migration copies only:

- top-level files: `config.yaml`, `.env`, `auth.json`, `SOUL.md`, `mcp.json`, channel directory/alias state, Feishu pairing, webhook subscriptions, Matrix threads, and the Grafana webhook HMAC secret;
- databases: `state.db`, `hermes_state.db`, `projects.db`, `kanban.db`, `memory_store.db`, `verification_evidence.db`, and `response_store.db`;
- directories: sessions, skills, plugins, cron, memories, platforms, MCP tokens, scripts, plans, workflows, Kanban, pairing, pending messages, and hooks; and
- the `codexlane`, `implementer`, `observer`, `orchestrator`, and `reviewer` profiles, using the corresponding profile configuration, database, secret, and durable-directory allowlists.

Nested symlinks are preserved without being followed. The copy excludes virtual environments, source/home/repository/worktree/workspace trees, `.git`, dependency trees, caches, logs, backups, checkpoints, temporary data, Python/test caches, profile `bin`, and profile LSP state. The stopped-source final copy converges stale target entries first, requires every present root/profile allowlisted database to have SQLite magic, also discovers nested databases by magic, recovers them, selects DELETE journal mode, and removes only their associated sidecars. Unrelated suffix-named selected files remain data.

## Parent-owned preparation before the user launch

The parent/operator completes every safe pre-stop action before asking the user to run the one-shot:

1. Provision and validate the inert candidate and retained PVC; run `preflight`, `initial-sync`, and the candidate smoke checks.
2. Suspend the `flux-system/cluster-state` parent Kustomization, `flux-system/apps` Kustomization, and `flux-system/cluster-state` GitRepository. Keep the target Deployment inactive with no target, migration, or retained-PVC consumer Pod.
3. Fetch the reviewed activation revision into source-controller, then leave the GitRepository suspended with `status.artifact.revision` exactly `main@sha1:<40 lowercase hex>`. Hand that exact revision to the user.
4. While `hermes-gateway.service` is still active, atomically install an owner-`0600` empty `/home/ben/.hermes/gateway-authority.enabled` token and load this exact owner-`0600` drop-in at `/home/ben/.config/systemd/user/hermes-gateway.service.d/20-authority-fence.conf`:

   ```ini
   [Unit]
   ConditionPathExists=/home/ben/.hermes/gateway-authority.enabled
   [Service]
   KillMode=control-group
   TimeoutStopSec=90s
   SendSIGKILL=yes
   ```

5. Prove the user manager needs no daemon reload, the source is active, the effective unit has `KillMode=control-group`, `SendSIGKILL=yes`, and a semantically parsed 90,000,000 μs stop timeout, `/home/ben/.kube/config` is readable, and `kube-system` UID is `16710d5a-45ec-4b64-a101-b1a4db28a6e7`.

The one-shot repeats only decision-relevant checks. It first takes a nonblocking process-lifetime lock on the fixed source directory; contention fails before result or authority mutation. No drain tokens, optional-platform health quorum, transient-unit identity, or `INVOCATION_ID` is required.

## User one-shot command

Set the exact value supplied by the parent:

```bash
REVISION='main@sha1:<replace-with-the-40-lowercase-hex-SHA>'
```

From an independent Hestia SSH shell, run exactly:

```bash
/home/ben/Documents/cluster-state/scripts/hermes-agent-cutover.sh "$REVISION"
```

Alternatively, use an independently supervised user unit:

```bash
systemd-run --user --unit=hermes-k8s-cutover.service --collect --wait --pipe \
  --property=Type=exec --property=RuntimeMaxSec=90min \
  /home/ben/Documents/cluster-state/scripts/hermes-agent-cutover.sh "$REVISION"
```

Normal duration is roughly 20 minutes. The final-copy timeout remains 3300 seconds, activation polling is at most 11 minutes, and the documented supervised command imposes a 90-minute hard process bound. Do not launch from inside the source gateway cgroup.

## Result meanings

The owner-`0600` atomic result is `/home/ben/.hermes/k8s-cutover-result.json`. It records `state`, `lastPhase`, exact `revision`, and `fence`:

- `started`: the initial result was written and read back; the source is not yet claimed fenced.
- `synced`: final sync completed, the token is absent, and the source is inactive with `MainPID=0`.
- `activation-attempted`: durably written before the apps Kustomization patch. This or `success` blocks rerunning the one-shot.
- `success`: apps acknowledged the fresh request token at the exact revision/current generation with `Ready=True`, `verify-target` passed, and the source remained fenced.
- `failure`: inspect `lastPhase`, `revision`, and `fence`. `verified-fenced` means token absence plus inactive/`MainPID=0` were proved; `fence-unknown` means they were not.

## Fail-fenced behavior

After its destructive trap is armed, the launcher removes and parent-directory-fsyncs the token, proves it absent, and only then enters helper final sync. Every error, signal, or premature exit repeats token removal and stops the source service; it never starts Hestia. It records or reports `verified-fenced` only after direct proof; otherwise it reports `fence-unknown`. Treat `fence-unknown` as an authority incident: stop both sides and establish actual token, source, Pod, and PVC-consumer state before recovery.

## Target-first recovery

Recovery always removes possible Kubernetes authority first: keep the parent and GitRepository suspended, suspend apps, stop/scale the target, and prove no target, migration, or retained-PVC consumer Pod exists. Only then decide which state is authoritative.

If activation was attempted, preserve and reconcile target-side writes before any source restoration; never recreate the source token directly from an uncertain or exposed state. If failure was definitively before activation, target absence is proved, and the stopped source is selected as authoritative, recreate the exact owner-`0600` token with a parent-directory fsync and use the existing target-first `rollback` helper. A later Kubernetes activation requires another stopped-source final sync.
