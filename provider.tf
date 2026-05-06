terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.35"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
}

# Grafana admin credentials are managed outside Terraform as a Kubernetes
# Secret. Reuse them here so alert rules can be managed through Grafana's
# alerting API instead of file provisioning.
data "kubernetes_secret_v1" "grafana_secrets" {
  metadata {
    name      = "grafana-secrets"
    namespace = "default"
  }
}

provider "grafana" {
  url    = "https://grafana.brmartin.co.uk"
  auth   = "admin:${data.kubernetes_secret_v1.grafana_secrets.data["GF_SECURITY_ADMIN_PASSWORD"]}"
  org_id = 1
}

provider "helm" {
  kubernetes = {
    config_path    = pathexpand(var.k8s_config_path)
    config_context = "default"
  }
}
