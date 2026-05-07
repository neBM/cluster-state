# Home Lab Cluster State

![Flux Badge](https://img.shields.io/badge/Flux-5468FF?logo=flux&logoColor=fff&style=for-the-badge)
![Kustomize Badge](https://img.shields.io/badge/Kustomize-326CE5?logo=kubernetes&logoColor=fff&style=for-the-badge)
![K3s Badge](https://img.shields.io/badge/K3s-FFC61C?logo=k3s&logoColor=000&style=for-the-badge)

## Overview

Git-tracked desired state for a home lab K3s cluster. Flux reconciles the cluster from this repository, and workloads are defined as plain Kubernetes manifests assembled with Kustomize.

## Layout

```text
clusters/
  k3s-homelab/
    flux-system/            # Flux install + sync + ordered Kustomizations
apps/                       # Application workloads
infrastructure/             # Storage, platform, shared services, observability
drivers/                    # Custom driver source trees and images
scripts/                    # Bootstrap and operational helpers
specs/                      # Historical design and migration specs
```

## Bootstrap

Prerequisites:

- `kubectl` pointed at the target cluster
- a GitLab deploy token for `https://git.brmartin.co.uk/ben/cluster-state.git`
- a webhook token for Flux notifications

Create the Flux Git credentials secret:

```bash
kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic flux-system -n flux-system \
  --from-literal=username='<deploy-token-username>' \
  --from-literal=password='<deploy-token-password>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

Create the webhook token secret:

```bash
kubectl create secret generic webhook-token -n flux-system \
  --from-literal=token='<random-webhook-token>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

Install Flux and the repo sync objects:

```bash
kubectl apply -k clusters/k3s-homelab/flux-system
```

Then register a GitLab webhook that points at:

```text
https://flux-webhook.brmartin.co.uk$(kubectl get receiver cluster-state -n flux-system -o jsonpath='{.status.webhookPath}')
```

## Validation

```bash
# Render every supported entrypoint
./scripts/validate_kustomize.sh

# Inspect a specific layer
kubectl kustomize infrastructure/platform
kubectl kustomize apps

# Compare the Flux bootstrap path to the live cluster
kubectl diff -k clusters/k3s-homelab/flux-system
```

## CI/CD

GitLab CI validates the rendered manifests and builds driver artifacts. Flux is the deployer for cluster state; merging to `main` and delivering the GitLab webhook is the deployment path.

## Notes

- Secrets stay out of git. Manifests reference existing secret names only.
- Avoid `kubectl apply` for live Secrets. It stores a copy of the payload in `kubectl.kubernetes.io/last-applied-configuration` metadata.
- SeaweedFS S3 is the live object-storage endpoint. Some workloads still use legacy `MINIO_*` secret key names for compatibility, and there is no active External Secrets controller in the cluster; see `docs/seaweedfs-s3-identities.md` for current mappings and manual rotation/repair steps.
- Flux source polling is set to a long interval and GitLab webhooks provide the fast path.
- Flux child `Kustomization` objects are authoritative with `prune: true` except for `storage`. Keep `storage` on `prune: false`: it owns the live SeaweedFS backend, the `seaweedfs` and `local-path-retain` `StorageClass` objects, and the restic backup PV/PVC path used by cluster backups. Its data-bearing pods retain host-path data and its managed PVs use `Retain`, so the main risk is cluster-wide storage outage from an accidental manifest deletion. Split the storage layer into smaller Flux `Kustomization` objects before considering pruning there.
- `apps/gitlab/kustomization.yaml` owns the GitLab upgrade flow. Set `migrationVersion` to the target GitLab release first and wait for the versioned migrations `Job` to complete, then set `appVersion` to the same value so the GitLab deployments roll after the schema is ready.
- If you re-run GitLab migrations at the current app version, restart `gitlab-webservice` and `gitlab-sidekiq` after the job completes so Rails reloads any post-migrate schema changes.
