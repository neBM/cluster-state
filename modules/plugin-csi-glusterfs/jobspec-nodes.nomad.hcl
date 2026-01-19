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
    # NFS v4.2 mount options for GlusterFS re-export via localhost
    # - nfsvers=4.2: Better file handle stability with FUSE re-export
    # - noatime: Don't update access times (performance)
    # - async: Async writes - safe since GlusterFS provides durability
    # - softerr: Return ETIMEDOUT on timeout (vs EIO for soft, or hang for hard)
    # - nocto: Skip close-to-open consistency (safe for single-writer volumes)
    # - lookupcache=all: Cache both positive and negative lookups
    # Note: using default actimeo (3-60s) now that NFS v4.2 is stable
    mount_flags: nfsvers=4.2,noatime,async,softerr,nocto,lookupcache=all
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
