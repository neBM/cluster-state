resource "nomad_job" "renovate" {
  jobspec = file("${path.module}/jobspec.nomad.hcl")
}
