# Decision: Nomad to Kubernetes Migration

**Date**: 2026-01-21
**Decision**: NO-GO for full migration, CONTINUE for VPA experimentation

## Rationale

### Why NO-GO for Full Migration

1. **Resource Overhead**: K8s control plane consumes ~500MB+ RAM per node vs ~160MB for Nomad. On a 3-node home cluster with limited resources, this is significant.

2. **Operational Complexity**: Running both orchestrators requires maintaining two sets of knowledge, tooling, and configurations.

3. **Working System**: Nomad + Consul Connect is working well for current needs. The migration effort doesn't solve any pressing problems.

4. **Manual Steps**: Many K8s components required manual installation (Cilium, VPA, ESO, Traefik). These would need to be automated before production use.

5. **Consul Integration**: The cluster heavily uses Consul for service discovery and the mesh. K8s services can access Consul DNS, but the integration is not as tight as Nomad's native Consul support.

### Why CONTINUE for VPA Experimentation

1. **VPA Value**: VPA provides resource recommendations that Nomad lacks. This data is valuable for right-sizing Nomad job resources.

2. **Low Risk**: K8s cluster runs alongside Nomad without affecting production services.

3. **Learning**: Good learning experience for K8s patterns that may be useful in the future.

## Recommended Actions

### Immediate
- [ ] Keep K8s cluster running for VPA data collection
- [ ] Document VPA recommendations after 24-48 hours
- [ ] Apply VPA insights to Nomad job resource limits

### Future Consideration (Re-evaluate in 6 months)
- If ARM64 nodes are upgraded with more RAM
- If Nomad develops significant limitations
- If K8s-only tooling becomes required

### Cleanup (If Abandoning K8s)
```bash
# Remove K8s services
TF_VAR_enable_k8s=false terraform apply

# Uninstall K3s from all nodes
/usr/bin/ssh 192.168.1.5 "sudo /usr/local/bin/k3s-uninstall.sh"
/usr/bin/ssh 192.168.1.6 "sudo /usr/local/bin/k3s-agent-uninstall.sh"
/usr/bin/ssh 192.168.1.7 "sudo /usr/local/bin/k3s-agent-uninstall.sh"
```

## Lessons for Future

1. **Hybrid Approach Works**: Nomad and K8s can coexist on same nodes
2. **Consul DNS Bridge**: CoreDNS forwarding enables K8s->Nomad communication
3. **VPA Portable Insights**: VPA recommendations apply to any orchestrator
4. **Infrastructure Cost**: K8s has real resource costs that matter on small clusters
