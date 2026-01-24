# Implementation Plan: Jayne Martin Counselling K8s Migration

**Branch**: `007-jayne-martin-k8s-migration` | **Date**: 2026-01-24 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/007-jayne-martin-k8s-migration/spec.md`

## Summary

Migrate the Jayne Martin Counselling static website from Nomad to Kubernetes, update external Traefik routing on Hestia, decommission the Nomad job, and analyze/remove Nomad from all cluster nodes if no longer needed. Consul and Vault remain in place.

## Technical Context

**Language/Version**: HCL (Terraform 1.x), YAML (Traefik dynamic config)
**Primary Dependencies**: Terraform kubernetes provider, kubectl provider for VPA CRDs
**Storage**: N/A (stateless website)
**Testing**: Manual HTTP verification, health check probes, `terraform plan` validation
**Target Platform**: Kubernetes (K3s) cluster on Hestia/Heracles/Nyx
**Project Type**: Infrastructure-as-Code module
**Performance Goals**: Website loads within 5 seconds, health checks respond within 5 seconds
**Constraints**: Zero downtime during migration, multi-arch support (amd64/arm64)
**Scale/Scope**: Single deployment, 1 replica, ~32MB memory

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Infrastructure as Code | PASS | All changes via Terraform modules and file edits |
| II. Simplicity First | PASS | Single module with main.tf only, following existing patterns |
| III. High Availability | PASS | Multi-arch affinity allows scheduling on any node; health checks defined |
| IV. Storage Patterns | N/A | Stateless website, no storage required |
| V. Security & Secrets | PASS | No secrets required for this service |
| VI. Service Mesh Patterns | N/A | Direct HTTP routing, no Consul Connect needed in K8s |

**Gate Result**: PASS - No violations, proceed to Phase 0.

### Post-Design Re-evaluation

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Infrastructure as Code | PASS | K8s module in Terraform, Traefik config as file |
| II. Simplicity First | PASS | Single module (main.tf + variables.tf + versions.tf), follows whoami pattern |
| III. High Availability | PASS | Multi-arch affinity, health probes, can run on any node |
| IV. Storage Patterns | N/A | Stateless - no storage |
| V. Security & Secrets | PASS | No secrets, public static website |
| VI. Service Mesh Patterns | N/A | No inter-service communication required |

**Post-Design Gate Result**: PASS - Design conforms to constitution.

## Project Structure

### Documentation (this feature)

```text
specs/007-jayne-martin-k8s-migration/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output (minimal - infrastructure only)
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output (N/A - no API contracts)
└── tasks.md             # Phase 2 output (created by /speckit.tasks)
```

### Source Code (repository root)

```text
modules-k8s/jayne-martin-counselling/
├── main.tf              # Deployment, Service, Ingress, VPA
├── variables.tf         # namespace, image_tag, vpa_mode
└── versions.tf          # Provider requirements

# External configuration (on Hestia)
/mnt/docker/traefik/traefik/dynamic_conf.yml  # Add k8s-jmc router

# Files to modify
kubernetes.tf            # Add module definition
main.tf                  # Remove Nomad module after validation
AGENTS.md                # Update to reflect Nomad removal (if applicable)
```

**Structure Decision**: Single Terraform module following existing `modules-k8s/whoami/` pattern. External Traefik config updated manually on Hestia.

## Complexity Tracking

No violations to justify - design follows established patterns.

## Phase 0-1 Artifacts

| Artifact | Status | Path |
|----------|--------|------|
| research.md | Complete | [research.md](research.md) |
| data-model.md | Complete | [data-model.md](data-model.md) |
| quickstart.md | Complete | [quickstart.md](quickstart.md) |
| contracts/ | Complete | [contracts/README.md](contracts/README.md) |

## Next Steps

Run `/speckit.tasks` to generate implementation tasks for Phase 2.
