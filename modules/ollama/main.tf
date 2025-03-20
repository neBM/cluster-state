resource "nomad_job" "ollama" {
  jobspec = file("${path.module}/jobspec.nomad.hcl")
}
