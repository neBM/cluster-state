job "plugin-martinibar-nodes" {
  type = "system"

  group "nodes" {
    task "plugin" {
      driver = "docker"

      config {
        image      = "mcr.microsoft.com/k8s/csi/nfs-csi:latest"
        privileged = true

        args = [
          "--endpoint=unix://csi/csi.sock",
          "--nodeid=${attr.unique.hostname}",
          "--v=5",
        ]
      }

      csi_plugin {
        id        = "martinibar"
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
