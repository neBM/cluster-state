job "plugin-glusterfs-nodes" {
  type = "system"

  group "nodes" {
    task "plugin" {
      driver = "docker"

      config {
        image        = "democraticcsi/democratic-csi:v1.9.5"
        privileged   = true
        network_mode = "host"

        args = [
          "--csi-version=1.5.0",
          "--csi-name=org.democratic-csi.nfs-glusterfs",
          "--driver-config-file=${NOMAD_TASK_DIR}/driver-config.yaml",
          "--log-level=warn",
          "--csi-mode=node",
          "--server-socket=/csi/csi.sock",
        ]
      }

      template {
        destination = "${NOMAD_TASK_DIR}/driver-config.yaml"
        data        = <<-EOF
driver: nfs-client
nfs:
  # Using kernel NFS v4.2 on Hestia for better file handle stability
  shareHost: 127.0.0.1
  shareBasePath: /storage
  controllerBasePath: /storage
  dirPermissionsMode: "0777"
  dirPermissionsUser: root
  dirPermissionsGroup: root
node:
  mount:
    # NFS v4.2 mount options
    # - nfsvers=4.2: Use NFS v4.2 for better file handle stability with FUSE re-export
    # - noatime: don't update access times (performance)
    # - softerr: return ETIMEDOUT on timeout (vs EIO for soft, or hang for hard)
    # - lookupcache=positive: cache positive lookups only (safer than none, faster than all)
    # - actimeo=0: disable attribute caching for consistency
    mount_flags: nfsvers=4.2,noatime,softerr,lookupcache=positive,actimeo=0
EOF
      }

      csi_plugin {
        id        = "glusterfs"
        type      = "node"
        mount_dir = "/csi"
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}
