# -----------------------------------------------------------------------------
# CSI Driver registration
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "csi_driver" {
  yaml_body = yamlencode({
    apiVersion = "storage.k8s.io/v1"
    kind       = "CSIDriver"
    metadata = {
      name   = "seaweedfs-csi-driver"
      labels = local.labels
    }
    spec = {
      attachRequired = true
      podInfoOnMount = true
      fsGroupPolicy  = "File"
    }
  })
}

# -----------------------------------------------------------------------------
# CSI Controller — Deployment (provisioner + attacher + resizer sidecars)
# -----------------------------------------------------------------------------

resource "kubernetes_deployment" "csi_controller" {
  metadata {
    name      = "seaweedfs-csi-controller"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "csi-controller" })
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = local.app_name, component = "csi-controller" }
    }

    template {
      metadata {
        labels = merge(local.labels, { component = "csi-controller" })
      }

      spec {
        service_account_name = kubernetes_service_account.csi.metadata[0].name

        toleration {
          key      = "node-role.kubernetes.io/control-plane"
          operator = "Exists"
          effect   = "NoSchedule"
        }

        # CSI plugin
        container {
          name              = "csi-seaweedfs"
          image             = "registry.brmartin.co.uk/ben/seaweedfs-csi-driver:${var.csi_driver_image_tag}"
          image_pull_policy = "IfNotPresent"

          args = [
            "--endpoint=$(CSI_ENDPOINT)",
            "--filer=$(SEAWEEDFS_FILER)",
            "--driverName=seaweedfs-csi-driver",
            "--components=controller",
            "--attacher=true",
            # Disable /metrics server in the controller pod — :9810 collides
            # with the csi-resizer sidecar's own metrics endpoint. The dial-retry
            # metrics only exist on node-side code paths, so the controller has
            # nothing useful to export. csi-node still serves /metrics on :9810.
            "--metricsPort=0",
          ]

          env {
            name  = "CSI_ENDPOINT"
            value = "unix:///var/lib/csi/sockets/pluginproxy/csi.sock"
          }

          env {
            name  = "SEAWEEDFS_FILER"
            value = "seaweedfs-filer:8888"
          }

          volume_mount {
            name       = "socket-dir"
            mount_path = "/var/lib/csi/sockets/pluginproxy"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }
        }

        # csi-provisioner sidecar
        container {
          name  = "csi-provisioner"
          image = "registry.k8s.io/sig-storage/csi-provisioner:${var.csi_provisioner_image_tag}"

          args = [
            "--csi-address=$(ADDRESS)",
            "--leader-election",
            "--leader-election-namespace=${var.namespace}",
            "--http-endpoint=:9809",
          ]

          env {
            name  = "ADDRESS"
            value = "/var/lib/csi/sockets/pluginproxy/csi.sock"
          }

          volume_mount {
            name       = "socket-dir"
            mount_path = "/var/lib/csi/sockets/pluginproxy"
          }

          resources {
            requests = {
              cpu    = "20m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "64Mi"
            }
          }
        }

        # csi-attacher sidecar
        container {
          name  = "csi-attacher"
          image = "registry.k8s.io/sig-storage/csi-attacher:${var.csi_attacher_image_tag}"

          args = [
            "--csi-address=$(ADDRESS)",
            "--leader-election",
            "--leader-election-namespace=${var.namespace}",
            "--http-endpoint=:9811",
          ]

          env {
            name  = "ADDRESS"
            value = "/var/lib/csi/sockets/pluginproxy/csi.sock"
          }

          volume_mount {
            name       = "socket-dir"
            mount_path = "/var/lib/csi/sockets/pluginproxy"
          }

          resources {
            requests = {
              cpu    = "20m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "64Mi"
            }
          }
        }

        # csi-resizer sidecar
        container {
          name  = "csi-resizer"
          image = "registry.k8s.io/sig-storage/csi-resizer:${var.csi_resizer_image_tag}"

          args = [
            "--csi-address=$(ADDRESS)",
            "--leader-election",
            "--leader-election-namespace=${var.namespace}",
            "--http-endpoint=:9810",
          ]

          env {
            name  = "ADDRESS"
            value = "/var/lib/csi/sockets/pluginproxy/csi.sock"
          }

          volume_mount {
            name       = "socket-dir"
            mount_path = "/var/lib/csi/sockets/pluginproxy"
          }

          resources {
            requests = {
              cpu    = "20m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "64Mi"
            }
          }
        }

        volume {
          name = "socket-dir"
          empty_dir {}
        }
      }
    }
  }
}

# -----------------------------------------------------------------------------
# CSI Node — DaemonSet (node plugin + registrar + mount helper)
# -----------------------------------------------------------------------------

resource "kubernetes_daemon_set_v1" "csi_node" {
  metadata {
    name      = "seaweedfs-csi-node"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "csi-node" })
  }

  spec {
    selector {
      match_labels = { app = local.app_name, component = "csi-node" }
    }

    template {
      metadata {
        labels = merge(local.labels, { component = "csi-node" })
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "9810"
          "prometheus.io/path"   = "/metrics"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.csi.metadata[0].name

        toleration {
          key      = "node-role.kubernetes.io/control-plane"
          operator = "Exists"
          effect   = "NoSchedule"
        }

        # CSI node plugin
        container {
          name              = "csi-seaweedfs"
          image             = "registry.brmartin.co.uk/ben/seaweedfs-csi-driver:${var.csi_driver_image_tag}"
          image_pull_policy = "IfNotPresent"

          args = [
            "--endpoint=$(CSI_ENDPOINT)",
            "--filer=$(SEAWEEDFS_FILER)",
            "--nodeid=$(NODE_ID)",
            "--driverName=seaweedfs-csi-driver",
            "--mountEndpoint=$(MOUNT_ENDPOINT)",
            "--cacheDir=/var/cache/seaweedfs",
            "--components=node",
          ]

          env {
            name  = "CSI_ENDPOINT"
            value = "unix:///csi/csi.sock"
          }

          env {
            name  = "SEAWEEDFS_FILER"
            value = "seaweedfs-filer:8888"
          }

          env {
            name = "NODE_ID"
            value_from {
              field_ref {
                field_path = "spec.nodeName"
              }
            }
          }

          env {
            name  = "MOUNT_ENDPOINT"
            value = "unix:///var/lib/seaweedfs-mount/seaweedfs-mount.sock"
          }

          env {
            name = "POD_NAME"
            value_from {
              field_ref {
                field_path = "metadata.name"
              }
            }
          }

          env {
            name = "POD_NAMESPACE"
            value_from {
              field_ref {
                field_path = "metadata.namespace"
              }
            }
          }

          security_context {
            privileged = true
          }

          port {
            name           = "healthz"
            container_port = 9808
          }

          port {
            name           = "metrics"
            container_port = 9810
            protocol       = "TCP"
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = "healthz"
            }
            initial_delay_seconds = 10
            period_seconds        = 30
            failure_threshold     = 5
          }

          volume_mount {
            name       = "plugin-dir"
            mount_path = "/csi"
          }

          volume_mount {
            name              = "kubelet-plugins"
            mount_path        = "/var/lib/kubelet/plugins"
            mount_propagation = "Bidirectional"
          }

          volume_mount {
            name              = "kubelet-pods"
            mount_path        = "/var/lib/kubelet/pods"
            mount_propagation = "Bidirectional"
          }

          volume_mount {
            name       = "dev"
            mount_path = "/dev"
          }

          volume_mount {
            name       = "cache"
            mount_path = "/var/cache/seaweedfs"
          }

          volume_mount {
            name       = "mount-socket"
            mount_path = "/var/lib/seaweedfs-mount"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }
        }

        # Node driver registrar
        container {
          name  = "node-driver-registrar"
          image = "registry.k8s.io/sig-storage/csi-node-driver-registrar:${var.csi_node_registrar_image_tag}"

          args = [
            "--csi-address=$(ADDRESS)",
            "--kubelet-registration-path=$(DRIVER_REG_SOCK_PATH)",
            "--http-endpoint=:9809",
          ]

          env {
            name  = "ADDRESS"
            value = "/csi/csi.sock"
          }

          env {
            name  = "DRIVER_REG_SOCK_PATH"
            value = "/var/lib/kubelet/plugins/seaweedfs-csi-driver/csi.sock"
          }

          env {
            name = "KUBE_NODE_NAME"
            value_from {
              field_ref {
                field_path = "spec.nodeName"
              }
            }
          }

          volume_mount {
            name       = "plugin-dir"
            mount_path = "/csi"
          }

          volume_mount {
            name       = "registration-dir"
            mount_path = "/registration"
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "16Mi"
            }
            limits = {
              cpu    = "50m"
              memory = "32Mi"
            }
          }
        }

        # Liveness probe sidecar
        container {
          name  = "liveness-probe"
          image = "registry.k8s.io/sig-storage/livenessprobe:${var.csi_liveness_probe_image_tag}"

          args = [
            "--csi-address=$(ADDRESS)",
            "--http-endpoint=:9808",
          ]

          env {
            name  = "ADDRESS"
            value = "/csi/csi.sock"
          }

          volume_mount {
            name       = "plugin-dir"
            mount_path = "/csi"
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "16Mi"
            }
            limits = {
              cpu    = "50m"
              memory = "32Mi"
            }
          }
        }

        volume {
          name = "plugin-dir"
          host_path {
            path = "/var/lib/kubelet/plugins/seaweedfs-csi-driver"
            type = "DirectoryOrCreate"
          }
        }

        volume {
          name = "kubelet-plugins"
          host_path {
            path = "/var/lib/kubelet/plugins"
            type = "Directory"
          }
        }

        volume {
          name = "kubelet-pods"
          host_path {
            path = "/var/lib/kubelet/pods"
            type = "Directory"
          }
        }

        volume {
          name = "registration-dir"
          host_path {
            path = "/var/lib/kubelet/plugins_registry"
            type = "Directory"
          }
        }

        volume {
          name = "dev"
          host_path {
            path = "/dev"
          }
        }

        volume {
          name = "cache"
          host_path {
            path = "/var/cache/seaweedfs"
            type = "DirectoryOrCreate"
          }
        }

        volume {
          name = "mount-socket"
          host_path {
            path = "/var/lib/seaweedfs-mount"
            type = "DirectoryOrCreate"
          }
        }
      }
    }
  }
}

# -----------------------------------------------------------------------------
# SeaweedFS Mount — DaemonSet (FUSE daemon host, independent lifecycle)
#
# Split from seaweedfs-csi-node so that CSI driver restarts do not kill FUSE
# sessions. Update strategy is OnDelete: operator-controlled restarts only,
# because restarting this DaemonSet kills all weed mount subprocesses and
# requires cycling every consumer pod on each affected node.
# -----------------------------------------------------------------------------

resource "kubernetes_daemon_set_v1" "seaweedfs_mount" {
  metadata {
    name      = "seaweedfs-mount"
    namespace = var.namespace
    labels    = merge(local.labels, { component = "seaweedfs-mount" })
  }

  spec {
    selector {
      match_labels = { app = local.app_name, component = "seaweedfs-mount" }
    }

    strategy {
      type = "OnDelete"
    }

    template {
      metadata {
        labels = merge(local.labels, { component = "seaweedfs-mount" })
      }

      spec {
        service_account_name = kubernetes_service_account.csi.metadata[0].name

        toleration {
          key      = "node-role.kubernetes.io/control-plane"
          operator = "Exists"
          effect   = "NoSchedule"
        }

        # The mount service. At startup it reconciles any stale fuse.seaweedfs
        # mounts left by a prior instance, then listens on the shared socket
        # for mount/unmount RPCs from csi-seaweedfs.
        container {
          name              = "seaweedfs-mount"
          image             = "registry.brmartin.co.uk/ben/seaweedfs-mount:${var.csi_mount_image_tag}"
          image_pull_policy = "IfNotPresent"

          args = [
            "--endpoint=$(MOUNT_ENDPOINT)",
          ]

          env {
            name  = "MOUNT_ENDPOINT"
            value = "unix:///var/lib/seaweedfs-mount/seaweedfs-mount.sock"
          }

          env {
            name  = "GOMEMLIMIT"
            value = "1800MiB"
          }

          security_context {
            privileged = true
          }

          volume_mount {
            name              = "kubelet-plugins"
            mount_path        = "/var/lib/kubelet/plugins"
            mount_propagation = "Bidirectional"
          }

          volume_mount {
            name              = "kubelet-pods"
            mount_path        = "/var/lib/kubelet/pods"
            mount_propagation = "Bidirectional"
          }

          volume_mount {
            name       = "mount-socket"
            mount_path = "/var/lib/seaweedfs-mount"
          }

          volume_mount {
            name       = "cache"
            mount_path = "/var/cache/seaweedfs"
          }

          volume_mount {
            name       = "dev"
            mount_path = "/dev"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "2Gi"
            }
          }
        }

        volume {
          name = "kubelet-plugins"
          host_path {
            path = "/var/lib/kubelet/plugins"
            type = "Directory"
          }
        }

        volume {
          name = "kubelet-pods"
          host_path {
            path = "/var/lib/kubelet/pods"
            type = "Directory"
          }
        }

        volume {
          name = "mount-socket"
          host_path {
            path = "/var/lib/seaweedfs-mount"
            type = "DirectoryOrCreate"
          }
        }

        volume {
          name = "cache"
          host_path {
            path = "/var/cache/seaweedfs"
            type = "DirectoryOrCreate"
          }
        }

        volume {
          name = "dev"
          host_path {
            path = "/dev"
          }
        }
      }
    }
  }
}
