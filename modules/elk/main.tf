resource "nomad_job" "elk" {
  jobspec = file("${path.module}/jobspec.nomad.hcl")

  hcl2 {
    vars = {
      "elastic_version" = "8.16.1",
    }
  }
}
