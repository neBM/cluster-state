terraform {
  required_version = ">= 1.2.0, < 2.0.0"
  backend "pg" {}
}

# =============================================================================
# Nomad CSI Plugins (required for media-centre)
# =============================================================================

# Martinibar CSI plugin (NFS) - for media-centre legacy volumes
module "plugin_csi_controller" {
  source = "./modules/nomad-job"

  jobspec_path = "./modules/plugin-csi/jobspec-controller.nomad.hcl"
}

module "plugin_csi_nodes" {
  source = "./modules/nomad-job"

  jobspec_path = "./modules/plugin-csi/jobspec-nodes.nomad.hcl"
}

# GlusterFS CSI plugin (democratic-csi) - for media-centre
module "plugin_csi_glusterfs_controller" {
  source = "./modules/nomad-job"

  jobspec_path = "./modules/plugin-csi-glusterfs/jobspec-controller.nomad.hcl"
}

module "plugin_csi_glusterfs_nodes" {
  source = "./modules/nomad-job"

  jobspec_path = "./modules/plugin-csi-glusterfs/jobspec-nodes.nomad.hcl"
}

# =============================================================================
# Nomad Services (NOT migrated to K8s)
# =============================================================================

# ELK Stack - Complex 3-node Elasticsearch cluster, excluded from migration
module "elk" {
  source = "./modules/nomad-job"

  jobspec_path = "./modules/elk/jobspec.nomad.hcl"
  use_hcl2     = true
  hcl2_vars = {
    # renovate: image=docker.elastic.co/elasticsearch/elasticsearch
    elastic_version = "9.2.3"
  }
}

# Media Centre - Plex, Sonarr, Radarr, etc. Excluded from migration
module "media_centre" {
  source = "./modules/media-centre"

  depends_on = [
    module.plugin_csi_glusterfs_controller,
    module.plugin_csi_glusterfs_nodes
  ]
}

# Jayne Martin Counselling - Static website (consider migrating later)
module "jayne_martin_counselling" {
  source = "./modules/nomad-job"

  jobspec_path = "./modules/jayne-martin-counselling/jobspec.nomad.hcl"
}
