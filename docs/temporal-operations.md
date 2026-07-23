# Temporal operations

Temporal runs in the dedicated `temporal` namespace as four independently scalable services: frontend, history, matching, and the system worker. There is deliberately no Temporal UI, ingress, NodePort, or load balancer. Hestia reaches the `temporal-frontend` ClusterIP directly on TCP 7233 through the cluster network.

The frontend is a fail-closed mutual-TLS boundary. It presents the DNS identity `temporal-frontend.temporal.svc.cluster.local`, requires every RPC client to present a certificate signed by the dedicated frontend client CA, and rejects plaintext, server-auth-only TLS, and untrusted client certificates. The unauthenticated server-admission switch is forbidden. Cilium independently limits external frontend traffic to TCP 7233 from the node identity selected by `kubernetes.io/hostname=hestia`; direct host-to-ClusterIP traffic is represented by Cilium as a host/node identity, not Hestia's LAN CIDR. The cluster's Cilium `enable-node-selector-labels` (`nodeSelectorLabels`) setting must therefore remain enabled. A caller must satisfy both this exact node policy and mTLS authentication; source IP alone is not an identity.

Temporal egress selects CoreDNS by its `coredns` Kubernetes service-account identity in `kube-system`, permits only TCP/UDP 53, and limits DNS queries to `*.cluster.local`. Do not replace that identity with a namespace-only selector or grant general DNS/network egress.

## Immutable runtime identity

The first boot is fenced to runtime identity `homelab-temporal-v1` and **128 history shards**. This is a conservative small-production count for this cluster: it leaves room for workflow growth without the operational overhead of the chart default of 512. Temporal does not support changing the history-shard count in place. Do not reconcile a different value against an initialized database.

A restore is admissible only when all of the following match the backup source:

- runtime identity `homelab-temporal-v1`;
- history shard count `128`;
- Temporal server/schema release `1.31.2`;
- both PostgreSQL databases (`temporal` and `temporal_visibility`) are from the same recovery point.

Keep all Temporal server Deployments stopped while restoring. Restore both databases atomically, verify the fence above from version-controlled desired state and backup metadata, then allow the version-matched schema upgrade Jobs to finish before restarting server compute. Never point this identity at a copied database while another cluster using the same identity is running.

## PostgreSQL prerequisite and Secret contracts

PostgreSQL is external at `192.168.1.10:5433`. An operator must provision the `temporal` and `temporal_visibility` databases and a least-privilege role before Flux reconciliation. PostgreSQL must require TLS and the server certificate must be valid for the configured address.

Each of the eight server pods is capped at two primary-store and one visibility-store PostgreSQL connections, for a Temporal-wide maximum of 24. This intentionally consumes no more than the existing shared PostgreSQL validator's 25-connection unbudgeted headroom; do not broaden either pool without re-budgeting the shared server first.

Manually provision one Secret named `temporal-postgres` in the `temporal` namespace. It must contain exactly the runtime material referenced by the manifests:

- `username` and `password`;
- `ca.crt`;
- `tls.crt` and `tls.key` for the client identity.

Secret values never belong in this repository. Do not use `kubectl apply` on a Secret manifest containing values because the payload can be copied into last-applied metadata.

Manually provision a second Secret named `temporal-frontend-mtls` in the `temporal` namespace. It must contain:

- `ca.crt`, the dedicated CA used to verify frontend server and admitted client identities;
- `server.crt` and `server.key`, with a server certificate valid for `temporal-frontend.temporal.svc.cluster.local`;
- `system-worker.crt` and `system-worker.key`, a distinct client identity used only by Temporal's in-cluster system worker.

The Hestia ADD worker uses another distinct client certificate and private key signed by the same dedicated CA. Its private key remains on Hestia and must not be copied into the Kubernetes Secret or Git. Configure the Temporal SDK with the CA, the exact frontend DNS server name, and the Hestia client certificate/key before enabling its activity queue. Certificate issuance must constrain extended key usages: server authentication for `server.crt`, and client authentication for the system-worker and Hestia identities.

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

Confirm the setup and upgrade Kustomizations are Ready before the server Kustomization. From Hestia, prove that a Temporal health RPC without a client certificate fails the TLS handshake, then prove that the same RPC succeeds with the dedicated Hestia client identity, trusted CA, and exact DNS server name. A connection from any other LAN source must fail even when it has no certificate. Verify that the in-cluster system worker is healthy through its separate client identity, server pods emit JSON logs under `kubernetes.container_logs.temporal`, and VictoriaMetrics scrapes port 9090.

Before testing Hestia connectivity after a Cilium reinstall or configuration change, verify that node-selector labels are enabled and that the Hestia node still carries `kubernetes.io/hostname=hestia`. Also verify that CoreDNS endpoints carry the `coredns` service-account identity. Do not broaden the policy to `host`, `world`, a LAN CIDR, or all `kube-system` endpoints to work around identity drift.

Do not query or print either Secret during verification. Diagnose missing-key, trust-chain, server-name, or certificate failures from redacted pod events and stable error categories, then have an authorized operator repair the manually managed Secret or Hestia credential.
