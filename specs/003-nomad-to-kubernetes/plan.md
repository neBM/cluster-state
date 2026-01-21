# Implementation Plan: Nomad to Kubernetes Migration (Proof of Concept)

**Branch**: `003-nomad-to-kubernetes` | **Date**: 2026-01-21 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/003-nomad-to-kubernetes/spec.md`

## Summary

Deploy a proof-of-concept Kubernetes cluster (K3s) alongside the existing Nomad cluster to validate migration feasibility. The PoC will demonstrate:
- 2-3 services running on Kubernetes (stateless + stateful)
- Vertical Pod Autoscaler providing resource recommendations
- Service mesh with mTLS between services
- Terraform-based deployment from this repository
- Vault secret injection

This is a learning opportunity and feasibility validation only - full migration is out of scope.

## Technical Context

**Orchestrator**: K3s (lightweight Kubernetes) alongside existing Nomad
**Infrastructure as Code**: Terraform with Kubernetes provider (coexisting with existing Nomad provider)
**Storage**: GlusterFS via NFS or Longhorn (NEEDS CLARIFICATION: best storage option for K3s)
**Service Mesh**: NEEDS CLARIFICATION: Cilium vs Linkerd vs Istio vs K3s built-in
**Ingress**: NEEDS CLARIFICATION: K3s Traefik vs existing external Traefik
**Secrets**: Vault with NEEDS CLARIFICATION: External Secrets Operator vs Vault Sidecar Injector
**VPA**: Kubernetes Vertical Pod Autoscaler
**Target Platform**: 3-node ARM64/AMD64 mixed cluster (Hestia, Heracles, Nyx)
**Testing**: Manual verification via kubectl, service health checks
**Constraints**: Must not disrupt existing Nomad services during PoC

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Infrastructure as Code | PASS | Terraform continues managing deployments |
| II. Simplicity First | PASS | K3s is simpler than full Kubernetes; one module per service pattern maintained |
| III. High Availability | PASS | K3s HA with 3 nodes; services tolerate node failure |
| IV. Storage Patterns | NEEDS VALIDATION | Must validate GlusterFS access from K8s or adopt alternative |
| V. Security & Secrets | PASS | Vault integration required; per-service credentials maintained |
| VI. Service Mesh Patterns | ADAPTATION REQUIRED | Consul Connect → Kubernetes-native mesh; explicit service policies still required |

### Constitution Adaptations Required

The constitution references Nomad/Consul-specific patterns that need Kubernetes equivalents:

| Current (Nomad/Consul) | Kubernetes Equivalent |
|------------------------|----------------------|
| Consul intentions | Network Policies or mesh AuthorizationPolicy |
| `<service>.virtual.consul` | Kubernetes Service DNS (`<service>.<namespace>.svc.cluster.local`) |
| Nomad jobspec + main.tf | Kubernetes manifests + main.tf |
| Consul Connect sidecar | Service mesh sidecar (Linkerd/Cilium/Istio) |
| Litestream with ephemeral disk | Litestream with emptyDir or PVC |

**Decision**: Constitution principles remain valid; implementation details change. The constitution should be updated post-PoC if full migration proceeds.

## Project Structure

### Documentation (this feature)

```text
specs/003-nomad-to-kubernetes/
├── spec.md              # Feature specification
├── plan.md              # This file
├── research.md          # Phase 0: Technology decisions
├── data-model.md        # Phase 1: Kubernetes resource model
├── quickstart.md        # Phase 1: Setup and deployment guide
├── contracts/           # Phase 1: Example manifests/templates
└── tasks.md             # Phase 2: Implementation tasks
```

### Source Code (repository root)

```text
# Existing Nomad structure (unchanged)
modules/
├── <service>/
│   ├── main.tf              # Terraform config
│   └── jobspec.nomad.hcl    # Nomad job definition

# New Kubernetes structure (added)
modules-k8s/                  # Separate directory for K8s modules during PoC
├── <service>/
│   ├── main.tf              # Terraform config with kubernetes provider
│   └── manifests/           # Kubernetes YAML manifests
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── ingress.yaml
│       └── vpa.yaml

# K3s cluster configuration
k8s/
├── cluster/                 # K3s installation scripts/config
├── core/                    # Core components (VPA, mesh, etc.)
│   ├── vpa/
│   ├── service-mesh/
│   └── vault-integration/
└── storage/                 # Storage provisioner configuration

main.tf                      # Updated to include K8s provider + modules
```

**Structure Decision**: Kubernetes modules in separate `modules-k8s/` directory during PoC to avoid confusion with Nomad modules. If full migration proceeds, modules would be consolidated or Nomad modules archived.

## Complexity Tracking

| Adaptation | Why Needed | Simpler Alternative Rejected Because |
|------------|------------|-------------------------------------|
| Separate modules-k8s/ directory | Avoid confusion during hybrid period | Single modules/ dir would mix Nomad and K8s, unclear which is active |
| Service mesh (new component) | FR-009 requires mTLS between services | No mesh would leave inter-service traffic unencrypted |
| VPA (new component) | Primary motivation for migration (FR-004) | Without VPA, main benefit of migration is lost |

## Research Required (Phase 0)

The following topics require research before proceeding:

1. **K3s Installation Strategy**: How to install K3s on existing nodes without disrupting Nomad
2. **Storage Solution**: GlusterFS access from K3s vs Longhorn vs other options
3. **Service Mesh Selection**: Cilium vs Linkerd vs Istio for lightweight homelab use
4. **Ingress Strategy**: Use K3s built-in Traefik vs external Traefik vs Nginx
5. **Vault Integration**: External Secrets Operator vs Vault Agent Injector
6. **Terraform Kubernetes Provider**: Best practices for managing K8s resources via Terraform
