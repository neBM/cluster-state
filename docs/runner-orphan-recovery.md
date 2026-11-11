# CI Pod exception recovery after Runner manager loss

## Ownership and scope

Infrastructure recovery owns this exception procedure. An alert or requester opens a
specific recovery review; it does not assign recurring manual sweeps to CI users or
promise a response window. The requester and infrastructure recovery explicitly
verify each case. Unknown cases remain retained and escalated, with capacity risk
recorded rather than silently accepted as reclaimed space.

Normal success, failure and cancellation cleanup stays Runner-owned. With separately
qualified Pod-owned storage, normal Pod deletion lets native ownership reclaim that
storage. This procedure neither enables that later storage change nor installs a
cleaner, controller, timer, privilege grant or age-only deletion policy. Existing CI
maintenance admission/drain/restore and GC procedures remain separate and unchanged.

## Existing alert and limitations

`ci-pod-suspected-orphan-review-api` lives in the existing Grafana provisioning file
`infrastructure/observability-ui/grafana/_grafana_alert_rules.yaml`. It queries the
existing VictoriaMetrics `prometheus` datasource for `kube_pod_created` joined to the
active `kube_pod_status_phase` by namespace, Pod name **and UID**. It aggregates away
duplicate scrape labels before joining, then excludes current durable infrastructure
controller owners using `unless on(namespace, pod, uid)` against the existing
`kube_pod_owner` metric with `owner_is_controller="true"` and
`owner_kind=~"DaemonSet|ReplicaSet|StatefulSet"`. No Pod-label metric or label allowlist
is needed. Standalone and Pod/Job-owned CI candidates, including non-Runner child
Pods, remain in scope in every phase. This is not a blanket exclusion of managed
Pods: review must establish actual Runner ownership, never infer it from the alert.
Missing owner data can produce review noise; it never grants deletion permission.

A Pod older than six hours, continuously observed for ten minutes, requires review
as a **suspected orphan**. Six hours is a triage threshold, not a maximum supported
job duration, terminal grace period, proof of manager loss or deletion permission.
Legitimate long jobs can alert. Pending, Running, Unknown and terminal Pods all
remain observable; only the verification below can authorize recovery. A standalone
Pod's deadline can stop execution but does not delete the Pod or reclaim its volumes.

Warning severity uses the existing `hermes-notify-only` route and existing downstream
Matrix notification path, not the critical actionable-remediation route. Do not add
a new webhook or scheduler. Provisioning, rule evaluation, and actual downstream
notification delivery must be checked by the deployment owner before relying on
this signal. Source rendering alone cannot establish delivery.

No matching CI Pods is normal (`noDataState: OK`); query errors alert. Missing or
stale kube-state-metrics data can hide Pods and is not evidence of absence: inspect
existing scrape-health alerts and confirm metric freshness during review. This rule
is not an independent monitoring-availability guarantee.

## Review record: all gates required

Keep the following evidence in the private incident/recovery record, **not this
public repository**. Pod specifications and logs can contain credentials and job
content. Use existing authorized operator access; never paste credentials in a
recipe or create a recovery identity.

1. Record cluster/context, namespace, exact Pod name, UID, resourceVersion,
   creation/deletion timestamps, phase/reason and actual job labels/annotations.
   Read the exact Pod, not just an alert or a cached list. Establish its GitLab
   project/job ID and Runner registration/manager system ID from consistent Pod,
   Runner and GitLab evidence. Names, age and labels alone are not authority.
2. Correlate the GitLab job/pipeline state with the owning manager generation,
   its last job activity, cleanup attempts and result acknowledgement. Verify the
   job is terminal and no manager, retry or completion path still needs this Pod.
   A replacement manager being healthy, an old manager being absent, or a missing
   job response proves none of this. No automatic cancellation is authorized. If
   cancellation is needed, obtain separate requester approval, use the supported
   GitLab path and then re-establish all these gates; this procedure is not that path.
3. Preserve required job traces, all relevant container/previous logs, events and
   artifacts through existing authorized retention/export paths. Confirm with the
   requester that needed evidence is secured and manager log/artifact collection
   has finished. Age since creation is not time since completion, and terminal
   phase does not acknowledge a GitLab result or preserve artifacts.
4. Prove effect-capable writers are terminal: build/helper, services, init and
   ephemeral containers, plus Kubedock/other child workloads that can still use the
   store or produce effects. Correlate terminated states and finished timestamps
   with current node/kubelet/runtime evidence for this exact UID. Reject missing
   states, restart/active writers, ongoing manager use and API ambiguity. A terminal
   API phase alone, especially `NodeLost`, is insufficient. For an unreachable or
   partitioned node, retain and escalate until authorized infrastructure recovery
   independently proves physical process retirement/fencing; do not force-delete
   to manufacture that proof. Pending/Running/Unknown is **not deletion permission**.
5. Bind each relevant volume to this Pod: volume name/type, PVC namespace/name/UID,
   PVC controlling owner UID, PV name/UID, PV claimRef UID, StorageClass, reclaim
   policy, backend handle/path and provisioner custody. For generic ephemeral
   storage, prove PVC controller ownership by the exact Pod UID. Check other
   consumers/attachments and any child owners. Shared/retained PVCs, hostPath stores,
   caches and containerd/Docker state must not be classified as job-owned garbage.
   Today's configuration may not use Pod-owned PVCs; do not claim otherwise.
6. Infrastructure recovery and the requester record explicit approval bound to
   that exact Pod UID and verified ownership/writer state. Immediately re-read the
   exact Pod and relevant job/manager/node/storage evidence. If UID, resourceVersion
   or any eligibility fact changed, stop and review again. Do not refresh a failed
   precondition and retry blindly. The API preconditions below close object races,
   not races in external job/manager facts; those facts must remain established.

## Exact-object deletion, only after approval

Do **not** use name-only `kubectl delete pod`, `kubectl delete -f pod.json`, a label
selector, `--all`, force deletion, grace-period shortening, finalizer removal or a
volume/directory prune. A Pod manifest's metadata does not make ordinary kubectl
deletion UID/resourceVersion-conditional.

The supported raw API path sends a `v1/DeleteOptions` request body. In the private
approved record, prepare `delete-options.json` with the **reviewed final** UID and
resourceVersion (replace both placeholders; never use these literal values):

```json
{
  "apiVersion": "v1",
  "kind": "DeleteOptions",
  "preconditions": {
    "uid": "REVIEWED-POD-UID",
    "resourceVersion": "REVIEWED-RESOURCE-VERSION"
  },
  "propagationPolicy": "Background"
}
```

For a verified CI Pod, substitute the reviewed context and exact DNS-valid Pod name
in this command. Inspect the JSON and URI together before executing. No deletion
collection URI is allowed. Default Pod graceful termination remains in effect.

```sh
kubectl --context=REVIEWED-CONTEXT --request-timeout=15s delete \
  --raw=/api/v1/namespaces/ci/pods/REVIEWED-POD-NAME \
  -f delete-options.json
```

A credential-free loopback fixture verified that kubectl `v1.36.2+k3s1` transmits
DELETE to this exact object path with both preconditions in the JSON body (and an
additional request-timeout query parameter). That proves native client wire form,
not live authorization, server precondition enforcement or volume reclamation.
Verify equivalent behavior if selecting a different native client version.

A conflict means **stop and re-review**, not remove preconditions. A timeout or
transport error leaves the result uncertain: read the exact target and correlate
UID/deletion state before deciding anything further. A 404 requires reconciliation
of the recorded UID and dependents; it is not proof of reclaimed bytes. Do not
retry against a same-name replacement. A successful DELETE response only accepts
the request; it does not prove process retirement or cleanup completion.

## Verify native reclamation and close

Using finite, case-specific observation bounds agreed in the recovery record:

- Observe disappearance of the original Pod UID; a same-name replacement is a
  different object and must remain untouched. If the Pod is terminating/stuck,
  inspect finalizers, events, node state and provisioner health; escalate rather
  than force or remove finalizers.
- For each proven Pod-owned PVC, observe native garbage collection of its UID,
  then PV reclamation under the recorded reclaim policy. Confirm the provisioner
  removed the exact recorded backend allocation and released its capacity using
  existing authorized storage diagnostics. Do not delete a PVC, PV, directory or
  backend directly to obtain a green outcome.
- Retain/Released policies or shared/hostPath storage do not promise automatic
  backend deletion. Document retained bytes and route the storage exception to
  infrastructure recovery; do not report complete reclaim. Do not change storage
  policy or broaden maintenance GC under this procedure.
- Record job/result preservation, original UID absence, dependent/backend results,
  residual uncertainty and alert state. Expiry of the observation bound is an
  unresolved recovery, not success. An alert resolving only means its query no
  longer matches. No broad Runner restart, registration change or scheduler
  restoration is implied by closing this incident.

## Native references

- [Kubernetes DeleteOptions and preconditions](https://kubernetes.io/docs/reference/kubernetes-api/common-definitions/delete-options/)
- [Pod lifecycle, termination and lost nodes](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/)
- [Generic ephemeral volume ownership](https://kubernetes.io/docs/concepts/storage/ephemeral-volumes/#generic-ephemeral-volumes)
- [kube-state-metrics Pod metrics](https://github.com/kubernetes/kube-state-metrics/blob/v2.14.0/docs/metrics/workload/pod-metrics.md)
- [kubectl delete raw API interface](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_delete/)
