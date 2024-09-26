resource "nomad_job" "plextraktsync" {
  jobspec = file("${path.module}/jobspec.nomad.hcl")
}
