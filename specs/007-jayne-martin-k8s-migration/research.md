# Research: Jayne Martin Counselling K8s Migration

**Feature**: 007-jayne-martin-k8s-migration
**Date**: 2026-01-24

## Research Tasks

### 1. External Traefik Routing Pattern

**Question**: How does external Traefik on Hestia route traffic to K8s services?

**Decision**: Add a file-based router in `/mnt/docker/traefik/traefik/dynamic_conf.yml` pointing to `to-k8s-traefik` service.

**Rationale**: 
- External Traefik uses file provider for static K8s routes (as seen with k8s-whoami, k8s-searxng, etc.)
- The `to-k8s-traefik` service already exists, pointing to `https://host.docker.internal:30443/` (K8s Traefik NodePort)
- This pattern is consistent with all other K8s service migrations

**Alternatives Considered**:
- Consul Catalog provider: Only works for Nomad services with Consul Connect
- Direct K8s service routing: Would require exposing services externally, unnecessary complexity

**Configuration Required**:
```yaml
# Add to /mnt/docker/traefik/traefik/dynamic_conf.yml under http.routers:
k8s-jmc:
  rule: "Host(`www.jaynemartincounselling.co.uk`)"
  service: to-k8s-traefik
  entryPoints:
    - websecure
```

**Note**: The non-www redirect middleware (`jaynemartincounselling-www-redir`) already exists and will continue to work.

---

### 2. TLS Certificate Handling

**Question**: How are TLS certificates handled for jaynemartincounselling.co.uk?

**Decision**: Certificates are managed by external Traefik via Cloudflare DNS challenge. K8s Ingress uses the wildcard-brmartin-tls secret (already available for *.brmartin.co.uk domains) or can use a dedicated cert-manager certificate.

**Rationale**:
- External Traefik's `traefik.yml` already includes jaynemartincounselling.co.uk in the ACME configuration
- External Traefik terminates TLS, so K8s Traefik receives traffic over HTTPS on port 30443 with insecure backend (insecureSkipVerify)
- K8s Ingress still needs TLS config for the internal Traefik to route correctly

**Implementation**:
- K8s Ingress references `wildcard-brmartin-tls` secret (acceptable since traffic is internal)
- Alternative: Create dedicated `jmc-tls` secret via cert-manager if strict cert matching required

---

### 3. Container Image Availability

**Question**: Is the container image available and multi-arch compatible?

**Decision**: Use existing image `registry.brmartin.co.uk/jayne-martin-counselling/website:latest`

**Rationale**:
- Image is already used by Nomad job and works on the cluster
- Registry is internal (registry.brmartin.co.uk) and accessible from all nodes
- Need to verify multi-arch support

**Verification Required**:
```bash
# Check image manifest for multi-arch
docker manifest inspect registry.brmartin.co.uk/jayne-martin-counselling/website:latest
```

**Fallback**: If not multi-arch, constrain to amd64 nodes only (acceptable for simple static site)

---

### 4. K8s Module Pattern

**Question**: What pattern should the K8s module follow?

**Decision**: Follow `modules-k8s/whoami/` pattern - simplest stateless service module.

**Rationale**:
- Whoami is the most similar service (stateless, single container, HTTP only)
- Includes: Deployment, Service, Ingress, VPA
- Multi-arch affinity configuration
- Health check probes

**Key Differences from Whoami**:
- Different hostname (www.jaynemartincounselling.co.uk)
- Different image (registry.brmartin.co.uk/jayne-martin-counselling/website:latest)
- Lower resource requirements (10 CPU, 32Mi memory per Nomad job)

---

### 5. Nomad Removal Analysis

**Question**: What dependencies exist on Nomad that could break if removed?

**Decision**: After JMC migration, Nomad can be safely removed from all nodes.

**Analysis**:
- **Current Nomad jobs**: Only jayne-martin-counselling remains
- **Traefik Nomad provider**: Used for service discovery, will have no services after JMC migration
- **Consul Connect**: Used by Nomad jobs for service mesh; K8s uses Cilium CNI instead
- **Vault**: Independent of Nomad, uses its own agent/server

**Removal Steps**:
1. Stop and remove Nomad job via Terraform
2. Verify no Nomad jobs running: `nomad job status`
3. On each node: `sudo systemctl stop nomad && sudo systemctl disable nomad`
4. Optionally remove Nomad package: `sudo apt remove nomad` or equivalent
5. Update AGENTS.md to remove Nomad references
6. Clean up Traefik config: Remove `nomad` provider from `traefik.yml` (optional, won't cause errors)

**Services Unaffected by Nomad Removal**:
- K8s (K3s) - Independent orchestrator
- Consul - Runs standalone, used by Vault
- Vault - Uses Consul backend, not Nomad
- External Traefik - File and consulCatalog providers remain

---

### 6. Zero-Downtime Cutover Strategy

**Question**: How to achieve zero downtime during migration?

**Decision**: Deploy K8s first, update Traefik routing, verify, then stop Nomad job.

**Rationale**:
- Both deployments can run simultaneously during cutover window
- Traefik file provider hot-reloads configuration changes
- Immediate rollback possible by reverting Traefik config

**Cutover Steps**:
1. Deploy K8s module via Terraform
2. Verify K8s deployment is healthy: `kubectl get pods`, check logs
3. Test internally: `curl -H "Host: www.jaynemartincounselling.co.uk" http://<k8s-pod-ip>`
4. Update external Traefik config (file edit, auto-reloads)
5. Verify external access: `curl https://www.jaynemartincounselling.co.uk`
6. Stop Nomad job: `terraform apply` with module removed
7. Clean up Terraform state

---

## Summary

All research questions resolved. Key findings:

| Topic | Decision | Confidence |
|-------|----------|------------|
| Traefik routing | File-based router to `to-k8s-traefik` | High |
| TLS handling | External Traefik terminates, K8s uses wildcard cert | High |
| Container image | Use existing, verify multi-arch | Medium |
| K8s module pattern | Follow whoami module | High |
| Nomad removal | Safe after JMC migration | High |
| Zero-downtime | Deploy K8s → Update Traefik → Stop Nomad | High |
