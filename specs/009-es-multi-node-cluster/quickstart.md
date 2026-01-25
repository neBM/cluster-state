# Quickstart: Elasticsearch Multi-Node Cluster Migration

**Estimated Time**: 30-45 minutes  
**Downtime**: ~15-20 minutes (snapshot/restore phase)  
**Risk Level**: Medium (data migration involved)

## Prerequisites

- [ ] Terraform environment loaded: `set -a && source .env && set +a`
- [ ] kubectl configured: `export KUBECONFIG=~/.kube/k3s-config`
- [ ] Access to MinIO for snapshots
- [ ] Sufficient local storage on Hestia and Heracles (50GB each)
- [ ] Current ES cluster healthy

## Pre-Migration Checklist

### 1. Verify Current Cluster Health
```bash
curl -sk -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cluster/health?pretty"
# Must be: "status": "yellow" or "green"
```

### 2. Record Document Counts
```bash
curl -sk -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cat/indices?v&s=index" > /tmp/pre-migration-indices.txt
cat /tmp/pre-migration-indices.txt
```

### 3. Verify Snapshot Repository
```bash
curl -sk -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_snapshot/minio_backup?pretty"
# Should show existing repository
```

### 4. Check Local Storage Availability
```bash
# On Hestia
/usr/bin/ssh 192.168.1.5 "df -h /opt/local-path-provisioner"

# On Heracles
/usr/bin/ssh 192.168.1.6 "df -h /opt/local-path-provisioner"
# Need 50GB+ free on each
```

---

## Migration Steps

### Phase 1: Snapshot Current Data (~5 min)

```bash
# Create snapshot
curl -sk -X PUT -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  -H "Content-Type: application/json" \
  "https://es.brmartin.co.uk/_snapshot/minio_backup/pre-multinode-migration" \
  -d '{
    "indices": "*",
    "ignore_unavailable": true,
    "include_global_state": true
  }'

# Monitor snapshot progress
watch -n 5 'curl -sk -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_snapshot/minio_backup/pre-multinode-migration/_status" | jq ".snapshots[0].state"'
# Wait for: "SUCCESS"
```

### Phase 2: Generate TLS Certificates (~5 min)

```bash
# Run on a node with elasticsearch-certutil available
# Or use the existing certificates if they support multiple SANs

# Option A: Reuse existing certificates (if they have wildcard or multiple SANs)
# Skip this phase

# Option B: Generate new per-node certificates
# See research.md Section 5 for detailed steps
```

### Phase 3: Apply Terraform Changes (~5 min)

```bash
# Plan changes
terraform plan \
  -target='module.k8s_elk' \
  -var="nomad_address=https://nomad.brmartin.co.uk:443" \
  -out=tfplan

# Review the plan carefully
# Expected changes:
# - StorageClass: local-path-retain (create)
# - StatefulSet: elasticsearch (destroy)
# - StatefulSet: elasticsearch-data (create)
# - StatefulSet: elasticsearch-tiebreaker (create)
# - Services: modified selectors
# - ConfigMaps: new data/tiebreaker configs

# Apply changes
terraform apply tfplan
```

### Phase 4: Wait for Cluster Formation (~5 min)

```bash
# Watch pod status
watch -n 2 'kubectl get pods -l app=elasticsearch -o wide'

# Expected pods:
# elasticsearch-data-0       Running  (Hestia)
# elasticsearch-data-1       Running  (Heracles)
# elasticsearch-tiebreaker-0 Running  (Nyx)

# Check cluster health
watch -n 5 'curl -sk -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cluster/health" | jq "{status, number_of_nodes, number_of_data_nodes}"'

# Wait for:
# - number_of_nodes: 3
# - number_of_data_nodes: 2
# - status: "green" (may start as "yellow" until shards allocate)
```

### Phase 5: Restore Snapshot (~10 min)

```bash
# Close all indices first (required for restore)
curl -sk -X POST -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_all/_close"

# Restore from snapshot
curl -sk -X POST -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  -H "Content-Type: application/json" \
  "https://es.brmartin.co.uk/_snapshot/minio_backup/pre-multinode-migration/_restore" \
  -d '{
    "indices": "*",
    "ignore_unavailable": true,
    "include_global_state": true,
    "index_settings": {
      "index.number_of_replicas": 1
    }
  }'

# Monitor restore progress
watch -n 5 'curl -sk -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cat/recovery?active_only=true&v"'

# Wait for recovery to complete (empty output = done)
```

### Phase 6: Verify Migration (~5 min)

```bash
# Compare document counts
curl -sk -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cat/indices?v&s=index" > /tmp/post-migration-indices.txt

diff /tmp/pre-migration-indices.txt /tmp/post-migration-indices.txt
# Should show no differences in doc counts

# Check shard allocation
curl -sk -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cat/shards?v" | head -20
# Should show shards distributed across elasticsearch-data-0 and elasticsearch-data-1

# Check Kibana connectivity
curl -sk "https://kibana.brmartin.co.uk/api/status" | jq '.status.overall.level'
# Expected: "available"
```

---

## Post-Migration Tasks

### 1. Remove Initial Master Nodes Setting

After cluster has successfully formed and is stable (1+ hours), update ConfigMaps to remove `cluster.initial_master_nodes` setting. This prevents issues on future restarts.

```bash
# Edit ConfigMap
kubectl edit configmap elasticsearch-data-config
# Remove the cluster.initial_master_nodes lines

kubectl edit configmap elasticsearch-tiebreaker-config
# Remove the cluster.initial_master_nodes lines

# Rolling restart to apply
kubectl rollout restart statefulset/elasticsearch-data
kubectl rollout restart statefulset/elasticsearch-tiebreaker
```

### 2. Verify Elastic Agent Connectivity

```bash
# Check Fleet Server can reach ES
curl -sk -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cat/nodes?v"

# Verify new logs are arriving
curl -sk -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/.ds-logs-docker.container_logs-*/_search?size=1&sort=@timestamp:desc" \
  | jq '.hits.hits[0]._source["@timestamp"]'
# Should be recent timestamp
```

### 3. Clean Up Old GlusterFS Data (After 1 Week Validation)

```bash
# Only after confirming migration success
/usr/bin/ssh 192.168.1.5 "sudo rm -rf /storage/v/glusterfs_elasticsearch_data.bak"
```

---

## Rollback Procedure

If migration fails:

### Quick Rollback (Data Loss Possible)

```bash
# Revert Terraform
git checkout HEAD~1 -- modules-k8s/elk/main.tf
terraform apply -target='module.k8s_elk' -var="nomad_address=https://nomad.brmartin.co.uk:443"

# Restore from snapshot to single-node
curl -sk -X POST -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_snapshot/minio_backup/pre-multinode-migration/_restore"
```

### Safe Rollback (Preserve Data)

```bash
# Take snapshot of current state first
curl -sk -X PUT -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_snapshot/minio_backup/failed-migration-backup"

# Then proceed with quick rollback
```

---

## Troubleshooting

### Pods Not Starting

```bash
# Check events
kubectl describe pod elasticsearch-data-0

# Common issues:
# - PVC pending: Check StorageClass exists
# - Image pull: Check node can pull ES image
# - Init container failed: Check vm.max_map_count setting
```

### Cluster Not Forming

```bash
# Check discovery
kubectl logs elasticsearch-data-0 | grep -i discovery

# Verify headless services
kubectl get endpoints elasticsearch-data-headless
kubectl get endpoints elasticsearch-tiebreaker-headless

# Check transport connectivity
kubectl exec elasticsearch-data-0 -- curl -s elasticsearch-data-1:9300
```

### Shard Allocation Issues

```bash
# Check allocation explanation
curl -sk -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cluster/allocation/explain?pretty"

# Force retry allocation
curl -sk -X POST -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cluster/reroute?retry_failed=true"
```

### High Flush Queue (Performance Issue)

```bash
# If flush queue is still high after migration:
# 1. Check disk I/O
kubectl exec elasticsearch-data-0 -- iostat -x 1 5

# 2. Verify local storage (not NFS)
kubectl exec elasticsearch-data-0 -- mount | grep elasticsearch

# 3. Consider reducing indexing rate or increasing resources
```
