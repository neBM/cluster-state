# Implementation Plan: Nomad to Kubernetes Full Migration

**Branch**: `004-nomad-to-k8s-migration` | **Date**: 2026-01-22 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/004-nomad-to-k8s-migration/spec.md`

## Summary

Migrate 16 Nomad services to Kubernetes while maintaining the same URLs, data, and user experience. Services are migrated one at a time (stop Nomad → deploy K8s → verify) to avoid OOM issues on the resource-constrained cluster. Media-centre and CSI plugins remain on Nomad.

## Technical Context

**Language/Version**: HCL (Terraform 1.x), YAML (K8s manifests via Terraform kubernetes provider)
**Primary Dependencies**: Terraform, Kubernetes (K3s), Cilium CNI, Traefik Ingress, External Secrets Operator
**Storage**: GlusterFS CSI (democratic-csi), MinIO (litestream backups), NFS-Ganesha
**Testing**: Manual verification per service (URL access, data integrity, health checks)
**Target Platform**: K3s cluster (3 nodes: Hestia amd64, Heracles arm64, Nyx arm64)
**Project Type**: Infrastructure-as-Code (Terraform modules)
**Performance Goals**: Services respond within 5 seconds, equivalent to Nomad performance
**Constraints**: One service at a time, downtime acceptable, ~500MB K8s overhead per node
**Scale/Scope**: 16 services to migrate, 11 migration phases

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Infrastructure as Code | ✅ PASS | All K8s resources via Terraform (modules-k8s/) |
| II. Simplicity First | ✅ PASS | One Terraform module per service pattern continues |
| III. High Availability | ✅ PASS | K8s provides pod restart, node affinity for multi-arch |
| IV. Storage Patterns | ✅ PASS | Same GlusterFS CSI, same litestream pattern |
| V. Security & Secrets | ✅ PASS | External Secrets Operator → Vault, per-service credentials |
| VI. Service Mesh | ⚠️ ADAPTING | Consul Connect → Cilium (CiliumNetworkPolicy replaces intentions) |

**Constitution Adaptation Required**: Principle VI references Consul Connect patterns. For K8s, we use:
- Cilium service mesh instead of Consul Connect
- CiliumNetworkPolicy instead of Consul intentions
- K8s Services instead of Consul virtual addresses

This is an acceptable evolution as the principles describe the *goals* (secure inter-service communication) not the specific implementation.

## Project Structure

### Documentation (this feature)

```text
specs/004-nomad-to-k8s-migration/
├── plan.md              # This file
├── research.md          # Phase 0: Technical research
├── data-model.md        # Phase 1: K8s resource patterns
├── quickstart.md        # Phase 1: Migration runbook
├── contracts/           # Phase 1: Module patterns
│   └── k8s-module-pattern.md
├── checklists/
│   └── requirements.md  # Spec quality checklist
└── tasks.md             # Phase 2: Implementation tasks (later)
```

### Source Code (repository root)

```text
modules-k8s/                    # K8s Terraform modules (one per service)
├── hubble-ui/                  # Already exists (PoC)
├── whoami/                     # Already exists (PoC)
├── echo/                       # Already exists (PoC)
├── overseerr/                  # Already exists (PoC) - to be replaced
├── searxng/                    # Phase 1 migration
├── nginx-sites/                # Phase 1 migration
├── vaultwarden/                # Phase 2 migration
├── open-webui/                 # Phase 3 migration
├── ollama/                     # Phase 3 migration
├── minio/                      # Phase 4 migration
├── keycloak/                   # Phase 5 migration
├── appflowy/                   # Phase 6 migration
├── elk/                        # Phase 7 migration
├── nextcloud/                  # Phase 8 migration
├── matrix/                     # Phase 9 migration
├── gitlab/                     # Phase 10 migration
├── gitlab-runner/              # Phase 10 migration
├── renovate/                   # Phase 11 migration (CronJob)
└── restic-backup/              # Phase 11 migration (CronJob)

kubernetes.tf                   # Root K8s module configuration
```

**Structure Decision**: Continue the established `modules-k8s/<service>/` pattern from the PoC. Each module contains:
- `main.tf` - Deployment/StatefulSet, Service, Ingress
- `variables.tf` - Configuration inputs
- `versions.tf` - Provider requirements
- `outputs.tf` - Exposed values
- `secrets.tf` - ExternalSecret resources (if needed)
- `vpa.tf` - VerticalPodAutoscaler (optional)

## Complexity Tracking

No constitution violations requiring justification. The Consul → Cilium adaptation is an acceptable technology evolution, not a principle violation.
