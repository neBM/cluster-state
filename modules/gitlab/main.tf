# GitLab uses host volumes on Hestia (direct GlusterFS FUSE mount)
# No CSI volumes needed - host volumes are configured in Nomad client config

resource "nomad_job" "gitlab" {
  jobspec = file("${path.module}/jobspec.nomad.hcl")
}
