terraform {
  required_version = ">= 1.2.0, < 2.0.0"
  backend "pg" {}
}

# CSI plugin should be deployed first as other jobs may depend on it
module "plugin_csi_controller" {
  source = "./modules/nomad-job"

  jobspec_path = "./modules/plugin-csi/jobspec-controller.nomad.hcl"
}

module "plugin_csi_nodes" {
  source = "./modules/nomad-job"

  jobspec_path = "./modules/plugin-csi/jobspec-nodes.nomad.hcl"
}

module "media_centre" {
  source = "./modules/nomad-job"

  jobspec_path = "./modules/media-centre/jobspec.nomad.hcl"
}

module "plextraktsync" {
  source = "./modules/nomad-job"

  jobspec_path = "./modules/plextraktsync/jobspec.nomad.hcl"
}

module "matrix" {
  source = "./modules/nomad-job"

  jobspec_path = "./modules/matrix/jobspec.nomad.hcl"
}

module "elk" {
  source = "./modules/nomad-job"

  jobspec_path = "./modules/elk/jobspec.nomad.hcl"
  use_hcl2     = true
  hcl2_vars = {
    # renovate: image=docker.elastic.co/elasticsearch/elasticsearch
    elastic_version = "9.2.3"
  }
}

module "renovate" {
  source = "./modules/nomad-job"

  jobspec_path = "./modules/renovate/jobspec.nomad.hcl"
}

module "forgejo" {
  source = "./modules/nomad-job"

  jobspec_path = "./modules/forgejo/jobspec.nomad.hcl"
}

module "keycloak" {
  source = "./modules/nomad-job"

  jobspec_path = "./modules/keycloak/jobspec.nomad.hcl"
}

module "jayne_martin_counselling" {
  source = "./modules/nomad-job"

  jobspec_path = "./modules/jayne-martin-counselling/jobspec.nomad.hcl"
}

# Modules with CSI volume dependencies
module "ollama" {
  source = "./modules/ollama"

  depends_on = [
    module.plugin_csi_controller,
    module.plugin_csi_nodes
  ]
}

module "minio" {
  source = "./modules/minio"

  depends_on = [
    module.plugin_csi_controller,
    module.plugin_csi_nodes
  ]
}

module "appflowy" {
  source = "./modules/appflowy"

  depends_on = [
    module.plugin_csi_controller,
    module.plugin_csi_nodes
  ]
}
