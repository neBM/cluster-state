# Hermes Agent cutover to Kubernetes

This is a one-time migration from `/home/ben/.hermes` on Hestia to the retained `default/hermes-agent-state` PVC. The only authority rule is simple: **never run the Hestia and Kubernetes gateways at the same time**.

## Current inactive state

`apps/hermes-agent` is ordinary Kubernetes desired state:

- Deployment `default/hermes-agent` has `replicas: 0` and `strategy: Recreate`;
- its future container command is `/opt/hermes/docker/entrypoint-dispatch.sh gateway run`;
- its readiness and liveness probes call the webhook `/health` endpoint;
- state uses the `local-path-retain` PVC and the Service is ClusterIP-only; and
- there is no candidate mode, migration Pod, Ingress, or externally exposed Service.

Merge and reconcile this inactive preparation before creating the activation change. Do not scale the Deployment manually while Hestia Hermes is active.

## Controller preparation

The controller performs these steps while `hermes-gateway.service` is still active.

1. Confirm the inactive preparation is on `main` and reconciled. Run the read-only host preflight:

   ```bash
   ./scripts/hermes-agent-cutover.sh preflight
   ```

2. Suspend the parent and both consumers so they cannot activate during the copy:

   ```bash
   export KUBECONFIG=/home/ben/.kube/config
   kubectl -n flux-system patch kustomization cluster-state --type=merge -p '{"spec":{"suspend":true}}'
   kubectl -n flux-system patch kustomization apps --type=merge -p '{"spec":{"suspend":true}}'
   kubectl -n flux-system patch kustomization observability-ui --type=merge -p '{"spec":{"suspend":true}}'
   kubectl -n flux-system get kustomization cluster-state apps observability-ui \
     -o custom-columns=NAME:.metadata.name,SUSPENDED:.spec.suspend
   ```

3. Create and merge a separate tiny activation MR containing exactly these native desired-state changes:

   - change the `apps/hermes-agent` Deployment from `replicas: 0` to `replicas: 1`;
   - add selector `app.kubernetes.io/name: hermes-agent` to `infrastructure/observability-ui/grafana/service-default-hermes-webhook.yaml`; and
   - remove `infrastructure/observability-ui/grafana/endpointslice-default-hermes-webhook.yaml` from its kustomization and delete that static EndpointSlice manifest.

   The current `default/hermes-webhook` Service is selectorless and its static EndpointSlice routes to Hestia at `192.168.1.5`; leaving that route in place would break Grafana webhooks after Hestia stops. Do not make these activation changes in the inactive preparation commit. Keep the three Kustomizations suspended. The `cluster-state` GitRepository remains active so source-controller can fetch the activation merge.

4. Set the activation merge commit and request a source refresh. Wait until the fetched artifact exactly matches it:

   ```bash
   ACTIVATION_SHA='<40-lowercase-hex activation merge commit>'
   REVISION="main@sha1:${ACTIVATION_SHA}"
   kubectl -n flux-system annotate --overwrite gitrepository/cluster-state \
     "reconcile.fluxcd.io/requestedAt=$(date -u +%s%N)"
   until [ "$(kubectl -n flux-system get gitrepository cluster-state \
     -o jsonpath='{.status.artifact.revision}')" = "$REVISION" ]; do sleep 2; done
   printf 'artifact ready: %s\n' "$REVISION"
   ```

Do not proceed unless all three Kustomizations still show `SUSPENDED=true`, the target Deployment still desires zero replicas, and no Hermes target Pod exists.

## User-run cutover

From an independent SSH shell on Hestia, repeat preflight and then run the cutover with the exact revision supplied by the controller. The commands below are repo-relative; at handoff the controller will provide the exact absolute command from the activation worktree in use:

```bash
./scripts/hermes-agent-cutover.sh preflight
./scripts/hermes-agent-cutover.sh cutover "$REVISION"
```

The cutover command resolves the destination from the live PVC and PV, stops and verifies the Hestia service, copies selected durable state with `rsync`, validates copied SQLite databases, sets ownership to `10000:10000`, then resumes in this order: `apps`, `observability-ui`, `cluster-state`. It waits for the Deployment rollout, checks the native Hermes ClusterIP health, reconciles observability, then proves the switched `default/hermes-webhook` ClusterIP reaches `/health` before reconnecting `cluster-state`.

The copy preserves Hermes configuration, credentials, databases, sessions, skills, plugins, cron, memories, platforms, scripts, plans, workflows, Kanban, pairing, pending messages, hooks, and durable profile state. It excludes source checkouts, virtual environments, caches, logs, backups and snapshots, checkpoints, worktrees and workspaces, rootless container storage, profile runtime/build state, temporary/LSP/bin trees, runtime result, PID, and lock files, and obsolete top-level state-database recovery artifacts.

## Success checks

The script prints `cutover success` only after the target health check and all three reconciliations. Confirm the final singleton state:

```bash
systemctl --user show hermes-gateway.service -p ActiveState -p MainPID
kubectl -n default get deployment hermes-agent
kubectl -n default get pods -l app.kubernetes.io/name=hermes-agent -o wide
CLUSTER_IP="$(kubectl -n default get service hermes-agent -o jsonpath='{.spec.clusterIP}')"
curl --fail --silent --show-error "http://${CLUSTER_IP}:8644/health"
kubectl -n flux-system get kustomization cluster-state apps observability-ui
```

Expected: Hestia is `ActiveState=inactive` with `MainPID=0`, the Deployment is available at one replica, exactly one Hermes Pod is Ready on Hestia, health succeeds, and the three Kustomizations are resumed and Ready.

## Failure and bounded recovery

The failure boundary is whether Kubernetes activation was attempted:

- **Before activation:** after stopping Hestia but before attempting `reconcile apps`, the script re-suspends the parent, `apps`, and `observability-ui`, scales the target to zero, proves zero desired replicas and no target Pods, then restores Hestia automatically. No target could have accepted writes and the original static Hestia EndpointSlice remains in place. If fencing, zero proof, restart, or health proof fails, Hestia remains stopped.
- **After an activation attempt:** the script treats the target as potentially having accepted writes. It re-suspends the same three reconcilers, attempts to scale and prove the target at zero, and deliberately leaves Hestia stopped even when target zero is proven.

Post-activation recovery is controller-owned and fail-closed. First inspect and reconcile any target-side changes. While the reconcilers remain suspended, revert the tiny activation desired-state change: restore `replicas: 0`, remove the Hermes selector from `default/hermes-webhook`, and restore its static Hestia EndpointSlice and kustomization reference. Then reconcile and verify the Hestia webhook route, prove both zero desired replicas and no target Pods, and only then start and health-check Hestia Hermes. Any failed or unknown Kubernetes read, write, reconciliation, route check, or zero proof stops this sequence with Hestia still stopped; do not continue through an uncertain result.
