# Research: GitLab Multi-Container Migration

**Feature**: 008-gitlab-multi-container
**Date**: 2026-01-24
**Status**: Complete

## Executive Summary

Migration from GitLab Omnibus to Cloud Native GitLab (CNG) containers is feasible without Helm charts. CNG images can be configured via environment variables and mounted configuration files. The development docker-compose setup proves that CNG can work with filesystem-based storage (not requiring object storage), which aligns with our PVC-based GlusterFS approach.

---

## 1. CNG Image Configuration

### Decision: Use environment variables + mounted config templates

**Rationale**: CNG images are designed for template-based configuration. Configuration files are Go/ERB templates processed at startup, with environment variables providing runtime values.

**Alternatives Considered**:
- Helm charts: Rejected per user requirement
- Hardcoded configs: Rejected - less flexible, harder to maintain

### CNG Image Tags for GitLab CE 18.8.2

| Component | Image |
|-----------|-------|
| Webservice | `registry.gitlab.com/gitlab-org/build/cng/gitlab-webservice-ce:v18.8.2` |
| Workhorse | `registry.gitlab.com/gitlab-org/build/cng/gitlab-workhorse-ce:v18.8.2` |
| Sidekiq | `registry.gitlab.com/gitlab-org/build/cng/gitlab-sidekiq-ce:v18.8.2` |
| Gitaly | `registry.gitlab.com/gitlab-org/build/cng/gitaly:v18.8.2` |
| GitLab Shell | Embedded in Gitaly (or separate: `gitlab-shell:v18.8.2`) |

**Note**: Gitaly and utility images don't have CE/EE variants.

### Component Configuration

#### Webservice (Puma)

**Environment Variables**:
```
CONFIG_TEMPLATE_DIRECTORY=/var/opt/gitlab/config/templates
CONFIG_DIRECTORY=/srv/gitlab/config
GITLAB_WEBSERVER=PUMA
GITLAB_HOST=git.brmartin.co.uk
GITLAB_PORT=443
ENABLE_BOOTSNAP=true
ACTION_CABLE_IN_APP=true
```

**Required Config Files** (mounted at `/var/opt/gitlab/config/templates/`):
- `gitlab.yml` - Main application config
- `database.yml` - PostgreSQL connection
- `resque.yml` - Redis connection

**Required Secrets**:
- `/srv/gitlab/.gitlab_workhorse_secret`
- `/etc/gitlab/postgres/password`

**Ports**: 8080 (Puma internal)

#### Workhorse

**Environment Variables**:
```
CONFIG_TEMPLATE_DIRECTORY=/var/opt/gitlab/config/templates
CONFIG_DIRECTORY=/srv/gitlab/config
GITLAB_WORKHORSE_EXTRA_ARGS=-authBackend http://gitlab-webservice:8080 -cableBackend http://gitlab-webservice:8080
```

**Required Config Files**:
- `workhorse-config.toml` - Workhorse configuration

**Required Secrets**:
- `/etc/gitlab/gitlab-workhorse/secret`

**Ports**: 8181 (main entry point)

#### Sidekiq

**Environment Variables**:
```
CONFIG_TEMPLATE_DIRECTORY=/var/opt/gitlab/config/templates
CONFIG_DIRECTORY=/srv/gitlab/config
GITLAB_HOST=git.brmartin.co.uk
GITLAB_PORT=443
ENABLE_BOOTSNAP=true
SIDEKIQ_CONCURRENCY=5
```

**Required Config Files**: Same as Webservice (gitlab.yml, database.yml, resque.yml)

**Ports**: None exposed (background worker)

#### Gitaly

**Environment Variables**:
```
GITALY_CONFIG_FILE=/etc/gitaly/config.toml
```

**Required Config File** (`/etc/gitaly/config.toml`):
```toml
socket_path = "/home/git/gitaly.socket"
bin_dir = "/usr/local/bin"
runtime_dir = "/home/git"

listen_addr = "0.0.0.0:8075"

[[storage]]
name = "default"
path = "/home/git/repositories"

[auth]
token = "<gitaly_token>"

[gitlab]
url = "http://gitlab-webservice:8080"
secret_file = "/etc/gitlab/shell/.gitlab_shell_secret"

[logging]
format = "json"
level = "info"
```

**Ports**: 8075 (gRPC)

---

## 2. Data Migration Strategy

### Decision: Direct volume migration with path mapping

**Rationale**: CNG's docker-compose dev setup proves filesystem storage works. We can migrate existing Omnibus data directly to PVCs without requiring object storage.

**Alternatives Considered**:
- Object storage migration: Rejected - adds complexity, changes architecture unnecessarily
- Backup/restore: Considered as fallback if direct migration fails

### Path Mapping: Omnibus → CNG

| Data Type | Omnibus Path | CNG Path |
|-----------|--------------|----------|
| Repositories | `/var/opt/gitlab/git-data/repositories` | `/home/git/repositories` (Gitaly) |
| Uploads | `/var/opt/gitlab/gitlab-rails/uploads` | `/srv/gitlab/public/uploads` |
| Shared | `/var/opt/gitlab/gitlab-rails/shared` | `/srv/gitlab/shared` |
| LFS | `/var/opt/gitlab/gitlab-rails/shared/lfs-objects` | `/srv/gitlab/shared/lfs-objects` |
| Artifacts | `/var/opt/gitlab/gitlab-rails/shared/artifacts` | `/srv/gitlab/shared/artifacts` |

### Migration Steps

1. **Stop Omnibus GitLab**
2. **Create PVCs** for each data type using glusterfs-nfs StorageClass
3. **Copy data** from Omnibus volumes to new PVC directories
4. **Deploy CNG containers** with PVCs mounted
5. **Run database migrations** (if version mismatch)
6. **Verify functionality**

### Data Compatibility

- **Repository format**: Identical (hashed storage `@hashed/xx/yy/...`)
- **Upload format**: Identical (direct file storage)
- **Database schema**: Compatible if same GitLab version
- **Secrets**: Need extraction and format conversion

---

## 3. Inter-Component Communication

### Decision: TCP-only communication via Kubernetes Services

**Rationale**: CNG uses TCP for all inter-component communication, matching our requirement to avoid Unix sockets on GlusterFS.

### Service Communication Map

```
                    ┌──────────────┐
                    │   Traefik    │
                    │  (Ingress)   │
                    └──────┬───────┘
                           │ :8181
                    ┌──────▼───────┐
                    │  Workhorse   │
                    │   :8181      │
                    └──────┬───────┘
                           │ :8080
           ┌───────────────┼───────────────┐
           │               │               │
    ┌──────▼───────┐┌──────▼───────┐┌──────▼───────┐
    │  Webservice  ││   Sidekiq    ││    Redis     │
    │    :8080     ││  (worker)    ││    :6379     │
    └──────┬───────┘└──────┬───────┘└──────────────┘
           │               │
           └───────┬───────┘
                   │ :8075
            ┌──────▼───────┐
            │    Gitaly    │
            │    :8075     │
            └──────────────┘
                   │
            ┌──────▼───────┐
            │  PostgreSQL  │
            │ (external)   │
            │    :5433     │
            └──────────────┘
```

### Kubernetes Services Required

| Service | Port | Target |
|---------|------|--------|
| gitlab-workhorse | 8181 | Workhorse pod |
| gitlab-webservice | 8080 | Webservice pod |
| gitlab-gitaly | 8075 | Gitaly pod |
| gitlab-redis | 6379 | Redis pod |

---

## 4. Secrets Extraction and Management

### Decision: Extract from Omnibus, convert to Kubernetes Secrets

**Rationale**: Existing secrets must be preserved to maintain access tokens, encrypted data, etc.

### Required Secrets

| Secret | Source (Omnibus) | Purpose |
|--------|------------------|---------|
| db_key_base | `/etc/gitlab/gitlab-secrets.json` | Database encryption |
| secret_key_base | `/etc/gitlab/gitlab-secrets.json` | Session signing |
| otp_key_base | `/etc/gitlab/gitlab-secrets.json` | 2FA encryption |
| openid_connect_signing_key | `/etc/gitlab/gitlab-secrets.json` | OIDC signing |
| workhorse_secret | Generate or extract | Workhorse auth |
| gitaly_token | Generate new | Gitaly auth |
| shell_secret | Generate or extract | Shell auth |

### Extraction Process

```bash
# On Omnibus host
cat /etc/gitlab/gitlab-secrets.json | jq '.gitlab_rails'

# Extract individual secrets
db_key_base=$(cat /etc/gitlab/gitlab-secrets.json | jq -r '.gitlab_rails.db_key_base')
secret_key_base=$(cat /etc/gitlab/gitlab-secrets.json | jq -r '.gitlab_rails.secret_key_base')
# ... etc
```

### Kubernetes Secret Structure

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-rails-secret
type: Opaque
stringData:
  secrets.yml: |
    production:
      db_key_base: "<extracted_value>"
      secret_key_base: "<extracted_value>"
      otp_key_base: "<extracted_value>"
```

---

## 5. Container Registry

### Decision: Deploy as separate container using CNG registry image

**Rationale**: Separation of concerns; registry is a distinct service with its own storage requirements.

**Alternatives Considered**:
- Keep bundled in webservice: Not possible with CNG architecture
- Skip registry: Rejected - currently in use

### Registry Configuration

**Image**: `registry.gitlab.com/gitlab-org/build/cng/gitlab-container-registry:v18.8.2`

**Storage**: Same PVC backend (GlusterFS NFS) for registry data

**Authentication**: JWT tokens signed by GitLab

---

## 6. Version Compatibility

### Decision: Use CNG v18.8.2 matching Omnibus v18.8.2

**Rationale**: Same version ensures database schema compatibility, no migration required.

**Verification**:
- Helm chart 9.8.2 maps to GitLab 18.8.2 ✓
- CNG images tagged v18.8.2 exist ✓
- CE variants available ✓

---

## 7. Startup Sequence

### Required Order

1. **PostgreSQL** (external - already running)
2. **Redis** (must be ready before Rails services)
3. **Gitaly** (can start independently)
4. **Webservice** (depends on PostgreSQL, Redis, Gitaly)
5. **Workhorse** (depends on Webservice)
6. **Sidekiq** (depends on PostgreSQL, Redis, Gitaly)
7. **Registry** (depends on Webservice for auth)

### Health Checks

| Component | Readiness Check |
|-----------|-----------------|
| Redis | `redis-cli ping` |
| Gitaly | gRPC health check on :8075 |
| Webservice | HTTP GET `/-/readiness` on :8080 |
| Workhorse | HTTP GET `/-/readiness` on :8181 |
| Sidekiq | Process running check |

---

## 8. Risk Assessment

### High Risk
- **Data migration failure**: Mitigated by backup before migration
- **Secrets incompatibility**: Mitigated by extraction verification

### Medium Risk
- **Performance regression**: Monitor after migration
- **Missing configuration**: Use CNG docker-compose as reference

### Low Risk
- **Image availability**: CNG images are public
- **Kubernetes compatibility**: Standard K8s resources

---

## References

- [GitLab CNG Repository](https://gitlab.com/gitlab-org/build/CNG)
- [CNG docker-compose.yml](https://gitlab.com/gitlab-org/build/CNG/-/blob/master/docker-compose.yml)
- [GitLab Helm Chart Version Mappings](https://docs.gitlab.com/charts/installation/version_mappings.html)
- [GitLab Webservice Chart Docs](https://docs.gitlab.com/charts/charts/gitlab/webservice/)
- [Gitaly Configuration](https://docs.gitlab.com/ee/administration/gitaly/configure_gitaly.html)
