# Implementation Plan: ELK Stack Migration to Kubernetes Single-Node

**Branch**: `006-elk-k8s-migration` | **Date**: 2026-01-24 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/006-elk-k8s-migration/spec.md`

## Summary

Migrate the existing 3-node Elasticsearch cluster and 2-instance Kibana deployment from Nomad to Kubernetes as a single-node cluster. The migration involves safely reducing the ES cluster to a single node, moving data to GlusterFS shared storage, deploying on K8s with existing TLS and external URLs, and decommissioning the Nomad ELK job.

## Technical Context

**Language/Version**: HCL (Terraform 1.x), YAML (Kubernetes manifests via Terraform)
**Primary Dependencies**: Terraform kubernetes/kubectl providers, Elasticsearch 9.x, Kibana 9.x
**Storage**: GlusterFS via NFS-Ganesha (hostPath mounts at `/storage/v/`)
**Testing**: Manual verification via ES API, Kibana UI, terraform plan
**Target Platform**: Kubernetes (K3s 1.34+) on hybrid arm64/amd64 cluster
**Project Type**: Infrastructure-as-Code (Terraform modules)
**Performance Goals**: Log ingestion resumes within 5 minutes, pod reschedule within 5 minutes
**Constraints**: Zero data loss during migration, single-node ES acceptable, ~23GB storage required
**Scale/Scope**: Single Elasticsearch node, single Kibana instance, serving 3-node cluster logs

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Infrastructure as Code | PASS | All changes via Terraform modules, no manual infra changes |
| II. Simplicity First | PASS | Single module for ELK (modules-k8s/elk/), explicit config, no abstraction layers |
| III. High Availability by Design | JUSTIFIED VIOLATION | Single-node ES by design (user requirement), acceptable for logging use case |
| IV. Storage Patterns | PASS | Using GlusterFS hostPath, no SQLite, no Unix sockets |
| V. Security & Secrets | PASS | TLS certs in K8s secrets, Kibana encryption keys via External Secrets Operator |
| VI. Service Mesh Patterns | N/A | Not using Consul Connect for K8s services |

**Gate Status**: PASS (with justified HA violation per user requirement for single-node)

## Project Structure

### Documentation (this feature)

```text
specs/006-elk-k8s-migration/
├── plan.md              # This file
├── research.md          # Phase 0: ES node removal, data migration research
├── data-model.md        # Phase 1: Storage paths, secrets structure
├── quickstart.md        # Phase 1: Migration runbook
├── contracts/           # Phase 1: N/A (no API contracts, infrastructure only)
└── tasks.md             # Phase 2 output (/speckit.tasks command)
```

### Source Code (repository root)

```text
modules-k8s/elk/
├── main.tf              # Elasticsearch and Kibana deployments, services, ingress
├── variables.tf         # Module variables (storage paths, resource limits, etc.)
├── versions.tf          # Provider requirements
└── secrets.tf           # ExternalSecret for Kibana encryption keys

modules/elk/             # To be removed after migration
├── main.tf              # Current Nomad module
└── jobspec.nomad.hcl    # Current Nomad job definition
```

**Structure Decision**: Single Terraform module at `modules-k8s/elk/` following existing K8s module patterns. The existing `modules/elk/` Nomad module will be removed from Terraform state and deleted after migration verification.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Single-node ES (HA violation) | User explicitly requested single-node for simplicity | Multi-node adds complexity without value for logging use case |
