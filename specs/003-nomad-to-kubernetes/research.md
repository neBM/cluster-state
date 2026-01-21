# Research: Nomad to Kubernetes Migration (PoC)

**Date**: 2026-01-21
**Status**: Complete

## Research Topics

1. K3s Installation Strategy
2. Storage Solution
3. Service Mesh Selection
4. Ingress Strategy
5. Vault Integration
6. Terraform Kubernetes Provider

---

## 1. K3s Installation Strategy

### Decision: Install K3s with embedded etcd HA alongside Nomad

### Rationale

K3s can be installed on existing nodes without disrupting other services. The installation uses systemd and doesn't conflict with Docker-based Nomad workloads.

### Installation Approach

```bash
# First server node (Hestia - amd64, will be primary)
curl -sfL https://get.k3s.io | K3S_TOKEN=<secret> sh -s - server \
    --cluster-init \
    --flannel-backend=none \
    --disable-network-policy \
    --disable=traefik \
    --tls-san=k8s.brmartin.co.uk

# Additional server nodes (Heracles, Nyx - arm64)
curl -sfL https://get.k3s.io | K3S_TOKEN=<secret> sh -s - server \
    --server https://192.168.1.5:6443 \
    --flannel-backend=none \
    --disable-network-policy \
    --disable=traefik
```

Key flags:
- `--cluster-init`: Enable embedded etcd for HA
- `--flannel-backend=none`: Disable default CNI (will use Cilium)
- `--disable-network-policy`: Let Cilium handle network policies
- `--disable=traefik`: Disable built-in Traefik (will configure separately)

### Alternatives Considered

| Option | Pros | Cons | Decision |
|--------|------|------|----------|
| K3s with embedded etcd | Simple HA, no external dependencies | Slightly more resource usage | **Selected** |
| K3s single server | Simplest setup | No HA, single point of failure | Rejected |
| Full Kubernetes (kubeadm) | Full feature set | Excessive complexity for homelab | Rejected |
| Managed K8s (EKS/GKE) | Managed control plane | Not on-premise, out of scope | Rejected |

### Coexistence with Nomad

- K3s uses ports 6443 (API), 10250 (kubelet) - no conflict with Nomad
- Both can schedule containers via containerd/Docker
- Resource limits should be set to prevent starvation

---

## 2. Storage Solution

### Decision: Use K3s local-path provisioner initially, evaluate Longhorn for production

### Rationale

For the PoC, the built-in local-path provisioner is sufficient and requires no additional setup. GlusterFS access from Kubernetes is complex and may not be needed for PoC services.

### Local-Path Provisioner (Default)

K3s includes Rancher's Local Path Provisioner out of the box:
- StorageClass: `local-path` (default)
- Data stored at: `/var/lib/rancher/k3s/storage/`
- Suitable for: Single-node access (ReadWriteOnce)

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: example-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 1Gi
```

### Longhorn (Future Consideration)

For production/full migration, Longhorn provides:
- Distributed block storage
- Replication across nodes
- Backup/restore capabilities
- UI for management

### GlusterFS Access

If needed, GlusterFS can be accessed via:
1. NFS client provisioner pointing to existing NFS re-exports
2. Direct GlusterFS CSI driver (more complex)

For PoC, this is **not required** - local-path is sufficient.

### Alternatives Considered

| Option | Pros | Cons | Decision |
|--------|------|------|----------|
| local-path | Zero setup, included in K3s | Single node only | **Selected for PoC** |
| Longhorn | Distributed, replicated, UI | Additional component | Future consideration |
| GlusterFS NFS | Reuse existing storage | Complex setup | Not needed for PoC |
| OpenEBS | Feature-rich | Heavy, complex | Overkill for homelab |

---

## 3. Service Mesh Selection

### Decision: Cilium with Hubble

### Rationale

Cilium provides CNI + service mesh in one component, reducing complexity. It's well-documented for K3s and supports the mixed amd64/arm64 architecture. Hubble provides excellent observability.

### Installation

```bash
# Install Cilium CLI
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz
sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin

# Install Cilium (after K3s is running)
cilium install --version 1.18.6 --set=ipam.operator.clusterPoolIPv4PodCIDRList="10.42.0.0/16"

# Enable Hubble for observability
cilium hubble enable --ui
```

### Features Used

- **CNI**: Pod networking (replaces Flannel)
- **Network Policies**: CiliumNetworkPolicy for traffic control
- **mTLS**: Service mesh with transparent encryption
- **Hubble**: Flow visibility and debugging

### Alternatives Considered

| Option | Pros | Cons | Decision |
|--------|------|------|----------|
| Cilium | CNI + mesh combined, eBPF-based, Hubble | Newer, learning curve | **Selected** |
| Linkerd | Lightweight, simple, mature | Separate from CNI | Good alternative |
| Istio | Feature-rich, widely adopted | Heavy, complex | Overkill for homelab |
| K3s default (Flannel) | Simple, zero config | No mesh capabilities | Insufficient |

---

## 4. Ingress Strategy

### Decision: Deploy Traefik separately on Kubernetes (not K3s built-in)

### Rationale

The existing external Traefik routes to Nomad via Consul Catalog. For Kubernetes, we need Traefik to also read Kubernetes Ingress resources. Options:

1. **Hybrid Traefik**: Single Traefik instance routing to both Nomad (via Consul) and K8s (via Kubernetes provider)
2. **K8s-only Traefik**: Separate Traefik on K8s for K8s services only

For PoC, option 2 is simpler and avoids disrupting production.

### Configuration

Deploy Traefik via Helm with IngressClass:

```yaml
# values.yaml for Traefik Helm chart
ingressClass:
  enabled: true
  isDefaultClass: true
  
providers:
  kubernetesIngress:
    enabled: true
    
ports:
  web:
    port: 8080
  websecure:
    port: 8443
    
service:
  type: LoadBalancer  # Or NodePort with external LB
```

### TLS/Certificates

- Use cert-manager for automatic Let's Encrypt certificates
- Or sync existing wildcard certificate as Kubernetes Secret

### Alternatives Considered

| Option | Pros | Cons | Decision |
|--------|------|------|----------|
| Separate Traefik on K8s | Isolated, no production risk | Needs separate IP/port | **Selected for PoC** |
| Hybrid Traefik | Single entry point | Complex, risky | Future consideration |
| K3s built-in Traefik | Zero setup | Less configurable | Disabled |
| Nginx Ingress | Well-documented | Another tool to learn | Not needed |

---

## 5. Vault Integration

### Decision: External Secrets Operator (ESO)

### Rationale

External Secrets Operator is the modern, Kubernetes-native approach to syncing secrets from Vault to Kubernetes Secrets. It's simpler than the Vault Agent Injector for basic use cases.

### Installation

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace
```

### Configuration

```yaml
# ClusterSecretStore pointing to existing Vault
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "https://vault.brmartin.co.uk"
      path: "nomad"  # Reuse existing secrets path
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "external-secrets"
---
# ExternalSecret to sync a specific secret
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: overseerr-secrets
spec:
  refreshInterval: "1h"
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: overseerr-secrets
  data:
    - secretKey: MINIO_ACCESS_KEY
      remoteRef:
        key: nomad/default/overseerr
        property: MINIO_ACCESS_KEY
```

### Vault Configuration Required

1. Enable Kubernetes auth method in Vault
2. Create policy for external-secrets role
3. Bind role to external-secrets ServiceAccount

### Alternatives Considered

| Option | Pros | Cons | Decision |
|--------|------|------|----------|
| External Secrets Operator | K8s-native, declarative, multi-backend | Another operator | **Selected** |
| Vault Agent Injector | HashiCorp official | Sidecar overhead, complex | Good alternative |
| Secrets Store CSI Driver | Direct mount | More complex setup | Not needed |
| Manual sync | Simple | Not automated | Not acceptable |

---

## 6. Terraform Kubernetes Provider

### Decision: Use hashicorp/kubernetes provider with kubectl_manifest for complex resources

### Rationale

The Terraform Kubernetes provider works well for standard resources. For CRDs and complex manifests, `kubectl_manifest` from the `gavinbunney/kubectl` provider is more flexible.

### Provider Configuration

```hcl
terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
  # Or use host/token for CI
}

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}
```

### Resource Patterns

```hcl
# Standard Deployment
resource "kubernetes_deployment_v1" "example" {
  metadata {
    name = "example"
  }
  spec {
    # ...
  }
}

# Complex CRD (e.g., VPA, ExternalSecret)
resource "kubectl_manifest" "vpa" {
  yaml_body = file("${path.module}/manifests/vpa.yaml")
}

# Helm release for complex components
resource "helm_release" "traefik" {
  name       = "traefik"
  repository = "https://traefik.github.io/charts"
  chart      = "traefik"
  values     = [file("${path.module}/values/traefik.yaml")]
}
```

### Module Structure

```
modules-k8s/overseerr/
├── main.tf           # Provider refs, resources
├── variables.tf      # Input variables
├── outputs.tf        # Outputs
└── manifests/
    ├── deployment.yaml
    ├── service.yaml
    ├── ingress.yaml
    └── vpa.yaml
```

---

## Summary of Decisions

| Topic | Decision | Confidence |
|-------|----------|------------|
| K3s Installation | Embedded etcd HA, disable Flannel/Traefik | High |
| Storage | local-path for PoC, Longhorn for future | High |
| Service Mesh | Cilium with Hubble | High |
| Ingress | Separate Traefik on K8s via Helm | Medium |
| Vault Integration | External Secrets Operator | High |
| Terraform | kubernetes + kubectl + helm providers | High |

## Open Questions (to resolve during implementation)

1. How to handle certificate management for K8s Traefik? (cert-manager or manual)
2. Exact resource limits for K3s to prevent Nomad starvation
3. Whether to use same kubeconfig path or separate for automation
