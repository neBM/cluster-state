<!--
=============================================================================
SYNC IMPACT REPORT

Version: 1.1.1 → 1.2.0 (MINOR)
Bump Rationale: Two new principles added (resource requests/limits, Renovate
inline comments) and stale Nomad/Consul/Elasticsearch references removed.
Removal of decommissioned-stack guidance constitutes material content change.

Modified Principles:
- I. Infrastructure as Code: Removed Nomad references, K8s-only now
- II. Simplicity First: Updated module path conventions (modules-k8s/)
- III. High Availability by Design: No change
- IV. Storage Patterns: Removed outdated nodatacow note (covered in AGENTS.md)
- V. Security & Secrets: Removed Vault/Nomad variables, updated to K8s Secrets
  + External Secrets Operator
- VI. Service Mesh Patterns: Replaced Consul Connect with Cilium

Added Principles:
- VII. Resource Management (NEW): Pod requests/limits required; derive from
  Goldilocks VPA recommendations for pre-existing workloads
- VIII. Dependency Management (NEW): Renovate inline comments required for all
  container image references in Terraform modules

Removed Sections:
- Service Mesh Patterns (Consul Connect) → replaced with Cilium-based guidance

Templates Requiring Updates:
- .specify/templates/plan-template.md: ✅ No changes needed (generic)
- .specify/templates/spec-template.md: ✅ No changes needed
- .specify/templates/tasks-template.md: ✅ No changes needed
- .specify/templates/checklist-template.md: ✅ No changes needed
- .specify/templates/agent-file-template.md: ✅ No changes needed

Follow-up TODOs: None
=============================================================================
-->

# Cluster State Constitution

## Core Principles

### I. Infrastructure as Code

All infrastructure changes MUST be made through Terraform (Kubernetes provider).
No manual changes to running infrastructure. Changes MUST be version-controlled,
reviewed, and applied through the standard `terraform plan → apply` workflow.
Kubernetes manifests are generated exclusively via the Terraform kubernetes
provider — raw YAML manifests MUST NOT be committed to this repository.

`lifecycle { ignore_changes = [...] }` MUST NOT be used. It hides drift and
creates confusing configs. Fix the root cause instead (e.g., remove unused
fields or use `terraform state rm` to reset state).

### II. Simplicity First

- Use frameworks directly; avoid unnecessary abstraction layers.
- One Terraform module per service (`modules-k8s/<service>/main.tf` +
  `variables.tf`).
- Prefer explicit configuration over clever automation.
- YAGNI — do not add features until they are needed.

### III. High Availability by Design

- Services MUST tolerate single-node failure.
- No single points of failure for persistent data.
- Health checks (liveness and readiness probes) MUST be defined for all
  Kubernetes workloads.
- Graceful degradation over hard failures.

### IV. Storage Patterns

- **SQLite databases**: Ephemeral disk with Litestream backup to MinIO. WAL
  mode is required; Litestream 0.3.x (generations) and 0.5.x (LTX) are NOT
  compatible — pin the version.
- **Persistent data**: PVCs with `glusterfs-nfs` StorageClass (preferred for
  new services). Legacy `hostPath` mounts to `/storage/v/` continue to work
  but MUST NOT be used for new services.
- **No Unix sockets on network storage**: Use TCP or `/run/` (tmpfs).
- **No SQLite on network storage**: Network filesystems cause locking issues.

### V. Security & Secrets

- Secrets MUST be managed through Kubernetes Secrets (synced via External
  Secrets Operator from Vault where applicable). No hardcoded credentials in
  Terraform sources.
- Principle of least privilege for all service accounts.
- **Per-service credentials**: Each service gets dedicated MinIO/database
  credentials; credentials MUST NOT be shared between services.
- Network policies (Cilium) MUST explicitly allow required service-to-service
  communication; default-deny posture is the target.

### VI. Service Mesh & Networking

- **Cilium CNI** is the network layer. Network policies are expressed as
  Cilium `NetworkPolicy` / `CiliumNetworkPolicy` resources.
- **Traefik IngressRoutes** handle all external traffic termination (TLS via
  cert-manager). Host-based routing only — no path-based ACLs that could be
  bypassed by encoded characters.
- `allowEncodedSlash: true` is set on the `websecure` entrypoint for GitLab
  API compatibility. Re-evaluate if path-based access-control rules are ever
  added.

### VII. Resource Management

All Kubernetes pod templates MUST declare both `requests` and `limits` for CPU
and memory on every container (including init and sidecar containers).

- **New services**: size conservatively based on expected workload.
- **Pre-existing services without limits**: query Goldilocks
  (https://goldilocks.brmartin.co.uk) for VPA recommendations and apply them.
  Goldilocks is the authoritative source for right-sizing existing workloads.
- Rationale: unbounded resource consumption causes node pressure and cascading
  failures; VPA data removes guesswork from sizing decisions.

### VIII. Dependency Management

All container image references inside `modules-k8s/**/*.tf` MUST carry a
Renovate inline comment so the custom regex manager can track and update them
automatically.

**Pattern for variable defaults** (the primary pattern used in this repo):

```hcl
# renovate: datasource=docker depName=<registry>/<image>
default = "<registry>/<image>:<tag>"
```

**Pattern for inline image strings**:

```hcl
image = "<registry>/<image>:<tag>" # renovate: datasource=docker depName=<registry>/<image>
```

The `customManagers` regex in `renovate.json` matches the first pattern.
Major image updates MUST NOT be auto-merged (`automerge: false` is enforced by
`packageRules`). Patch updates auto-merge within the configured schedule.

## Infrastructure Constraints

### Cluster Topology

| Node | IP | Arch | Role |
|------|----|------|------|
| Hestia | 192.168.1.5 | amd64 | Primary, NVIDIA GTX 1070 (2× virtual GPU), GlusterFS client |
| Heracles | 192.168.1.6 | arm64 | Worker, GlusterFS brick |
| Nyx | 192.168.1.7 | arm64 | Worker, GlusterFS brick |

### Storage Architecture

```
GlusterFS bricks (Heracles/Nyx)
  → NFS-Ganesha V9.4 FSAL_GLUSTER (stable fileids, all 3 nodes)
    → nfs-subdir-external-provisioner (127.0.0.1:/storage)
      → PVC / hostPath mounts in containers
```

### Naming Conventions

- GlusterFS volumes: `glusterfs_<service>_<type>`
- Kubernetes namespaces: `default` (primary workloads), `kube-system`
  (cluster components)
- Terraform modules: `modules-k8s/<service>/`
- PVC `volume-name` annotation: `<service>_<type>` (controls subdirectory
  under `/storage/v/`)

## Development Workflow

### Making Changes

1. Edit `modules-k8s/<service>/main.tf` (and `variables.tf` as needed).
2. `set -a && source .env && set +a` — load Vault token and backend vars.
3. `terraform plan -out=tfplan` — review changes.
4. `terraform apply tfplan` — deploy.
5. Verify via `kubectl get pods` / `kubectl logs` / Grafana dashboards.

### Verification Checklist

- Pod starts and passes liveness/readiness probes.
- Resource `requests` and `limits` present on all containers.
- Renovate inline comment present for every image reference.
- Loki logs show no startup errors (`{namespace="default",container="<name>"}`).
- Metrics visible in VictoriaMetrics / Grafana if service exposes `/metrics`.

### Documentation

- `AGENTS.md` is the operational runbook — update when adding new patterns or
  fixing non-obvious issues.
- `docs/` contains deep-dive architecture notes; update when the architecture
  changes.

## Governance

This constitution establishes binding principles for cluster infrastructure.
Amendments require:

1. Clear rationale documenting why the change is needed.
2. Version bump following semantic versioning (MAJOR: principle
   removal/redefinition; MINOR: new principle or material expansion; PATCH:
   clarifications and wording).
3. Update to this file and `AGENTS.md` if operational procedures change.
4. Sync Impact Report embedded as an HTML comment at the top of this file.

**Version**: 1.2.0 | **Ratified**: 2026-01-20 | **Last Amended**: 2026-03-08
