resource "nomad_job" "ollama_core" {
  jobspec = file("${path.module}/jobspec.nomad.hcl")
}
