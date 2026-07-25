# IB Gateway paper workload with broker observer

`ib-gateway-paper` runs only the paper-trading, read-only API profile. `broker-observer` is a credential-isolated sidecar in the same Pod and reaches the Gateway only through the existing localhost API at `127.0.0.1:4002`. Neither container is exposed by a Service, Ingress, Gateway, HTTPRoute, or container port.

## Immutable admitted artifacts

Both images were independently built, audited, and admitted by autonomous-investing system project 35, protected-main pipeline 5591, at source commit `6d37a1a275f50acccfe35e341e0d16d36ab6c701`:

- IB Gateway admission job 20419: `registry.brmartin.co.uk:443/autonomous-investing/system/ib-gateway@sha256:fd88e62b91efcd392ee9da607ceaee98569f2278d830a33466b9b729725b59d0`
- Broker observer admission job 20420: `registry.brmartin.co.uk:443/autonomous-investing/system/broker-observer@sha256:773311d3950bb6392b778f8f6240bc7e53860494d722d26fdaf8ab571a72c166`

`ib-gateway-paper-deployment-policy.yaml` and `broker-observer-deployment-policy.yaml` are separate, non-Kubernetes audit records. They are deliberately not Kustomize resources. Deployment validation requires each exact schema, provenance identity, repository, digest, and reference, then binds each reference independently to its container and optional CLI expectation.

The protected-main scans reported:

- Broker observer: zero Critical, zero High, and an exactly empty top-level `ignoredMatches` list.
- IB Gateway: zero Critical, exactly six retained non-Jackson High findings, and an exactly empty top-level `ignoredMatches` list. Matched `jackson-annotations`, `jackson-core`, and `jackson-databind` 2.18.9 are present; there are no Jackson vulnerability findings.

The retained IB Gateway High tuples are:

- `GHSA-78wr-2p64-hpwj`, `commons-io`, `2.11.0`
- `CVE-2025-53066`, `openjdk`, `17.0.16.0.101`
- `CVE-2026-21932`, `openjdk`, `17.0.16.0.101`
- `CVE-2026-21945`, `openjdk`, `17.0.16.0.101`
- `CVE-2026-22016`, `openjdk`, `17.0.16.0.101`
- `CVE-2026-34282`, `openjdk`, `17.0.16.0.101`

## Credential and runtime isolation

Broker credentials remain outside Git. The Gateway alone reads `TWS_USERID` and `TWS_PASSWORD` files from the separately managed `ibkr-paper-gateway-credentials` Secret. The observer receives no environment configuration and mounts none of the credential, settings, Gateway `/tmp`, or `/run/ibc` volumes. Its only writable filesystem is a private 16 MiB memory-backed volume at `/tmp`; its image root remains read-only. `/run/ibc` remains an exclusive memory-backed Gateway mount.

The observer opens no network listener. Same-Pod networking nevertheless means it inherits the Pod's existing Cilium egress authority: exact-name cluster DNS plus the documented IBKR endpoints on TCP 4000/4001. This is an explicit residual risk of localhost observation. The rollout does not widen the egress policy.

The observer supervisor's generic health state proves only local lifecycle and watchdog health. It is not authenticated broker-session readiness and must not be reported as such. Durable broker-snapshot persistence belongs to the separate storage amendment and is not provided or claimed by this rollout.

## Policy-first rollout

Use two merge requests for a new environment or rebuild:

1. The foundation MR renders exactly the Namespace, default-deny NetworkPolicy, and CiliumNetworkPolicy. It renders neither policy record, the settings PVC, nor the Deployment. Run `uv run --locked --script scripts/validate_ibgateway_manifest.py --phase foundation`, and wait for Flux to reconcile it.
2. Provision `ibkr-paper-gateway-credentials` through the approved out-of-band Secret workflow. Confirm only that the named Secret exists; never read or print its data during rollout review.
3. The deployment MR adds the `local-path-retain` settings PVC, singleton hardened two-container Deployment, and both non-rendered policy records together. Validate both admitted identities:

   ```sh
   uv run --locked --script scripts/validate_ibgateway_manifest.py \
     --phase deployment \
     --expected-image 'registry.brmartin.co.uk:443/autonomous-investing/system/ib-gateway@sha256:fd88e62b91efcd392ee9da607ceaee98569f2278d830a33466b9b729725b59d0' \
     --expected-broker-observer-image 'registry.brmartin.co.uk:443/autonomous-investing/system/broker-observer@sha256:773311d3950bb6392b778f8f6240bc7e53860494d722d26fdaf8ab571a72c166'
   ```

This split is required because the authoritative `apps` Flux Kustomization has `wait: true`, while `local-path-retain` uses `WaitForFirstConsumer`. A PVC without its Deployment consumer can remain Pending and hold foundation reconciliation unhealthy. The validator discovers the exact authoritative Flux apps render and fails closed on partial source or rendered resource sets.

The Pod uses only `ndots: "1"` so external broker names are queried directly. Rollout can still require the user's IBKR 2FA approval. Pod readiness, container process health, and observer supervisor health do not prove the authenticated session. Do not use the API until the challenge is completed and the paper/read-only session is independently verified; this workload never authorizes live trading or capital movement.
