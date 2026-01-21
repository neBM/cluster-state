# Findings: Nomad to Kubernetes PoC Migration

**Date**: 2026-01-21
**Status**: PoC Complete

## Summary

Successfully deployed a 3-node K3s cluster alongside the existing Nomad cluster, with three PoC services running on Kubernetes while Nomad continues to run production workloads.

## What Worked Well

### K3s Installation
- K3s with embedded etcd provides a simple HA setup without external dependencies
- Installation was straightforward once cgroup issues on ARM64 nodes were resolved
- All three nodes (Hestia amd64, Heracles arm64, Nyx arm64) running as control-plane nodes

### Cilium CNI
- Cilium v1.18.6 installed successfully with Hubble UI for observability
- CiliumNetworkPolicy works as expected - successfully blocked unauthorized traffic
- Hubble provides excellent visibility into traffic flows
- Inter-node connectivity required opening firewall port 8472/udp (VXLAN) on Hestia

### External Secrets Operator + Vault
- ESO integrates well with existing Vault instance
- Kubernetes auth method configured with token reviewer ServiceAccount
- ClusterSecretStore provides cluster-wide access to Nomad secrets
- Secrets sync correctly from `nomad/default/*` path

### VPA (Vertical Pod Autoscaler)
- VPA installed from kubernetes/autoscaler repo
- Requires manual TLS cert generation for admission controller (cert names: `caCert.pem`, `serverCert.pem`, `serverKey.pem`)
- Recommendations generating for whoami after just a few minutes

### Traefik Ingress
- Helm-installed Traefik works well as ingress controller
- NodePort 30443 accessible for HTTPS
- TLSStore configures default wildcard certificate
- Wildcard cert extracted from existing Traefik ACME JSON

### Consul DNS Integration
- CoreDNS custom config forwards `.consul` domain to Consul DNS (port 8600)
- Allows K8s pods to reach Nomad services via `service.consul` names
- Critical for hybrid Nomad+K8s deployments

### Litestream + MinIO
- Litestream sidecar pattern works identically to Nomad setup
- Successfully replicating SQLite to MinIO via Consul DNS
- Separate bucket (`overseerr-k8s-litestream`) avoids conflicts with Nomad instance

## Issues Encountered

### ARM64 Cgroup Configuration
**Problem**: K3s failed to start on ARM64 nodes (Heracles, Nyx) due to memory cgroup being disabled.
**Solution**: Added `cgroup_memory=1 cgroup_enable=memory` to `/boot/firmware/current/cmdline.txt`
**Root Cause**: Default kernel config on these ARM64 systems had `cgroup_disable=memory`

### VPA Admission Controller TLS
**Problem**: VPA admission controller stuck in ContainerCreating, missing TLS secret.
**Solution**: Manually generated TLS certs with correct key names (`caCert.pem`, `serverCert.pem`, `serverKey.pem`)
**Note**: The VPA installation script should handle this but didn't run correctly

### Cilium Inter-Node Connectivity
**Problem**: Cilium showed 2/3 nodes reachable, pod-to-pod traffic failing between nodes.
**Solution**: Opened firewall ports on Hestia: 8472/udp (VXLAN), 4240/tcp (health)
**Root Cause**: Hestia's firewalld was blocking Cilium's VXLAN tunnel traffic

### Vault Kubernetes Auth
**Problem**: Initial "permission denied" errors from Vault K8s auth.
**Solution**: Created `vault-token-reviewer` ServiceAccount with `system:auth-delegator` ClusterRoleBinding, generated long-lived token for Vault to verify K8s tokens.
**Note**: Vault running outside K8s needs a reviewer JWT to validate K8s ServiceAccount tokens

### ESO API Version
**Problem**: ExternalSecret/ClusterSecretStore using `v1beta1` API version failed.
**Solution**: ESO now uses `external-secrets.io/v1` API version (GA release)

## Comparison: Nomad vs Kubernetes

| Aspect | Nomad | Kubernetes |
|--------|-------|------------|
| Installation complexity | Lower (single binary) | Higher (control plane components) |
| Resource overhead | Lower (~100MB) | Higher (~500MB+ for control plane) |
| Service mesh | Consul Connect (built-in) | Cilium (separate install) |
| Secret management | Vault integration (native) | ESO + Vault (extra component) |
| VPA equivalent | N/A (manual) | VPA (works well) |
| Network policies | Consul intentions | CiliumNetworkPolicy (more granular) |
| Ingress | Traefik (Docker Compose) | Traefik (Helm) |
| Learning curve | Lower | Higher |
| Ecosystem | Smaller | Much larger |

## Resource Usage Comparison

### K8s Control Plane Overhead (per node)
- etcd: ~50MB RAM
- kube-apiserver: ~200MB RAM
- kube-controller-manager: ~50MB RAM
- kube-scheduler: ~20MB RAM
- Cilium: ~150MB RAM
- CoreDNS: ~20MB RAM
- **Total: ~500MB+ per node**

### Nomad Overhead (per node)
- Nomad agent: ~80MB RAM
- Consul agent: ~80MB RAM
- **Total: ~160MB per node**

## Recommendations

### Short-term (Current State)
1. Keep Nomad for production workloads - it's working well
2. Use K8s for testing VPA recommendations on select services
3. Monitor VPA recommendations over 24-48 hours before acting

### Medium-term (If Migrating)
1. Migrate stateless services first (whoami pattern)
2. Migrate stateful services with litestream backup verification
3. Keep Nomad running until K8s services proven stable
4. Enable Cilium encryption (WireGuard) for mTLS

### Not Recommended
1. Full migration without solving the resource overhead issue
2. Running both orchestrators long-term (operational complexity)
3. Migrating services that heavily use Consul Connect features

## Files Created

```
specs/003-nomad-to-kubernetes/
├── tasks.md              # Task tracking
└── findings.md           # This document

k8s/core/vault-integration/
└── main.tf               # ClusterSecretStore for Vault

modules-k8s/
├── whoami/               # Stateless demo service
├── echo/                 # Network policy testing
└── overseerr/            # Stateful service with litestream

kubernetes.tf             # K8s provider and module config
```

## Manual Configuration (Not in Terraform)

The following was configured manually and would need to be documented/automated for production:

1. **K3s Installation** - Installed via curl script on each node
2. **Cilium Installation** - Installed via cilium CLI
3. **VPA Installation** - Installed via kubectl from kubernetes/autoscaler repo
4. **ESO Installation** - Installed via Helm
5. **Traefik Installation** - Installed via Helm
6. **Vault Kubernetes Auth** - Configured via vault CLI
7. **CoreDNS Consul Forwarding** - ConfigMap `coredns-custom`
8. **Firewall Rules** - Opened ports on Hestia
9. **TLS Secret** - Extracted from Traefik ACME JSON
10. **MinIO Bucket/User** - Created via mc CLI
