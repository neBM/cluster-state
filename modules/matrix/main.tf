resource "nomad_job" "matrix" {
  jobspec = file("${path.module}/jobspec.nomad.hcl")
}
