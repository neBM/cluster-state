resource "nomad_job" "dummy" {
  jobspec = file("${path.module}/jobspec.nomad.hcl")
}