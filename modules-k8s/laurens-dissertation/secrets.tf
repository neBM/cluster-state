# Optional secret: laurens-dissertation-secrets
#
# The deployment references this secret with optional=true on every key, so
# the pod starts even if the secret does not exist. Create it manually to
# enable the residential proxy:
#
#   kubectl create secret generic laurens-dissertation-secrets \
#     --from-literal=PROXY_URL="http://user:pass@proxy.example.com:8080" \
#     -n default
#
# Supported keys:
#   PROXY_URL   — residential proxy for Amazon anti-bot mitigation (optional)
