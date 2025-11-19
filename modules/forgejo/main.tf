resource "nomad_job" "forgejo" {
  jobspec = file("${path.module}/jobspec.nomad.hcl")
}
