# Implementation Plan: GitLab Multi-Container Migration

**Branch**: `008-gitlab-multi-container` | **Date**: 2026-01-24 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/008-gitlab-multi-container/spec.md`

## Summary

Migrate GitLab from a single Omnibus container to a multi-container architecture using Cloud Native GitLab (CNG) images. The migration preserves all existing data (repositories, users, access tokens, CI/CD configurations) while separating components (webservice, workhorse, sidekiq, gitaly) into individual containers following the single responsibility principle. No Helm charts - pure Terraform with Kubernetes provider.

## Technical Context

**Language/Version**: HCL (Terraform 1.x), YAML (Kubernetes manifests via Terraform)
**Primary Dependencies**: Kubernetes provider, kubectl provider, CNG container images (registry.gitlab.com/gitlab-org/build/cng)
**Storage**: PVCs with glusterfs-nfs StorageClass (GlusterFS via NFS-Ganesha), External PostgreSQL (192.168.1.10:5433)
**Testing**: Manual verification - health checks, git operations, CI pipelines, registry push/pull
**Target Platform**: K3s cluster (Hestia/Heracles/Nyx nodes)
**Project Type**: Infrastructure-as-Code (Terraform modules)
**Performance Goals**: Match current Omnibus performance (single user workload)
**Constraints**: No Helm charts, downtime acceptable, data preservation mandatory
**Scale/Scope**: Single replica per component, ~4-6 containers total

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Infrastructure as Code | PASS | All changes via Terraform modules |
| II. Simplicity First | PASS | One module (modules-k8s/gitlab/), explicit config, no unnecessary abstraction |
| III. High Availability by Design | N/A | Single replica acceptable per spec (Out of Scope) |
| IV. Storage Patterns | PASS | PVCs for persistent data, TCP-only (no Unix sockets), no SQLite |
| V. Security & Secrets | PASS | Secrets via External Secrets Operator (Vault), no hardcoded credentials |
| VI. Service Mesh Patterns | N/A | Not using Consul Connect for this service |

**Infrastructure Constraints Check**:
- Storage Architecture: PVCs → glusterfs-nfs StorageClass → NFS-Ganesha (FSAL_GLUSTER) → GlusterFS bricks
- Naming: Will use `glusterfs_gitlab_*` pattern for volumes
- Node placement: No constraint (all nodes have NFS access)

## Project Structure

### Documentation (this feature)

```text
specs/008-gitlab-multi-container/
├── spec.md              # Feature specification
├── plan.md              # This file
├── research.md          # Phase 0 output - CNG configuration research
├── data-model.md        # Phase 1 output - volume/secret structure
├── quickstart.md        # Phase 1 output - migration runbook
├── contracts/           # Phase 1 output - service ports/endpoints
└── tasks.md             # Phase 2 output (created by /speckit.tasks)
```

### Source Code (repository root)

```text
modules-k8s/gitlab/
├── main.tf              # Rewritten - multiple deployments, services, configmaps
├── variables.tf         # Updated - CNG image tags, component configs
├── secrets.tf           # Updated - additional secrets (gitaly token, workhorse secret)
├── outputs.tf           # Updated - service endpoints
└── versions.tf          # Unchanged
```

**Structure Decision**: Existing single-module structure retained. The `main.tf` will be significantly rewritten to define separate Deployment/Service resources for each component (webservice, workhorse, sidekiq, gitaly, redis) while maintaining the existing IngressRoute configurations.

## Complexity Tracking

No constitution violations requiring justification.

## Research Areas (Phase 0) - COMPLETED

See [research.md](research.md) for detailed findings.

1. **CNG Image Configuration**: ✅ Environment variables + mounted config templates
2. **Data Migration Strategy**: ✅ Direct volume migration with path mapping
3. **Inter-component Communication**: ✅ TCP-only via Kubernetes Services
4. **Secrets Extraction**: ✅ Extract from Omnibus, convert to K8s Secrets
5. **Container Registry**: ✅ Separate container using CNG registry image
6. **Version Compatibility**: ✅ CNG v18.8.2 images available for CE

## Constitution Check (Post-Design)

*Re-evaluation after Phase 1 design completion.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Infrastructure as Code | PASS | All resources defined in Terraform (PVCs, ConfigMaps, Secrets, Deployments, Services) |
| II. Simplicity First | PASS | Single module, explicit config templates, no Helm abstraction |
| III. High Availability by Design | N/A | Single replica per spec (explicitly out of scope) |
| IV. Storage Patterns | PASS | PVCs with glusterfs-nfs, TCP-only communication (no Unix sockets), no SQLite |
| V. Security & Secrets | PASS | Rails secrets from Vault via ESO, generated tokens stored as K8s Secrets |
| VI. Service Mesh Patterns | N/A | Not using Consul Connect (K8s internal services sufficient) |

**Design Artifacts**:
- [data-model.md](data-model.md) - PVCs, Secrets, ConfigMaps
- [contracts/services.yaml](contracts/services.yaml) - Service ports and communication
- [quickstart.md](quickstart.md) - Migration runbook

**Ready for**: `/speckit.tasks` to generate implementation tasks
