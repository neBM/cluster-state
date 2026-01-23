# Data Model: Kubernetes Volume Provisioning

**Feature**: 005-k8s-volume-provisioning  
**Date**: 2026-01-23

## Entities

### StorageClass

Kubernetes resource that defines how volumes are provisioned.

| Field | Type | Description |
|-------|------|-------------|
| name | string | `glusterfs-nfs` |
| provisioner | string | `nfs.io/nfs-subdir-external-provisioner` |
| reclaimPolicy | enum | `Retain` (preserve data on PVC deletion) |
| volumeBindingMode | enum | `Immediate` (provision when PVC created) |
| parameters.pathPattern | string | `glusterfs_${.PVC.annotations.volume-name}` |
| parameters.onDelete | string | `retain` (don't delete directory) |

### PersistentVolumeClaim (PVC)

Request for storage that triggers directory creation.

| Field | Type | Description |
|-------|------|-------------|
| name | string | Service-specific (e.g., `myapp-data`) |
| storageClassName | string | `glusterfs-nfs` |
| accessModes | list | `[ReadWriteMany]` or `[ReadWriteOnce]` |
| storage | quantity | Requested size (ignored - no quota support) |
| annotations.volume-name | string | Directory suffix (e.g., `myapp_data`) |

### PersistentVolume (PV)

Automatically created by provisioner when PVC is bound.

| Field | Type | Description |
|-------|------|-------------|
| name | string | Auto-generated (pvc-{uuid}) |
| storageClassName | string | `glusterfs-nfs` |
| nfs.server | string | `127.0.0.1` |
| nfs.path | string | `/storage/v/glusterfs_{volume-name}` |
| persistentVolumeReclaimPolicy | enum | `Retain` |

## Relationships

```
┌─────────────────┐
│  StorageClass   │
│  glusterfs-nfs  │
└────────┬────────┘
         │ references
         ▼
┌─────────────────┐         ┌─────────────────┐
│      PVC        │ ──────> │       PV        │
│  myapp-data     │ creates │  pvc-{uuid}     │
│                 │         │                 │
│ annotations:    │         │ nfs.path:       │
│   volume-name:  │         │   /storage/v/   │
│     myapp_data  │         │   glusterfs_    │
└─────────────────┘         │   myapp_data    │
                            └────────┬────────┘
                                     │ mounts
                                     ▼
                            ┌─────────────────┐
                            │    Directory    │
                            │  (GlusterFS)    │
                            │                 │
                            │ /storage/v/     │
                            │ glusterfs_      │
                            │ myapp_data/     │
                            └─────────────────┘
```

## State Transitions

### PVC Lifecycle

```
                    ┌──────────────┐
                    │   Created    │
                    │  (Pending)   │
                    └──────┬───────┘
                           │ provisioner detects
                           ▼
                    ┌──────────────┐
                    │  Provisioning│
                    │              │
                    │ • Create dir │
                    │ • Create PV  │
                    └──────┬───────┘
                           │ success
                           ▼
                    ┌──────────────┐
                    │    Bound     │
                    │              │
                    │ PVC → PV     │
                    │ linked       │
                    └──────┬───────┘
                           │ PVC deleted
                           ▼
                    ┌──────────────┐
                    │   Released   │
                    │              │
                    │ PV retained  │
                    │ Dir retained │
                    └──────────────┘
```

## Validation Rules

### PVC Annotations

- `volume-name` MUST be provided via annotation
- `volume-name` MUST match pattern `[a-z0-9_]+` (lowercase, numbers, underscores)
- `volume-name` SHOULD follow convention `<service>_<type>` (e.g., `myapp_data`, `gitlab_config`)

### Directory Creation

- Directory MUST be created under `/storage/v/`
- Directory MUST have permissions `0777`
- Directory MUST have ownership `root:root`
- Directory name MUST be `glusterfs_{volume-name}`

### Access Modes

| Mode | Use Case |
|------|----------|
| `ReadWriteMany` (RWX) | Multiple pods, multiple nodes (default) |
| `ReadWriteOnce` (RWO) | Single pod only |
| `ReadOnlyMany` (ROX) | Read-only access from multiple pods |

## Terraform Variables

### nfs-provisioner Module

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| namespace | string | `default` | K8s namespace for provisioner |
| nfs_server | string | `127.0.0.1` | NFS server address |
| nfs_path | string | `/storage/v` | NFS export path |
| storage_class_name | string | `glusterfs-nfs` | StorageClass name |
| reclaim_policy | string | `Retain` | What happens on PVC delete |
| path_pattern | string | `glusterfs_${.PVC.annotations.volume-name}` | Directory naming pattern |

### Service Module PVC

| Variable | Type | Required | Description |
|----------|------|----------|-------------|
| volume_name | string | Yes | Directory suffix (e.g., `myapp_data`) |
| storage_size | string | No | Requested size (e.g., `1Gi`) - cosmetic only |
| access_mode | string | No | `ReadWriteMany` (default) or `ReadWriteOnce` |
