resource "nomad_job" "restic_backup" {
  jobspec = file("${path.module}/jobspec.nomad.hcl")
}
