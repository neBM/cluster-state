# Task Breakdown: Observability Stack (Prometheus, Grafana, Meshery)

**Branch**: `010-observability-stack` | **Date**: 2026-01-26 | **Plan**: [plan.md](plan.md)

## Phase 1: Prometheus Foundation

### 1.1 Create Prometheus Module Structure
- [X] Create directory `modules-k8s/prometheus/`
- [X] Create `variables.tf` with module inputs
- [X] Create `main.tf` with basic structure and locals

### 1.2 Implement Prometheus RBAC
- [X] Create `rbac.tf` with ServiceAccount
- [X] Add ClusterRole with required permissions (nodes, pods, services, endpoints)
- [X] Add ClusterRoleBinding

### 1.3 Create Prometheus Configuration
- [X] Create ConfigMap with prometheus.yml scrape configuration
- [X] Include kubernetes-apiservers, kubernetes-nodes, kubernetes-cadvisor jobs
- [X] Include kubernetes-service-endpoints and kubernetes-pods jobs with annotation-based discovery

### 1.4 Create Prometheus Storage
- [X] Create PVC for Prometheus data (10Gi, local-path StorageClass — migrated from glusterfs-nfs)
- [X] Add volume-name annotation for directory naming

### 1.5 Create Prometheus Deployment
- [X] Create Deployment with prometheus:v2.54.1 image
- [X] Configure volume mounts for data and config
- [X] Add liveness and readiness probes
- [X] Set resource requests/limits (500m-2000m CPU, 1Gi-2Gi memory)
- [X] Add node affinity to prefer Hestia (amd64)

### 1.6 Create Prometheus Service and Ingress
- [X] Create ClusterIP Service on port 9090
- [X] Create IngressRoute for prometheus.brmartin.co.uk
- [X] Add ServersTransport for scheme configuration

### 1.7 Add Prometheus to Terraform
- [X] Add module block to kubernetes.tf
- [X] Configure module variables
- [X] Run terraform plan and verify

### 1.8 Deploy Node Exporter (Parallel)
- [X] Create `modules-k8s/node-exporter/` module
- [X] Implement DaemonSet with hostNetwork and hostPID
- [X] Configure volume mounts for /proc, /sys, /root
- [X] Add Service with prometheus.io/scrape annotation
- [X] Add to kubernetes.tf

### 1.9 Deploy kube-state-metrics (Parallel)
- [X] Create `modules-k8s/kube-state-metrics/` module
- [X] Implement Deployment with appropriate RBAC
- [X] Add Service with prometheus.io/scrape annotation
- [X] Add to kubernetes.tf

### 1.10 Verify Prometheus Deployment
- [X] Apply terraform changes
- [X] Verify Prometheus UI accessible (/-/ready returns 200 internally, 403 externally — behind auth middleware)
- [X] Check targets page shows discovered services (27 active targets, 24 up)
- [X] Verify metrics from node-exporter and kube-state-metrics

## Phase 2: Grafana Visualization

### 2.1 Create Keycloak Client
- [X] Access Keycloak admin console
- [X] Create client 'grafana' in prod realm (already existed)
- [X] Configure as confidential client with openid-connect (verified — client_secret auth works)
- [X] Set redirect URIs to https://grafana.brmartin.co.uk/*
- [X] Copy client secret

### 2.2 Add Grafana Secrets to Vault
- [X] Create Vault entry at nomad/default/grafana (already existed)
- [X] Add GF_SECURITY_ADMIN_PASSWORD (present in Vault)
- [X] Add OAUTH_CLIENT_SECRET from Keycloak (present in Vault)

### 2.3 Create Grafana Module Structure
- [X] Create directory `modules-k8s/grafana/`
- [X] Create `variables.tf` with module inputs
- [X] Create `main.tf` with basic structure

### 2.4 Create Grafana ExternalSecret
- [X] Create `secrets.tf` with ExternalSecret resource
- [X] Reference vault-backend ClusterSecretStore
- [X] Map Vault keys to K8s secret keys

### 2.5 Create Grafana Configuration
- [X] Create ConfigMap for datasource provisioning (prometheus.yaml)
- [X] Create ConfigMap for dashboard provisioning config
- [X] Create ConfigMap for initial dashboards (optional)

### 2.6 Create Grafana Storage
- [X] Create PVC for Grafana data (1Gi, local-path StorageClass — changed from glusterfs-nfs)
- [X] Add volume-name annotation

### 2.7 Create Grafana Deployment
- [X] Create Deployment with grafana:11.4.0 image
- [X] Configure OAuth environment variables
- [X] Mount secrets, datasources, and data volume
- [X] Add liveness and readiness probes
- [X] Set resource requests/limits (100m-500m CPU, 256Mi-512Mi memory)

### 2.8 Create Grafana Service and Ingress
- [X] Create ClusterIP Service on port 3000
- [X] Create IngressRoute for grafana.brmartin.co.uk

### 2.9 Add Grafana to Terraform
- [X] Add module block to kubernetes.tf
- [X] Configure module variables
- [X] Run terraform plan and verify

### 2.10 Verify Grafana Deployment
- [X] Apply terraform changes (deployment created, v11.4.0 healthy)
- [X] Test OAuth login via Keycloak (confirmed working)
- [X] Verify Prometheus datasource connected (API confirms datasource uid PBFA97CFB590B2093 active)
- [X] Import basic Kubernetes dashboard

## Phase 3: Meshery Service Mesh Management

### 3.1 Create Meshery Module Structure
- [X] Create directory `modules-k8s/meshery/`
- [X] Create `variables.tf` with module inputs
- [X] Create `main.tf` with basic structure

### 3.2 Implement Meshery RBAC
- [X] Create `rbac.tf` with ServiceAccount
- [X] Add ClusterRole with broad permissions for mesh management
- [X] Add ClusterRoleBinding

### 3.3 Create Meshery Deployment
- [X] Create Deployment with meshery:stable-v0.8.200 image (updated from v0.7.159)
- [X] Configure environment for Cilium adapter
- [X] Add liveness, readiness, and startup probes (fixed port 9081→8080, added arch nodeSelector)
- [X] Set resource requests/limits (100m-500m CPU, 256Mi-1Gi memory)
- **Note**: Scaled to 0 — OOMKills at 1Gi. Needs 2Gi+ to run. Parked for now.

### 3.4 Create Meshery Service and Ingress
- [X] Create ClusterIP Service on port 9081 (proxies to container port 8080)
- [X] Create IngressRoute for meshery.brmartin.co.uk

### 3.5 Add Meshery to Terraform
- [X] Add module block to kubernetes.tf
- [X] Configure module variables (replicas=0, parked)
- [X] Run terraform plan and verify

### 3.6 Verify Meshery Deployment
- [X] Apply terraform changes
- [ ] Access Meshery UI (**BLOCKED** — scaled to 0, needs 2Gi+ memory)
- [ ] Verify Cilium adapter connection (**BLOCKED**)
- [ ] Check service mesh visualization (**BLOCKED**)

## Phase 4: Integration and Dashboards

### 4.1 Annotate Existing Services
- [X] Add prometheus.io/scrape annotations to Traefik
- [X] Add annotations to MinIO (if metrics endpoint available)
- [X] Add annotations to Keycloak metrics endpoint
- [X] Add annotations to other services with metrics

### 4.2 Import Grafana Dashboards
- [X] Import Kubernetes Cluster dashboard (ID: 6417) → uid: 4XuMd2Iiz
- [X] Import Kubernetes Pods dashboard (ID: 6336) → uid: -7mPcYniz
- [X] Import Node Exporter Full dashboard (ID: 1860) → uid: rYdddlPWk
- [X] Import Traefik dashboard (ID: 4475) → uid: qPdAviJmz
- [X] Configure dashboard variables (pre-configured in community dashboards, auto-populated from Prometheus)

### 4.3 Configure Grafana Alerts
- [X] Create alert rules for critical metrics (6 rules: Node Down, Pod CrashLooping, High Memory, High CPU, Disk Space Low, Target Down)
- [X] Configure notification channels (default email contact point — SMTP not configured, alerts visible in Grafana UI)
- [X] Test alert delivery (rules evaluating — Prometheus Target Down correctly in Pending state for meshery endpoints)

### 4.4 Update Documentation
- [X] Add observability section to AGENTS.md
- [X] Document Prometheus scraping patterns
- [X] Document Grafana dashboard access
- [X] Document common queries and troubleshooting

### 4.5 Final Verification
- [X] Verify all services are being scraped (27 targets, 24 up — 3 are meshery endpoints which are scaled to 0)
- [X] Check Grafana dashboards show data (confirmed by user)
- [ ] Test Meshery service mesh features (**BLOCKED** — parked)
- [ ] Monitor for 24h stability (started 2026-01-27 ~20:00 UTC)

## Dependencies

- Phase 1 must complete before Phase 2 (Grafana needs Prometheus)
- Phase 2 and Phase 3 can run in parallel
- Phase 4 depends on all previous phases
- Within Phase 1: Tasks 1.8 and 1.9 can run in parallel with 1.1-1.7

## Success Criteria

- [X] Prometheus successfully scrapes all annotated services (27 targets, 24 up)
- [X] Grafana accessible via Keycloak SSO (confirmed working)
- [X] Dashboards display metrics from all nodes and services (4 dashboards imported, data confirmed)
- [ ] Meshery shows Cilium service mesh topology (**BLOCKED** — parked)
- [ ] All components stable for 24+ hours (monitoring started 2026-01-27)
- [X] Documentation updated in AGENTS.md

## Risk Mitigations

| Risk | Mitigation | Outcome |
|------|------------|---------|
| Prometheus OOM | Monitor memory usage, adjust retention if needed | ✅ Running stable at ~734Mi / 1Gi limit |
| GlusterFS latency | Monitor query performance, consider local storage if issues | ⚠️ **HIT** — TSDB corrupted from stale NFS handles. Migrated Prometheus + Grafana to local-path |
| ARM64 compatibility | All images verified for multi-arch support | ⚠️ **HIT** — Meshery is amd64-only. Added nodeSelector. |
| Keycloak downtime | Document fallback admin login for Grafana | Pending — admin password in Vault |
| Meshery memory | (not originally identified) | ⚠️ **HIT** — OOMKills at 1Gi. Needs 2Gi+. Scaled to 0. |