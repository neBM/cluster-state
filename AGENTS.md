# Cluster State - Agent Guide

## Overview

Infrastructure-as-Code repository for a Nomad cluster. Services are deployed via Terraform which submits Nomad jobspecs.

## Architecture

- **Nomad** - Workload orchestration
- **Consul** - Service mesh (transparent proxy mode)
- **Terraform** - Infrastructure provisioning
- **GlusterFS** - Distributed storage (CSI volumes)
- **Martinibar (NFS)** - Legacy storage (migrating away)
- **MinIO** - Object storage (backups, litestream)

## Project Structure

```
modules/           # Terraform modules, each containing jobspecs
  ├── <service>/
  │   ├── main.tf              # Terraform config, CSI volumes
  │   └── jobspec.nomad.hcl    # Nomad job definition
main.tf            # Root terraform config
```

## Key Locations

| Location | Description |
|----------|-------------|
| Hestia (192.168.1.5) | Primary node, NVIDIA GPU, storage |
| `/storage/v/` | GlusterFS volumes on Hestia |
| `/mnt/csi/` | Legacy CSI backups on Hestia |
| `/var/lib/docker/volumes/` | Docker volume backups on Hestia |

## Common Commands

```bash
# Load environment
set -a && source .env && set +a

# Terraform
terraform plan -var="nomad_address=https://nomad.brmartin.co.uk:443" -out=tfplan
terraform apply tfplan

# Nomad
nomad job status <job>
nomad alloc logs <alloc> <task>
nomad alloc exec -task <task> <alloc> <command>
nomad volume status

# Data operations (run on Hestia to avoid timeouts)
ssh 192.168.1.5 "rsync -av --progress <src>/ <dst>/"
```

## Naming Conventions

- GlusterFS volumes: `glusterfs_<service>_<type>`
- Martinibar volumes: `martinibar_prod_<service>_<type>`

## Critical Warnings

- **CSI Volume Deletion**: `nomad volume delete` deletes the underlying data. Always backup first.
- **SQLite on Network Storage**: Use ephemeral disk with litestream for SQLite databases. Network filesystems cause locking issues.
- **SQLite WAL Mode**: Litestream requires WAL mode. Empty WAL files need a write to initialize the header.

## Debugging Tips

### Litestream Issues
- Check logs: `nomad alloc logs <alloc> litestream`
- "database disk image is malformed" during checkpoint = WAL/database mismatch
- Fix: Stop allocation, restore clean database, remove `-wal` and `-shm` files, restart

### GlusterFS Issues
- Stale mounts: Restart CSI node plugin
- Mount options configured in `modules/plugin-csi-glusterfs/`

## Links

- Nomad UI: https://nomad.brmartin.co.uk:443
