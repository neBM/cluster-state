output "service_account_name" {
  description = "Name of the created service account"
  value       = kubernetes_service_account.ci.metadata[0].name
}

output "token_secret_name" {
  description = "Name of the secret containing the service account token"
  value       = kubernetes_secret.ci_token.metadata[0].name
}

output "token" {
  description = "Service account token for API authentication"
  value       = kubernetes_secret.ci_token.data["token"]
  sensitive   = true
}

output "ca_cert" {
  description = "Cluster CA certificate (base64 encoded)"
  value       = kubernetes_secret.ci_token.data["ca.crt"]
  sensitive   = true
}

output "namespace" {
  description = "Namespace of the service account"
  value       = kubernetes_secret.ci_token.data["namespace"]
}
