resource "nomad_job" "keycloak" {
  jobspec = file("${path.module}/jobspec.nomad.hcl")
}
