# Research: ELK Stack Migration to Kubernetes Single-Node

**Feature**: 006-elk-k8s-migration  
**Date**: 2026-01-24  
**Status**: Complete

## Executive Summary

This research covers the safe migration of a 3-node Elasticsearch cluster to a single-node K8s deployment. Key findings:

1. **Node removal is safe** using Elasticsearch's built-in shard relocation APIs
2. **Single-node mode** requires `discovery.type: single-node` configuration
3. **StatefulSet** is recommended for K8s deployment with hostPath to GlusterFS
4. **Zero downtime** achievable with rolling shard relocation before shutdown

---

## 1. Elasticsearch Node Removal Procedure

### Decision: Use In-Place Shard Relocation

**Rationale**: The cluster contains ~23GB of data. Relocating shards to the remaining node is faster and safer than snapshot/restore. Shards are moved while the cluster is online, minimizing downtime.

**Alternatives Considered**:
- **Snapshot & Restore**: More complex, requires snapshot repository setup, longer downtime
- **Data copy & fresh cluster**: Risky, requires stopping all nodes, potential data loss window

### Step-by-Step Procedure

#### Pre-Flight Checks
```bash
# 1. Verify cluster health (must be green)
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cluster/health?pretty"

# 2. Get document counts for verification
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cat/count?v"

# 3. Check disk space on target node (Hestia - has most storage)
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cat/allocation?v&h=node,disk.avail,disk.used,disk.percent"
```

#### Phase 1: Set Replicas to Zero
```bash
# Single node cannot have replicas - set to 0 for all indices
curl -X PUT "https://es.brmartin.co.uk/_all/_settings" \
  -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  -H "Content-Type: application/json" -d '{
  "index": {
    "number_of_replicas": 0
  }
}'

# Update index templates for future indices
curl -X PUT "https://es.brmartin.co.uk/_index_template/single-node-template" \
  -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  -H "Content-Type: application/json" -d '{
  "index_patterns": ["*"],
  "template": {
    "settings": {
      "number_of_replicas": 0
    }
  },
  "priority": 100
}'
```

#### Phase 2: Exclude Nodes from Allocation
```bash
# Exclude Heracles and Nyx from shard allocation
# This triggers shards to relocate to Hestia
curl -X PUT "https://es.brmartin.co.uk/_cluster/settings" \
  -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  -H "Content-Type: application/json" -d '{
  "persistent": {
    "cluster.routing.allocation.exclude._name": "heracles,nyx"
  }
}'
```

#### Phase 3: Monitor Shard Relocation
```bash
# Watch shard movement (run until no RELOCATING shards)
watch -n 5 'curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cat/shards?v&h=index,shard,prirep,state,node" | \
  grep -E "RELOCATING|INITIALIZING|hestia"'

# Check recovery progress
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cat/recovery?v&active_only=true"
```

**Wait until**:
- All shards show state `STARTED`
- All shards are on `hestia`
- No `RELOCATING` or `INITIALIZING` shards

#### Phase 4: Verify and Shutdown
```bash
# Verify all shards on Hestia
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cat/shards?v" | awk '{print $NF}' | sort | uniq -c

# Verify document counts match pre-migration
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cat/count?v"

# Stop Nomad ELK job (will stop all 3 nodes)
nomad job stop elk
```

---

## 2. Single-Node Configuration

### Decision: Use `discovery.type: single-node`

**Rationale**: This is the official Elasticsearch setting for single-node clusters. It:
- Disables multi-node bootstrap checks
- Sets the node as the sole master
- Prevents accidental cluster formation with other nodes

**Configuration Changes**:
```yaml
# elasticsearch.yml for K8s deployment
cluster.name: "docker-cluster"  # Keep same cluster name
node.name: "elk-node"

# CRITICAL: Single-node discovery
discovery.type: single-node

# Remove multi-node discovery settings (were in Nomad config):
# discovery.seed_hosts: []        # REMOVE
# cluster.initial_master_nodes: [] # REMOVE

# Network settings
network.host: 0.0.0.0
http.port: 9200

# Path settings (updated for GlusterFS)
path.data: /usr/share/elasticsearch/data
```

---

## 3. Kubernetes Deployment Pattern

### Decision: Use StatefulSet with hostPath

**Rationale**: 
- StatefulSet provides stable pod identity and storage
- hostPath to GlusterFS allows pod to run on any node
- Matches pattern used by other services in this cluster

**Alternatives Considered**:
- **Deployment**: Lacks stable storage guarantees, not recommended for stateful apps
- **PVC with dynamic provisioning**: Adds complexity, hostPath works well with existing NFS-Ganesha setup

### StatefulSet Configuration

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: elasticsearch
spec:
  serviceName: elasticsearch
  replicas: 1
  selector:
    matchLabels:
      app: elasticsearch
  template:
    spec:
      initContainers:
        - name: sysctl
          image: busybox
          securityContext:
            privileged: true
          command: ["sh", "-c", "sysctl -w vm.max_map_count=262144"]
      containers:
        - name: elasticsearch
          image: docker.elastic.co/elasticsearch/elasticsearch:9.2.3
          env:
            - name: discovery.type
              value: single-node
            - name: ES_JAVA_OPTS
              value: "-Xms2g -Xmx2g"
            - name: xpack.security.enabled
              value: "true"
          resources:
            requests:
              memory: "4Gi"
              cpu: "1000m"
            limits:
              memory: "4Gi"
              cpu: "2000m"
          volumeMounts:
            - name: data
              mountPath: /usr/share/elasticsearch/data
            - name: certs
              mountPath: /usr/share/elasticsearch/config/certs
              readOnly: true
          readinessProbe:
            httpGet:
              path: /_cluster/health?wait_for_status=yellow&timeout=1s
              port: 9200
              scheme: HTTPS
            initialDelaySeconds: 30
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /_cluster/health
              port: 9200
              scheme: HTTPS
            initialDelaySeconds: 90
            periodSeconds: 20
      volumes:
        - name: data
          hostPath:
            path: /storage/v/glusterfs_elasticsearch_data
            type: DirectoryOrCreate
        - name: certs
          secret:
            secretName: elasticsearch-certs
```

### Resource Sizing

| Resource | Request | Limit | Rationale |
|----------|---------|-------|-----------|
| Memory | 4Gi | 4Gi | Equal for QoS Guaranteed; 2GB heap + 2GB Lucene cache |
| CPU | 1000m | 2000m | Baseline + burst for indexing spikes |

### Health Checks

| Probe | Endpoint | Delay | Period | Rationale |
|-------|----------|-------|--------|-----------|
| Readiness | `/_cluster/health?wait_for_status=yellow` | 30s | 10s | Yellow is healthy for single-node |
| Liveness | `/_cluster/health` | 90s | 20s | Allow time for JVM startup and index recovery |

---

## 4. TLS Certificate Migration

### Decision: Migrate Existing Certs to K8s Secrets

**Rationale**: Existing certificates are already trusted by Kibana and Filebeat. Reusing them avoids reconfiguration of clients.

**Certificate Files to Migrate**:
```
/mnt/docker/elastic-hestia/config/certs/
├── elastic-certificates.p12   # Transport layer (node-to-node)
├── http.p12                   # HTTP layer (client access)
└── elasticsearch-ca.pem       # CA certificate
```

**K8s Secret Structure**:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: elasticsearch-certs
type: Opaque
data:
  elastic-certificates.p12: <base64>
  http.p12: <base64>
  elasticsearch-ca.pem: <base64>
```

**ES Configuration**:
```yaml
xpack.security.transport.ssl:
  enabled: true
  verification_mode: certificate
  keystore.path: /usr/share/elasticsearch/config/certs/elastic-certificates.p12
  truststore.path: /usr/share/elasticsearch/config/certs/elastic-certificates.p12
xpack.security.http.ssl:
  enabled: true
  keystore.path: /usr/share/elasticsearch/config/certs/http.p12
```

---

## 5. Data Migration to GlusterFS

### Decision: Copy Data After Cluster Reduction

**Rationale**: 
1. Reduce cluster to single node first (shards on Hestia)
2. Stop ES
3. Copy data from `/var/lib/elasticsearch` to `/storage/v/glusterfs_elasticsearch_data`
4. Start K8s deployment pointing to new path

**Migration Steps**:
```bash
# 1. After cluster is reduced to single node on Hestia
nomad job stop elk

# 2. Copy data to GlusterFS (on Hestia)
rsync -av --progress /var/lib/elasticsearch/ /storage/v/glusterfs_elasticsearch_data/

# 3. Set correct ownership (ES runs as uid 1000)
chown -R 1000:1000 /storage/v/glusterfs_elasticsearch_data/

# 4. Deploy K8s StatefulSet
terraform apply -target=module.k8s_elk
```

### Verification
```bash
# Compare sizes
du -sh /var/lib/elasticsearch
du -sh /storage/v/glusterfs_elasticsearch_data

# After ES starts, verify indices
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cat/indices?v"
```

---

## 6. Kibana Deployment

### Decision: Single Deployment with External Secrets

**Configuration**:
- Single Kibana instance (was 2 on Nomad)
- Secrets via External Secrets Operator from Vault
- Connect to single ES node

**Kibana Configuration**:
```yaml
elasticsearch:
  hosts: ["https://elasticsearch:9200"]
  username: ${ELASTICSEARCH_USERNAME}
  password: ${ELASTICSEARCH_PASSWORD}
  ssl:
    verificationMode: certificate
    certificateAuthorities: ["/usr/share/kibana/config/certs/elasticsearch-ca.pem"]
server:
  host: "0.0.0.0"
  publicBaseUrl: "https://kibana.brmartin.co.uk"
xpack:
  encryptedSavedObjects:
    encryptionKey: ${XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY}
  reporting:
    encryptionKey: ${XPACK_REPORTING_ENCRYPTIONKEY}
  security:
    encryptionKey: ${XPACK_SECURITY_ENCRYPTIONKEY}
```

---

## 7. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Data loss during shard relocation | Low | High | Verify counts before/after, keep original data until verified |
| Insufficient disk space on target node | Low | High | Check allocation before starting |
| GlusterFS I/O bottleneck | Medium | Medium | Monitor latency, can migrate to local SSD if needed |
| Filebeat connection issues | Low | Medium | Filebeat connects to hostname, not node IPs |
| TLS certificate issues | Low | Medium | Test connectivity before cutting over |

---

## 8. Rollback Plan

If migration fails at any point:

1. **Before Nomad job stopped**: Re-enable allocation to all nodes
   ```bash
   curl -X PUT "https://es.brmartin.co.uk/_cluster/settings" \
     -H "Content-Type: application/json" -d '{
     "persistent": {
       "cluster.routing.allocation.exclude._name": null
     }
   }'
   ```

2. **After Nomad job stopped**: Restart Nomad ELK job
   ```bash
   cd /path/to/cluster-state
   terraform apply -target=module.elk
   ```

3. **After K8s deployment fails**: Keep original data at `/var/lib/elasticsearch`, redeploy Nomad job

---

## Appendix: Commands Quick Reference

### Pre-Migration Verification
```bash
# Cluster health
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" "https://es.brmartin.co.uk/_cluster/health?pretty"

# Document count (save for comparison)
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" "https://es.brmartin.co.uk/_cat/count?v"

# Disk allocation
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" "https://es.brmartin.co.uk/_cat/allocation?v"
```

### Migration Execution
```bash
# Set replicas to 0
curl -X PUT "https://es.brmartin.co.uk/_all/_settings" -H "Content-Type: application/json" \
  -H "Authorization: ApiKey $ELASTIC_API_KEY" -d '{"index":{"number_of_replicas":0}}'

# Exclude nodes
curl -X PUT "https://es.brmartin.co.uk/_cluster/settings" -H "Content-Type: application/json" \
  -H "Authorization: ApiKey $ELASTIC_API_KEY" -d '{"persistent":{"cluster.routing.allocation.exclude._name":"heracles,nyx"}}'

# Monitor relocation
watch -n 5 'curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" "https://es.brmartin.co.uk/_cat/shards?v" | grep -v hestia'
```

### Post-Migration Verification
```bash
# Cluster health (should be green with replicas=0)
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" "https://es.brmartin.co.uk/_cluster/health?pretty"

# Verify single node
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" "https://es.brmartin.co.uk/_cat/nodes?v"

# Verify document count matches pre-migration
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" "https://es.brmartin.co.uk/_cat/count?v"
```
