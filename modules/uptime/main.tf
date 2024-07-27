resource "nomad_job" "uptime" {
  jobspec = file("${path.module}/jobspec.json")
  json    = true
}
