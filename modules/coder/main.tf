resource "nomad_job" "coder" {
  jobspec = file("${path.module}/jobspec.json")
  json    = true
}
