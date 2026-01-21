# Implementation Plan: Migrate Overseerr to Nomad

**Branch**: `001-migrate-overseerr-nomad` | **Date**: 2026-01-20 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-migrate-overseerr-nomad/spec.md`

## Summary

Migrate Overseerr media request management service from docker-compose to Nomad with:
- Consul Connect service mesh for ingress (Traefik) and outbound connectivity
- Litestream pattern for SQLite database backup to MinIO (ephemeral disk + S3 replication)
- GlusterFS CSI volume for non-database config files (settings.json, logs)
- No node constraints to enable failover across Hestia/Heracles/Nyx
- Direct IP connections to Sonarr/Radarr (still on docker-compose at 192.168.1.5)

## Technical Context

**Language/Version**: HCL (Terraform 1.x, Nomad jobspec)
**Primary Dependencies**: Nomad, Consul Connect, Traefik, Litestream, MinIO
**Storage**: Ephemeral disk (SQLite via litestream), GlusterFS CSI (config files)
**Testing**: Manual verification via Nomad UI, service health checks, Elasticsearch logs
**Target Platform**: Nomad cluster (Hestia amd64, Heracles/Nyx arm64)
**Project Type**: Infrastructure-as-Code module
**Performance Goals**: Service startup < 2 minutes, database restore < 60 seconds
**Constraints**: No node constraints, transparent proxy for outbound, SQLite not on network FS
**Scale/Scope**: Single service deployment, ~4.5MB database

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Evidence |
|-----------|--------|----------|
| I. Infrastructure as Code | PASS | All changes via Terraform module + Nomad jobspec |
| II. Simplicity First | PASS | One module (main.tf + jobspec.nomad.hcl), follows existing patterns |
| III. High Availability | PASS | No node constraints, litestream for data recovery |
| IV. Storage Patterns | PASS | SQLite on ephemeral disk + litestream, GlusterFS for config only |
| V. Security & Secrets | PASS | MinIO credentials via Vault template, Consul Connect mesh |

**Gate Result**: PASS - No violations, proceed to Phase 0.

## Project Structure

### Documentation (this feature)

```text
specs/001-migrate-overseerr-nomad/
├── spec.md              # Feature specification (complete)
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output (N/A for IaC)
└── tasks.md             # Phase 2 output (/speckit.tasks)
```

### Source Code (repository root)

```text
modules/overseerr/
├── main.tf              # Terraform config: CSI volume, job dependency
└── jobspec.nomad.hcl    # Nomad job: overseerr task, litestream restore/sidecar
```

**Structure Decision**: Standard single-service Terraform module following existing patterns (e.g., `modules/vaultwarden/`, `modules/media-centre/`). No frontend/backend split - this is IaC.

## Complexity Tracking

> No violations - table not required.
