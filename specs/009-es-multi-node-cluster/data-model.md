# Data Model: Elasticsearch Multi-Node Cluster

**Date**: 2026-01-25  
**Status**: Complete  
**Related**: [spec.md](./spec.md), [research.md](./research.md)

## Entity Overview

This document defines the Kubernetes resources and Elasticsearch cluster topology for the multi-node cluster migration.

---

## Elasticsearch Cluster Topology

### Node Configuration Matrix

| Node Name | K8s Resource | Host | Roles | Memory | CPU | Storage | JVM Heap |
|-----------|--------------|------|-------|--------|-----|---------|----------|
| elasticsearch-data-0 | StatefulSet | Hestia | master, data, data_content, data_hot, ingest, ml | 6Gi | 2000m | 50Gi (local-path) | 3g |
| elasticsearch-data-1 | StatefulSet | Heracles | master, data, data_content, data_hot, ingest | 6Gi | 2000m | 50Gi (local-path) | 3g |
| elasticsearch-tiebreaker-0 | StatefulSet | Nyx | master, voting_only | 512Mi | 500m | None | 256m |

### Shard Distribution

**Target State** (after migration):
- All indices: 1 primary shard + 1 replica = 2 copies
- Primary shards distributed across both data nodes
- Replica shards on opposite data node from primary
- Tiebreaker holds no shards

**Example Distribution**:
```
Index: logs-docker.container_logs-2026.01
├── Primary Shard 0 → elasticsearch-data-0 (Hestia)
│   └── Replica 0 → elasticsearch-data-1 (Heracles)
├── Primary Shard 1 → elasticsearch-data-1 (Heracles)
│   └── Replica 1 → elasticsearch-data-0 (Hestia)
```

---

## Kubernetes Resources

### 1. StorageClass: local-path-retain

```yaml
Entity: StorageClass
Name: local-path-retain
Purpose: Local storage with data retention on PVC deletion

Fields:
- provisioner: rancher.io/local-path
- reclaimPolicy: Retain  # Critical - prevents data loss
- volumeBindingMode: WaitForFirstConsumer  # Binds to scheduled node
```

### 2. StatefulSet: elasticsearch-data

```yaml
Entity: StatefulSet
Name: elasticsearch-data
Namespace: default
Replicas: 2

Pod Template:
  Labels:
    app: elasticsearch
    role: data
  
  Node Affinity:
    required:
      - kubernetes.io/hostname in [hestia, heracles]
  
  Pod Anti-Affinity:
    required:
      - app: elasticsearch, role: data
      - topologyKey: kubernetes.io/hostname
  
  Init Containers:
    - name: sysctl
      image: busybox:1.36
      command: sysctl -w vm.max_map_count=262144
      privileged: true
  
  Containers:
    - name: elasticsearch
      image: docker.elastic.co/elasticsearch/elasticsearch:9.2.3
      ports:
        - 9200 (http)
        - 9300 (transport)
      resources:
        requests: { cpu: 1000m, memory: 6Gi }
        limits: { cpu: 2000m, memory: 6Gi }
      env:
        - ES_JAVA_OPTS: -Xms3g -Xmx3g
        - node.roles: master,data,data_content,data_hot,ingest
        - node.name: $(POD_NAME)
        - cluster.name: docker-cluster
        - discovery.seed_hosts: elasticsearch-data-headless,elasticsearch-tiebreaker-headless
        - cluster.initial_master_nodes: elasticsearch-data-0,elasticsearch-data-1,elasticsearch-tiebreaker-0
      volumeMounts:
        - name: data → /usr/share/elasticsearch/data
        - name: config → /usr/share/elasticsearch/config/elasticsearch.yml
        - name: certs → /usr/share/elasticsearch/config/certs
        - name: keystore → /usr/share/elasticsearch/config/elasticsearch.keystore

VolumeClaimTemplates:
  - name: data
    storageClassName: local-path-retain
    accessModes: [ReadWriteOnce]
    storage: 50Gi
```

### 3. StatefulSet: elasticsearch-tiebreaker

```yaml
Entity: StatefulSet
Name: elasticsearch-tiebreaker
Namespace: default
Replicas: 1

Pod Template:
  Labels:
    app: elasticsearch
    role: tiebreaker
  
  Node Affinity:
    required:
      - kubernetes.io/hostname in [nyx]
  
  Init Containers:
    - name: sysctl
      image: busybox:1.36
      command: sysctl -w vm.max_map_count=262144
      privileged: true
  
  Containers:
    - name: elasticsearch
      image: docker.elastic.co/elasticsearch/elasticsearch:9.2.3
      ports:
        - 9200 (http)
        - 9300 (transport)
      resources:
        requests: { cpu: 100m, memory: 512Mi }
        limits: { cpu: 500m, memory: 1Gi }
      env:
        - ES_JAVA_OPTS: -Xms256m -Xmx256m
        - node.roles: master,voting_only
        - node.name: $(POD_NAME)
        - cluster.name: docker-cluster
        - discovery.seed_hosts: elasticsearch-data-headless,elasticsearch-tiebreaker-headless
        - cluster.initial_master_nodes: elasticsearch-data-0,elasticsearch-data-1,elasticsearch-tiebreaker-0
      volumeMounts:
        - name: config → /usr/share/elasticsearch/config/elasticsearch.yml
        - name: certs → /usr/share/elasticsearch/config/certs

Volumes (no PVC):
  - name: config (ConfigMap)
  - name: certs (Secret)
```

### 4. Services

```yaml
# Headless Service for data node discovery
Entity: Service
Name: elasticsearch-data-headless
Type: ClusterIP (None)
Selector: app=elasticsearch, role=data
Ports:
  - 9200 (http)
  - 9300 (transport)

---
# Headless Service for tiebreaker discovery
Entity: Service
Name: elasticsearch-tiebreaker-headless
Type: ClusterIP (None)
Selector: app=elasticsearch, role=tiebreaker
Ports:
  - 9200 (http)
  - 9300 (transport)

---
# ClusterIP Service for HTTP API
Entity: Service
Name: elasticsearch
Type: ClusterIP
Selector: app=elasticsearch, role=data  # Only data nodes serve HTTP
Ports:
  - 9200 (http)

---
# NodePort Service for external access (Elastic Agent, Fleet)
Entity: Service
Name: elasticsearch-nodeport
Type: NodePort
Selector: app=elasticsearch, role=data
Ports:
  - 9200 → 30092
```

### 5. ConfigMaps

```yaml
Entity: ConfigMap
Name: elasticsearch-data-config

Data:
  elasticsearch.yml: |
    cluster.name: "docker-cluster"
    network.host: 0.0.0.0
    http.port: 9200
    transport.port: 9300
    
    path.data: /usr/share/elasticsearch/data
    
    bootstrap.memory_lock: true
    
    xpack:
      ml.enabled: true  # Only on data nodes
      security:
        enabled: true
        enrollment.enabled: false
        authc:
          anonymous:
            username: anonymous_user
            roles: remote_monitoring_collector
            authz_exception: false
        transport.ssl:
          enabled: true
          verification_mode: certificate
          key: /usr/share/elasticsearch/config/certs/tls.key
          certificate: /usr/share/elasticsearch/config/certs/tls.crt
          certificate_authorities: /usr/share/elasticsearch/config/certs/ca.crt
        http.ssl:
          enabled: true
          keystore.path: /usr/share/elasticsearch/config/certs/http.p12

---
Entity: ConfigMap
Name: elasticsearch-tiebreaker-config

Data:
  elasticsearch.yml: |
    cluster.name: "docker-cluster"
    network.host: 0.0.0.0
    http.port: 9200
    transport.port: 9300
    
    # No path.data - tiebreaker stores no data
    
    bootstrap.memory_lock: false  # Not needed for small heap
    
    xpack:
      ml.enabled: false  # No ML on tiebreaker
      security:
        enabled: true
        enrollment.enabled: false
        transport.ssl:
          enabled: true
          verification_mode: certificate
          key: /usr/share/elasticsearch/config/certs/tls.key
          certificate: /usr/share/elasticsearch/config/certs/tls.crt
          certificate_authorities: /usr/share/elasticsearch/config/certs/ca.crt
        http.ssl:
          enabled: true
          keystore.path: /usr/share/elasticsearch/config/certs/http.p12
```

### 6. Secrets

```yaml
# Per-node TLS certificates
Entity: Secret
Name: elasticsearch-certs-data-0
Data:
  - tls.crt: (PEM certificate for elasticsearch-data-0)
  - tls.key: (PEM private key)
  - ca.crt: (CA certificate)

Entity: Secret
Name: elasticsearch-certs-data-1
Data:
  - tls.crt: (PEM certificate for elasticsearch-data-1)
  - tls.key: (PEM private key)
  - ca.crt: (CA certificate)

Entity: Secret
Name: elasticsearch-certs-tiebreaker-0
Data:
  - tls.crt: (PEM certificate for elasticsearch-tiebreaker-0)
  - tls.key: (PEM private key)
  - ca.crt: (CA certificate)

# HTTP layer keystore (shared)
Entity: Secret
Name: elasticsearch-certs
Data:
  - http.p12: (HTTP layer PKCS12 keystore - existing)
  - elasticsearch.keystore: (ES keystore with passwords - existing)
```

---

## State Transitions

### Cluster Health States

```
┌──────────────┐  All nodes healthy   ┌──────────────┐
│    GREEN     │◄────────────────────│    YELLOW    │
│  (normal)    │                      │ (degraded)   │
└──────┬───────┘                      └──────┬───────┘
       │                                     │
       │ 1 node fails                        │ 2+ nodes fail
       ▼                                     ▼
┌──────────────┐                      ┌──────────────┐
│    YELLOW    │                      │     RED      │
│ (1 node down)│                      │ (unavailable)│
└──────────────┘                      └──────────────┘
```

**State Descriptions**:

| State | Condition | Impact |
|-------|-----------|--------|
| GREEN | All shards allocated, all replicas available | Normal operation |
| YELLOW | Primary shards OK, some replicas unavailable | Reads/writes work, reduced redundancy |
| RED | Some primary shards unavailable | Data loss risk, partial functionality |

### Node Failure Scenarios

| Scenario | Cluster State | Data Availability | Action |
|----------|---------------|-------------------|--------|
| Tiebreaker fails | GREEN | 100% | Cluster continues, reduced quorum tolerance |
| 1 data node fails | YELLOW | 100% (from replicas) | Writes continue to remaining node |
| 2 data nodes fail | RED | 0% | Cluster unavailable |
| Tiebreaker + 1 data | YELLOW | 100% | 2 nodes have quorum, cluster operates |

---

## Validation Rules

### Resource Constraints

| Resource | Minimum | Recommended | Maximum |
|----------|---------|-------------|---------|
| Data node memory | 4Gi | 6Gi | 8Gi |
| Data node CPU | 1000m | 2000m | 4000m |
| Data node storage | 30Gi | 50Gi | 100Gi |
| Tiebreaker memory | 256Mi | 512Mi | 1Gi |
| Tiebreaker CPU | 100m | 250m | 500m |

### Index Settings Requirements

All indices MUST have:
```json
{
  "settings": {
    "number_of_replicas": 1,
    "number_of_shards": 1  // Or appropriate for data size
  }
}
```

### ILM Policy Requirements

Existing ILM policies remain unchanged. Default template should enforce:
- `number_of_replicas: 1` for all new indices
- Rollover settings unchanged
- Retention settings unchanged

---

## Relationships

```
                    ┌─────────────────────┐
                    │   StorageClass      │
                    │  local-path-retain  │
                    └──────────┬──────────┘
                               │ provisions
                               ▼
┌───────────────────────────────────────────────────────────┐
│                  StatefulSet: elasticsearch-data          │
│  ┌─────────────────────┐    ┌─────────────────────┐      │
│  │ elasticsearch-data-0│    │ elasticsearch-data-1│      │
│  │      (Hestia)       │    │     (Heracles)      │      │
│  └──────────┬──────────┘    └──────────┬──────────┘      │
│             │ mounts                   │ mounts          │
│             ▼                          ▼                 │
│  ┌─────────────────────┐    ┌─────────────────────┐      │
│  │ PVC: data-es-data-0 │    │ PVC: data-es-data-1 │      │
│  └─────────────────────┘    └─────────────────────┘      │
└───────────────────────────────────────────────────────────┘
                               │
                               │ discovery
                               ▼
┌───────────────────────────────────────────────────────────┐
│             StatefulSet: elasticsearch-tiebreaker         │
│  ┌───────────────────────────────────────────────────┐   │
│  │           elasticsearch-tiebreaker-0              │   │
│  │                    (Nyx)                          │   │
│  │               No persistent storage               │   │
│  └───────────────────────────────────────────────────┘   │
└───────────────────────────────────────────────────────────┘
                               │
                               │ serves
                               ▼
┌───────────────────────────────────────────────────────────┐
│                    Service: elasticsearch                 │
│              (ClusterIP, load-balanced HTTP)              │
└───────────────────────────────────────────────────────────┘
                               │
                               │ connects
                               ▼
┌───────────────────────────────────────────────────────────┐
│                    Deployment: kibana                     │
│                     (unchanged)                           │
└───────────────────────────────────────────────────────────┘
```

---

## Terraform Module Structure

```hcl
modules-k8s/elk/
├── main.tf
│   ├── locals { }
│   ├── kubernetes_storage_class.local_path_retain
│   ├── kubernetes_config_map.elasticsearch_data
│   ├── kubernetes_config_map.elasticsearch_tiebreaker
│   ├── kubernetes_stateful_set.elasticsearch_data     # NEW
│   ├── kubernetes_stateful_set.elasticsearch_tiebreaker # NEW
│   ├── kubernetes_stateful_set.elasticsearch          # REMOVE
│   ├── kubernetes_service.elasticsearch_data_headless # NEW
│   ├── kubernetes_service.elasticsearch_tiebreaker_headless # NEW
│   ├── kubernetes_service.elasticsearch_headless      # MODIFY
│   ├── kubernetes_service.elasticsearch               # MODIFY selector
│   ├── kubernetes_service.elasticsearch_nodeport      # MODIFY selector
│   ├── kubernetes_config_map.kibana                   # UNCHANGED
│   ├── kubernetes_deployment.kibana                   # UNCHANGED
│   ├── kubernetes_service.kibana                      # UNCHANGED
│   └── kubectl_manifest.* (IngressRoutes)             # UNCHANGED
├── variables.tf
│   ├── es_data_memory_request  # NEW
│   ├── es_data_memory_limit    # NEW
│   ├── es_tiebreaker_memory_*  # NEW
│   ├── es_data_storage_size    # NEW
│   └── es_data_hostnames       # NEW (list: [hestia, heracles])
├── secrets.tf                   # UNCHANGED
└── versions.tf                  # UNCHANGED
```
