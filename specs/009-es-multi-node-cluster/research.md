# Research: Elasticsearch Multi-Node Cluster

**Date**: 2026-01-25  
**Status**: Complete  
**Related**: [spec.md](./spec.md), [plan.md](./plan.md)

## Executive Summary

Research confirms the "two data nodes + voting-only tiebreaker" architecture is Elastic's recommended pattern for high availability in small clusters. Key decisions:

1. **Storage**: Use local-path provisioner with `Retain` policy (NOT GlusterFS - improved I/O)
2. **Architecture**: Separate StatefulSets for data nodes and tiebreaker
3. **TLS**: Shared CA with per-node certificates in PEM format
4. **Discovery**: Kubernetes headless service DNS for cluster formation

---

## Research Topics

### 1. Cluster Formation: Discovery and Initial Master Nodes

**Decision**: Use headless service DNS-based discovery with explicit node names

**Configuration**:
```yaml
# For a 3-node cluster (2 data + 1 voting-only tiebreaker)
discovery.seed_hosts:
  - elasticsearch-data-0.elasticsearch-data-headless.default.svc.cluster.local
  - elasticsearch-data-1.elasticsearch-data-headless.default.svc.cluster.local
  - elasticsearch-tiebreaker-0.elasticsearch-tiebreaker-headless.default.svc.cluster.local

cluster.initial_master_nodes:
  - elasticsearch-data-0
  - elasticsearch-data-1
  - elasticsearch-tiebreaker-0
```

**Rationale**:
- Kubernetes headless service provides stable DNS names for StatefulSet pods
- `cluster.initial_master_nodes` is ONLY used during initial cluster bootstrap
- Node names match pod names from StatefulSet (deterministic)
- Transport port 9300 used for inter-node communication

**Alternatives Considered**:
- IP-based discovery: Rejected - pod IPs change on restart
- Single seed host: Rejected - creates SPOF during discovery

---

### 2. Node Roles Configuration

**Decision**: 
- **Data nodes (2)**: `master`, `data`, `data_content`, `data_hot`, `ingest`
- **Tiebreaker (1)**: `master`, `voting_only`

**Data Node Configuration (elasticsearch-data-0, elasticsearch-data-1)**:
```yaml
node.roles:
  - master
  - data
  - data_content
  - data_hot
  - ingest
```

**Voting-Only Tiebreaker Configuration (elasticsearch-tiebreaker-0)**:
```yaml
node.roles:
  - master
  - voting_only
```

**Rationale**:
- All nodes master-eligible ensures quorum (2 of 3) for cluster decisions
- `voting_only` means tiebreaker participates in elections but never becomes master
- Per Elastic docs: "This extra node should be a dedicated voting-only master-eligible node, meaning it has no other roles"
- Tiebreaker stores no data, only cluster state metadata (~10-50MB)

**Alternatives Considered**:
- Dedicated master nodes: Rejected - overkill for 3-node homelab cluster
- All nodes with data: Rejected - tiebreaker would waste storage

---

### 3. Voting-Only Tiebreaker: Resource Requirements

**Decision**: Minimal resources for voting-only master

**Resource Allocation**:
```yaml
resources:
  requests:
    cpu: "100m"      # 0.1 CPU core
    memory: "512Mi"  # 512 MB RAM
  limits:
    cpu: "500m"      # 0.5 CPU core
    memory: "1Gi"    # 1 GB RAM

# JVM Heap (50% of memory limit)
ES_JAVA_OPTS: "-Xms256m -Xmx256m"
```

**Resource Comparison**:
| Resource | Data Node | Voting-Only | Savings |
|----------|-----------|-------------|---------|
| Memory | 4-8GB | 512MB-1GB | 75-87% |
| CPU | 1-2 cores | 0.1-0.5 cores | 75-90% |
| Storage | 50GB+ | 0 | 100% |
| JVM Heap | 2-4GB | 256MB | 87-93% |

**Rationale**:
- Voting-only nodes don't store data: no heap needed for field data, doc values, or segments
- Only stores cluster state metadata
- Per spec requirement FR-004: "tiebreaker node MUST have minimal resource requirements (256Mi memory or less)"
- Note: 256Mi may be insufficient for JVM - research suggests 512Mi minimum for stable operation

**Risk**: FR-004 specifies 256Mi but research indicates JVM needs ~256MB heap + OS overhead. Recommend 512Mi minimum with 256Mi heap.

---

### 4. Storage Strategy: Local-Path vs GlusterFS

**Decision**: Use local-path StorageClass with `Retain` reclaim policy

**Why NOT GlusterFS**:
- Current GlusterFS I/O bottleneck: 95% CPU, 17+ flush queue, frequent OOM
- ES performs heavy random I/O - network storage adds latency
- Local NVMe/SSD on each node eliminates network overhead
- Spec explicitly requires: "Data nodes MUST use local storage instead of GlusterFS/NFS"

**Local-Path Configuration**:
```hcl
# Custom StorageClass with Retain policy
resource "kubernetes_storage_class" "local_path_retain" {
  metadata {
    name = "local-path-retain"
  }
  
  storage_provisioner = "rancher.io/local-path"
  reclaim_policy      = "Retain"
  volume_binding_mode = "WaitForFirstConsumer"
}
```

**Node Affinity Mechanism**:
1. Pod created with node affinity (e.g., `hostname=hestia`)
2. Scheduler places pod on Hestia
3. PVC binding triggered, local-path creates directory on Hestia
4. PV gets permanent node affinity
5. Future pod restarts mount same PV on same node

**Data Persistence Behavior**:
| Scenario | Outcome |
|----------|---------|
| Pod deleted/recreated | Data retained, same PV |
| Node temporary failure | Pod pending until node returns |
| Node permanent failure | Data stranded (ES replication provides HA) |
| PVC deleted (Delete policy) | Data LOST |
| PVC deleted (Retain policy) | Data retained |

**Rationale**:
- Local storage dramatically improves ES I/O performance
- `Retain` policy prevents accidental data loss
- ES shard replication provides data redundancy across nodes
- `WaitForFirstConsumer` ensures PV created on correct node

**Alternatives Considered**:
- hostPath (current): Simpler but no PVC abstraction
- GlusterFS: Rejected per spec - I/O bottleneck
- NFS: Rejected - same network overhead issues

---

### 5. TLS Configuration: Transport Layer Certificates

**Decision**: Shared CA with per-node certificates in PEM format

**Certificate Generation**:
```bash
# 1. Generate CA (one-time)
elasticsearch-certutil ca --pem --out ca.zip

# 2. Generate per-node certificates with DNS SANs
elasticsearch-certutil cert \
  --ca-cert ca/ca.crt \
  --ca-key ca/ca.key \
  --pem \
  --name elasticsearch-data-0 \
  --dns elasticsearch-data-0.elasticsearch-data-headless.default.svc.cluster.local \
  --dns elasticsearch-data-0 \
  --dns localhost \
  --out elasticsearch-data-0.zip

# Repeat for elasticsearch-data-1 and elasticsearch-tiebreaker-0
```

**Kubernetes Secrets**:
```bash
# Per-node secret
kubectl create secret generic elasticsearch-certs-data-0 \
  --from-file=tls.crt=elasticsearch-data-0/elasticsearch-data-0.crt \
  --from-file=tls.key=elasticsearch-data-0/elasticsearch-data-0.key \
  --from-file=ca.crt=ca/ca.crt

# Shared CA secret (for all nodes)
kubectl create secret generic elasticsearch-ca \
  --from-file=ca.crt=ca/ca.crt
```

**elasticsearch.yml Configuration**:
```yaml
xpack.security.transport.ssl:
  enabled: true
  verification_mode: certificate
  certificate: /usr/share/elasticsearch/config/certs/tls.crt
  key: /usr/share/elasticsearch/config/certs/tls.key
  certificate_authorities: /usr/share/elasticsearch/config/certs/ca.crt
```

**Rationale**:
- Shared CA simplifies trust (all nodes trust same CA)
- Per-node certs provide node identity verification
- PEM format easier to manage in K8s Secrets than PKCS#12
- DNS SANs include headless service names for pod-to-pod discovery

**Alternatives Considered**:
- Single shared certificate: Rejected - security risk, no node identity
- PKCS#12 keystores: Rejected - requires password management
- cert-manager: Adds complexity, manual is sufficient for 3 nodes

---

### 6. Kubernetes Deployment Pattern

**Decision**: Separate StatefulSets for data nodes and tiebreaker

**Architecture**:
```
┌─────────────────────────────────────────────────────────────┐
│                    elasticsearch-data                        │
│                    (StatefulSet, replicas=2)                │
│  ┌─────────────────────┐  ┌─────────────────────┐          │
│  │ elasticsearch-data-0│  │ elasticsearch-data-1│          │
│  │ (Hestia, amd64)     │  │ (Heracles, arm64)   │          │
│  │ master,data,ingest  │  │ master,data,ingest  │          │
│  │ PVC: 50GB local     │  │ PVC: 50GB local     │          │
│  └─────────────────────┘  └─────────────────────┘          │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                 elasticsearch-tiebreaker                     │
│                 (StatefulSet, replicas=1)                   │
│  ┌─────────────────────────────────────────────┐           │
│  │        elasticsearch-tiebreaker-0           │           │
│  │        (Nyx, arm64)                         │           │
│  │        master,voting_only                   │           │
│  │        No storage (ephemeral)               │           │
│  └─────────────────────────────────────────────┘           │
└─────────────────────────────────────────────────────────────┘
```

**Services**:
- `elasticsearch-data-headless` (ClusterIP: None) - For transport discovery
- `elasticsearch-tiebreaker-headless` (ClusterIP: None) - For transport discovery  
- `elasticsearch` (ClusterIP) - HTTP API load-balanced across data nodes
- `elasticsearch-nodeport` (NodePort) - For Elastic Agent connectivity

**Rationale**:
- Separate StatefulSets: different resource requirements, independent scaling
- StatefulSet provides stable pod names: `elasticsearch-data-0`, `elasticsearch-data-1`
- Headless services enable direct DNS resolution per pod
- Tiebreaker doesn't need volumeClaimTemplates (no storage)

**Alternatives Considered**:
| Approach | Pros | Cons | Decision |
|----------|------|------|----------|
| Single StatefulSet (3 replicas) | Simpler YAML | Can't differentiate resources | Rejected |
| Separate StatefulSets | Different resources per role | More YAML | **Chosen** |
| StatefulSet + Deployment | Tiebreaker in Deployment | Loses stable network identity | Rejected |

---

### 7. Node Affinity and Pod Placement

**Decision**: Explicit node affinity for deterministic placement

**Data Nodes Affinity**:
```hcl
affinity {
  node_affinity {
    required_during_scheduling_ignored_during_execution {
      node_selector_term {
        match_expressions {
          key      = "kubernetes.io/hostname"
          operator = "In"
          values   = ["hestia", "heracles"]
        }
      }
    }
  }
  
  pod_anti_affinity {
    required_during_scheduling_ignored_during_execution {
      label_selector {
        match_labels = { app = "elasticsearch", role = "data" }
      }
      topology_key = "kubernetes.io/hostname"
    }
  }
}
```

**Tiebreaker Affinity**:
```hcl
affinity {
  node_affinity {
    required_during_scheduling_ignored_during_execution {
      node_selector_term {
        match_expressions {
          key      = "kubernetes.io/hostname"
          operator = "In"
          values   = ["nyx"]
        }
      }
    }
  }
}
```

**Placement Result**:
| Pod | Node | Rationale |
|-----|------|-----------|
| elasticsearch-data-0 | Hestia (amd64, 16GB) | First data node, ML workloads |
| elasticsearch-data-1 | Heracles (arm64, 16GB) | Second data node |
| elasticsearch-tiebreaker-0 | Nyx (arm64, 8GB) | Minimal resource tiebreaker |

**Rationale**:
- Data nodes on 16GB RAM nodes (Hestia, Heracles) for adequate heap
- Tiebreaker on 8GB node (Nyx) - minimal footprint
- Pod anti-affinity ensures data nodes spread across different hosts
- Explicit affinity prevents accidental placement changes

---

## Assumptions and Risks

### Validated Assumptions

| Assumption | Validation |
|------------|------------|
| ES 9.2.3 supports `voting_only` role | Confirmed - introduced in ES 7.3, stable in 9.x |
| local-path StorageClass available | Confirmed - `kubectl get sc` shows `local-path (default)` |
| K3s nodes have sufficient disk for 50GB | Needs verification - check `/opt/local-path-provisioner` space |

### Open Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Tiebreaker 256Mi may be insufficient | Pod OOM | Use 512Mi minimum, monitor heap usage |
| Node failure strands local data | Data unavailable until node returns | ES replication provides redundancy |
| Certificate management overhead | Initial setup complexity | Document procedure, automate if needed |
| Initial master bootstrap timing | Cluster may not form | Remove `cluster.initial_master_nodes` after first boot |

---

## Migration Considerations

### Snapshot/Restore Approach (Recommended)

1. **Pre-migration snapshot**: Take full snapshot to MinIO
2. **Deploy new cluster**: 3 empty nodes with local storage
3. **Restore snapshot**: All indices restored with replication
4. **Verify**: Check document counts, Kibana connectivity
5. **Cleanup**: Remove old GlusterFS data after validation

### Estimated Downtime

- Snapshot: ~5 minutes (16GB data)
- Deploy new cluster: ~5 minutes
- Cluster formation: ~2 minutes
- Restore: ~10 minutes (16GB data)
- Verification: ~5 minutes
- **Total: ~30 minutes**

---

## References

- [Elasticsearch 8.x High Availability Cluster Design](https://www.elastic.co/guide/en/elasticsearch/reference/8.19/high-availability-cluster-design-large-clusters.html)
- [Rancher Local-Path Provisioner](https://github.com/rancher/local-path-provisioner)
- [Kubernetes StatefulSets](https://kubernetes.io/docs/tutorials/stateful-application/basic-stateful-set/)
- Current ELK module: `/home/ben/Documents/Personal/projects/iac/cluster-state/modules-k8s/elk/main.tf`
