# GlitchTip Deployment - Design

**Date:** 2026-04-28  
**Status:** Approved

## Goal

Add GlitchTip to the Kubernetes cluster-state repo as a public service on `https://glitchtip.brmartin.co.uk`, behind Traefik, with Keycloak OIDC login and working outbound email from the first deploy.

## Approach

Implement a dedicated Terraform module at `modules-k8s/glitchtip` instead of introducing Helm for this one service. The first release will use a single GlitchTip pod with the worker embedded in-process. That keeps the deployment compact, matches the rest of the repo's custom-module style, and avoids a second deployment until the service actually needs horizontal scaling.

## Architecture

```
Browser
  -> Traefik Ingress
  -> glitchtip Service
  -> glitchtip Deployment
       - main GlitchTip web process
       - embedded background worker
       - init bootstrap container
  -> external PostgreSQL (192.168.1.10:5433)
  -> shared Valkey service
  -> uploads PVC on SeaweedFS
  -> mail relay at mail.brmartin.co.uk:587
  -> Keycloak OIDC at sso.brmartin.co.uk
```

## Module Layout

### New: `modules-k8s/glitchtip`

The module will contain:

- one `kubernetes_persistent_volume_claim` for uploads
- one `kubernetes_deployment` for GlitchTip web + embedded worker
- one `kubernetes_service` for cluster-internal traffic
- one `kubernetes_ingress_v1` for public Traefik exposure

The module will read two existing secrets:

- `glitchtip-secrets` for runtime/bootstrap values
- `glitchtip-oidc-secret` for Keycloak client credentials

`glitchtip-secrets` is a plain Kubernetes Secret created during rollout, not committed to git. It holds the app's internal secret key, database DSN, SMTP URL, and bootstrap admin credentials.

The module will use the existing shared `valkey` deployment already defined in `kubernetes.tf`.

## Runtime Configuration

### Image

- `glitchtip/glitchtip:6.1.5`

### Core environment

- `GLITCHTIP_DOMAIN=https://glitchtip.brmartin.co.uk`
- `ALLOWED_HOSTS=glitchtip.brmartin.co.uk`
- `CSRF_TRUSTED_ORIGINS=https://glitchtip.brmartin.co.uk`
- `GLITCHTIP_EMBED_WORKER=true`
- `SKIP_INIT=true`
- `VALKEY_URL=redis://valkey.default.svc.cluster.local:6379/0`
- `ENABLE_USER_REGISTRATION=false`
- `ENABLE_SOCIAL_APPS_USER_REGISTRATION=true`
- `LOG_LEVEL=INFO`

### Secret-backed env

From `glitchtip-secrets`:

- `SECRET_KEY`
- `DATABASE_URL`
- `EMAIL_URL`
- `DEFAULT_FROM_EMAIL`
- `DJANGO_SUPERUSER_USERNAME`
- `DJANGO_SUPERUSER_EMAIL`
- `DJANGO_SUPERUSER_PASSWORD`

From `glitchtip-oidc-secret`:

- `OIDC_CLIENT_ID`
- `OIDC_CLIENT_SECRET`

### Mail

GlitchTip will send mail through the existing in-cluster relay using the logical hostname `mail.brmartin.co.uk:587`, not the Service DNS name. That preserves TLS hostname verification while still routing through the internal Postfix service via CoreDNS.

The `EMAIL_URL` value will use STARTTLS, e.g.:

- `smtp+tls://svc-glitchtip:<password>@mail.brmartin.co.uk:587`

## Storage

Uploads will use a `seaweedfs` RWX PVC mounted at `/code/uploads`, which is the GlitchTip backend's uploads directory in the current container image.

Proposed size:

- `5Gi`

That is enough for source maps and normal attachment growth without over-allocating.

## Bootstrap And SSO

Because GlitchTip's OpenID Connect provider configuration lives in Django's social-app tables, the deployment will seed that configuration automatically instead of requiring a manual admin step.

An init container will:

1. wait for PostgreSQL
2. run `python manage.py migrate`
3. create the Django superuser if it does not exist
4. create or update the Django `Site` row for `glitchtip.brmartin.co.uk`
5. create or update the `SocialApp` record for OpenID Connect
6. attach that social app to the GlitchTip site

The OpenID Connect provider data will be:

- provider: `openid_connect`
- provider_id: `keycloak`
- display name: `Keycloak`
- callback URL: `https://glitchtip.brmartin.co.uk/accounts/oidc/keycloak/login/callback/`
- server URL: `https://sso.brmartin.co.uk/realms/prod/.well-known/openid-configuration`

The bootstrap step is idempotent so it can run on every pod start without creating duplicate objects.

## PostgreSQL

GlitchTip will use the cluster's external PostgreSQL instance at `192.168.1.10:5433`.

The deployment assumes a dedicated `glitchtip` database and role. Those will be created outside Kubernetes during rollout, then referenced from `DATABASE_URL`.

## Networking

- Public ingress via Traefik on `websecure`
- TLS secret: existing wildcard certificate in the `traefik` namespace
- No separate NetworkPolicy for the first pass

## Error Handling

- If bootstrap migration or social-app seeding fails, the pod should never become ready.
- If the mail relay or Postgres connection fails, the pod should restart and surface the error in logs.
- If the uploads PVC cannot mount, the pod should remain pending rather than starting without durable uploads.

## Verification

The rollout is considered complete when:

1. `https://glitchtip.brmartin.co.uk` loads through Traefik
2. GlitchTip can authenticate via Keycloak
3. Email delivery uses `mail.brmartin.co.uk:587`
4. Migrations run successfully on a fresh pod
5. Uploaded files survive a pod restart

## Out Of Scope

- Helm chart adoption
- Separate worker deployment
- S3-backed uploads
- Multi-replica scaling
- Custom NetworkPolicies
