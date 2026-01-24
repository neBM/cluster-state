# Data Model: ELK Stack Migration to Kubernetes

**Feature**: 006-elk-k8s-migration  
**Date**: 2026-01-24  
**Status**: Complete

---

## 1. Storage Paths

### Current State (Nomad)

| Component | Path | Node | Description |
|-----------|------|------|-------------|
| ES Data | `/var/lib/elasticsearch` | All nodes | Local data directories (not shared) |
| ES Config | `/mnt/docker/elastic-{node}/config` | Per-node | Node-specific config including certs |
| ES Certs | `/mnt/docker/elastic-{node}/config/certs/` | Per-node | TLS certificates for transport/HTTP |
| Kibana Config | `/mnt/docker/elastic/kibana/config` | Hestia | Shared config (contains CA cert) |

### Target State (Kubernetes)

| Component | Path (Host) | Path (Container) | Description |
|-----------|-------------|------------------|-------------|
| ES Data | `/storage/v/glusterfs_elasticsearch_data` | `/usr/share/elasticsearch/data` | GlusterFS-backed, pod-portable |
| ES Certs | K8s Secret `elasticsearch-certs` | `/usr/share/elasticsearch/config/certs` | Mounted as volume |
| Kibana Config | K8s ConfigMap | `/usr/share/kibana/config` | Generated from Terraform |
| Kibana Certs | K8s Secret `kibana-certs` | `/usr/share/kibana/config/certs` | CA certificate for ES connection |

### Storage Capacity

| Volume | Current Size | Projected Size | Notes |
|--------|--------------|----------------|-------|
| ES Data | ~23GB | ~25GB (with growth) | After ILM cleanup, 30-day retention |
| ES Certs | ~10KB | ~10KB | Static certificates |
| Kibana Config | ~5KB | ~5KB | Generated ConfigMap |

---

## 2. Secrets Structure

### Current Secrets (Nomad Variables)

Location: `nomad/jobs/elk/kibana/kibana`

| Key | Description |
|-----|-------------|
| `kibana_username` | Elasticsearch username for Kibana |
| `kibana_password` | Elasticsearch password for Kibana |
| `kibana_encryptedSavedObjects_encryptionKey` | Kibana saved objects encryption (32 char) |
| `kibana_reporting_encryptionKey` | Kibana reporting encryption (32 char) |
| `kibana_security_encryptionKey` | Kibana security encryption (32 char) |

### Target Secrets (Kubernetes)

#### Vault Path for External Secrets

New Vault path: `secret/k8s/elk/kibana`

| Vault Key | K8s Secret Name | K8s Secret Key |
|-----------|-----------------|----------------|
| `kibana_username` | `kibana-credentials` | `ELASTICSEARCH_USERNAME` |
| `kibana_password` | `kibana-credentials` | `ELASTICSEARCH_PASSWORD` |
| `kibana_encryptedSavedObjects_encryptionKey` | `kibana-encryption-keys` | `XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY` |
| `kibana_reporting_encryptionKey` | `kibana-encryption-keys` | `XPACK_REPORTING_ENCRYPTIONKEY` |
| `kibana_security_encryptionKey` | `kibana-encryption-keys` | `XPACK_SECURITY_ENCRYPTIONKEY` |

#### TLS Certificates (Manual K8s Secrets)

| K8s Secret | Keys | Source |
|------------|------|--------|
| `elasticsearch-certs` | `elastic-certificates.p12`, `http.p12` | `/mnt/docker/elastic-hestia/config/certs/` |
| `kibana-certs` | `elasticsearch-ca.pem` | `/mnt/docker/elastic/kibana/config/elasticsearch-ca.pem` |

**Note**: TLS certificates are created manually via kubectl before Terraform apply. They contain the PKCS12 keystore password (`changeit`) which ES expects.

---

## 3. Kubernetes Resource Inventory

### Namespace

All resources in `default` namespace (matching existing K8s services).

### Elasticsearch Resources

| Kind | Name | Description |
|------|------|-------------|
| StatefulSet | `elasticsearch` | Single-replica ES deployment |
| Service | `elasticsearch` | ClusterIP service for internal access (9200) |
| Service | `elasticsearch-headless` | Headless service for StatefulSet DNS |
| ConfigMap | `elasticsearch-config` | elasticsearch.yml configuration |
| Secret | `elasticsearch-certs` | TLS certificates (manual) |
| IngressRoute | `elasticsearch` | Traefik route for es.brmartin.co.uk |
| ServersTransport | `elasticsearch` | Traefik backend TLS config |

### Kibana Resources

| Kind | Name | Description |
|------|------|-------------|
| Deployment | `kibana` | Single-replica Kibana deployment |
| Service | `kibana` | ClusterIP service (5601) |
| ConfigMap | `kibana-config` | kibana.yml configuration |
| Secret | `kibana-credentials` | ES username/password (via ExternalSecret) |
| Secret | `kibana-encryption-keys` | xpack encryption keys (via ExternalSecret) |
| Secret | `kibana-certs` | CA certificate for ES (manual) |
| ExternalSecret | `kibana-credentials` | Syncs from Vault |
| ExternalSecret | `kibana-encryption-keys` | Syncs from Vault |
| IngressRoute | `kibana` | Traefik route for kibana.brmartin.co.uk |

### Resource Specifications

#### Elasticsearch StatefulSet

```yaml
resources:
  requests:
    memory: "4Gi"
    cpu: "1000m"
  limits:
    memory: "4Gi"
    cpu: "2000m"

env:
  - name: ES_JAVA_OPTS
    value: "-Xms2g -Xmx2g"
  - name: discovery.type
    value: "single-node"

volumes:
  - name: data
    hostPath:
      path: /storage/v/glusterfs_elasticsearch_data
      type: DirectoryOrCreate
  - name: certs
    secret:
      secretName: elasticsearch-certs

initContainers:
  - name: sysctl
    image: busybox:1.36
    command: ["sh", "-c", "sysctl -w vm.max_map_count=262144"]
    securityContext:
      privileged: true
```

#### Kibana Deployment

```yaml
resources:
  requests:
    memory: "512Mi"
    cpu: "250m"
  limits:
    memory: "1Gi"
    cpu: "500m"

volumes:
  - name: config
    configMap:
      name: kibana-config
  - name: certs
    secret:
      secretName: kibana-certs

envFrom:
  - secretRef:
      name: kibana-credentials
  - secretRef:
      name: kibana-encryption-keys
```

---

## 4. Network Configuration

### Internal Services

| Service | Port | Protocol | Target |
|---------|------|----------|--------|
| elasticsearch | 9200 | HTTPS | ES HTTP API |
| elasticsearch-headless | 9200, 9300 | HTTPS/TCP | StatefulSet pods |
| kibana | 5601 | HTTP | Kibana UI |

### External Access (Two-Layer Traefik)

Traffic flows: Internet → External Traefik (Hestia Docker) → K8s Traefik → Service

**External Traefik** (`/mnt/docker/traefik/traefik/dynamic_conf.yml` on Hestia):

| Router | Host | Service | Notes |
|--------|------|---------|-------|
| `k8s-es` | `es.brmartin.co.uk` | `to-k8s-traefik` | Routes to K8s Traefik |
| `k8s-kibana` | `kibana.brmartin.co.uk` | `to-k8s-traefik` | Routes to K8s Traefik |

**K8s Traefik IngressRoutes** (in modules-k8s/elk/main.tf):

| Host | Service | TLS | Notes |
|------|---------|-----|-------|
| `es.brmartin.co.uk` | elasticsearch:9200 | Backend HTTPS | ServersTransport with skip verify |
| `kibana.brmartin.co.uk` | kibana:5601 | Backend HTTP | Standard Traefik TLS termination |

**Migration Note**: Currently ES/Kibana routes come from Consul catalog (Nomad job tags). After migration, static routes in external Traefik's `dynamic_conf.yml` must be added to route through K8s Traefik.

### Filebeat Configuration (No Changes Required)

Filebeat agents connect to `es.brmartin.co.uk:443` which resolves through Traefik. No client-side changes needed.

---

## 5. Configuration Templates

### elasticsearch.yml

```yaml
cluster.name: "docker-cluster"
node.name: "elk-node"
discovery.type: single-node

network.host: 0.0.0.0
http.port: 9200

path.data: /usr/share/elasticsearch/data

bootstrap.memory_lock: true

xpack:
  ml.enabled: false
  security:
    enabled: true
    enrollment.enabled: false
    transport.ssl:
      enabled: true
      verification_mode: certificate
      keystore.path: /usr/share/elasticsearch/config/certs/elastic-certificates.p12
      truststore.path: /usr/share/elasticsearch/config/certs/elastic-certificates.p12
    http.ssl:
      enabled: true
      keystore.path: /usr/share/elasticsearch/config/certs/http.p12
```

### kibana.yml

```yaml
server:
  host: "0.0.0.0"
  port: 5601
  publicBaseUrl: "https://kibana.brmartin.co.uk"
  ssl.enabled: false

elasticsearch:
  hosts: ["https://elasticsearch:9200"]
  username: "${ELASTICSEARCH_USERNAME}"
  password: "${ELASTICSEARCH_PASSWORD}"
  requestTimeout: 600000
  ssl:
    verificationMode: certificate
    certificateAuthorities:
      - /usr/share/kibana/config/certs/elasticsearch-ca.pem

xpack:
  encryptedSavedObjects:
    encryptionKey: "${XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY}"
  reporting:
    encryptionKey: "${XPACK_REPORTING_ENCRYPTIONKEY}"
  security:
    encryptionKey: "${XPACK_SECURITY_ENCRYPTIONKEY}"
  alerting:
    rules:
      run:
        alerts:
          max: 10000
```

---

## 6. Data Migration Mapping

| Source (Nomad) | Destination (K8s) | Migration Method |
|----------------|-------------------|------------------|
| `/var/lib/elasticsearch/*` on Hestia | `/storage/v/glusterfs_elasticsearch_data/` | rsync after cluster reduction |
| `/mnt/docker/elastic-hestia/config/certs/*` | Secret `elasticsearch-certs` | kubectl create secret |
| `/mnt/docker/elastic/kibana/config/elasticsearch-ca.pem` | Secret `kibana-certs` | kubectl create secret |
| Nomad var `nomad/jobs/elk/kibana/kibana` | Vault `secret/k8s/elk/kibana` | vault kv put |
| Consul catalog routes (via Nomad job tags) | External Traefik `dynamic_conf.yml` | Add k8s-es, k8s-kibana routers |

---

## 7. Ownership and Permissions

| Path | UID:GID | Notes |
|------|---------|-------|
| `/storage/v/glusterfs_elasticsearch_data` | 1000:1000 | ES runs as elasticsearch user (uid 1000) |
| K8s Secrets | N/A | Mounted as root-owned, readable |

**Important**: After rsync, run `chown -R 1000:1000 /storage/v/glusterfs_elasticsearch_data/` to ensure ES can write.
