# Reference existing athenaeum-secrets K8s secret
# Secret must be created manually before module is applied
# Contains all environment variables for backend and frontend
#
# Expected secret keys:
# Backend:
#   - DATABASE_URL
#   - KEYCLOAK_SERVER_URL
#   - KEYCLOAK_REALM
#   - KEYCLOAK_CLIENT_ID
#   - KEYCLOAK_CLIENT_SECRET
#   - REDIS_URL
#   - MINIO_ENDPOINT
#   - MINIO_ACCESS_KEY
#   - MINIO_SECRET_KEY
#   - MINIO_BUCKET
# Frontend:
#   - VUE_APP_API_URL
#   - VUE_APP_KEYCLOAK_URL
#   - VUE_APP_KEYCLOAK_REALM
#   - VUE_APP_KEYCLOAK_CLIENT_ID

data "kubernetes_secret" "athenaeum" {
  metadata {
    name      = "athenaeum-secrets"
    namespace = var.namespace
  }
}
