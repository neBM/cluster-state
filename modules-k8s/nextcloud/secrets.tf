# Nextcloud secrets are managed outside Terraform as a plain Kubernetes Secret.
# Secret name: nextcloud-secrets
#
# Required keys:
#   db_password        - PostgreSQL password
#   instanceid         - Nextcloud instance ID (from config.php after initial install)
#   passwordsalt       - Password salt (from config.php after initial install)
#   secret             - Secret key for CSRF/session tokens (from config.php after initial install)
#   oidc_client_secret - Keycloak OIDC client secret
#   mail_smtp_password - SMTP password for outgoing mail
#
# The init container reads these keys and generates zz-secrets.config.php,
# which Nextcloud loads alongside config.php. This protects against NFS
# corruption of config.php causing Nextcloud to show the install wizard.
