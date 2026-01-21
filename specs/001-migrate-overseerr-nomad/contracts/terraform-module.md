# Terraform Module Contract: overseerr

**Module Path**: `modules/overseerr/`

## Files

| File | Purpose |
|------|---------|
| `main.tf` | Terraform resources (CSI volume, job) |
| `jobspec.nomad.hcl` | Nomad job definition |

## Resources Created

### `nomad_csi_volume.glusterfs_overseerr_config`

```hcl
resource "nomad_csi_volume" "glusterfs_overseerr_config" {
  plugin_id    = "glusterfs"
  name         = "glusterfs_overseerr_config"
  volume_id    = "glusterfs_overseerr_config"
  capacity_min = "100MiB"
  capacity_max = "1GiB"

  capability {
    access_mode     = "single-node-writer"
    attachment_mode = "file-system"
  }

  lifecycle {
    prevent_destroy = true
  }
}
```

### `nomad_job.overseerr`

```hcl
resource "nomad_job" "overseerr" {
  depends_on = [nomad_csi_volume.glusterfs_overseerr_config]
  jobspec    = file("${path.module}/jobspec.nomad.hcl")
}
```

## Data Sources

### `nomad_plugin.glusterfs`

```hcl
data "nomad_plugin" "glusterfs" {
  plugin_id        = "glusterfs"
  wait_for_healthy = true
}
```

## Dependencies

| Resource | Depends On |
|----------|-----------|
| `nomad_csi_volume.glusterfs_overseerr_config` | `data.nomad_plugin.glusterfs` |
| `nomad_job.overseerr` | `nomad_csi_volume.glusterfs_overseerr_config` |

## External Dependencies (Not Managed by Module)

| Dependency | Location | Required State | Status |
|------------|----------|----------------|--------|
| GlusterFS CSI plugin | `modules/plugin-csi-glusterfs` | Healthy | Existing |
| MinIO service | `modules/minio` | Running | Existing |
| MinIO bucket | MinIO | `overseerr-litestream` exists | **Created** |
| Vault secret | Vault | `nomad/default/overseerr` with MINIO_* keys | **Created** |
| Traefik | `modules/traefik` | Running, watching Consul catalog | Existing |

## Module Usage

```hcl
# In root main.tf
module "overseerr" {
  source = "./modules/overseerr"
}
```

No variables or outputs - module is self-contained following existing patterns.
