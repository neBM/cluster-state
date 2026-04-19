# Terraform → Kustomize Migration Design

**Date:** 2026-04-19
**Status:** Approved

## Goal

Replace Terraform as the k8s resource manager with Kustomize. Motivation: the Terraform `kubernetes` provider's typed resources (`kubernetes_deployment`, etc.) permanently lag the Kubernetes API — specifically, `ResourceClaimTemplate` (DRA) is unsupported, blocking the approved iris-dra-hardware-transcode work. Kustomize uses raw YAML and has no API-lag problem.

## Scope

Full migration. All k8s resources currently managed by Terraform move to Kustomize. No Terraform remains in this repo.

## Repository Structure

Replace `modules-k8s/` with `k8s/`, one directory per workload. Each directory contains flat YAML resource files and a `kustomization.yaml` listing them. A root `k8s/kustomization.yaml` references all components.

```
k8s/
  kustomization.yaml          ← root, references all components
  core/
    kustomization.yaml
    policies/                 ← existing
  alloy/
    kustomization.yaml
    deployment.yaml
    service.yaml
    ...
  media-centre/
    kustomization.yaml
    deployment.yaml
    pvc.yaml
    ...
  ... (one directory per current module)
```

No base/overlays split — single cluster, no environment separation needed. Each component is self-contained with flat YAML files. This is the industry-standard structure for single-cluster Kustomize deployments.

## Migration Process

Cutover happens in one pipeline run via Option A (export from live cluster).

### 0. Build new ACT_IMAGE first (long lead time)

The ACT image (`/home/ben/Documents/Personal/projects/libraries/act`) is a large multi-arch build (Ubuntu + Android SDK + Java + Go etc.) that takes significant time. Start this before any other migration work.

Changes to `libraries/act/Dockerfile`:
- Remove: HashiCorp apt repo + `terraform` package
- Add: `kubectl` (from Kubernetes apt repo) and `kustomize` (binary install from GitHub releases, pinned version via renovate)

Merge and let the `libraries/act` pipeline build and push the new image tag before proceeding. The cluster-state pipeline stays on the current image until cutover.

### 1. Export script (`scripts/export-to-kustomize.sh`)

For each workload directory, `kubectl get` the following resource types with `-o yaml`:

- `Deployment`, `StatefulSet`, `DaemonSet`
- `Service`, `Ingress`
- `ConfigMap`
- `ServiceAccount`, `Role`, `RoleBinding`, `ClusterRole`, `ClusterRoleBinding`
- `PersistentVolumeClaim`, `StorageClass`
- `CiliumNetworkPolicy`, `VerticalPodAutoscaler`, `ExternalSecret`
- Any other CRDs present (`ResourceSlice`, `DeviceClass`, etc.)

Strip runtime fields from each resource:
- `metadata.resourceVersion`
- `metadata.uid`
- `metadata.creationTimestamp`
- `metadata.managedFields`
- `metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"]`
- `.status`

Split into per-resource YAML files. Generate a `kustomization.yaml` per directory listing all files.

### 2. Secrets

Secrets are not exported or committed. They already exist in the cluster; Kustomize manifests reference them by name only (no change to existing secret management).

### 3. Verify before cutover

Run `kubectl diff -k k8s/` after export. Should show no changes if the export faithfully reflects live state. Any diff must be resolved before proceeding.

### 4. Cutover

Merge to main → CI runs `kubectl apply -k k8s/` → done. The Terraform pipeline is removed in the same commit.

## CI Pipeline

Two jobs replace the three Terraform stages:

| Job | Trigger | Command |
|---|---|---|
| `validate` | MR | `kustomize build k8s/ > /dev/null` |
| `apply` | `main`, manual | `kubectl apply -k k8s/` |

The `before_script` kubeconfig setup is unchanged (same ServiceAccount token, same `K8S_HOST`/`K8S_TOKEN`/`K8S_CA_CERT` CI variables).

`ACT_IMAGE` Dockerfile: replace `terraform`/`tflint` with `kustomize`. `kubectl` is already present or added alongside it.

## Cleanup (post-cutover)

- Delete `modules-k8s/` and all root `*.tf` files
- Drop PostgreSQL TF state schema; remove `PG_CONN_STR` CI variable
- Remove `TF_IN_AUTOMATION` CI variable
- Delete `.terraform/`, `.terraform.lock.hcl`, `tfplan`, `.tflint.hcl`
- Update `.pre-commit-config.yaml` to remove Terraform hooks
- Update `renovate.json`: remove Terraform manager, add `kubectl`/`kustomize` version tracking

## Files Changed

| Path | Change |
|---|---|
| `k8s/` | New directory — all workload manifests |
| `scripts/export-to-kustomize.sh` | New — export + strip script |
| `.gitlab-ci.yml` | Replace 3-stage TF pipeline with validate + apply |
| `libraries/act/Dockerfile` | Swap terraform for kubectl + kustomize (built first, long lead time) |
| `renovate.json` | Update managers |
| `modules-k8s/` | Deleted |
| `*.tf` (root) | Deleted |
| `.terraform*`, `tfplan`, `.tflint.hcl` | Deleted |
