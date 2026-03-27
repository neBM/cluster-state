# iris-secrets must be created manually before applying this module:
#
#   kubectl create secret generic iris-secrets \
#     --from-literal=DATABASE_URL="postgresql://iris:<password>@192.168.1.10:5433/iris?sslmode=disable" \
#     --from-literal=SECRET_KEY="$(openssl rand -hex 32)" \
#     --from-literal=TMDB_API_KEY="<key>" \
#     --from-literal=TVDB_API_KEY="<key>" \
#     --from-literal=TRAKT_CLIENT_ID="<id>" \
#     --from-literal=TRAKT_CLIENT_SECRET="<secret>"
#
# TMDB_API_KEY, TVDB_API_KEY, TRAKT_CLIENT_ID, and TRAKT_CLIENT_SECRET are
# optional — omit them if not configured.

data "kubernetes_secret" "iris" {
  metadata {
    name      = "iris-secrets"
    namespace = var.namespace
  }
}
