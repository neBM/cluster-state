# Tasks: Nomad to Kubernetes Migration (Proof of Concept)

**Date**: 2026-01-21
**Status**: In Progress

## Phase 0: Research & Planning (COMPLETE)

- [x] T001: Research K3s installation strategy
- [x] T002: Research storage solution options
- [x] T003: Research service mesh selection
- [x] T004: Research ingress strategy
- [x] T005: Research Vault integration approach
- [x] T006: Research Terraform Kubernetes provider patterns
- [x] T007: Document decisions in research.md
- [x] T008: Create data-model.md with Kubernetes resource patterns
- [x] T009: Create quickstart.md deployment guide

## Phase 1: Terraform Module Design (COMPLETE)

- [x] T010: Create contracts/k8s-module-pattern.md
- [x] T011: Create modules-k8s/whoami/ (stateless PoC)
- [x] T012: Create modules-k8s/overseerr/ (stateful PoC with litestream)
- [x] T013: Create modules-k8s/echo/ (mesh testing)
- [x] T014: Create k8s/core/vault-integration/ config
- [x] T015: Update provider.tf with kubernetes + kubectl providers
- [x] T016: Create kubernetes.tf with K8s provider config and module calls
- [x] T017: Validate Terraform configuration (terraform validate)

## Phase 2: K3s Cluster Installation

- [x] T018: Generate K3S_TOKEN and store securely
- [x] T019: Install K3s on Hestia (primary server node)
- [x] T020: Copy kubeconfig and verify cluster access
- [x] T021: Install K3s on Heracles (server node) - required cgroup cmdline fix
- [x] T022: Install K3s on Nyx (server node)
- [x] T023: Verify all nodes are Ready (3/3 nodes joined)

## Phase 3: Core Components Installation

- [x] T024: Install Cilium CLI on Hestia
- [x] T025: Install Cilium CNI/mesh on cluster
- [x] T026: Verify Cilium status and node connectivity (2 nodes Ready)
- [x] T027: Install Vertical Pod Autoscaler (VPA)
- [x] T028: Install External Secrets Operator via Helm
- [ ] T029: Configure Vault Kubernetes auth method
- [ ] T030: Create ClusterSecretStore for Vault backend
- [x] T031: Install Traefik via Helm with IngressClass
- [ ] T032: Create TLS secret for wildcard certificate

## Phase 4: PoC Service Deployment

- [ ] T033: Create MinIO bucket for overseerr-k8s litestream
- [ ] T034: Set TF_VAR_enable_k8s=true and run terraform init
- [ ] T035: Deploy k8s_vault_integration module
- [ ] T036: Deploy k8s_whoami module
- [ ] T037: Verify whoami service via kubectl
- [ ] T038: Test whoami ingress at whoami-k8s.brmartin.co.uk
- [ ] T039: Deploy k8s_echo module
- [ ] T040: Test network policy (whoami → echo allowed)
- [ ] T041: Deploy k8s_overseerr module
- [ ] T042: Verify overseerr pods and litestream logs
- [ ] T043: Test overseerr ingress at overseerr-k8s.brmartin.co.uk

## Phase 5: Validation & Documentation

- [ ] T044: Verify VPA recommendations are generated (wait 24h)
- [ ] T045: Test mTLS between services via Hubble
- [ ] T046: Verify network policy blocks unauthorized traffic
- [ ] T047: Verify Nomad services remain unaffected
- [ ] T048: Document findings and lessons learned
- [ ] T049: Update spec with go/no-go decision
- [ ] T050: Commit all changes

## Execution Notes

- **Phases 0-1**: Complete (Terraform modules created)
- **Phase 2**: Requires SSH access to cluster nodes
- **Phase 3**: Requires cluster to be running
- **Phase 4**: Requires Terraform with enable_k8s=true
- **Phase 5**: Requires services to be deployed and running

## Dependencies

```
T018 → T019 → T020 → T021,T022[P] → T023
T023 → T024 → T025 → T026
T026 → T027,T028,T031[P]
T028 → T029 → T030
T030,T031 → T033 → T034 → T035 → T036 → T037 → T038
T038 → T039 → T040
T035 → T041 → T042 → T043
T043 → T044,T045,T046,T047[P] → T048 → T049 → T050
```

[P] = Can run in parallel
