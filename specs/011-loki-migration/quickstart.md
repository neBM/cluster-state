# Quickstart: ELK to Loki Migration

**Branch**: `011-loki-migration` | **Date**: 2026-03-08

This is the implementation guide for the migration from ELK to Loki + Alloy. The migration is designed as a parallel run: Alloy and Elastic Agent both collect logs simultaneously during validation, then ELK is decommissioned once Loki coverage is confirmed.

---

## Prerequisites

Before starting:
- [ ] `.env` loaded: `set -a && source .env && set +a`
- [ ] `KUBECONFIG=~/.kube/k3s-config` exported
- [ ] MinIO accessible and healthy: `kubectl get pod -n default -l app.kubernetes.io/name=minio`
- [ ] Grafana accessible: `https://grafana.brmartin.co.uk`

---

## Phase 1: MinIO Preparation

### 1.1 Create dedicated MinIO user and bucket

Log into the MinIO Console at `https://minio.brmartin.co.uk` and:

1. Create user `loki` with a strong random password
2. Create a policy `loki-policy` with the following JSON:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": ["s3:ListBucket"],
         "Resource": ["arn:aws:s3:::loki"]
       },
       {
         "Effect": "Allow",
         "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
         "Resource": ["arn:aws:s3:::loki/*"]
       }
     ]
   }
   ```
3. Assign `loki-policy` to the `loki` user
4. Create bucket `loki` (no versioning needed)
5. Note the access key and secret key for the `loki` user

### 1.2 Create Kubernetes Secret

```bash
kubectl create secret generic loki-minio \
  --namespace=default \
  --from-literal=MINIO_ACCESS_KEY=<loki-user-access-key> \
  --from-literal=MINIO_SECRET_KEY=<loki-user-secret-key>
```

Verify:
```bash
kubectl get secret loki-minio -n default
```

---

## Phase 2: Deploy Loki

### 2.1 Create Terraform module `modules-k8s/loki/`

Two files: `main.tf` and `variables.tf` (see data-model.md for the module structure and contracts/component-interfaces.md for the Loki config).

Key resources in `main.tf`:
- `kubernetes_config_map` — Loki `loki.yaml` configuration
- `kubernetes_deployment` — Loki monolithic deployment (1 replica, Recreate strategy)
- `kubernetes_service` — ClusterIP on port 3100

Key variables in `variables.tf`:
- `image_tag` — default `"3.4.1"` (latest stable; multi-arch)
- `minio_endpoint` — `"http://minio-api.default.svc.cluster.local:9000"`
- `minio_bucket` — `"loki"`
- `minio_secret_name` — `"loki-minio"`
- `retention_period` — `"720h"`
- `namespace` — `"default"`

### 2.2 Add module to `kubernetes.tf`

```hcl
module "k8s_loki" {
  source = "./modules-k8s/loki"

  namespace         = "default"
  minio_endpoint    = "http://minio-api.default.svc.cluster.local:9000"
  minio_bucket      = "loki"
  minio_secret_name = "loki-minio"
  retention_period  = "720h"
}
```

### 2.3 Apply

```bash
terraform plan -target='module.k8s_loki' -out=tfplan
terraform apply tfplan
```

### 2.4 Verify Loki is running

```bash
kubectl get pod -n default -l app.kubernetes.io/name=loki
kubectl logs -n default -l app.kubernetes.io/name=loki --tail=20

# Check ready endpoint
kubectl exec -n default -l app.kubernetes.io/name=loki -- wget -qO- http://localhost:3100/ready
# Expected: "ready"

# Check MinIO bucket has been written to (after a few minutes of operation)
# (check via MinIO console)
```

---

## Phase 3: Deploy Grafana Alloy

### 3.1 Create Terraform module `modules-k8s/alloy/`

Key resources in `main.tf`:
- `kubernetes_service_account` — `alloy` in `default` namespace
- `kubernetes_cluster_role` + `kubernetes_cluster_role_binding` — K8s API discovery permissions
- `kubernetes_config_map` — `config.alloy` (the Alloy pipeline config)
- `kubernetes_daemon_set_v1` — Alloy DaemonSet (tolerates control-plane taint)

Key variables:
- `image_tag` — default `"1.7.1"` (latest stable; multi-arch)
- `loki_url` — `"http://loki.default.svc.cluster.local:3100/loki/api/v1/push"`
- `namespace` — `"default"`

The DaemonSet mounts (all read-only except alloy state):
- `/var/log/pods` — pod logs
- `/var/log/journal` — persistent journal
- `/run/log/journal` — volatile journal
- `/var/log` — syslog, auth.log
- `/var/lib/alloy` — Alloy WAL + positions (hostPath DirectoryOrCreate, read-write)

### 3.2 Add module to `kubernetes.tf`

```hcl
module "k8s_alloy" {
  source = "./modules-k8s/alloy"

  namespace = "default"
  loki_url  = "http://loki.default.svc.cluster.local:3100/loki/api/v1/push"
}
```

### 3.3 Apply

```bash
terraform plan -target='module.k8s_alloy' -out=tfplan
terraform apply tfplan
```

### 3.4 Verify Alloy is running on all nodes

```bash
kubectl get pods -n default -l app.kubernetes.io/name=alloy -o wide
# Should show 3 pods: one on hestia, heracles, nyx

kubectl logs -n default -l app.kubernetes.io/name=alloy --tail=20
# Should show "discovered N targets" and successful sends to Loki
```

---

## Phase 4: Add Loki Datasource to Grafana

### 4.1 Update Grafana module

In `modules-k8s/grafana/main.tf`, add a new key `"loki.yaml"` to the `kubernetes_config_map.datasources` resource `data` map:

```hcl
"loki.yaml" = yamlencode({
  apiVersion = 1
  datasources = [
    {
      name      = "Loki"
      type      = "loki"
      uid       = "loki"
      access    = "proxy"
      url       = var.loki_url
      isDefault = false
      editable  = true
      jsonData = {
        maxLines = 1000
        timeout  = 60
      }
    }
  ]
})
```

Also add `loki_url` variable to `variables.tf`:
```hcl
variable "loki_url" {
  type    = string
  default = "http://loki.default.svc.cluster.local:3100"
}
```

Update the module call in `kubernetes.tf`:
```hcl
module "k8s_grafana" {
  # ... existing variables ...
  loki_url = "http://loki.default.svc.cluster.local:3100"
}
```

### 4.2 Apply Grafana update

```bash
terraform plan -target='module.k8s_grafana' -out=tfplan
terraform apply tfplan

# Restart Grafana to pick up new datasource provisioning
kubectl rollout restart deployment/grafana -n default
kubectl rollout status deployment/grafana -n default
```

### 4.3 Verify Loki datasource in Grafana

1. Go to `https://grafana.brmartin.co.uk`
2. Navigate to Connections → Data Sources
3. Confirm "Loki" datasource appears and shows "Data source is working"

---

## Phase 5: Validation (Parallel Run)

At this point both Elastic Agent (→ Elasticsearch) and Alloy (→ Loki) are running simultaneously. Validate Loki coverage before decommissioning ELK.

### 5.1 Verify log coverage

In Grafana Explore with Loki datasource:

```logql
# Check all three nodes have recent logs
{node="hestia"} | __error__=""
{node="heracles"} | __error__=""
{node="nyx"} | __error__=""

# Check key services
{namespace="default", container="gitlab-webservice"}
{namespace="default", container="synapse"}
{namespace="default", container="traefik"}
{namespace="default", container="loki"}

# Verify noise is filtered
{namespace="default"} |= "kube-probe"
# → should return 0 results

# Verify journal logs
{job="journal"} | unit="k3s.service"
```

### 5.2 Verify MinIO storage

Check MinIO console at `https://minio.brmartin.co.uk`:
- Bucket `loki` has objects under `fake/chunks/`
- Objects are growing over time

### 5.3 Check Loki metrics

```bash
kubectl exec -n default -l app.kubernetes.io/name=loki -- wget -qO- http://localhost:3100/metrics | grep -E 'loki_ingester|loki_compactor'
```

Key metrics to check:
- `loki_ingester_chunks_flushed_total` — should be incrementing
- `loki_compactor_apply_retention_last_successful_run_timestamp_seconds` — confirms compactor is running

### 5.4 Declare validation complete

When satisfied that all pod logs are visible in Grafana Explore, proceed to decommission.

---

## Phase 6: Decommission ELK

**Only proceed when Phase 5 validation is complete.**

### 6.1 Remove ELK and Elastic Agent from Terraform

In `kubernetes.tf`, remove or comment out:
```hcl
# REMOVE: module "k8s_elk" { ... }
# REMOVE: module "k8s_elastic_agent" { ... }
```

### 6.2 Remove from Terraform state and apply

```bash
# Optional: remove state entries for PVCs to prevent accidental deletion on re-plan
# (PVCs use Retain policy so data is safe, but clean up from state)

terraform plan -out=tfplan
# Review: should show destruction of ELK + elastic-agent resources
terraform apply tfplan
```

### 6.3 Clean up PVCs (after confirming no data needed)

The 50Gi local NVMe PVCs are retained by `local-path-retain` StorageClass even after PVC deletion. To actually free disk space on Hestia and Heracles, delete the PVCs:

```bash
kubectl get pvc -n default | grep elasticsearch
kubectl delete pvc elasticsearch-data-elasticsearch-data-0 -n default
kubectl delete pvc elasticsearch-data-elasticsearch-data-1 -n default
```

Then manually remove the data directories on each node if needed:
```bash
/usr/bin/ssh 192.168.1.5 "sudo rm -rf /var/lib/rancher/k3s/storage/pvc-*"
# (use the specific PVC directory from kubectl describe pv)
```

### 6.4 Remove DNS entries (optional)

The Traefik IngressRoutes for `es.brmartin.co.uk` and `kibana.brmartin.co.uk` are removed by Terraform. No DNS changes needed if these resolve via wildcard to the cluster.

### 6.5 Verify decommission

```bash
kubectl get pods -n default | grep -E 'elasticsearch|kibana'
# → no results

kubectl get pods -n elastic-system
# → namespace may linger if empty; can be removed:
kubectl delete namespace elastic-system

KUBECONFIG=~/.kube/k3s-config kubectl top nodes
# → heracles should be significantly below 100% RAM
```

---

## Phase 7: Post-Migration Verification

### 7.1 Check RAM reduction

```bash
kubectl top nodes
# Before: heracles at 100% (4.9/5GB)
# After: heracles should be ~55-65% without ES data-1
```

### 7.2 Verify 30-day retention is configured

```bash
kubectl exec -n default -l app.kubernetes.io/name=loki -- wget -qO- http://localhost:3100/config | grep retention
# Should show: retention_period: 720h
```

### 7.3 Run final acceptance query set

```logql
# All P1 scenarios from the spec:
{namespace="default", container="gitlab-webservice"} | limit 10
{node="heracles"} | __error__="" | limit 10
{node="nyx"} | __error__="" | limit 10
{job="journal"} | limit 10
```

---

## Rollback Plan

If Loki is not performing acceptably during Phase 5:

1. Do NOT remove Elastic Agent — it continues collecting logs
2. Scale Loki to 0: `kubectl scale deployment loki -n default --replicas=0`
3. Remove the Loki datasource from Grafana (or keep it as a secondary)
4. Investigate the issue (check `kubectl logs -n default deployment/loki`)
5. Fix and redeploy

The existing ELK stack remains fully operational throughout the parallel run and is only removed in Phase 6, which is a deliberate manual step.

---

## Key Configuration Values Reference

| Value | Setting |
|---|---|
| Loki image | `grafana/loki:3.4.1` |
| Alloy image | `grafana/alloy:v1.7.1` |
| MinIO internal endpoint | `http://minio-api.default.svc.cluster.local:9000` |
| MinIO bucket | `loki` |
| Loki internal URL | `http://loki.default.svc.cluster.local:3100` |
| Loki push endpoint | `http://loki.default.svc.cluster.local:3100/loki/api/v1/push` |
| Retention | `720h` (30 days) |
| WAL dir | `/loki/wal` (emptyDir) |
| Alloy positions dir | `/var/lib/alloy` (hostPath DirectoryOrCreate) |
| Cluster label | `k3s-homelab` |
