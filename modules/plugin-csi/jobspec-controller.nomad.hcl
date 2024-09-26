job "plugin-nfs-controller" {
  group "controller" {
    task "plugin" {
      driver = "docker"

      config {
        image = "mcr.microsoft.com/k8s/csi/nfs-csi:latest"

        args = [
          "--endpoint=unix://csi/csi.sock",
          "--nodeid=${attr.unique.hostname}",
          "--v=5",
        ]
      }

      csi_plugin {
        id        = "nfs"
        type      = "controller"
        mount_dir = "/csi"
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}
