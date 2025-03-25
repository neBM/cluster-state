resource "nomad_job" "elk" {
  jobspec = file("${path.module}/jobspec.nomad.hcl")

  hcl2 {
    vars = {
      # renovate: image=docker.elastic.co/elasticsearch/elasticsearch
      "elastic_version" = "8.17.4",
    }
  }
}
