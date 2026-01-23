# Quickstart: Nomad to Kubernetes Migration Runbook

**Phase**: 1 - Design  
**Date**: 2026-01-22

## Prerequisites

Before starting migration:

```bash
# 1. Verify K8s cluster is healthy
kubectl get nodes
# All nodes should be Ready

# 2. Verify core K8s components
kubectl get pods -n kube-system
kubectl get pods -n traefik
kubectl get pods -n external-secrets

# 3. Verify ClusterSecretStore works
kubectl get clustersecretstores
# vault-backend should be ready

# 4. Verify TLS secret exists
kubectl get secret -n traefik wildcard-brmartin-tls

# 5. Load Terraform environment
cd /path/to/cluster-state
set -a && source .env && set +a
```

---

## Migration Procedure (Per Service)

### Step 1: Pre-Migration Checks

```bash
# Check Nomad job status
nomad job status <service>

# Verify storage path exists
ls -la /storage/v/glusterfs_<service>_*

# Note the current image version from jobspec
grep "image" modules/<service>/jobspec.nomad.hcl
```

### Step 2: Stop Nomad Job

```bash
# Stop the Nomad job (frees resources, releases storage)
nomad job stop <service>

# Verify it's stopped
nomad job status <service>
# Should show "dead"
```

### Step 3: Create K8s Module (if not exists)

```bash
# Create module directory
mkdir -p modules-k8s/<service>

# Create files based on patterns in contracts/k8s-module-pattern.md
# - main.tf
# - variables.tf
# - versions.tf
# - outputs.tf
# - secrets.tf (if needed)
```

### Step 4: Copy TLS Secret (if needed)

```bash
# If deploying to a new namespace
kubectl get secret -n traefik wildcard-brmartin-tls -o yaml | \
  sed 's/namespace: traefik/namespace: <namespace>/' | kubectl apply -f -
```

### Step 5: Deploy to K8s

```bash
# Add module to kubernetes.tf
# module "k8s_<service>" {
#   count  = var.enable_k8s ? 1 : 0
#   source = "./modules-k8s/<service>"
#   ...
# }

# Initialize and apply
terraform init
terraform plan -target=module.k8s_<service> \
  -var="nomad_address=https://nomad.brmartin.co.uk:443" \
  -var="enable_k8s=true" \
  -out=tfplan

terraform apply tfplan
```

### Step 6: Verify K8s Deployment

```bash
# Check pod status
kubectl get pods -l app=<service>

# Check logs
kubectl logs -l app=<service> --tail=50

# Check service
kubectl get svc <service>

# Check ingress
kubectl get ingress <service>
```

### Step 7: Update External Traefik

```bash
# SSH to Hestia
/usr/bin/ssh 192.168.1.5

# Edit dynamic config
sudo vim /mnt/docker/traefik/traefik/dynamic_conf.yml

# Add router:
#     k8s-<service>:
#       rule: "Host(`<hostname>.brmartin.co.uk`)"
#       service: to-k8s-traefik
#       middlewares:           # if OAuth needed
#         - oauth-auth@docker
#       entryPoints:
#         - websecure

# Traefik auto-reloads, or force:
docker kill -s HUP traefik
```

### Step 8: Verify External Access

```bash
# Test from outside
curl -sI https://<hostname>.brmartin.co.uk

# Should get 200 OK (or OAuth redirect if protected)
```

### Step 9: Data Verification

Service-specific checks:

| Service | Verification |
|---------|-------------|
| vaultwarden | Log in, check passwords exist |
| overseerr | Check media requests |
| gitlab | Clone a repo, check issues |
| nextcloud | Browse files |
| minio | List buckets via mc |
| keycloak | Test SSO login |
| matrix | Check room history |

---

## Rollback Procedure

If K8s deployment fails:

```bash
# 1. Delete K8s workload
kubectl delete deployment/<service> --namespace=default
# or
kubectl delete statefulset/<service> --namespace=default

# 2. Remove from Terraform state (optional)
terraform state rm module.k8s_<service>

# 3. Restart Nomad job
nomad job run modules/<service>/jobspec.nomad.hcl

# 4. Verify Nomad job is running
nomad job status <service>

# 5. Remove K8s route from external Traefik
/usr/bin/ssh 192.168.1.5
sudo vim /mnt/docker/traefik/traefik/dynamic_conf.yml
# Remove the k8s-<service> router
```

---

## Phase-by-Phase Migration

### Phase 1: Stateless Services

```bash
# searxng
nomad job stop searxng
# Create modules-k8s/searxng/
terraform apply -target=module.k8s_searxng
# Update Traefik with oauth-auth middleware
curl https://searx.brmartin.co.uk  # Test

# nginx-sites  
nomad job stop nginx-sites
# Create modules-k8s/nginx-sites/
terraform apply -target=module.k8s_nginx_sites
# Update Traefik
curl https://brmartin.co.uk  # Test
curl https://martinilink.co.uk  # Test
```

### Phase 2: Litestream Services

```bash
# vaultwarden
nomad job stop vaultwarden
# Create modules-k8s/vaultwarden/ (with litestream sidecar)
terraform apply -target=module.k8s_vaultwarden
# Update Traefik
# Log in and verify passwords

# overseerr (replace PoC)
# First delete existing K8s overseerr PoC
terraform destroy -target=module.k8s_overseerr
nomad job stop overseerr
# Recreate modules-k8s/overseerr/ with production URL
terraform apply -target=module.k8s_overseerr
# Update Traefik (use overseerr.brmartin.co.uk, not overseerr-k8s)
```

### Phase 3: AI Stack

```bash
# ollama (GPU)
# Verify NVIDIA device plugin
kubectl get nodes -o json | jq '.items[].status.allocatable["nvidia.com/gpu"]'
# If null, install nvidia device plugin first

nomad job stop ollama
# Create modules-k8s/ollama/ with GPU resources
terraform apply -target=module.k8s_ollama
# No Traefik update (internal service)

# open-webui
nomad job stop open-webui
# Create modules-k8s/open-webui/ (with litestream)
terraform apply -target=module.k8s_open_webui
# Update Traefik
curl https://chat.brmartin.co.uk
```

### Phase 4: MinIO

**Critical**: This affects all litestream services

```bash
# Before stopping:
# Verify litestream backups are current for all services

nomad job stop minio
# Create modules-k8s/minio/
terraform apply -target=module.k8s_minio
# Update Traefik

# After migration:
# Update minio_endpoint in all K8s modules to use K8s service name:
# minio_endpoint = "http://minio.default.svc.cluster.local:9000"
```

### Phase 5-10: Complex Services

Follow same pattern. Order matters for dependencies:
- keycloak before services using SSO
- elk before services relying on logging
- gitlab last (most complex)

### Phase 11: Periodic Jobs

```bash
# renovate
# Create modules-k8s/renovate/ as CronJob
terraform apply -target=module.k8s_renovate
# No Traefik update (no external access)
# Wait for next scheduled run to verify

# restic-backup
# Create modules-k8s/restic-backup/ as CronJob
terraform apply -target=module.k8s_restic_backup
# Verify next backup completes successfully
```

---

## Post-Migration Cleanup

After all services migrated and verified:

```bash
# 1. Verify all K8s services healthy
kubectl get pods -A | grep -v kube-system | grep -v traefik

# 2. Verify Nomad only has expected jobs
nomad job status
# Should only show: media-centre, plugin-glusterfs-*, plugin-martinibar-*

# 3. Clean up old Nomad job definitions (optional)
# Keep modules/ for reference, or archive

# 4. Update AGENTS.md with K8s commands
# Update constitution if needed
```

---

## Troubleshooting

### Pod won't start

```bash
kubectl describe pod <pod-name>
kubectl logs <pod-name> --previous
```

### Storage permission denied

```bash
# Check GlusterFS mount
ls -la /storage/v/glusterfs_<service>_*

# Check pod's security context
# May need to add:
# securityContext:
#   fsGroup: 1000
#   runAsUser: 1000
```

### Litestream restore fails

```bash
# Check MinIO connectivity
kubectl run -it --rm debug --image=curlimages/curl -- \
  curl http://minio-minio.service.consul:9000/minio/health/live

# Check bucket exists
mc ls minio/<bucket>

# Manual restore
kubectl exec -it <pod> -c litestream -- \
  litestream restore -config /etc/litestream.yml /data/db.sqlite3
```

### External access not working

```bash
# Check K8s ingress
kubectl get ingress <service>

# Check K8s Traefik logs
kubectl logs -n traefik -l app.kubernetes.io/name=traefik --tail=50

# Check external Traefik logs
/usr/bin/ssh 192.168.1.5 "docker logs traefik 2>&1 | tail -50"

# Verify route exists
/usr/bin/ssh 192.168.1.5 "grep <service> /mnt/docker/traefik/traefik/dynamic_conf.yml"
```
