# Implementation Plan: Observability Stack (Prometheus, Grafana, Meshery)

**Branch**: `010-observability-stack` | **Date**: 2026-01-26 | **Spec**: N/A (plan-first)
**Input**: User request for observability stack with Prometheus, Grafana, and Meshery

## Summary

Deploy a comprehensive observability stack consisting of Prometheus (metrics collection), Grafana (visualization/dashboards), and Meshery (service mesh management) to the K3s cluster. Implementation follows existing Terraform module patterns in `modules-k8s/`, using native Kubernetes resources (no Helm provider - consistent with existing codebase), GlusterFS for persistent storage, Traefik IngressRoutes for external access, and Keycloak SSO for authentication.

## Technical Context

**Language/Version**: HCL (Terraform 1.x)
**Primary Dependencies**: Kubernetes provider, kubectl provider (for CRDs)
**Storage**: GlusterFS via NFS (`glusterfs-nfs` StorageClass) for Prometheus data, Grafana config
**Testing**: `terraform plan`, manual verification via Kubernetes and service UIs
**Target Platform**: K3s 1.34+ cluster (Hestia/Heracles/Nyx)
**Project Type**: Infrastructure-as-Code modules
**Performance Goals**: Prometheus scrape interval 15s, 30-day retention, Grafana <2s dashboard load
**Constraints**: ARM64 compatibility (Heracles/Nyx), memory-constrained nodes (~8GB each)
**Scale/Scope**: ~25 services to monitor, 3 nodes, single Prometheus instance (no HA initially)

## Constitution Check

*GATE: Must pass before implementation. Based on `.specify/memory/constitution.md`*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Infrastructure as Code | PASS | All changes via Terraform modules |
| II. Simplicity First | PASS | One module per service, native K8s resources |
| III. High Availability | PARTIAL | Single Prometheus initially; Grafana stateless |
| IV. Storage Patterns | PASS | GlusterFS for persistent data, no SQLite |
| V. Security & Secrets | PASS | Vault via ExternalSecrets, per-service credentials |
| VI. Service Mesh Patterns | N/A | Using Cilium CNI, not Consul Connect |

**Note**: HA for Prometheus can be added later via Thanos or Prometheus Operator if needed.

## Project Structure

### Documentation (this feature)

```text
.specify/specs/010-observability-stack/
├── plan.md              # This file
├── research.md          # Technology research (to be created)
└── tasks.md             # Task breakdown (to be created via /speckit.tasks)
```

### Source Code (repository root)

```text
modules-k8s/
├── prometheus/
│   ├── main.tf          # Deployment, Service, ConfigMap, PVC, IngressRoute
│   ├── variables.tf     # Module inputs
│   ├── secrets.tf       # ExternalSecret for basic auth (optional)
│   └── rbac.tf          # ServiceAccount, ClusterRole, ClusterRoleBinding
├── grafana/
│   ├── main.tf          # Deployment, Service, ConfigMap, PVC, IngressRoute
│   ├── variables.tf     # Module inputs
│   └── secrets.tf       # ExternalSecret for admin password, OAuth client
└── meshery/
    ├── main.tf          # Deployment, Service, IngressRoute
    ├── variables.tf     # Module inputs
    └── rbac.tf          # ServiceAccount, ClusterRole (needs cluster-wide access)

kubernetes.tf            # Module instantiations (add to existing file)
```

**Structure Decision**: Follows existing pattern of one module per service with `main.tf`, `variables.tf`, and optional `secrets.tf`/`rbac.tf` files.

## Component Architecture

### 1. Prometheus

**Purpose**: Metrics collection and storage

**Architecture**:
```
┌─────────────────────────────────────────────────────────────────┐
│                         Prometheus                               │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │ Scrape Jobs │  │   TSDB      │  │    Service Discovery    │  │
│  │ (15s int.)  │  │ (GlusterFS) │  │  (K8s API annotations)  │  │
│  └─────────────┘  └─────────────┘  └─────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
         ↑                                      ↑
    ┌────┴────┐                          ┌──────┴──────┐
    │ Targets │                          │ K8s API     │
    │ (pods)  │                          │ (discovery) │
    └─────────┘                          └─────────────┘
```

**Key Decisions**:
- **Single instance** (not HA) - sufficient for homelab scale
- **Kubernetes SD** for automatic target discovery via annotations
- **30-day retention** with ~10GB storage allocation
- **Node affinity**: Prefer Hestia (amd64, more resources)

**Storage**:
```hcl
# PVC with glusterfs-nfs StorageClass
resource "kubernetes_persistent_volume_claim" "prometheus_data" {
  metadata {
    name = "prometheus-data"
    annotations = {
      "volume-name" = "prometheus_data"  # Creates /storage/v/glusterfs_prometheus_data
    }
  }
  spec {
    storage_class_name = "glusterfs-nfs"
    access_modes       = ["ReadWriteMany"]
    resources {
      requests = { storage = "10Gi" }
    }
  }
}
```

**RBAC Requirements**:
- ClusterRole to read pods, services, endpoints, nodes for service discovery
- ServiceAccount bound to ClusterRole

**Scrape Configuration**:
```yaml
# Key scrape jobs
- job_name: 'kubernetes-pods'
  kubernetes_sd_configs:
    - role: pod
  relabel_configs:
    - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
      action: keep
      regex: true

- job_name: 'kubernetes-nodes'
  kubernetes_sd_configs:
    - role: node
  # Scrape kubelet metrics

- job_name: 'kubernetes-services'
  kubernetes_sd_configs:
    - role: service
  relabel_configs:
    - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_scrape]
      action: keep
      regex: true
```

**Ingress**:
- Hostname: `prometheus.brmartin.co.uk`
- TLS via `wildcard-brmartin-tls` secret
- Optional: OAuth middleware for authentication (or rely on Prometheus basic auth)

### 2. Grafana

**Purpose**: Visualization, dashboards, alerting UI

**Architecture**:
```
┌─────────────────────────────────────────────────────────────────┐
│                          Grafana                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │ Dashboards  │  │   Plugins   │  │    Data Sources         │  │
│  │ (provisioned)│ │ (bundled)   │  │  - Prometheus           │  │
│  └─────────────┘  └─────────────┘  │  - Elasticsearch        │  │
│                                     └─────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
         ↑                                      ↑
    ┌────┴────┐                          ┌──────┴──────┐
    │ Keycloak│                          │ Prometheus  │
    │ (OAuth) │                          │ (metrics)   │
    └─────────┘                          └─────────────┘
```

**Key Decisions**:
- **Keycloak OAuth** for SSO authentication (existing pattern)
- **Provisioned dashboards** via ConfigMaps (Kubernetes, Node Exporter, etc.)
- **Provisioned data sources** (Prometheus, optionally Elasticsearch)
- **GlusterFS storage** for Grafana SQLite database and plugins

**Storage**:
```hcl
resource "kubernetes_persistent_volume_claim" "grafana_data" {
  metadata {
    name = "grafana-data"
    annotations = {
      "volume-name" = "grafana_data"  # Creates /storage/v/glusterfs_grafana_data
    }
  }
  spec {
    storage_class_name = "glusterfs-nfs"
    access_modes       = ["ReadWriteMany"]
    resources {
      requests = { storage = "1Gi" }
    }
  }
}
```

**Keycloak Integration**:
```hcl
# Environment variables for OAuth
env {
  name  = "GF_AUTH_GENERIC_OAUTH_ENABLED"
  value = "true"
}
env {
  name  = "GF_AUTH_GENERIC_OAUTH_NAME"
  value = "Keycloak"
}
env {
  name  = "GF_AUTH_GENERIC_OAUTH_CLIENT_ID"
  value = "grafana"
}
env {
  name = "GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET"
  value_from {
    secret_key_ref {
      name = "grafana-secrets"
      key  = "OAUTH_CLIENT_SECRET"
    }
  }
}
env {
  name  = "GF_AUTH_GENERIC_OAUTH_AUTH_URL"
  value = "https://sso.brmartin.co.uk/realms/prod/protocol/openid-connect/auth"
}
env {
  name  = "GF_AUTH_GENERIC_OAUTH_TOKEN_URL"
  value = "https://sso.brmartin.co.uk/realms/prod/protocol/openid-connect/token"
}
env {
  name  = "GF_AUTH_GENERIC_OAUTH_API_URL"
  value = "https://sso.brmartin.co.uk/realms/prod/protocol/openid-connect/userinfo"
}
```

**Secrets (via Vault/ExternalSecrets)**:
- `GF_SECURITY_ADMIN_PASSWORD` - Initial admin password
- `OAUTH_CLIENT_SECRET` - Keycloak client secret

**Ingress**:
- Hostname: `grafana.brmartin.co.uk`
- TLS via `wildcard-brmartin-tls` secret

### 3. Meshery

**Purpose**: Service mesh management and visualization (Cilium in this cluster)

**Architecture**:
```
┌─────────────────────────────────────────────────────────────────┐
│                          Meshery                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │ Adapters    │  │   UI        │  │    Performance Testing  │  │
│  │ (Cilium)    │  │ (React)     │  │    (Nighthawk)          │  │
│  └─────────────┘  └─────────────┘  └─────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
         ↑                                      ↑
    ┌────┴────┐                          ┌──────┴──────┐
    │ Cilium  │                          │ K8s API     │
    │ (CNI)   │                          │ (cluster)   │
    └─────────┘                          └─────────────┘
```

**Key Decisions**:
- **Cilium adapter** for service mesh visualization (cluster uses Cilium CNI)
- **Keycloak OAuth** for authentication
- **No persistent storage** initially (stateless, config via environment)
- **Cluster-admin RBAC** required for mesh management

**RBAC Requirements**:
- ClusterRole with broad permissions (similar to cluster-admin)
- ServiceAccount for Meshery to interact with K8s API and Cilium

**Ingress**:
- Hostname: `meshery.brmartin.co.uk`
- TLS via `wildcard-brmartin-tls` secret

## Integration Points

### Prometheus → Grafana
- Grafana data source configured to query `http://prometheus.default.svc.cluster.local:9090`
- Provisioned via ConfigMap

### Prometheus → Existing Services
Services need annotations for auto-discovery:
```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8080"
  prometheus.io/path: "/metrics"
```

### Grafana → Keycloak
- Create Keycloak client `grafana` in `prod` realm
- Configure redirect URIs: `https://grafana.brmartin.co.uk/*`
- Store client secret in Vault at `nomad/default/grafana`

### Meshery → Cilium
- Meshery Cilium adapter connects to Cilium API
- Requires access to Cilium CRDs and Hubble

## Secrets Management

All secrets stored in Vault and synced via ExternalSecrets:

| Secret | Vault Path | Keys |
|--------|------------|------|
| `prometheus-secrets` | `nomad/default/prometheus` | `BASIC_AUTH_PASSWORD` (optional) |
| `grafana-secrets` | `nomad/default/grafana` | `GF_SECURITY_ADMIN_PASSWORD`, `OAUTH_CLIENT_SECRET` |
| `meshery-secrets` | `nomad/default/meshery` | `MESHERY_PROVIDER_TOKEN` (optional) |

## Resource Estimates

| Component | CPU Request | CPU Limit | Memory Request | Memory Limit |
|-----------|-------------|-----------|----------------|--------------|
| Prometheus | 500m | 2000m | 1Gi | 2Gi |
| Grafana | 100m | 500m | 256Mi | 512Mi |
| Meshery | 200m | 1000m | 256Mi | 512Mi |

## Implementation Phases

### Phase 1: Prometheus (Foundation)
1. Create `modules-k8s/prometheus/` module structure
2. Implement RBAC (ServiceAccount, ClusterRole, ClusterRoleBinding)
3. Create ConfigMap with scrape configuration
4. Create PVC for data storage
5. Create Deployment with proper probes
6. Create Service (ClusterIP)
7. Create IngressRoute for external access
8. Add module to `kubernetes.tf`
9. Verify scraping works with existing services

### Phase 2: Grafana (Visualization)
1. Create Keycloak client for Grafana OAuth
2. Add secrets to Vault
3. Create `modules-k8s/grafana/` module structure
4. Create ExternalSecret for credentials
5. Create ConfigMaps for data source and dashboard provisioning
6. Create PVC for data storage
7. Create Deployment with OAuth configuration
8. Create Service (ClusterIP)
9. Create IngressRoute
10. Add module to `kubernetes.tf`
11. Verify OAuth login and Prometheus data source

### Phase 3: Meshery (Service Mesh Management)
1. Create `modules-k8s/meshery/` module structure
2. Implement RBAC (cluster-wide permissions)
3. Create Deployment with Cilium adapter
4. Create Service (ClusterIP)
5. Create IngressRoute
6. Add module to `kubernetes.tf`
7. Verify Cilium connectivity and mesh visualization

### Phase 4: Integration & Dashboards
1. Add Prometheus annotations to existing services
2. Import/create Kubernetes dashboards in Grafana
3. Import/create Node Exporter dashboards
4. Configure Grafana alerting (optional)
5. Document monitoring patterns in AGENTS.md

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Prometheus OOM on high cardinality | Service crash | Set memory limits, configure retention, use recording rules |
| GlusterFS latency for Prometheus TSDB | Slow queries | Monitor performance, consider local-path storage if needed |
| Keycloak unavailable blocks Grafana login | No dashboard access | Configure fallback admin login |
| ARM64 image compatibility | Pods won't schedule | Verify multi-arch images for all components |

## Success Criteria

1. Prometheus successfully scrapes all K8s nodes and annotated services
2. Grafana accessible via SSO with working Prometheus data source
3. Meshery shows Cilium service mesh topology
4. All components pass health checks and remain stable for 24h
5. Documentation updated in AGENTS.md

## Open Questions

1. **Alertmanager**: Should we deploy Alertmanager for alert routing? (Recommend: Phase 2 addition)
2. **Node Exporter**: Deploy as DaemonSet for host metrics? (Recommend: Yes, add to Phase 1)
3. **kube-state-metrics**: Deploy for K8s object metrics? (Recommend: Yes, add to Phase 1)
4. **Prometheus retention**: 30 days sufficient? (Recommend: Start with 30d, adjust based on storage usage)

## References

- [Prometheus Kubernetes SD](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#kubernetes_sd_config)
- [Grafana OAuth Configuration](https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-authentication/generic-oauth/)
- [Meshery Documentation](https://docs.meshery.io/)
- [Existing ELK module](modules-k8s/elk/main.tf) - Pattern reference
- [Existing Keycloak module](modules-k8s/keycloak/main.tf) - OAuth pattern reference
