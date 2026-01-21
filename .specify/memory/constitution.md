# Cluster State Constitution

## Core Principles

### I. Infrastructure as Code
All infrastructure changes are made through Terraform and Nomad jobspecs. No manual changes to running infrastructure. Changes must be version-controlled, reviewed, and applied through the standard workflow.

### II. Simplicity First
- Use frameworks directly, avoid unnecessary abstraction layers
- One Terraform module per service (main.tf + jobspec.nomad.hcl)
- Prefer explicit configuration over clever automation
- YAGNI - don't add features until they're needed

### III. High Availability by Design
- Services must tolerate single node failure
- No single points of failure for persistent data
- Health checks required for all services
- Graceful degradation over hard failures

### IV. Storage Patterns
- **SQLite databases**: Ephemeral disk with litestream backup to MinIO
- **Persistent data**: GlusterFS CSI volumes (distributed, not replicated)
- **No Unix sockets on network storage**: Use TCP or tmpfs
- **Btrfs bricks require nodatacow**: Prevents NFS fileid instability

### V. Security & Secrets
- Secrets managed through Vault or Nomad variables
- No hardcoded credentials in jobspecs
- Consul Connect service mesh for inter-service communication
- Principle of least privilege for service accounts
- **Per-service credentials**: Each service gets dedicated MinIO/database credentials, never shared

### VI. Service Mesh Patterns
- **Consul intentions required**: Explicitly allow service-to-service communication (e.g., traefik→overseerr, overseerr→minio)
- **Virtual addresses**: Use `http://<service>-<task>.virtual.consul` for mesh routing
- **Transparent proxy**: Default mode for Consul Connect sidecars

## Infrastructure Constraints

### Cluster Topology
- **Hestia (192.168.1.5)**: amd64, NVIDIA GPU, GlusterFS client
- **Heracles (192.168.1.6)**: arm64, GlusterFS brick
- **Nyx (192.168.1.7)**: arm64, GlusterFS brick

### Storage Architecture
```
GlusterFS bricks (Heracles/Nyx) → FUSE mount → NFS re-export → CSI → Containers
```

### Naming Conventions
- GlusterFS volumes: `glusterfs_<service>_<type>`
- Nomad jobs: lowercase with hyphens (e.g., `media-centre`)
- Terraform modules: `modules/<service>/`

## Development Workflow

### Changes Require
1. Edit Terraform/jobspec files
2. `terraform plan` to preview changes
3. `terraform apply` to deploy
4. Verify via Nomad UI or logs

### Testing
- Verify services start and pass health checks
- Check Elasticsearch logs for errors
- Test service functionality manually

### Documentation
- AGENTS.md contains operational runbooks
- Update when adding new patterns or fixing issues

## Governance

This constitution establishes immutable principles for cluster infrastructure. Amendments require:
1. Documentation of the change rationale
2. Update to this constitution
3. Update to AGENTS.md if operational procedures change

**Version**: 1.1.0 | **Ratified**: 2026-01-20 | **Last Amended**: 2026-01-21
