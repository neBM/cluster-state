# Quickstart: ELK Stack Migration to Kubernetes

**Feature**: 006-elk-k8s-migration  
**Date**: 2026-01-24  
**Estimated Duration**: 2-3 hours (mostly waiting for shard relocation)

---

## Prerequisites

Before starting the migration:

1. **Environment variables loaded**:
   ```bash
   set -a && source .env && set +a
   ```

2. **Verify cluster health is GREEN**:
   ```bash
   curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
     "https://es.brmartin.co.uk/_cluster/health?pretty"
   ```

3. **Verify all 3 nodes are present**:
   ```bash
   curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
     "https://es.brmartin.co.uk/_cat/nodes?v"
   ```

4. **Record baseline document count** (save this for verification):
   ```bash
   curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
     "https://es.brmartin.co.uk/_cat/count?v"
   # Expected: ~100-200 million docs (varies with log volume)
   ```

5. **Check disk space on Hestia** (target node):
   ```bash
   curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
     "https://es.brmartin.co.uk/_cat/allocation?v&h=node,disk.avail,disk.used,disk.percent"
   # Hestia should have >50GB available
   ```

6. **Check GlusterFS space**:
   ```bash
   /usr/bin/ssh 192.168.1.5 "df -h /storage/v/"
   # Should have >30GB available
   ```

---

## Phase 1: Reduce Cluster to Single Node

### Step 1.1: Set Replicas to Zero

Single-node cluster cannot maintain replicas. Set all indices to 0 replicas:

```bash
# Set existing indices to 0 replicas
curl -X PUT "https://es.brmartin.co.uk/_all/_settings" \
  -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  -H "Content-Type: application/json" -d '{
  "index": {
    "number_of_replicas": 0
  }
}'

# Update template for future indices
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

### Step 1.2: Exclude Nodes from Allocation

Trigger shard relocation to Hestia:

```bash
curl -X PUT "https://es.brmartin.co.uk/_cluster/settings" \
  -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  -H "Content-Type: application/json" -d '{
  "persistent": {
    "cluster.routing.allocation.exclude._name": "heracles,nyx"
  }
}'
```

### Step 1.3: Monitor Shard Relocation

Wait until all shards are on Hestia:

```bash
# Watch shard movement (Ctrl+C when complete)
watch -n 10 'curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cat/shards?v&h=index,shard,prirep,state,node" | \
  grep -v hestia | grep -v "^index"'

# When output is empty (all on hestia), check recovery status
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cat/recovery?v&active_only=true"
```

**Expected duration**: 15-45 minutes depending on data volume.

### Step 1.4: Verify Single-Node State

Before proceeding:

```bash
# All shards should be on hestia
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cat/shards?v" | awk '{print $NF}' | sort | uniq -c

# Cluster health should be green or yellow
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cluster/health?pretty"

# Document count should match baseline
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cat/count?v"
```

---

## Phase 2: Prepare Secrets and Storage

### Step 2.1: Migrate Kibana Secrets to Vault

Get existing secrets from Nomad and store in Vault:

```bash
# Read current Nomad variables (requires Nomad access)
nomad var get nomad/jobs/elk/kibana/kibana

# Create new Vault secret path
vault kv put secret/k8s/elk/kibana \
  kibana_username="kibana_system" \
  kibana_password="<password-from-nomad>" \
  kibana_encryptedSavedObjects_encryptionKey="<key-from-nomad>" \
  kibana_reporting_encryptionKey="<key-from-nomad>" \
  kibana_security_encryptionKey="<key-from-nomad>"
```

### Step 2.2: Create TLS Certificate Secrets

```bash
export KUBECONFIG=~/.kube/k3s-config

# Elasticsearch certificates
kubectl create secret generic elasticsearch-certs \
  --from-file=elastic-certificates.p12=/mnt/docker/elastic-hestia/config/certs/elastic-certificates.p12 \
  --from-file=http.p12=/mnt/docker/elastic-hestia/config/certs/http.p12 \
  -n default

# Kibana CA certificate
kubectl create secret generic kibana-certs \
  --from-file=elasticsearch-ca.pem=/mnt/docker/elastic/kibana/config/elasticsearch-ca.pem \
  -n default
```

### Step 2.3: Create GlusterFS Directory

```bash
/usr/bin/ssh 192.168.1.5 "sudo mkdir -p /storage/v/glusterfs_elasticsearch_data && \
  sudo chown 1000:1000 /storage/v/glusterfs_elasticsearch_data"
```

### Step 2.4: Prepare External Traefik Routes (Commented Out)

Add new routes to `/mnt/docker/traefik/traefik/dynamic_conf.yml` on Hestia, but keep them commented until migration is complete:

```bash
/usr/bin/ssh 192.168.1.5 "cat >> /mnt/docker/traefik/traefik/dynamic_conf.yml << 'EOF'

# ELK K8s Migration - uncomment after K8s deployment is ready
#    k8s-es:
#      rule: \"Host(\`es.brmartin.co.uk\`)\"
#      service: to-k8s-traefik
#      entryPoints:
#        - websecure
#    k8s-kibana:
#      rule: \"Host(\`kibana.brmartin.co.uk\`)\"
#      service: to-k8s-traefik
#      entryPoints:
#        - websecure
EOF"
```

**Note**: Currently ES/Kibana routes come from Consul catalog via Nomad job tags. These static routes will replace them after migration.

---

## Phase 3: Stop Nomad and Migrate Data

### Step 3.1: Stop Nomad ELK Job

```bash
nomad job stop elk
```

### Step 3.2: Copy Elasticsearch Data to GlusterFS

```bash
/usr/bin/ssh 192.168.1.5 "sudo rsync -av --progress \
  /var/lib/elasticsearch/ \
  /storage/v/glusterfs_elasticsearch_data/"

# Fix ownership
/usr/bin/ssh 192.168.1.5 "sudo chown -R 1000:1000 /storage/v/glusterfs_elasticsearch_data/"

# Verify data copied
/usr/bin/ssh 192.168.1.5 "sudo du -sh /storage/v/glusterfs_elasticsearch_data/"
```

---

## Phase 4: Deploy Kubernetes Resources

### Step 4.1: Apply Terraform

```bash
set -a && source .env && set +a

# Plan first
terraform plan -target='module.k8s_elk' \
  -var="nomad_address=https://nomad.brmartin.co.uk:443" \
  -out=tfplan

# Review and apply
terraform apply tfplan
```

### Step 4.2: Wait for Pods to Start

```bash
export KUBECONFIG=~/.kube/k3s-config

# Watch pod status
kubectl get pods -l app=elasticsearch -w

# Check ES logs for startup issues
kubectl logs -l app=elasticsearch -f
```

### Step 4.3: Activate External Traefik Routes

Uncomment the ES and Kibana routes in external Traefik config (Traefik auto-reloads):

```bash
/usr/bin/ssh 192.168.1.5 "sed -i 's/^#    k8s-es:/    k8s-es:/; s/^#      rule.*es\.brmartin/      rule: \"Host(\`es.brmartin/; s/^#      service: to-k8s-traefik/      service: to-k8s-traefik/; s/^#      entryPoints:/      entryPoints:/; s/^#        - websecure/        - websecure/' /mnt/docker/traefik/traefik/dynamic_conf.yml"

/usr/bin/ssh 192.168.1.5 "sed -i 's/^#    k8s-kibana:/    k8s-kibana:/; s/^#      rule.*kibana\.brmartin/      rule: \"Host(\`kibana.brmartin/; s/^#      service: to-k8s-traefik/      service: to-k8s-traefik/; s/^#      entryPoints:/      entryPoints:/; s/^#        - websecure/        - websecure/' /mnt/docker/traefik/traefik/dynamic_conf.yml"

# Verify routes are active
/usr/bin/ssh 192.168.1.5 "grep -A4 'k8s-es:\|k8s-kibana:' /mnt/docker/traefik/traefik/dynamic_conf.yml"
```

### Step 4.4: Verify Elasticsearch Health

```bash
# Wait for cluster to be ready
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cluster/health?pretty"

# Verify node count (should be 1)
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cat/nodes?v"

# Verify document count matches baseline
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cat/count?v"

# Check indices
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cat/indices?v&s=index"
```

### Step 4.5: Verify Kibana

```bash
# Check Kibana pod
kubectl get pods -l app=kibana

# Access Kibana UI
# Open https://kibana.brmartin.co.uk in browser
# Verify dashboards load correctly
```

### Step 4.6: Verify Log Ingestion

Wait 5 minutes, then check for new logs:

```bash
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/.ds-logs-docker.container_logs-*/_search" \
  -H "Content-Type: application/json" -d '{
  "size": 5,
  "query": {"range": {"@timestamp": {"gte": "now-5m"}}},
  "sort": [{"@timestamp": "desc"}]
}' | jq '.hits.hits[]._source | {time: .["@timestamp"], container: .container.name}'
```

---

## Phase 5: Cleanup

### Step 5.1: Remove Nomad Module from Terraform

After verifying K8s deployment is stable (wait at least 24 hours):

```bash
# Remove from Terraform state (does NOT delete data)
terraform state rm module.elk

# Delete Nomad module files
rm -rf modules/elk/
# Remove module declaration from main.tf
```

### Step 5.2: Archive Original Data (Optional)

Keep original data for 7 days before deletion:

```bash
# On Hestia - move to archive location
/usr/bin/ssh 192.168.1.5 "sudo mv /var/lib/elasticsearch /var/lib/elasticsearch.bak"

# After 7 days of stable operation
/usr/bin/ssh 192.168.1.5 "sudo rm -rf /var/lib/elasticsearch.bak"
```

---

## Rollback Procedure

### If Migration Fails During Phase 1 (Shard Relocation)

Re-enable all nodes:

```bash
curl -X PUT "https://es.brmartin.co.uk/_cluster/settings" \
  -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  -H "Content-Type: application/json" -d '{
  "persistent": {
    "cluster.routing.allocation.exclude._name": null
  }
}'

# Restore replicas
curl -X PUT "https://es.brmartin.co.uk/_all/_settings" \
  -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  -H "Content-Type: application/json" -d '{
  "index": {
    "number_of_replicas": 1
  }
}'
```

### If Migration Fails During Phase 3 (Data Copy)

Restart Nomad job:

```bash
set -a && source .env && set +a
terraform apply -target=module.elk -var="nomad_address=https://nomad.brmartin.co.uk:443"
```

### If Migration Fails During Phase 4 (K8s Deployment)

1. Revert external Traefik routes (re-comment or remove k8s-es/k8s-kibana):

```bash
/usr/bin/ssh 192.168.1.5 "sed -i 's/^    k8s-es:/#    k8s-es:/; s/^      rule.*es\.brmartin/#      rule: \"Host(\`es.brmartin/; s/^      service: to-k8s-traefik/#      service: to-k8s-traefik/; s/^      entryPoints:/#      entryPoints:/; s/^        - websecure/#        - websecure/' /mnt/docker/traefik/traefik/dynamic_conf.yml"
```

2. Keep K8s resources for debugging

3. Restart Nomad job from original data:

```bash
# ES data is still at /var/lib/elasticsearch
set -a && source .env && set +a
terraform apply -target=module.elk -var="nomad_address=https://nomad.brmartin.co.uk:443"
```

4. Delete failed K8s resources:

```bash
export KUBECONFIG=~/.kube/k3s-config
kubectl delete statefulset elasticsearch
kubectl delete deployment kibana
kubectl delete secret elasticsearch-certs kibana-certs
```

---

## Troubleshooting

### Elasticsearch Won't Start

**Check init container**:
```bash
kubectl logs elasticsearch-0 -c sysctl
```

**Check ES container logs**:
```bash
kubectl logs elasticsearch-0
```

**Common issues**:
- `max virtual memory areas vm.max_map_count [65530] is too low`: Init container failed
- `java.nio.file.AccessDeniedException`: Ownership issue on data directory

### Kibana Can't Connect to Elasticsearch

**Check connectivity**:
```bash
kubectl exec -it $(kubectl get pod -l app=kibana -o name) -- \
  curl -k https://elasticsearch:9200
```

**Check credentials**:
```bash
kubectl get secret kibana-credentials -o jsonpath='{.data.ELASTICSEARCH_USERNAME}' | base64 -d
```

### Shards Stuck RELOCATING

**Check recovery progress**:
```bash
curl -s -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  "https://es.brmartin.co.uk/_cat/recovery?v&active_only=true"
```

**Increase recovery speed temporarily**:
```bash
curl -X PUT "https://es.brmartin.co.uk/_cluster/settings" \
  -H "Authorization: ApiKey $ELASTIC_API_KEY" \
  -H "Content-Type: application/json" -d '{
  "transient": {
    "indices.recovery.max_bytes_per_sec": "100mb"
  }
}'
```

### Pod Evicted or OOMKilled

**Check resource usage**:
```bash
kubectl top pod elasticsearch-0
kubectl describe pod elasticsearch-0 | grep -A5 "Last State"
```

**Increase memory limits** in Terraform and reapply.

---

## Verification Checklist

| Check | Command | Expected Result |
|-------|---------|-----------------|
| ES Health | `curl .../\_cluster/health` | `status: green` or `yellow` |
| Node Count | `curl .../\_cat/nodes` | 1 node (`elk-node`) |
| Doc Count | `curl .../\_cat/count` | Matches pre-migration |
| Kibana UI | Browser | Dashboards load |
| Log Ingestion | Check for recent logs | New logs within 5 min |
| External URL (ES) | `curl https://es.brmartin.co.uk` | 200 OK |
| External URL (Kibana) | `curl https://kibana.brmartin.co.uk` | 200 OK |
