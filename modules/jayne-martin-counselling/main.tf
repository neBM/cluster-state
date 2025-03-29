resource "nomad_job" "jayne-martin-counselling" {
  jobspec = file("${path.module}/jobspec.nomad.hcl")
}
