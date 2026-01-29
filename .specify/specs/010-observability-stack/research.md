# Research: Observability Stack

**Feature**: 010-observability-stack | **Date**: 2026-01-26

## Technology Selection

### Prometheus

**Version**: 2.54.x (latest stable)
**Image**: `prom/prometheus:v2.54.1` (multi-arch: amd64, arm64)

**Why Prometheus**:
- De facto standard for Kubernetes metrics
- Native Kubernetes service discovery
- Efficient time-series database
- Rich ecosystem (exporters, integrations)
- Already used by many existing tools (Grafana, alerting systems)

**Alternatives Considered**:
- **Victoria Metrics**: Better performance, but adds complexity
- **Mimir**: Designed for scale we don't need
- **Thanos**: HA solution, overkill for homelab

### Grafana

**Version**: 11.x (latest stable)
**Image**: `grafana/grafana:11.4.0` (multi-arch: amd64, arm64)

**Why Grafana**:
- Industry standard visualization
- Native Keycloak/OAuth support
- Extensive dashboard ecosystem
- Supports multiple data sources (Prometheus, Elasticsearch)

**Alternatives Considered**:
- **Kibana**: Already deployed for logs, but Prometheus integration is limited
- **Chronograf**: InfluxDB-focused, not ideal for Prometheus

### Meshery

**Version**: 0.7.x (latest stable)
**Image**: `layer5/meshery:v0.7.159` (multi-arch: amd64, arm64)

**Why Meshery**:
- Multi-mesh support (works with Cilium)
- Service mesh visualization
- Performance testing capabilities
- Active development by Layer5

**Alternatives Considered**:
- **Hubble UI**: Already deployed, but limited to Cilium-specific views
- **Kiali**: Istio-focused, not ideal for Cilium

## Container Images

All images verified for multi-arch support (amd64 + arm64):

| Component | Image | Tag | Verified |
|-----------|-------|-----|----------|
| Prometheus | `prom/prometheus` | `v2.54.1` | Yes |
| Grafana | `grafana/grafana` | `11.4.0` | Yes |
| Meshery | `layer5/meshery` | `v0.7.159` | Yes |
| Node Exporter | `prom/node-exporter` | `v1.8.2` | Yes |
| kube-state-metrics | `registry.k8s.io/kube-state-metrics/kube-state-metrics` | `v2.13.0` | Yes |

## Prometheus Configuration

### Service Discovery

Kubernetes service discovery configuration for automatic target detection:

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  # Scrape Prometheus itself
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  # Kubernetes API servers
  - job_name: 'kubernetes-apiservers'
    kubernetes_sd_configs:
      - role: endpoints
    scheme: https
    tls_config:
      ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
    relabel_configs:
      - source_labels: [__meta_kubernetes_namespace, __meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name]
        action: keep
        regex: default;kubernetes;https

  # Kubernetes nodes (kubelet)
  - job_name: 'kubernetes-nodes'
    kubernetes_sd_configs:
      - role: node
    scheme: https
    tls_config:
      ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
    relabel_configs:
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)

  # Kubernetes nodes (cadvisor)
  - job_name: 'kubernetes-cadvisor'
    kubernetes_sd_configs:
      - role: node
    scheme: https
    tls_config:
      ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
    metrics_path: /metrics/cadvisor
    relabel_configs:
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)

  # Kubernetes service endpoints
  - job_name: 'kubernetes-service-endpoints'
    kubernetes_sd_configs:
      - role: endpoints
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_scrape]
        action: keep
        regex: true
      - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_scheme]
        action: replace
        target_label: __scheme__
        regex: (https?)
      - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      - source_labels: [__address__, __meta_kubernetes_service_annotation_prometheus_io_port]
        action: replace
        target_label: __address__
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
      - action: labelmap
        regex: __meta_kubernetes_service_label_(.+)
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        target_label: kubernetes_namespace
      - source_labels: [__meta_kubernetes_service_name]
        action: replace
        target_label: kubernetes_name

  # Kubernetes pods (for pods with prometheus.io/scrape annotation)
  - job_name: 'kubernetes-pods'
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: true
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scheme]
        action: replace
        target_label: __scheme__
        regex: (https?)
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        target_label: __address__
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        target_label: kubernetes_namespace
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: kubernetes_pod_name
```

### Storage Requirements

Prometheus TSDB storage calculation:
- ~25 services with ~100 metrics each = 2,500 time series
- 15s scrape interval = 4 samples/minute = 5,760 samples/day per series
- 30 days retention = 172,800 samples per series
- Estimated storage: ~5-10GB (with compression)

**Recommendation**: 10Gi PVC with monitoring for growth

### RBAC Requirements

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prometheus
rules:
  - apiGroups: [""]
    resources:
      - nodes
      - nodes/proxy
      - nodes/metrics
      - services
      - endpoints
      - pods
    verbs: ["get", "list", "watch"]
  - apiGroups: ["extensions", "networking.k8s.io"]
    resources:
      - ingresses
    verbs: ["get", "list", "watch"]
  - nonResourceURLs: ["/metrics", "/metrics/cadvisor"]
    verbs: ["get"]
```

## Grafana Configuration

### OAuth with Keycloak

Keycloak client configuration:
1. Create client `grafana` in `prod` realm
2. Client Protocol: `openid-connect`
3. Access Type: `confidential`
4. Valid Redirect URIs: `https://grafana.brmartin.co.uk/*`
5. Web Origins: `https://grafana.brmartin.co.uk`

Grafana environment variables:
```
GF_SERVER_ROOT_URL=https://grafana.brmartin.co.uk
GF_AUTH_GENERIC_OAUTH_ENABLED=true
GF_AUTH_GENERIC_OAUTH_NAME=Keycloak
GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP=true
GF_AUTH_GENERIC_OAUTH_CLIENT_ID=grafana
GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=<from-vault>
GF_AUTH_GENERIC_OAUTH_SCOPES=openid email profile
GF_AUTH_GENERIC_OAUTH_AUTH_URL=https://sso.brmartin.co.uk/realms/prod/protocol/openid-connect/auth
GF_AUTH_GENERIC_OAUTH_TOKEN_URL=https://sso.brmartin.co.uk/realms/prod/protocol/openid-connect/token
GF_AUTH_GENERIC_OAUTH_API_URL=https://sso.brmartin.co.uk/realms/prod/protocol/openid-connect/userinfo
GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH=contains(groups[*], 'admin') && 'Admin' || 'Viewer'
```

### Data Source Provisioning

```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus.default.svc.cluster.local:9090
    isDefault: true
    editable: false
    
  - name: Elasticsearch
    type: elasticsearch
    access: proxy
    url: https://elasticsearch.default.svc.cluster.local:9200
    database: "logs-*"
    basicAuth: true
    basicAuthUser: elastic
    jsonData:
      esVersion: "9.0.0"
      timeField: "@timestamp"
      tlsSkipVerify: true
    secureJsonData:
      basicAuthPassword: <from-vault>
```

### Dashboard Provisioning

Recommended dashboards (via ConfigMap):
1. **Kubernetes Cluster** (ID: 6417) - Cluster overview
2. **Kubernetes Pods** (ID: 6336) - Pod-level metrics
3. **Node Exporter Full** (ID: 1860) - Host metrics
4. **Traefik** (ID: 4475) - Ingress metrics

## Meshery Configuration

### Cilium Adapter

Meshery connects to Cilium via:
1. Kubernetes API (for CRDs)
2. Hubble Relay (for flow data)

Required environment variables:
```
MESHERY_ADAPTER_URL=meshery-cilium:10012
```

### RBAC Requirements

Meshery requires extensive permissions for mesh management:
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: meshery
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["cilium.io"]
    resources: ["*"]
    verbs: ["*"]
  - apiGroups: [""]
    resources: ["configmaps", "secrets"]
    verbs: ["create", "update", "patch", "delete"]
```

## Node Exporter (Recommended Addition)

Deploy as DaemonSet for host-level metrics:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
spec:
  selector:
    matchLabels:
      app: node-exporter
  template:
    spec:
      hostNetwork: true
      hostPID: true
      containers:
        - name: node-exporter
          image: prom/node-exporter:v1.8.2
          args:
            - --path.procfs=/host/proc
            - --path.sysfs=/host/sys
            - --path.rootfs=/host/root
            - --collector.filesystem.ignored-mount-points=^/(dev|proc|sys|var/lib/docker/.+)($|/)
          ports:
            - containerPort: 9100
              hostPort: 9100
          volumeMounts:
            - name: proc
              mountPath: /host/proc
              readOnly: true
            - name: sys
              mountPath: /host/sys
              readOnly: true
            - name: root
              mountPath: /host/root
              readOnly: true
      volumes:
        - name: proc
          hostPath:
            path: /proc
        - name: sys
          hostPath:
            path: /sys
        - name: root
          hostPath:
            path: /
```

## kube-state-metrics (Recommended Addition)

Deploy for Kubernetes object metrics:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kube-state-metrics
spec:
  replicas: 1
  template:
    spec:
      serviceAccountName: kube-state-metrics
      containers:
        - name: kube-state-metrics
          image: registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.13.0
          ports:
            - containerPort: 8080
              name: http-metrics
            - containerPort: 8081
              name: telemetry
```

## Existing Service Annotations

Services that should be annotated for Prometheus scraping:

| Service | Metrics Port | Metrics Path | Notes |
|---------|--------------|--------------|-------|
| Traefik | 9100 | /metrics | Already exposes metrics |
| MinIO | 9000 | /minio/v2/metrics/cluster | Requires auth |
| Elasticsearch | 9200 | /_prometheus/metrics | Via plugin |
| Keycloak | 9000 | /metrics | Management port |
| GitLab | Various | /metrics | Multiple components |

## Network Policies

If Cilium network policies are enforced, allow:
1. Prometheus → all pods (for scraping)
2. Grafana → Prometheus (for queries)
3. Grafana → Keycloak (for OAuth)
4. Meshery → Cilium/Hubble (for mesh data)
5. External → Prometheus/Grafana/Meshery (via Traefik)

## Monitoring the Monitors

Meta-monitoring considerations:
1. Prometheus self-scraping (built-in)
2. Grafana health endpoint (`/api/health`)
3. Alerting on Prometheus down (external check or Elasticsearch alert)

## References

- [Prometheus Operator vs Vanilla](https://prometheus.io/docs/prometheus/latest/getting_started/)
- [Grafana Keycloak Integration](https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-authentication/keycloak/)
- [Meshery Cilium Adapter](https://docs.meshery.io/extensibility/adapters/cilium)
- [kube-state-metrics](https://github.com/kubernetes/kube-state-metrics)
- [Node Exporter](https://github.com/prometheus/node_exporter)
