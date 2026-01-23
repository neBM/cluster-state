# Implementation Plan: Kubernetes Volume Provisioning

**Branch**: `005-k8s-volume-provisioning` | **Date**: 2026-01-23 | **Spec**: [spec.md](./spec.md)  
**Input**: Feature specification from `/specs/005-k8s-volume-provisioning/spec.md`

## Summary

Enable Kubernetes to automatically create storage volumes (directories on GlusterFS/NFS) without manual intervention. Implementation uses the **NFS Subdir External Provisioner** to provide dynamic volume provisioning with custom directory naming that matches the existing `glusterfs_<service>_<type>` convention.

## Technical Context

**Language/Version**: HCL (Terraform 1.12+), YAML (Kubernetes manifests)  
**Primary Dependencies**: NFS Subdir External Provisioner, Kubernetes 1.34+  
**Storage**: GlusterFS via NFS-Ganesha at `/storage/v/` on all nodes  
**Testing**: Manual verification via `kubectl`, Terraform plan/apply  
**Target Platform**: K3s cluster (Hestia, Heracles, Nyx)  
**Project Type**: Infrastructure-as-Code (Terraform modules)  
**Performance Goals**: Volume creation within 30 seconds of PVC creation  
**Constraints**: Must maintain existing naming convention, no breaking changes to running services  
**Scale/Scope**: ~20 K8s services, 3 nodes

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| **I. Infrastructure as Code** | PASS | All changes via Terraform, no manual intervention |
| **II. Simplicity First** | PASS | Using established provisioner, one new module |
| **III. High Availability by Design** | PASS | Provisioner is stateless, NFS available on all nodes |
| **IV. Storage Patterns** | PASS | GlusterFS CSI volumes pattern maintained |
| **V. Security & Secrets** | PASS | No secrets required for NFS provisioner |
| **VI. Service Mesh Patterns** | N/A | Not service mesh related |

**Naming Convention**: `glusterfs_<service>_<type>` - PASS (configurable via pathPattern)

**Post-Design Re-check**: PASS - Design maintains all constitution principles.

## Project Structure

### Documentation (this feature)

```text
specs/005-k8s-volume-provisioning/
├── spec.md              # Feature specification
├── plan.md              # This file
├── research.md          # Approach evaluation (complete)
├── data-model.md        # Entity definitions
├── quickstart.md        # Setup and testing guide
├── contracts/           # N/A (no API contracts)
├── checklists/
│   └── requirements.md  # Specification checklist
└── tasks.md             # Implementation tasks (Phase 2)
```

### Source Code (repository root)

```text
modules-k8s/
├── nfs-provisioner/           # NEW: NFS Subdir External Provisioner
│   ├── main.tf                # Deployment, ServiceAccount, RBAC
│   ├── storage-class.tf       # StorageClass with pathPattern
│   ├── variables.tf           # Configuration variables
│   └── versions.tf            # Provider requirements
│
├── <existing-services>/       # UNCHANGED initially
│   └── main.tf                # Continue using hostPath
│
└── <new-services>/            # NEW services use PVC pattern
    └── main.tf                # PVC with volume-name annotation

kubernetes.tf                   # Add nfs-provisioner module
```

**Structure Decision**: Single new module `modules-k8s/nfs-provisioner/` following existing pattern. Existing services unchanged; new services can optionally use PVC pattern.

## Implementation Approach

### Phase 1: Core Provisioner (P1 - Required)

Deploy NFS Subdir External Provisioner with custom StorageClass.

**Components**:
1. ServiceAccount + ClusterRole + ClusterRoleBinding (RBAC)
2. Deployment (nfs-subdir-external-provisioner)
3. StorageClass (glusterfs-nfs) with pathPattern

**Deliverables**:
- `modules-k8s/nfs-provisioner/` module
- Integration in `kubernetes.tf`

### Phase 2: Test Service (P1 - Required)

Create test service to validate provisioner works correctly.

**Test Cases**:
1. PVC creates directory automatically
2. Directory follows naming convention
3. Pod can read/write to volume
4. Existing hostPath services unaffected

### Phase 3: Documentation (P2 - Important)

Update AGENTS.md with new volume provisioning pattern.

**Additions**:
- How to use PVC for new services
- When to use hostPath vs PVC
- Troubleshooting guide

### Phase 4: Migration Guide (P3 - Optional)

Document process to migrate existing hostPath services to PVC.

**Note**: Migration is optional - hostPath continues to work.

## Complexity Tracking

No constitution violations. Design uses standard Kubernetes patterns with minimal custom code.
