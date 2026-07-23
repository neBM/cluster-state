# Temporal operations

Temporal runs in the dedicated `temporal` namespace as four independently scalable services: frontend, history, matching, and the system worker. There is deliberately no Temporal UI, ingress, NodePort, or load balancer. Hestia reaches the `temporal-frontend` ClusterIP directly on TCP 7233 through the cluster network.

Temporal's application-layer authorizer is intentionally disabled with the server's explicit `TEMPORAL_ALLOW_NO_AUTH=true` admission switch. The Cilium policy is therefore the authentication boundary: only Hestia may initiate frontend RPC traffic, and no other LAN source is admitted. Do not broaden the Hestia CIDR without first adding and validating an application-layer authorizer.

## Immutable runtime identity

The first boot is fenced to runtime identity `homelab-temporal-v1` and **128 history shards**. This is a conservative small-production count for this cluster: it leaves room for workflow growth without the operational overhead of the chart default of 512. Temporal does not support changing the history-shard count in place. Do not reconcile a different value against an initialized database.

A restore is admissible only when all of the following match the backup source:

- runtime identity `homelab-temporal-v1`;
- history shard count `128`;
- Temporal server/schema release `1.31.2`;
- both PostgreSQL databases (`temporal` and `temporal_visibility`) are from the same recovery point.

Keep all Temporal server Deployments stopped while restoring. Restore both databases atomically, verify the fence above from version-controlled desired state and backup metadata, then allow the version-matched schema upgrade Jobs to finish before restarting server compute. Never point this identity at a copied database while another cluster using the same identity is running.

## PostgreSQL prerequisite and Secret contract

PostgreSQL is external at `192.168.1.10:5433`. An operator must provision the `temporal` and `temporal_visibility` databases and a least-privilege role before Flux reconciliation. PostgreSQL must require TLS and the server certificate must be valid for the configured address.

Each of the eight server pods is capped at two primary-store and one visibility-store PostgreSQL connections, for a Temporal-wide maximum of 24. This intentionally consumes no more than the existing shared PostgreSQL validator's 25-connection unbudgeted headroom; do not broaden either pool without re-budgeting the shared server first.

Manually provision one Secret named `temporal-postgres` in the `temporal` namespace. It must contain exactly the runtime material referenced by the manifests:

- `username` and `password`;
- `ca.crt`;
- `tls.crt` and `tls.key` for the client identity.

Secret values never belong in this repository. Do not use `kubectl apply` on a Secret manifest containing values because the payload can be copied into last-applied metadata.

## Reconciliation order

Flux enforces three fail-closed stages:

1. `temporal-schema-setup` runs idempotent 1.31.2 setup against both databases.
2. `temporal-schema-upgrade` waits for setup and applies the 1.31.2 PostgreSQL v12 versioned schemas to both databases.
3. `temporal` waits for both upgrade Jobs to complete before creating server compute.

A failed Job blocks the next stage. Do not bypass the dependency chain or start the Deployments manually.

## Non-secret verification

The following checks do not read Kubernetes Secrets:

```bash
./scripts/validate_kustomize.sh
uv run --locked --script scripts/validate_temporal_manifest.py
python3 scripts/test_validate_temporal_manifest.py

kubectl get kustomizations -n flux-system temporal-schema-setup temporal-schema-upgrade temporal
kubectl get jobs -n temporal -l app.kubernetes.io/name=temporal
kubectl get deployments,services,poddisruptionbudgets -n temporal
kubectl get ciliumnetworkpolicy -n temporal temporal
```

Confirm the setup and upgrade Kustomizations are Ready before the server Kustomization. From Hestia, verify a TCP connection to the rendered `temporal-frontend` ClusterIP on 7233. A connection from any other LAN source must fail. Verify that server pods emit JSON logs under `kubernetes.container_logs.temporal` and that VictoriaMetrics scrapes port 9090.

Do not query or print the Secret during verification. Diagnose missing-key or certificate failures from redacted pod events and stable error categories, then have an authorized operator repair the manually managed Secret.
