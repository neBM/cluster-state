resource "nomad_job" "dummy" {
  jobspec = file("${path.module}/jobspec.json")
  json    = true
}