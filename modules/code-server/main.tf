resource "nomad_job" "media-centre" {
  jobspec = file("${path.module}/jobspec.json")
  json    = true
}
