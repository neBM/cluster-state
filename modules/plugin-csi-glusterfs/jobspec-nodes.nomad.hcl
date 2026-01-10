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
  shareHost: 127.0.0.1
  shareBasePath: /storage
  controllerBasePath: /storage
  dirPermissionsMode: "0777"
  dirPermissionsUser: root
  dirPermissionsGroup: root
  mountOptions:
    - nfsvers=3
    - noatime
    - ac
    - actimeo=60
    - lookupcache=positive
    - hard
    - intr
    - retrans=3
    - timeo=600
    - rsize=1048576
    - wsize=1048576
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
