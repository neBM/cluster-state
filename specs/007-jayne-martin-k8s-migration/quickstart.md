# Quickstart: Jayne Martin Counselling K8s Migration

**Feature**: 007-jayne-martin-k8s-migration
**Date**: 2026-01-24

## Prerequisites

- Access to cluster nodes via SSH (192.168.1.5, 192.168.1.6, 192.168.1.7)
- Terraform configured with backend and providers
- KUBECONFIG set to `~/.kube/k3s-config`
- Environment variables loaded: `set -a && source .env && set +a`

## Quick Deploy

### 1. Create K8s Module

```bash
# Create module directory
mkdir -p modules-k8s/jayne-martin-counselling

# Files to create:
# - modules-k8s/jayne-martin-counselling/main.tf
# - modules-k8s/jayne-martin-counselling/variables.tf
# - modules-k8s/jayne-martin-counselling/versions.tf

# Add module to kubernetes.tf
```

### 2. Deploy to Kubernetes

```bash
# Load environment
set -a && source .env && set +a

# Plan (K8s module only first)
terraform plan -target='module.k8s_jayne_martin_counselling' \
  -var="nomad_address=https://nomad.brmartin.co.uk:443" -out=tfplan

# Apply
terraform apply tfplan

# Verify deployment
KUBECONFIG=~/.kube/k3s-config kubectl get pods -l app=jayne-martin-counselling
KUBECONFIG=~/.kube/k3s-config kubectl logs -l app=jayne-martin-counselling
```

### 3. Update External Traefik

```bash
# SSH to Hestia and edit config
/usr/bin/ssh 192.168.1.5 "sudo nano /mnt/docker/traefik/traefik/dynamic_conf.yml"

# Add under http.routers:
#   k8s-jmc:
#     rule: "Host(`www.jaynemartincounselling.co.uk`)"
#     service: to-k8s-traefik
#     entryPoints:
#       - websecure

# Traefik auto-reloads on file change
```

### 4. Verify Migration

```bash
# Test website
curl -I https://www.jaynemartincounselling.co.uk

# Check K8s pod health
KUBECONFIG=~/.kube/k3s-config kubectl get pods -l app=jayne-martin-counselling -o wide
```

### 5. Decommission Nomad Job

```bash
# Remove Nomad module from main.tf, then:
terraform plan -var="nomad_address=https://nomad.brmartin.co.uk:443" -out=tfplan
terraform apply tfplan

# Verify no Nomad jobs remain
nomad job status
```

### 6. Remove Nomad (Optional)

```bash
# On each node (Hestia, Heracles, Nyx):
/usr/bin/ssh 192.168.1.X "sudo systemctl stop nomad && sudo systemctl disable nomad"

# Verify
/usr/bin/ssh 192.168.1.5 "systemctl is-active nomad"  # Should show "inactive"

# Update documentation
# Edit AGENTS.md to remove Nomad references
```

## Rollback

If issues occur after Traefik cutover but before Nomad job removal:

```bash
# Revert Traefik config on Hestia
/usr/bin/ssh 192.168.1.5 "sudo nano /mnt/docker/traefik/traefik/dynamic_conf.yml"
# Remove or comment out k8s-jmc router

# Traffic automatically returns to Nomad via Consul Catalog
```

## Verification Commands

```bash
# K8s deployment status
KUBECONFIG=~/.kube/k3s-config kubectl get deployment jayne-martin-counselling -o wide

# Pod logs
KUBECONFIG=~/.kube/k3s-config kubectl logs -l app=jayne-martin-counselling --tail=50

# Health check
KUBECONFIG=~/.kube/k3s-config kubectl exec -it deploy/jayne-martin-counselling -- wget -qO- http://localhost/

# Ingress status
KUBECONFIG=~/.kube/k3s-config kubectl get ingress jayne-martin-counselling

# External Traefik logs (for routing issues)
/usr/bin/ssh 192.168.1.5 "docker logs traefik --tail=100 2>&1 | grep -i jmc"
```
