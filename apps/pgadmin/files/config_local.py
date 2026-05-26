import logging
import os

CONFIG_DATABASE_URI = os.environ["CONFIG_DATABASE_URI"]

ALLOWED_HOSTS = ["pgadmin.brmartin.co.uk"]
AUTHENTICATION_SOURCES = ["oauth2", "internal"]
CONSOLE_LOG_LEVEL = logging.INFO
ENHANCED_COOKIE_PROTECTION = False
MASTER_PASSWORD_REQUIRED = True
SESSION_COOKIE_SECURE = True
STRICT_TRANSPORT_SECURITY_ENABLED = True

OAUTH2_AUTO_CREATE_USER = True
OAUTH2_CONFIG = [
    {
        "OAUTH2_NAME": "keycloak",
        "OAUTH2_DISPLAY_NAME": "Keycloak",
        "OAUTH2_CLIENT_ID": "pgadmin",
        "OAUTH2_CLIENT_SECRET": os.environ["OAUTH2_CLIENT_SECRET"],
        "OAUTH2_SERVER_METADATA_URL": "https://sso.brmartin.co.uk/realms/prod/.well-known/openid-configuration",
        "OAUTH2_SCOPE": "openid email profile",
        "OAUTH2_USERNAME_CLAIM": "preferred_username",
        "OAUTH2_ADDITIONAL_CLAIMS": {
            "groups": ["pgadmin-users"],
        },
        "OAUTH2_SSL_CERT_VERIFICATION": True,
    }
]
