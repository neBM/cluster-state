resource "nomad_job" "nfs-controller" {
  jobspec = file("${path.module}/jobspec-controller.nomad.hcl")
}

resource "nomad_job" "nfs-nodes" {
  jobspec = file("${path.module}/jobspec-nodes.nomad.hcl")
}
