# Quickstart: GitLab Multi-Container Migration

**Feature**: 008-gitlab-multi-container
**Date**: 2026-01-24

## Prerequisites

- [ ] Access to Hestia node (SSH)
- [ ] kubectl configured for K3s cluster
- [ ] Terraform CLI available
- [ ] Maintenance window scheduled (target: 2 hours)

## Pre-Migration Checklist

- [ ] Verify current GitLab is healthy: `https://git.brmartin.co.uk/-/readiness`
- [ ] Note current GitLab version: `gitlab/gitlab-ce:18.8.2-ce.0`
- [ ] Backup PostgreSQL database (external, already backed up separately)
- [ ] Document existing runner configurations
- [ ] Notify users of maintenance window

---

## Phase 1: Extract Secrets (Pre-Downtime)

```bash
# SSH to Hestia
/usr/bin/ssh 192.168.1.5

# Extract secrets from running Omnibus container
kubectl exec -it $(kubectl get pod -l app=gitlab -o jsonpath='{.items[0].metadata.name}') -- \
  cat /etc/gitlab/gitlab-secrets.json > /tmp/gitlab-secrets.json

# Extract key values
cat /tmp/gitlab-secrets.json | jq -r '.gitlab_rails.db_key_base'
cat /tmp/gitlab-secrets.json | jq -r '.gitlab_rails.secret_key_base'
cat /tmp/gitlab-secrets.json | jq -r '.gitlab_rails.otp_key_base'
cat /tmp/gitlab-secrets.json | jq -r '.gitlab_rails.openid_connect_signing_key'

# Generate new tokens (or extract existing)
# Workhorse secret (32-byte hex)
openssl rand -hex 32 > /tmp/workhorse-secret

# Gitaly token
openssl rand -base64 32 > /tmp/gitaly-token

# Shell secret
openssl rand -base64 32 > /tmp/shell-secret
```

---

## Phase 2: Stop Omnibus GitLab (Downtime Begins)

```bash
# Scale down current GitLab deployment
kubectl scale deployment gitlab --replicas=0

# Verify it's stopped
kubectl get pods -l app=gitlab

# Record start time
echo "Downtime started: $(date)"
```

---

## Phase 3: Prepare PVC Data

```bash
# SSH to Hestia
/usr/bin/ssh 192.168.1.5

# Create new PVC directories (provisioner will create on PVC creation, but we need to copy data)
# The NFS provisioner creates directories at /storage/v/glusterfs_<volume-name>

# Verify source data locations
ls -la /storage/v/glusterfs_gitlab_data/git-data/repositories/
ls -la /storage/v/glusterfs_gitlab_data/gitlab-rails/uploads/
ls -la /storage/v/glusterfs_gitlab_data/gitlab-rails/shared/
```

---

## Phase 4: Apply Terraform

```bash
# From cluster-state repo root
cd /home/ben/Documents/Personal/projects/iac/cluster-state

# Load environment
set -a && source .env && set +a

# Plan changes (targeting gitlab module)
terraform plan -target='module.k8s_gitlab' \
  -var="nomad_address=https://nomad.brmartin.co.uk:443" \
  -out=tfplan

# Review plan carefully!
# Should show:
# - Old single deployment being replaced
# - New deployments for each component
# - New services
# - New PVCs
# - New secrets/configmaps

# Apply
terraform apply tfplan
```

---

## Phase 5: Data Migration

```bash
# SSH to Hestia
/usr/bin/ssh 192.168.1.5

# Copy repository data to new PVC location
# (Adjust paths based on actual PVC mount points)
sudo rsync -av --progress \
  /storage/v/glusterfs_gitlab_data/git-data/repositories/ \
  /storage/v/glusterfs_gitlab_repositories/

# Copy uploads
sudo rsync -av --progress \
  /storage/v/glusterfs_gitlab_data/gitlab-rails/uploads/ \
  /storage/v/glusterfs_gitlab_uploads/

# Copy shared data (LFS, artifacts, etc.)
sudo rsync -av --progress \
  /storage/v/glusterfs_gitlab_data/gitlab-rails/shared/ \
  /storage/v/glusterfs_gitlab_shared/

# Copy registry data
sudo rsync -av --progress \
  /storage/v/glusterfs_gitlab_data/gitlab-rails/shared/registry/ \
  /storage/v/glusterfs_gitlab_registry/

# Fix permissions (CNG runs as git user, UID 1000)
sudo chown -R 1000:1000 /storage/v/glusterfs_gitlab_repositories/
sudo chown -R 1000:1000 /storage/v/glusterfs_gitlab_uploads/
sudo chown -R 1000:1000 /storage/v/glusterfs_gitlab_shared/
sudo chown -R 1000:1000 /storage/v/glusterfs_gitlab_registry/
```

---

## Phase 6: Verify Deployment

```bash
# Check all pods are running
kubectl get pods -l app=gitlab

# Expected output:
# gitlab-webservice-xxx    1/1     Running
# gitlab-workhorse-xxx     1/1     Running
# gitlab-sidekiq-xxx       1/1     Running
# gitlab-gitaly-xxx        1/1     Running
# gitlab-redis-xxx         1/1     Running
# gitlab-registry-xxx      1/1     Running

# Check pod logs for errors
kubectl logs -l app=gitlab,component=webservice --tail=50
kubectl logs -l app=gitlab,component=gitaly --tail=50

# Check services
kubectl get svc -l app=gitlab
```

---

## Phase 7: Functional Verification

### Web UI
- [ ] Access `https://git.brmartin.co.uk`
- [ ] Login with existing credentials
- [ ] Navigate to a project
- [ ] View repository files

### Git Operations
```bash
# Clone a test repo
git clone https://git.brmartin.co.uk/<user>/<project>.git /tmp/test-clone
cd /tmp/test-clone

# Make a change
echo "Migration test $(date)" >> README.md
git add . && git commit -m "Test post-migration commit"

# Push (uses existing credentials)
git push
```

### CI/CD
- [ ] Trigger a pipeline on a test project
- [ ] Verify runner picks up the job
- [ ] Check job completes successfully

### Container Registry
```bash
# Login to registry
docker login registry.brmartin.co.uk

# Pull existing image
docker pull registry.brmartin.co.uk/<project>/<image>:latest

# Push test image
docker tag alpine:latest registry.brmartin.co.uk/<user>/test:migration
docker push registry.brmartin.co.uk/<user>/test:migration
```

### Access Tokens
- [ ] Test existing personal access token via API:
```bash
curl -H "PRIVATE-TOKEN: <token>" https://git.brmartin.co.uk/api/v4/user
```

---

## Phase 8: Completion

```bash
# Record end time
echo "Downtime ended: $(date)"

# Notify users that maintenance is complete
```

---

## Rollback Procedure

If migration fails:

```bash
# 1. Stop new deployment
kubectl scale deployment -l app=gitlab --replicas=0

# 2. Restore old deployment
terraform apply -target='module.k8s_gitlab' \
  -var="nomad_address=https://nomad.brmartin.co.uk:443" \
  # Use previous terraform state or revert main.tf changes

# 3. Scale up old deployment
kubectl scale deployment gitlab --replicas=1

# 4. Verify old GitLab is working
curl -s https://git.brmartin.co.uk/-/readiness
```

---

## Troubleshooting

### Webservice won't start
```bash
# Check logs
kubectl logs -l app=gitlab,component=webservice -f

# Common issues:
# - Database connection: Check PostgreSQL is accessible
# - Secrets missing: Verify gitlab-rails-secret exists
# - Config error: Check configmap template syntax
```

### Gitaly won't start
```bash
kubectl logs -l app=gitlab,component=gitaly -f

# Common issues:
# - Repository path not writable
# - Auth token mismatch
# - Shell secret missing
```

### Registry authentication fails
```bash
kubectl logs -l app=gitlab,component=registry -f

# Common issues:
# - JWT signing key mismatch
# - Certificate issues
# - Webservice not reachable for auth callback
```

### Git push/pull fails
```bash
# Check Workhorse logs
kubectl logs -l app=gitlab,component=workhorse -f

# Check Gitaly connectivity
kubectl exec -it <webservice-pod> -- curl -v http://gitlab-gitaly:8075
```
