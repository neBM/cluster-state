locals {
  labels = {
    managed-by  = "terraform"
    environment = "prod"
  }

  wildcard_dns_names = [
    var.root_domain,
    "*.${var.root_domain}",
  ]
}

# Cloudflare API token is stored outside Terraform as a plain Kubernetes Secret.
# Create it in the cert-manager namespace before applying this module:
#   kubectl create secret generic cloudflare-api-token-secret -n cert-manager \
#     --from-literal=api-token='<cloudflare-token>'
data "kubernetes_secret" "cloudflare_api_token" {
  depends_on = [
    kubernetes_namespace.cert_manager,
  ]

  metadata {
    name      = "cloudflare-api-token-secret"
    namespace = kubernetes_namespace.cert_manager.metadata[0].name
  }
}

resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = var.namespace
    labels = merge(local.labels, {
      app = "cert-manager"
    })
  }
}

resource "kubernetes_namespace" "reloader" {
  metadata {
    name = var.reloader_namespace
    labels = merge(local.labels, {
      app = "reloader"
    })
  }
}

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.20.2"
  namespace        = kubernetes_namespace.cert_manager.metadata[0].name
  create_namespace = false
  wait             = true
  timeout          = 600

  set = [
    {
      name  = "crds.enabled"
      value = "true"
    },
  ]
}

resource "helm_release" "reloader" {
  name             = "reloader"
  repository       = "https://stakater.github.io/stakater-charts"
  chart            = "reloader"
  version          = "2.2.9"
  namespace        = kubernetes_namespace.reloader.metadata[0].name
  create_namespace = false
  wait             = true
  timeout          = 300

  set = [
    {
      name  = "reloader.reloadStrategy"
      value = "annotations"
    },
  ]
}

resource "kubectl_manifest" "cluster_issuer" {
  depends_on = [
    helm_release.cert_manager,
    data.kubernetes_secret.cloudflare_api_token,
  ]

  validate_schema = false
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = var.cluster_issuer_name
      labels = merge(local.labels, {
        app = "cert-manager"
      })
    }
    spec = {
      acme = {
        email  = var.acme_email
        server = "https://acme-v02.api.letsencrypt.org/directory"
        privateKeySecretRef = {
          name = "${var.cluster_issuer_name}-account-key"
        }
        solvers = [
          {
            dns01 = {
              cloudflare = {
                apiTokenSecretRef = {
                  name = data.kubernetes_secret.cloudflare_api_token.metadata[0].name
                  key  = "api-token"
                }
              }
            }
          }
        ]
      }
    }
  })
}

resource "kubectl_manifest" "wildcard_certificate" {
  for_each = toset(var.certificate_namespaces)

  depends_on = [
    kubectl_manifest.cluster_issuer,
  ]

  validate_schema = false
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = var.wildcard_secret_name
      namespace = each.value
      labels = merge(local.labels, {
        app = "cert-manager"
      })
    }
    spec = {
      secretName = var.wildcard_secret_name
      commonName = var.root_domain
      dnsNames   = local.wildcard_dns_names
      privateKey = {
        algorithm = "RSA"
        size      = 2048
      }
      issuerRef = {
        name  = var.cluster_issuer_name
        kind  = "ClusterIssuer"
        group = "cert-manager.io"
      }
      secretTemplate = {
        annotations = {
          "reloader.stakater.com/match" = "true"
        }
      }
    }
  })
}
