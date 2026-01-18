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
          "--log-level=info",
          "--csi-mode=node",
          "--server-socket=/csi/csi.sock",
        ]
      }

      template {
        destination = "${NOMAD_TASK_DIR}/driver-config.yaml"
        data        = <<-EOF
driver: nfs-client
nfs:
  # Using kernel NFS on Hestia with noac to prevent stale file handles
  shareHost: 127.0.0.1
  shareBasePath: /storage
  controllerBasePath: /storage
  dirPermissionsMode: "0777"
  dirPermissionsUser: root
  dirPermissionsGroup: root
node:
  mount:
    # Comma-separated mount options for NFS
    # softerr: return ETIMEDOUT on timeout (vs EIO for soft, or hang for hard)
    # lookupcache=none: don't cache directory lookups (helps with stale handles)
    # actimeo=0: disable attribute caching
    # cto: close-to-open consistency (revalidate on open)
    # timeo=150: 15 second timeout (in deciseconds)
    # retrans=5: 5 retries before reporting error  
    # local_lock=all: handle locking locally (required for flock)
    mount_flags: "nfsvers=3,noatime,softerr,lookupcache=none,actimeo=0,cto,timeo=150,retrans=5,rsize=1048576,wsize=1048576,local_lock=all"
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
