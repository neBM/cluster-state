resource "nomad_job" "this" {
  jobspec = file(var.jobspec_path)

  dynamic "hcl2" {
    for_each = var.use_hcl2 ? [1] : []
    content {
      vars = var.hcl2_vars
    }
  }

  purge_on_destroy = var.purge_on_destroy
  detach           = var.detach
}
