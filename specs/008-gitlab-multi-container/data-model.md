# Data Model: GitLab Multi-Container Migration

**Feature**: 008-gitlab-multi-container
**Date**: 2026-01-24

## Overview

This document defines the storage volumes, secrets, and configuration entities required for the GitLab multi-container deployment.

---

## 1. Persistent Volume Claims

### PVC: gitlab-repositories

**Purpose**: Git repository storage (Gitaly)

```yaml
metadata:
  name: gitlab-repositories
  annotations:
    volume-name: "gitlab_repositories"
spec:
  storageClassName: glusterfs-nfs
  accessModes: ["ReadWriteMany"]
  resources:
    requests:
      storage: 50Gi
```

**Mount Path**: `/home/git/repositories` (Gitaly container)

**Data Source**: Migration from `/storage/v/glusterfs_gitlab_data/git-data/repositories`

---

### PVC: gitlab-uploads

**Purpose**: User-uploaded files (avatars, attachments)

```yaml
metadata:
  name: gitlab-uploads
  annotations:
    volume-name: "gitlab_uploads"
spec:
  storageClassName: glusterfs-nfs
  accessModes: ["ReadWriteMany"]
  resources:
    requests:
      storage: 10Gi
```

**Mount Path**: `/srv/gitlab/public/uploads` (Webservice, Workhorse, Sidekiq)

**Data Source**: Migration from `/storage/v/glusterfs_gitlab_data/gitlab-rails/uploads`

---

### PVC: gitlab-shared

**Purpose**: Shared application data (LFS, artifacts, packages)

```yaml
metadata:
  name: gitlab-shared
  annotations:
    volume-name: "gitlab_shared"
spec:
  storageClassName: glusterfs-nfs
  accessModes: ["ReadWriteMany"]
  resources:
    requests:
      storage: 20Gi
```

**Mount Path**: `/srv/gitlab/shared` (Webservice, Workhorse, Sidekiq)

**Data Source**: Migration from `/storage/v/glusterfs_gitlab_data/gitlab-rails/shared`

---

### PVC: gitlab-config

**Purpose**: GitLab configuration files (generated at runtime)

```yaml
metadata:
  name: gitlab-config
  annotations:
    volume-name: "gitlab_config"
spec:
  storageClassName: glusterfs-nfs
  accessModes: ["ReadWriteMany"]
  resources:
    requests:
      storage: 1Gi
```

**Mount Path**: `/srv/gitlab/config` (Webservice, Sidekiq)

**Data Source**: New (generated from templates)

---

### PVC: gitlab-registry

**Purpose**: Container registry image storage

```yaml
metadata:
  name: gitlab-registry
  annotations:
    volume-name: "gitlab_registry"
spec:
  storageClassName: glusterfs-nfs
  accessModes: ["ReadWriteMany"]
  resources:
    requests:
      storage: 20Gi
```

**Mount Path**: `/var/lib/registry` (Registry container)

**Data Source**: Migration from `/storage/v/glusterfs_gitlab_data/gitlab-rails/shared/registry`

---

## 2. Kubernetes Secrets

### Secret: gitlab-rails-secret

**Purpose**: Rails application encryption keys

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-rails-secret
type: Opaque
stringData:
  secrets.yml: |
    production:
      db_key_base: "<from gitlab-secrets.json>"
      secret_key_base: "<from gitlab-secrets.json>"
      otp_key_base: "<from gitlab-secrets.json>"
      openid_connect_signing_key: |
        <from gitlab-secrets.json>
```

**Source**: Extract from Omnibus `/etc/gitlab/gitlab-secrets.json`

**Used By**: Webservice, Sidekiq

---

### Secret: gitlab-database

**Purpose**: PostgreSQL connection credentials

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-database
type: Opaque
stringData:
  password: "<db_password>"
```

**Source**: Existing External Secrets Operator (Vault path: nomad/default/gitlab)

**Used By**: Webservice, Sidekiq

---

### Secret: gitlab-workhorse

**Purpose**: Workhorse authentication token

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-workhorse
type: Opaque
stringData:
  secret: "<32-byte-hex-string>"
```

**Source**: Generate new or extract from Omnibus

**Used By**: Webservice, Workhorse

---

### Secret: gitlab-shell

**Purpose**: GitLab Shell authentication token

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-shell
type: Opaque
stringData:
  secret: "<random-string>"
```

**Source**: Generate new or extract from Omnibus

**Used By**: Webservice, Gitaly

---

### Secret: gitlab-gitaly

**Purpose**: Gitaly authentication token

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-gitaly
type: Opaque
stringData:
  token: "<random-string>"
```

**Source**: Generate new

**Used By**: Webservice, Sidekiq, Gitaly

---

### Secret: gitlab-registry-auth

**Purpose**: Registry JWT signing key

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-registry-auth
type: Opaque
stringData:
  registry-auth.key: |
    -----BEGIN RSA PRIVATE KEY-----
    <key content>
    -----END RSA PRIVATE KEY-----
  registry-auth.crt: |
    -----BEGIN CERTIFICATE-----
    <cert content>
    -----END CERTIFICATE-----
```

**Source**: Generate new key pair or extract from Omnibus

**Used By**: Webservice (signing), Registry (verification)

---

## 3. ConfigMaps

### ConfigMap: gitlab-config-templates

**Purpose**: Configuration file templates

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: gitlab-config-templates
data:
  gitlab.yml: |
    # See research.md for full template
  database.yml: |
    production:
      adapter: postgresql
      encoding: unicode
      database: gitlabhq_production
      host: 192.168.1.10
      port: 5433
      username: gitlab
      password: <%= File.read('/etc/gitlab/postgres/password').strip %>
  resque.yml: |
    production:
      url: redis://gitlab-redis:6379
```

**Used By**: Webservice, Sidekiq

---

### ConfigMap: gitaly-config

**Purpose**: Gitaly server configuration

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: gitaly-config
data:
  config.toml: |
    socket_path = "/home/git/gitaly.socket"
    bin_dir = "/usr/local/bin"
    runtime_dir = "/home/git"
    listen_addr = "0.0.0.0:8075"
    
    [[storage]]
    name = "default"
    path = "/home/git/repositories"
    
    [auth]
    token = "<gitaly_token_placeholder>"
    
    [gitlab]
    url = "http://gitlab-webservice:8080"
    secret_file = "/etc/gitlab/shell/.gitlab_shell_secret"
    
    [logging]
    format = "json"
    level = "info"
```

**Used By**: Gitaly

---

### ConfigMap: workhorse-config

**Purpose**: Workhorse proxy configuration

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: workhorse-config
data:
  workhorse-config.toml: |
    [redis]
    URL = "redis://gitlab-redis:6379"
    
    [[listeners]]
    network = "tcp"
    addr = "0.0.0.0:8181"
```

**Used By**: Workhorse

---

## 4. Entity Relationships

```
┌─────────────────────────────────────────────────────────────────┐
│                        External Services                         │
├─────────────────────────────────────────────────────────────────┤
│  PostgreSQL (192.168.1.10:5433)  ◄──── gitlab-database secret   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                         GitLab Pods                              │
├─────────────────┬─────────────────┬─────────────────────────────┤
│   Webservice    │    Sidekiq      │         Gitaly              │
│                 │                 │                              │
│ ◄── rails-secret│ ◄── rails-secret│ ◄── gitaly secret           │
│ ◄── db secret   │ ◄── db secret   │ ◄── shell secret            │
│ ◄── workhorse   │ ◄── gitaly      │                              │
│ ◄── shell       │ ◄── shell       │                              │
│ ◄── gitaly      │                 │                              │
│ ◄── registry    │                 │                              │
│                 │                 │                              │
│ ◄── uploads PVC │ ◄── uploads PVC │ ◄── repositories PVC        │
│ ◄── shared PVC  │ ◄── shared PVC  │                              │
│ ◄── config PVC  │ ◄── config PVC  │                              │
└─────────────────┴─────────────────┴─────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                       Supporting Pods                            │
├─────────────────────────┬───────────────────────────────────────┤
│       Workhorse         │           Redis                        │
│                         │                                        │
│ ◄── workhorse secret    │  (no secrets)                         │
│ ◄── uploads PVC         │                                        │
│ ◄── shared PVC          │                                        │
├─────────────────────────┴───────────────────────────────────────┤
│       Registry                                                   │
│                                                                  │
│ ◄── registry-auth secret                                         │
│ ◄── registry PVC                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 5. Data Migration Mapping

| Omnibus Source | PVC Target | Notes |
|----------------|------------|-------|
| `/storage/v/glusterfs_gitlab_data/git-data/repositories` | gitlab-repositories | Hashed storage format |
| `/storage/v/glusterfs_gitlab_data/gitlab-rails/uploads` | gitlab-uploads | Direct copy |
| `/storage/v/glusterfs_gitlab_data/gitlab-rails/shared` | gitlab-shared | Includes LFS, artifacts |
| `/storage/v/glusterfs_gitlab_data/gitlab-rails/shared/registry` | gitlab-registry | Container images |
| `/storage/v/glusterfs_gitlab_config` | gitlab-config | Discard (regenerate) |

---

## 6. Validation Rules

### PVC Validation
- All PVCs must be bound before deployment starts
- Storage class must be `glusterfs-nfs`
- Access mode must be `ReadWriteMany` for shared volumes

### Secret Validation
- `gitlab-rails-secret`: Must contain valid `secrets.yml` with all required keys
- `gitlab-database`: Password must match external PostgreSQL
- Token secrets: Must be non-empty strings

### ConfigMap Validation
- Templates must be valid ERB/Go template syntax
- Database host/port must match external PostgreSQL
- Service names must match Kubernetes Service definitions
