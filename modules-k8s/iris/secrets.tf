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
#
# iris-sentry and iris-sentry-web must be created manually before applying
# this module:
#
#   kubectl create secret generic iris-sentry \
#     --from-literal=dsn="<backend GlitchTip DSN>"
#
#   kubectl create secret generic iris-sentry-web \
#     --from-literal=dsn="<frontend GlitchTip DSN>"
#
# iris-csp must be created manually before applying this module:
#
#   kubectl create secret generic iris-csp \
#     --from-literal=report_uri="<GlitchTip web project security endpoint URL>"

data "kubernetes_secret" "iris" {
  metadata {
    name      = "iris-secrets"
    namespace = var.namespace
  }
}

data "kubernetes_secret" "iris_sentry" {
  metadata {
    name      = "iris-sentry"
    namespace = var.namespace
  }
}

data "kubernetes_secret" "iris_sentry_web" {
  metadata {
    name      = "iris-sentry-web"
    namespace = var.namespace
  }
}

data "kubernetes_secret" "iris_csp" {
  metadata {
    name      = "iris-csp"
    namespace = var.namespace
  }
}
