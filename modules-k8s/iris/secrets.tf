# iris-secrets must be created manually before applying this module:
#
#   kubectl create secret generic iris-secrets \
#     --from-literal=DATABASE_URL="postgresql://iris:<password>@192.168.1.10:5433/iris?sslmode=disable" \
#     --from-literal=TMDB_API_KEY="<key>" \
#     --from-literal=TVDB_API_KEY="<key>"

data "kubernetes_secret" "iris" {
  metadata {
    name      = "iris-secrets"
    namespace = var.namespace
  }
}
