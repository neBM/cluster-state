# Quickstart: Nomad to Kubernetes PoC

**Date**: 2026-01-21

This guide provides step-by-step instructions for deploying the Kubernetes PoC alongside the existing Nomad cluster.

## Prerequisites

- SSH access to all three nodes (Hestia, Heracles, Nyx)
- Existing Vault accessible at `https://vault.brmartin.co.uk`
- This repository checked out locally
- Terraform installed locally

## Phase 1: K3s Installation

### 1.1 Generate Cluster Token

```bash
# Generate a secure token for cluster join
export K3S_TOKEN=$(openssl rand -hex 32)
echo "K3S_TOKEN: $K3S_TOKEN"
# Save this token securely!
```

### 1.2 Install K3s on Primary Node (Hestia)

```bash
/usr/bin/ssh 192.168.1.5 "curl -sfL https://get.k3s.io | K3S_TOKEN=$K3S_TOKEN sh -s - server \
    --cluster-init \
    --flannel-backend=none \
    --disable-network-policy \
    --disable=traefik \
    --disable=servicelb \
    --tls-san=k8s.brmartin.co.uk \
    --tls-san=192.168.1.5"
```

### 1.3 Get Kubeconfig

```bash
/usr/bin/ssh 192.168.1.5 "sudo cat /etc/rancher/k3s/k3s.yaml" > ~/.kube/k3s-config
# Update server address
sed -i 's/127.0.0.1/192.168.1.5/g' ~/.kube/k3s-config
export KUBECONFIG=~/.kube/k3s-config
```

### 1.4 Join Additional Server Nodes

```bash
# Heracles (arm64)
/usr/bin/ssh 192.168.1.6 "curl -sfL https://get.k3s.io | K3S_TOKEN=$K3S_TOKEN sh -s - server \
    --server https://192.168.1.5:6443 \
    --flannel-backend=none \
    --disable-network-policy \
    --disable=traefik \
    --disable=servicelb"

# Nyx (arm64)
/usr/bin/ssh 192.168.1.7 "curl -sfL https://get.k3s.io | K3S_TOKEN=$K3S_TOKEN sh -s - server \
    --server https://192.168.1.5:6443 \
    --flannel-backend=none \
    --disable-network-policy \
    --disable=traefik \
    --disable=servicelb"
```

### 1.5 Verify Cluster

```bash
kubectl get nodes
# Should show all 3 nodes (may be NotReady until Cilium is installed)
```

## Phase 2: Install Cilium (CNI + Service Mesh)

### 2.1 Install Cilium CLI

```bash
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
```

### 2.2 Install Cilium

```bash
cilium install --version 1.18.6 \
    --set ipam.operator.clusterPoolIPv4PodCIDRList="10.42.0.0/16" \
    --set hubble.enabled=true \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true
```

### 2.3 Verify Cilium

```bash
cilium status --wait
kubectl get nodes  # Should all be Ready now
```

## Phase 3: Install Core Components

### 3.1 Install Vertical Pod Autoscaler

```bash
# Clone VPA repo
git clone https://github.com/kubernetes/autoscaler.git /tmp/autoscaler
cd /tmp/autoscaler/vertical-pod-autoscaler

# Install VPA
./hack/vpa-up.sh

# Verify
kubectl get pods -n kube-system | grep vpa
```

### 3.2 Install External Secrets Operator

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install external-secrets external-secrets/external-secrets \
    -n external-secrets \
    --create-namespace \
    --set installCRDs=true
```

### 3.3 Configure Vault ClusterSecretStore

First, configure Vault for Kubernetes auth (run once):

```bash
# Enable Kubernetes auth in Vault
vault auth enable kubernetes

# Configure Kubernetes auth
vault write auth/kubernetes/config \
    kubernetes_host="https://192.168.1.5:6443" \
    kubernetes_ca_cert=@/path/to/k3s/ca.crt

# Create policy for external-secrets
vault policy write external-secrets - <<EOF
path "nomad/data/*" {
  capabilities = ["read"]
}
EOF

# Create role for external-secrets
vault write auth/kubernetes/role/external-secrets \
    bound_service_account_names=external-secrets \
    bound_service_account_namespaces=external-secrets \
    policies=external-secrets \
    ttl=1h
```

Then apply the ClusterSecretStore:

```yaml
# k8s/core/vault-integration/cluster-secret-store.yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "https://vault.brmartin.co.uk"
      path: "nomad"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "external-secrets"
          serviceAccountRef:
            name: "external-secrets"
            namespace: "external-secrets"
```

```bash
kubectl apply -f k8s/core/vault-integration/cluster-secret-store.yaml
```

### 3.4 Install Traefik

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update

helm install traefik traefik/traefik \
    -n traefik \
    --create-namespace \
    --set service.type=NodePort \
    --set ports.web.nodePort=30080 \
    --set ports.websecure.nodePort=30443 \
    --set ingressClass.enabled=true \
    --set ingressClass.isDefaultClass=true
```

## Phase 4: Deploy First PoC Service (Whoami)

### 4.1 Create Module Structure

```bash
mkdir -p modules-k8s/whoami/manifests
```

### 4.2 Create Terraform Configuration

```bash
# modules-k8s/whoami/main.tf - created via terraform apply
```

### 4.3 Deploy via Terraform

```bash
cd /path/to/cluster-state
set -a && source .env && set +a

terraform init
terraform plan -target=module.k8s_whoami
terraform apply -target=module.k8s_whoami
```

### 4.4 Verify

```bash
kubectl get pods -l app=whoami
kubectl get ingress whoami
curl -k https://whoami.brmartin.co.uk  # Or via NodePort
```

## Phase 5: Deploy Stateful PoC Service (Overseerr on K8s)

### 5.1 Prepare Secrets

Ensure Vault has the overseerr secrets (already exists from Nomad migration).

### 5.2 Deploy

```bash
terraform plan -target=module.k8s_overseerr
terraform apply -target=module.k8s_overseerr
```

### 5.3 Verify

```bash
kubectl get pods -l app=overseerr
kubectl get pvc
kubectl logs -l app=overseerr -c litestream
curl -k https://overseerr-k8s.brmartin.co.uk/api/v1/status
```

## Phase 6: Verify VPA

### 6.1 Check VPA Recommendations

```bash
kubectl get vpa
kubectl describe vpa whoami-vpa
kubectl describe vpa overseerr-vpa
```

Wait 24 hours for meaningful recommendations.

## Phase 7: Test Service Mesh

### 7.1 Deploy Echo Server

```bash
terraform apply -target=module.k8s_echo
```

### 7.2 Test mTLS Communication

```bash
# From whoami pod, curl echo server
kubectl exec -it deploy/whoami -- curl http://echo.default.svc.cluster.local

# Verify encryption via Hubble
cilium hubble ui
# Open browser to Hubble UI and observe encrypted flows
```

### 7.3 Test Network Policy

```bash
# Apply policy that only allows whoami → echo
kubectl apply -f k8s/core/policies/allow-whoami-to-echo.yaml

# Verify whoami can reach echo
kubectl exec -it deploy/whoami -- curl http://echo.default.svc.cluster.local

# Verify other pods cannot (should timeout/fail)
kubectl run test --rm -it --image=curlimages/curl -- curl http://echo.default.svc.cluster.local
```

## Rollback Procedures

### Remove K3s from a Node

```bash
/usr/bin/ssh <node-ip> "/usr/local/bin/k3s-uninstall.sh"
# or for agents:
/usr/bin/ssh <node-ip> "/usr/local/bin/k3s-agent-uninstall.sh"
```

### Stop K3s Without Removing

```bash
/usr/bin/ssh <node-ip> "sudo systemctl stop k3s"
```

### Remove PoC Services

```bash
terraform destroy -target=module.k8s_whoami
terraform destroy -target=module.k8s_overseerr
terraform destroy -target=module.k8s_echo
```

## Monitoring Nomad During PoC

Regularly check that Nomad services are unaffected:

```bash
nomad job status
nomad node status

# Check resource usage
/usr/bin/ssh 192.168.1.5 "htop"  # or similar
```

## Success Checklist

- [ ] K3s cluster running on all 3 nodes
- [ ] Cilium installed and healthy
- [ ] VPA installed
- [ ] External Secrets Operator installed
- [ ] Vault ClusterSecretStore configured
- [ ] Traefik ingress working
- [ ] Whoami service accessible via HTTPS
- [ ] Overseerr running with persistent storage
- [ ] Litestream backing up to MinIO
- [ ] VPA providing recommendations
- [ ] mTLS verified between services
- [ ] Network policy blocking unauthorized traffic
- [ ] Nomad services unaffected
