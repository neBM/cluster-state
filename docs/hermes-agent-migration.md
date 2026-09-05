# Hermes Agent cutover to Kubernetes

This is a one-time migration from `/home/ben/.hermes` on Hestia to the retained `default/hermes-agent-state` PVC. The only authority rule is simple: **never run the Hestia and Kubernetes gateways at the same time**.

## Gated activation state

This activation revision makes the native Kubernetes path the Git desired state:

- Deployment `default/hermes-agent` has `replicas: 1` and `strategy: Recreate`;
- its container command is `/opt/hermes/docker/entrypoint-dispatch.sh gateway run`;
- its readiness and liveness probes call the webhook `/health` endpoint;
- state uses the `local-path-retain` PVC and the Service is ClusterIP-only; and
- there is no candidate mode, migration Pod, Ingress, or externally exposed Service.

Live activation remains gated. With this revision on Git `main`, the parent `cluster-state`, `apps`, and `observability-ui` Kustomizations remain suspended; therefore the live Deployment stays at zero replicas with no target Pod even though Git desires one. Allow the `cluster-state` GitRepository to fetch the exact activation revision, then it may be suspended to pin that artifact through the cutover handoff.

Until the user-run cutover resumes `observability-ui`, the live selectorless `default/hermes-webhook` Service and its static EndpointSlice still route to Hestia at `192.168.1.5`. This revision adds the native Hermes selector but deliberately retains the static EndpointSlice manifest as an inert `endpoints: []` resource and removes its temporary prune-disabled annotation. Removing the prune-disabled file in this same revision would leave the live Hestia endpoint behind.

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

3. Merge this tiny activation revision containing exactly these native desired-state changes:

   - change the `apps/hermes-agent` Deployment from `replicas: 0` to `replicas: 1`;
   - add selector `app.kubernetes.io/name: hermes-agent` to `infrastructure/observability-ui/grafana/service-default-hermes-webhook.yaml`; and
   - keep `infrastructure/observability-ui/grafana/endpointslice-default-hermes-webhook.yaml` referenced, remove its prune-disabled annotation, and replace the Hestia endpoint with `endpoints: []`.

   Keep all three Kustomizations suspended. Do not scale the live Deployment manually while Hestia Hermes is active.

4. Set the activation merge commit and request a source refresh. Wait until the fetched artifact exactly matches it:

   ```bash
   ACTIVATION_SHA='<40-lowercase-hex activation merge commit>'
   REVISION="main@sha1:${ACTIVATION_SHA}"
   kubectl -n flux-system annotate --overwrite gitrepository/cluster-state \
     "reconcile.fluxcd.io/requestedAt=$(date -u +%s%N)"
   until [ "$(kubectl -n flux-system get gitrepository cluster-state \
     -o jsonpath='{.status.artifact.revision}')" = "$REVISION" ]; do sleep 2; done
   printf 'artifact ready: %s\n' "$REVISION"
   kubectl -n flux-system patch gitrepository cluster-state --type=merge \
     -p '{"spec":{"suspend":true}}'
   ```

Do not proceed unless the GitRepository still reports the exact activation artifact, all three Kustomizations show `SUSPENDED=true`, the live target Deployment still desires zero replicas, and no Hermes target Pod exists.

## User-run cutover

From an independent SSH shell on Hestia, repeat preflight and then run the cutover with the exact revision supplied by the controller. The commands below are repo-relative; at handoff the controller will provide the exact absolute command from the activation worktree in use:

```bash
./scripts/hermes-agent-cutover.sh preflight
./scripts/hermes-agent-cutover.sh cutover "$REVISION"
```

The cutover command resolves the destination from the live PVC and PV, invokes the supported `/home/ben/.local/bin/hermes gateway stop` path so Hermes records a planned stop, then strictly proves `ActiveState=inactive` and `MainPID=0` before rechecking target zero and copying selected durable state. It validates copied SQLite databases, sets ownership to `10000:10000`, then resumes in this order: `apps`, `observability-ui`, `cluster-state`. It waits for the Deployment rollout, checks the native Hermes ClusterIP health, reconciles observability, then uses bounded retries to tolerate ordinary EndpointSlice-controller propagation before proving the switched `default/hermes-webhook` ClusterIP reaches `/health` and reconnecting `cluster-state`.

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

## Post-success cleanup

After the result is accepted, make a routine cleanup commit that deletes the now-inert static EndpointSlice file and its kustomization reference. Because activation first removed the prune-disabled annotation, normal Flux pruning can then remove that inert object safely while the Service continues to use controller-managed endpoints. Retire one-shot cutover and migration assets as appropriate, while retaining useful steady-state validation.

## Failure and bounded recovery

The failure boundary is whether Kubernetes activation was attempted:

- **Before activation:** after stopping Hestia but before attempting `reconcile apps`, the script re-suspends the parent, `apps`, and `observability-ui`, scales the target to zero, proves zero desired replicas and no target Pods, then restores Hestia automatically. It polls source activity and `/health` for up to about 60 seconds so ordinary startup is not misclassified. No target could have accepted writes and the original static Hestia EndpointSlice remains in place. If fencing, zero proof, restart, or bounded health proof fails, Hestia remains stopped.
- **After an activation attempt:** the script treats the target as potentially having accepted writes. It re-suspends the same three reconcilers, attempts to scale and prove the target at zero, and deliberately leaves Hestia stopped even when target zero is proven.

Post-activation recovery is controller-owned and fail-closed. First inspect and reconcile any target-side changes. While the reconcilers remain suspended, revert the tiny activation desired-state change: restore `replicas: 0`, remove the Hermes selector from `default/hermes-webhook`, and restore the static Hestia endpoint plus its temporary prune-disabled annotation. Then reconcile and verify the Hestia webhook route, prove both zero desired replicas and no target Pods, and only then start and health-check Hestia Hermes. Any failed or unknown Kubernetes read, write, reconciliation, route check, or zero proof stops this sequence with Hestia still stopped; do not continue through an uncertain result.
