# Nextcloud - File storage platform
#
# Components:
# - nextcloud: Main app with redis sidecar (port 80)
# - cron: Background jobs container (shares volumes with nextcloud)
#
# Storage (PVCs via seaweedfs StorageClass)
#
# External PostgreSQL on 192.168.1.10:5433

locals {
  nextcloud_labels = {
    app       = "nextcloud"
    component = "nextcloud"
  }

  # Elastic Agent log routing annotations
  elastic_log_annotations = {
    "elastic.co/dataset" = "kubernetes.container_logs.nextcloud"
  }
}

# =============================================================================
# Persistent Volume Claims (glusterfs-nfs)
# =============================================================================

resource "kubernetes_persistent_volume_claim" "config" {
  metadata {
    name      = "nextcloud-config"
    namespace = var.namespace
  }
  spec {
    storage_class_name = "seaweedfs"
    access_modes       = ["ReadWriteMany"]
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "custom_apps" {
  metadata {
    name      = "nextcloud-custom-apps"
    namespace = var.namespace
  }
  spec {
    storage_class_name = "seaweedfs"
    access_modes       = ["ReadWriteMany"]
    resources {
      requests = {
        storage = "5Gi"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "data" {
  metadata {
    name      = "nextcloud-data"
    namespace = var.namespace
  }
  spec {
    storage_class_name = "seaweedfs"
    access_modes       = ["ReadWriteMany"]
    resources {
      requests = {
        storage = "50Gi"
      }
    }
  }
}

# =============================================================================
# Config override files (mounted via subPath, immune to NFS corruption)
#
# Nextcloud loads all *.config.php files from the config directory. Values in
# later files (alphabetically) override earlier ones. The "zz-" prefix ensures
# these load last, so they always take precedence over config.php on the NFS PVC.
#
# This follows the same pattern as the official Nextcloud Helm chart:
# https://github.com/nextcloud/helm/blob/main/charts/nextcloud/templates/_helpers.tpl
# =============================================================================

resource "kubernetes_config_map" "nextcloud_config" {
  metadata {
    name      = "nextcloud-config-override"
    namespace = var.namespace
    labels    = local.nextcloud_labels
  }

  data = {
    "zz-override.config.php" = <<-PHP
      <?php
      $CONFIG = array (
        'installed' => true,
        'dbtype' => 'pgsql',
        'dbhost' => '${var.db_host}:${var.db_port}',
        'dbname' => '${var.db_name}',
        'dbuser' => '${var.db_user}',
        'dbtableprefix' => 'oc_',
        'datadirectory' => '/var/www/html/data',
        'overwriteprotocol' => 'https',
        'overwrite.cli.url' => 'https://${var.hostname}',
        'trusted_domains' => array (
          0 => '${var.hostname}',
          1 => '192.168.1.*',
        ),
        'trusted_proxies' => array (
          0 => '172.26.0.0/16',
          1 => '10.0.0.0/8',
          2 => 'fd00::/24',
        ),
        'upgrade.disable-web' => true,
        'maintenance_window_start' => 1,
        'oidc_login_client_id' => '${var.oidc_client_id}',
        'oidc_login_provider_url' => '${var.oidc_provider_url}',
        'oidc_login_end_session_redirect' => 'true',
        'oidc_login_logout_url' => 'https://${var.hostname}/apps/oidc_login/oidc',
        'oidc_login_auto_redirect' => 'true',
        'oidc_login_redir_fallback' => 'true',
        'oidc_login_disable_registration' => 'false',
        'oidc_login_attributes' => array (
          'id' => 'preferred_username',
          'mail' => 'email',
        ),
        'mail_from_address' => 'services',
        'mail_smtpmode' => 'smtp',
        'mail_sendmailmode' => 'smtp',
        'mail_domain' => 'brmartin.co.uk',
        'mail_smtphost' => 'mail.brmartin.co.uk',
        'mail_smtpport' => '587',
        'mail_smtpauth' => 1,
        'mail_smtpname' => '${var.mail_smtp_user}',
        'app_install_overwrite' => array (
          0 => 'oidc_login',
        ),
      );
    PHP

  }
}

# =============================================================================
# Nextcloud Deployment (with Redis sidecar)
# =============================================================================

resource "kubernetes_deployment" "nextcloud" {
  metadata {
    name      = "nextcloud"
    namespace = var.namespace
    labels    = local.nextcloud_labels
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate" # Required for RWX volumes with single-writer semantics
    }

    selector {
      match_labels = local.nextcloud_labels
    }

    template {
      metadata {
        labels      = local.nextcloud_labels
        annotations = local.elastic_log_annotations
      }

      spec {
        security_context {
          fs_group               = 33
          fs_group_change_policy = "OnRootMismatch"
        }

        # FUSE mounts default to 777; Nextcloud rejects world-readable data dirs.
        # fsGroup handles ownership via -map.gid; this just fixes permissions.
        init_container {
          name    = "fix-data-perms"
          image   = "busybox:1"
          command = ["sh", "-c", "chown 33:33 /nc-data && chmod 0770 /nc-data && chown 33:33 /nc-config /nc-custom-apps"]

          volume_mount {
            name              = "config"
            mount_path        = "/nc-config"
            mount_propagation = "HostToContainer"
          }

          volume_mount {
            name              = "custom-apps"
            mount_path        = "/nc-custom-apps"
            mount_propagation = "HostToContainer"
          }

          volume_mount {
            name              = "data"
            mount_path        = "/nc-data"
            mount_propagation = "HostToContainer"
          }
        }

        # Generate zz-secrets.config.php from K8s secret keys into an emptyDir.
        # This runs before Nextcloud starts, ensuring critical secrets are available
        # even if the NFS-mounted config.php gets corrupted.
        init_container {
          name  = "generate-secrets-config"
          image = "busybox:1"
          command = [
            "sh", "-c",
            <<-EOT
            cat > /out/zz-secrets.config.php <<'EOPHP'
            <?php
            $CONFIG = array (
            EOPHP
            for pair in \
              "instanceid:$NC_INSTANCEID" \
              "passwordsalt:$NC_PASSWORDSALT" \
              "secret:$NC_SECRET" \
              "dbpassword:$NC_DBPASSWORD" \
              "oidc_login_client_secret:$NC_OIDC_CLIENT_SECRET" \
              "mail_smtppassword:$NC_MAIL_SMTP_PASSWORD"; do
              key=$${pair%%:*}
              val=$${pair#*:}
              printf "  '%s' => '%s',\n" "$key" "$val" >> /out/zz-secrets.config.php
            done
            echo ');' >> /out/zz-secrets.config.php
            EOT
          ]

          dynamic "env" {
            for_each = {
              NC_INSTANCEID         = "instanceid"
              NC_PASSWORDSALT       = "passwordsalt"
              NC_SECRET             = "secret"
              NC_DBPASSWORD         = "db_password"
              NC_OIDC_CLIENT_SECRET = "oidc_client_secret"
              NC_MAIL_SMTP_PASSWORD = "mail_smtp_password"
            }
            content {
              name = env.key
              value_from {
                secret_key_ref {
                  name = "nextcloud-secrets"
                  key  = env.value
                }
              }
            }
          }

          volume_mount {
            name       = "config-secrets"
            mount_path = "/out"
          }
        }

        # Redis sidecar for caching and file locking
        container {
          name  = "redis"
          image = "${var.redis_image}:${var.redis_tag}"
          args  = ["--save", ""] # Disable persistence, ephemeral cache only

          port {
            container_port = 6379
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }

          liveness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
        }

        # Main Nextcloud container
        container {
          name  = "nextcloud"
          image = "${var.nextcloud_image}:${var.nextcloud_tag}"

          port {
            container_port = 80
          }

          env {
            name  = "POSTGRES_HOST"
            value = "${var.db_host}:${var.db_port}"
          }

          env {
            name  = "POSTGRES_DB"
            value = var.db_name
          }

          env {
            name  = "POSTGRES_USER"
            value = var.db_user
          }

          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = "nextcloud-secrets"
                key  = "db_password"
              }
            }
          }

          env {
            name  = "NEXTCLOUD_TRUSTED_DOMAINS"
            value = var.hostname
          }

          env {
            name  = "OVERWRITEPROTOCOL"
            value = "https"
          }

          env {
            name  = "TRUSTED_PROXIES"
            value = "172.26.0.0/16 10.0.0.0/8"
          }

          env {
            name  = "REDIS_HOST"
            value = "127.0.0.1" # Redis sidecar in same pod
          }

          volume_mount {
            name              = "config"
            mount_path        = "/var/www/html/config"
            mount_propagation = "HostToContainer"
          }

          volume_mount {
            name              = "custom-apps"
            mount_path        = "/var/www/html/custom_apps"
            mount_propagation = "HostToContainer"
          }

          volume_mount {
            name              = "data"
            mount_path        = "/var/www/html/data"
            mount_propagation = "HostToContainer"
          }

          volume_mount {
            name       = "config-override"
            mount_path = "/var/www/html/config/zz-override.config.php"
            sub_path   = "zz-override.config.php"
            read_only  = true
          }

          volume_mount {
            name       = "config-secrets"
            mount_path = "/var/www/html/config/zz-secrets.config.php"
            sub_path   = "zz-secrets.config.php"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "25m"
              memory = "256Mi"
            }
            limits = {
              memory = "1024Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/status.php"
              port = 80
              http_header {
                name  = "Host"
                value = var.hostname
              }
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            timeout_seconds       = 10
          }

          readiness_probe {
            http_get {
              path = "/status.php"
              port = 80
              http_header {
                name  = "Host"
                value = var.hostname
              }
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            timeout_seconds       = 5
          }
        }

        # Cron container for background jobs
        container {
          name    = "cron"
          image   = "${var.nextcloud_image}:${var.nextcloud_tag}"
          command = ["/cron.sh"]

          env {
            name  = "REDIS_HOST"
            value = "127.0.0.1"
          }

          volume_mount {
            name              = "config"
            mount_path        = "/var/www/html/config"
            mount_propagation = "HostToContainer"
          }

          volume_mount {
            name              = "custom-apps"
            mount_path        = "/var/www/html/custom_apps"
            mount_propagation = "HostToContainer"
          }

          volume_mount {
            name              = "data"
            mount_path        = "/var/www/html/data"
            mount_propagation = "HostToContainer"
          }

          volume_mount {
            name       = "config-override"
            mount_path = "/var/www/html/config/zz-override.config.php"
            sub_path   = "zz-override.config.php"
            read_only  = true
          }

          volume_mount {
            name       = "config-secrets"
            mount_path = "/var/www/html/config/zz-secrets.config.php"
            sub_path   = "zz-secrets.config.php"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }

        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.config.metadata[0].name
          }
        }

        volume {
          name = "custom-apps"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.custom_apps.metadata[0].name
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data.metadata[0].name
          }
        }

        volume {
          name = "config-override"
          config_map {
            name = kubernetes_config_map.nextcloud_config.metadata[0].name
          }
        }

        volume {
          name = "config-secrets"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [
    kubernetes_persistent_volume_claim.config,
    kubernetes_persistent_volume_claim.custom_apps,
    kubernetes_persistent_volume_claim.data,
  ]
}

resource "kubernetes_service" "nextcloud" {
  metadata {
    name      = "nextcloud"
    namespace = var.namespace
    labels    = local.nextcloud_labels
  }

  spec {
    selector = local.nextcloud_labels

    port {
      port        = 80
      target_port = 80
    }
  }
}

# =============================================================================
# IngressRoute for path-based routing with WebDAV redirect middleware
# =============================================================================

resource "kubectl_manifest" "ingressroute" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "nextcloud"
      namespace = var.namespace
      labels    = { app = "nextcloud" }
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match = "Host(`${var.hostname}`)"
          kind  = "Rule"
          middlewares = [
            { name = "nextcloud-webdav-redirect", namespace = var.namespace }
          ]
          services = [
            {
              name = kubernetes_service.nextcloud.metadata[0].name
              port = 80
            }
          ]
        }
      ]
      tls = {
        secretName = "wildcard-brmartin-tls"
      }
    }
  })
}

# WebDAV redirect middleware for CalDAV/CardDAV clients
resource "kubectl_manifest" "webdav_redirect" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "nextcloud-webdav-redirect"
      namespace = var.namespace
    }
    spec = {
      redirectRegex = {
        regex       = "https://(.*)/.well-known/(?:card|cal)dav"
        replacement = "https://$1/remote.php/dav"
        permanent   = true
      }
    }
  })
}
