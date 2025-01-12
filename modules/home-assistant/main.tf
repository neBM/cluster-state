resource "nomad_job" "home-assistant" {
  jobspec = file("${path.module}/jobspec.nomad.hcl")
}
