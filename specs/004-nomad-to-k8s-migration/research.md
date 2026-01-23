# Research: Nomad to Kubernetes Full Migration

**Phase**: 0 - Research  
**Date**: 2026-01-22

## Key Technical Decisions

### 1. Storage Access Strategy

**Decision**: Use direct NFS mounts via hostPath, not democratic-csi

**Rationale**: 
- democratic-csi is only installed on Nomad (provides CSI for Nomad jobs)
- K8s cluster doesn't have democratic-csi installed
- NFS-Ganesha exports GlusterFS at `/storage/v/` on all nodes
- K8s pods can mount NFS directly via hostPath or static PV

**Alternatives Considered**:
| Option | Pros | Cons |
|--------|------|------|
| Install democratic-csi on K8s | Consistent with Nomad | Duplicate CSI, complexity, resource overhead |
| Direct NFS mount via hostPath | Simple, no new components | Requires node affinity if data locality needed |
| Static PV + PVC | K8s-native approach | More YAML, but manageable |

**Implementation**:
```yaml
# Option A: hostPath (simplest)
volumes:
  - name: data
    hostPath:
      path: /storage/v/glusterfs_<service>_<type>
      type: Directory

# Option B: Static PV (more K8s-native)
apiVersion: v1
kind: PersistentVolume
metadata:
  name: glusterfs-<service>-data
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: /storage/v/glusterfs_<service>_<type>
```

**Chosen**: hostPath for simplicity. The NFS mount is already available at `/storage/v/` on all nodes via NFS-Ganesha.

---

### 2. MinIO Access for Litestream

**Decision**: Use MinIO's direct S3 endpoint via node network

**Rationale**:
- MinIO runs on Nomad with Consul service `minio-s3` on port 9000
- K8s pods can access via Consul DNS (`minio-s3.service.consul:9000`) - CoreDNS already configured
- Alternatively, use direct IP since MinIO is pinned to Hestia

**Current PoC Pattern** (from `modules-k8s/overseerr/main.tf`):
```hcl
minio_endpoint = "http://minio-minio.service.consul:9000"
```

**Note**: Once MinIO migrates to K8s, update endpoint to K8s service name.

---

### 3. External Traefik Routing

**Decision**: Add routes to `/mnt/docker/traefik/traefik/dynamic_conf.yml` on Hestia

**Rationale**:
- External Traefik (Docker) is the public entry point
- K8s Traefik is internal (NodePort 30443)
- Existing pattern from PoC works: external → K8s Traefik → Ingress → Service

**Pattern**:
```yaml
# In dynamic_conf.yml
routers:
  k8s-<service>:
    rule: "Host(`<service>.brmartin.co.uk`)"
    service: to-k8s-traefik
    middlewares:
      - oauth-auth@docker  # if needed
    entryPoints:
      - websecure
```

---

### 4. Secrets Management

**Decision**: Continue using External Secrets Operator → Vault

**Rationale**:
- Already configured in K8s cluster
- ClusterSecretStore `vault-backend` works
- Same Vault paths as Nomad (`nomad/data/default/<service>`)

**Pattern**:
```hcl
resource "kubectl_manifest" "external_secret" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    spec = {
      secretStoreRef = { name = "vault-backend", kind = "ClusterSecretStore" }
      target = { name = "<service>-secrets" }
      data = [
        { secretKey = "VAR_NAME", remoteRef = { key = "default/<service>", property = "VAR_NAME" } }
      ]
    }
  })
}
```

---

### 5. Service Mesh / Network Policies

**Decision**: Use CiliumNetworkPolicy where inter-service communication needed

**Rationale**:
- Cilium CNI is installed with Hubble
- CiliumNetworkPolicy replaces Consul intentions
- Most services don't need explicit policies (default allow)

**When to Add CiliumNetworkPolicy**:
- Services that should only accept traffic from specific sources
- Currently, only `echo` service has a policy (from PoC testing)

---

### 6. TLS Certificate Distribution

**Decision**: Copy `wildcard-brmartin-tls` to each namespace as needed

**Rationale**:
- K8s Traefik terminates TLS for K8s Ingress
- External Traefik terminates TLS for public traffic
- Both need the wildcard certificate

**Current state**:
- Secret exists in `traefik` namespace
- Copied to `kube-system` for Hubble UI

**Pattern for new services**:
```bash
kubectl get secret -n traefik wildcard-brmartin-tls -o yaml | \
  sed 's/namespace: traefik/namespace: <namespace>/' | kubectl apply -f -
```

Or use Terraform to create in each namespace.

---

### 7. GPU Workloads (Ollama)

**Decision**: Use K8s node selector + NVIDIA device plugin

**Rationale**:
- Hestia has NVIDIA GPU
- K3s can use NVIDIA device plugin
- Node selector for `kubernetes.io/hostname: hestia`

**Prerequisites**:
- NVIDIA container toolkit on Hestia
- K8s NVIDIA device plugin DaemonSet

**Check if already configured**:
```bash
kubectl get nodes -o json | jq '.items[].status.allocatable["nvidia.com/gpu"]'
```

---

### 8. Periodic Jobs (CronJobs)

**Decision**: Migrate renovate and restic-backup as K8s CronJobs

**Rationale**:
- K8s CronJob is equivalent to Nomad periodic job
- Same schedule syntax (cron format)

**Nomad periodic syntax**:
```hcl
periodic {
  cron = "0 */4 * * *"
}
```

**K8s CronJob**:
```yaml
spec:
  schedule: "0 */4 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers: [...]
          restartPolicy: Never
```

---

## Migration Order Validation

Based on service dependencies:

| Phase | Services | Dependencies | Verification |
|-------|----------|--------------|--------------|
| 1 | searxng, nginx-sites | None (stateless/simple) | URL access |
| 2 | vaultwarden, overseerr | MinIO (litestream) | Login, data access |
| 3 | open-webui, ollama | GPU (ollama), SQLite (open-webui) | Chat functionality |
| 4 | minio | None (but many depend on it) | S3 API, litestream backup |
| 5 | keycloak | GlusterFS | SSO login flow |
| 6 | appflowy | GlusterFS, multi-container | Document access |
| 7 | elk | GlusterFS, heavy workload | Log ingestion, Kibana |
| 8 | nextcloud | GlusterFS, Collabora | File access, editing |
| 9 | matrix | GlusterFS, multiple frontends | Message history |
| 10 | gitlab, gitlab-runner | GlusterFS, registry, CI | Repo access, CI pipelines |
| 11 | renovate, restic-backup | Periodic scheduling | Successful runs |

**Critical Path**: MinIO migration (Phase 4) affects litestream services. Verify litestream continues working after MinIO migrates.

---

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Storage path mismatch | Medium | High | Verify GlusterFS paths match before stopping Nomad |
| MinIO migration breaks litestream | Medium | High | Test backup/restore cycle after MinIO migration |
| GPU workload fails on K8s | Low | Medium | Test ollama on K8s before migrating open-webui |
| OOM during migration | Medium | Medium | Strict one-at-a-time, verify resources freed |
| Network policy too restrictive | Low | Low | Start without policies, add as needed |

---

## Open Questions (Resolved)

1. ~~How to access GlusterFS from K8s?~~ → hostPath to `/storage/v/`
2. ~~How to access MinIO from K8s?~~ → Consul DNS or direct endpoint
3. ~~How to handle Consul intentions?~~ → CiliumNetworkPolicy (optional)
4. ~~Where to store TLS cert?~~ → Copy to each namespace
5. ~~How to handle periodic jobs?~~ → K8s CronJob
