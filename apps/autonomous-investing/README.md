# IB Gateway paper workload

`ib-gateway-paper` runs only the paper-trading, read-only API profile. Its image comes through the governed source build and admission pipeline and remains pinned to the immutable digest admitted by protected-main pipeline 5261.

`ib-gateway-paper-deployment-policy.yaml` is the non-Kubernetes audit record for that independently verified artifact. It records system project 35, admission job 19838, source commit `4a9a2c858fa23e182e06b5cd835b9dddb6dc789d`, and the exact admitted repository and digest. It is deliberately not a Kustomize resource. Deployment validation requires its exact schema and values and binds its image reference to both the Deployment and any `--expected-image` argument.

Broker credentials stay out of Git. The Deployment reads only `TWS_USERID` and `TWS_PASSWORD` files from the separately managed `ibkr-paper-gateway-credentials` Secret.

## Policy-first rollout

Use two merge requests for a new environment or a rebuild:

1. The foundation MR renders exactly the Namespace, default-deny NetworkPolicy, and CiliumNetworkPolicy. It must render neither the settings PVC nor the Deployment. The foundation branch may omit the PVC, Deployment, and deployment-policy source files; the phase-aware mutation harness still runs all common foundation tests. Run `uv run --locked --script scripts/validate_ibgateway_manifest.py --phase foundation` and wait for Flux to reconcile the foundation before continuing.
2. Provision `ibkr-paper-gateway-credentials` through the approved out-of-band Secret workflow after the namespace exists. Confirm only that the named Secret exists; do not read or print its data during rollout review.
3. Only after the Secret exists, the deployment MR adds the `local-path-retain` settings PVC and the singleton hardened Deployment together, plus the non-rendered deployment-policy record for the protected-main admitted digest. Run `uv run --locked --script scripts/validate_ibgateway_manifest.py --phase deployment --expected-image '<admitted-image-reference>'` before merge.

This split is required for Flux health: the authoritative `apps` Flux Kustomization has `wait: true`, while `local-path-retain` has `volumeBindingMode: WaitForFirstConsumer`. A PVC created without its Deployment has no consumer, remains Pending, and can hold the foundation reconciliation unhealthy. Adding the PVC and its consumer atomically in the deployment phase allows provisioning to proceed.

The validator discovers the apps render from the exact authoritative Flux `apps` Kustomization instead of assuming `./apps`. Its default `--phase auto` selects deployment whenever any Deployment is present in `autonomous-investing`; otherwise it selects foundation. Exact phase resource sets make partial states fail closed: foundation forbids both PVCs and Deployments, while deployment requires exactly the named PVC and Deployment. `--expected-image` is valid only in deployment phase. The current full authoritative apps render is the completed five-resource deployment phase.

There is deliberately no Service, Ingress, Gateway, or HTTPRoute. The API remains same-pod localhost only at `127.0.0.1:4002`. `/run/ibc` is an exclusive memory-backed mount owned by the single Gateway container; do not add an init container, sidecar, or second mount of that volume.

Egress evidence is limited to the documented IBKR paper endpoints `zdc1.ibllc.com`, `zdc1-hb1.ibllc.com`, `zdc1-hb2.ibllc.com`, `ndc1.ibllc.com`, `ndc1-hb1.ibllc.com`, and `ndc1-hb2.ibllc.com` on TCP 4000/4001, plus exact-name DNS queries through cluster CoreDNS. The Pod sets only `ndots: "1"` so these external names are queried directly rather than first expanding through cluster search domains. Successful startup still has an operator-controlled 2FA gate: pod readiness is not session readiness, and operators must not use the API until the challenge is completed and the paper/read-only session is verified.
