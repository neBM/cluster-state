# Architecture Review: 010-observability-stack

**Date**: 2026-01-26 | **Reviewer**: @speckit/architect | **Status**: APPROVED with recommendations

## Executive Summary

Reviewed tasks.md against plan.md and research.md for the observability stack implementation. The task breakdown is comprehensive, well-structured, and properly implements all core requirements. Minor gaps identified in testing procedures and performance validation tasks.

## Completeness

### Core Requirements ✅
- [x] All user stories have acceptance criteria (implicit in task structure)
- [x] Module structure follows existing patterns
- [x] Storage approach correctly uses GlusterFS via PVC
- [x] Ingress patterns match existing Traefik IngressRoute usage
- [x] Secrets management follows ExternalSecrets pattern
- [x] RBAC patterns are appropriate
- [x] Resource estimates are reasonable for cluster constraints
- [x] Dependencies between components correctly identified
- [x] Phasing makes logical sense
- [x] Node Exporter and kube-state-metrics included as recommended

### Gaps Identified
- [ ] Missing: Explicit testing/verification tasks for each component
- [ ] Missing: Performance validation against plan.md goals (15s scrape, <2s dashboards)
- [ ] Missing: Network policy configuration (mentioned in research.md)
- [ ] Missing: Rollback procedures for failed deployments
- [ ] Missing: Prometheus recording rules for common queries
- [ ] Missing: Elasticsearch datasource for Grafana (mentioned in research.md)

## Consistency

### Plan Alignment ✅
- [x] Task structure follows 4-phase approach from plan.md exactly
- [x] Technology versions match (Prometheus 2.54.1, Grafana 11.4.0, Meshery 0.7.159)
- [x] Module structure matches existing patterns (main.tf, variables.tf, secrets.tf, rbac.tf)
- [x] Naming conventions follow established patterns
- [x] Integration patterns match existing services

### Minor Inconsistencies
- [ ] Plan mentions optional Prometheus basic auth, not included in tasks
- [ ] Research.md includes Elasticsearch datasource config, not in tasks
- [ ] Research.md mentions network policies, not included in task breakdown

## Implementability

### Technology Validation ✅
- [x] All container images verified for multi-arch support (amd64/arm64)
- [x] Storage patterns follow constitution (no SQLite on network storage for high-write)
- [x] Resource constraints considered for ARM64 nodes (8GB RAM)
- [x] Keycloak OAuth pattern matches existing implementations
- [x] RBAC requirements clearly defined and appropriate

### Implementation Risks
- [ ] Risk: GlusterFS performance for Prometheus TSDB (mentioned but no mitigation task)
- [ ] Risk: Memory pressure with multiple exporters on ARM nodes
- [ ] Risk: Meshery broad permissions (security consideration not addressed)
- [ ] Risk: No performance testing tasks to validate plan.md goals

## Dependencies

### Dependency Chain Validated ✅
```
Phase 1 (Prometheus Foundation)
    ├── Tasks 1.1-1.7 (Sequential - core Prometheus)
    ├── Task 1.8 (Node Exporter) [P]
    └── Task 1.9 (kube-state-metrics) [P]
         ↓
Phase 2 (Grafana) ←→ Phase 3 (Meshery) [P]
         ↓
Phase 4 (Integration & Dashboards)
```

### Additional Dependencies Found
- Task 2.1 → 2.2: Keycloak client must exist before adding secret to Vault
- Task 4.1: Should specify which services have metrics endpoints
- Task 1.10: Should run after both 1.8 and 1.9 complete

### Parallelization Opportunities ✅
- Tasks 1.8 and 1.9 correctly marked as parallel [P]
- Phases 2 and 3 correctly identified as parallelizable
- Within phases, most tasks are sequential by nature

## Task Granularity Analysis

### Well-Structured Tasks ✅
- Atomic, testable units of work
- Clear deliverables for each task
- Appropriate level of implementation detail
- Logical grouping by component

### Tasks Needing Refinement
1. **Task 4.1 "Annotate Existing Services"** - Should enumerate specific services:
   - Traefik (port 9100, path /metrics)
   - MinIO (port 9000, path /minio/v2/metrics/cluster)
   - Keycloak (port 9000, path /metrics)
   - GitLab components (various ports)

2. **Task 4.2 "Import Grafana Dashboards"** - Could be more specific:
   - Import and configure Kubernetes Cluster dashboard (ID: 6417)
   - Import and configure Node Exporter dashboard (ID: 1860)
   - Import and configure Traefik dashboard (ID: 4475)

## Recommendation
**APPROVED** with recommended additions

The task breakdown is comprehensive and implementation-ready. The suggested additions are quality improvements rather than blockers.

### Required Changes
None - the task breakdown is sufficient to proceed with implementation.

### Strongly Recommended Additions

1. **Add Testing Tasks** (after each deployment phase):
   ```markdown
   ### 1.11 Test Prometheus Functionality
   - [ ] Verify Prometheus UI accessible at prometheus.brmartin.co.uk
   - [ ] Check targets page shows all nodes (3/3 up)
   - [ ] Verify node-exporter metrics from all nodes
   - [ ] Confirm kube-state-metrics collecting
   - [ ] Test example PromQL query
   ```

2. **Add Performance Validation** (Phase 4):
   ```markdown
   ### 4.6 Performance Validation
   - [ ] Verify 15s scrape interval maintained
   - [ ] Test Grafana dashboard load time <2s
   - [ ] Monitor Prometheus memory usage
   - [ ] Check GlusterFS latency impact on queries
   ```

3. **Specify Service Annotations** (Task 4.1):
   ```markdown
   ### 4.1 Annotate Existing Services
   - [ ] Add annotations to Traefik (port 9100)
   - [ ] Add annotations to MinIO (port 9000, requires auth)
   - [ ] Add annotations to Keycloak (port 9000)
   - [ ] Add annotations to GitLab webservice
   - [ ] Document any services without metrics
   ```

### Nice-to-Have Additions

1. **Network Policies** (if Cilium enforcement active):
   ```markdown
   ### 1.12 Configure Network Policies
   - [ ] Allow Prometheus → all pods (scraping)
   - [ ] Allow Grafana → Prometheus (queries)
   - [ ] Test metrics still collected
   ```

2. **Rollback Documentation**:
   ```markdown
   ### 5.1 Document Rollback Procedures
   - [ ] Document terraform destroy commands
   - [ ] List manual cleanup if needed
   - [ ] Document data preservation steps
   ```

3. **Elasticsearch Datasource** (mentioned in research.md):
   ```markdown
   ### 2.5.1 Add Elasticsearch Datasource
   - [ ] Add ES datasource to provisioning ConfigMap
   - [ ] Configure with API key from Vault
   - [ ] Test log queries in Grafana
   ```

## Technical Architecture Notes

### 1. Module Structure Validation ✅
The implementation correctly follows established patterns:
- Separate files: `main.tf`, `variables.tf`, `secrets.tf`, `rbac.tf`
- Uses `kubectl_manifest` for CRDs (IngressRoute, ExternalSecret)
- Proper use of locals for labels and common configuration
- Matches patterns from `elk`, `keycloak`, and other existing modules

### 2. Storage Architecture ✅
Correct use of PVCs with `glusterfs-nfs` StorageClass:
- **Prometheus**: 10Gi for TSDB (appropriate for 30-day retention)
- **Grafana**: 1Gi for SQLite database (low-write, acceptable on GlusterFS)
- **Meshery**: No persistent storage (stateless - correct choice)

**Performance Consideration**: Monitor Prometheus query latency on GlusterFS. If >100ms p99, consider migration to local-path storage (similar to Elasticsearch).

### 3. High Availability Considerations
Current design (single instances) is appropriate for homelab scale:
- **Prometheus**: Single instance OK, can add Thanos later if needed
- **Grafana**: Effectively stateless with external auth
- **Meshery**: Stateless, single instance sufficient

Future HA path documented but not required initially.

### 4. Security Architecture
- **Prometheus**: Optional basic auth, consider adding for external access
- **Grafana**: Keycloak OAuth integration (follows existing pattern)
- **Meshery**: Requires broad RBAC - document security implications
- **Secrets**: All sensitive data in Vault via ExternalSecrets ✅

### 5. Resource Planning
Total resource allocation well within cluster capacity:
| Component | CPU (request/limit) | Memory (request/limit) | Node Affinity |
|-----------|---------------------|------------------------|---------------|
| Prometheus | 500m/2000m | 1Gi/2Gi | Prefer Hestia (amd64) |
| Grafana | 100m/500m | 256Mi/512Mi | Any |
| Meshery | 200m/1000m | 256Mi/512Mi | Any |
| Node Exporter | 50m/200m | 64Mi/128Mi | All (DaemonSet) |
| kube-state-metrics | 100m/500m | 128Mi/256Mi | Any |
| **Total** | **950m/4200m** | **~1.5Gi/3Gi** | - |

### 6. Integration Architecture
```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Prometheus │────▶│   Grafana   │     │   Meshery   │
│  (metrics)  │     │ (visualize) │     │ (mesh mgmt) │
└─────────────┘     └─────────────┘     └─────────────┘
       ▲                    │                    │
       │                    ▼                    ▼
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Services  │     │  Keycloak   │     │   Cilium    │
│ (annotated) │     │   (OAuth)   │     │    (CNI)    │
└─────────────┘     └─────────────┘     └─────────────┘
```

### 7. Monitoring Coverage
Post-implementation, the following will be monitored:
- **Infrastructure**: All nodes via node-exporter
- **Kubernetes**: All resources via kube-state-metrics
- **Services**: Any pod/service with prometheus.io annotations
- **Network**: Cilium metrics via Meshery
- **Ingress**: Traefik metrics

### 8. Data Retention Strategy
- **Prometheus**: 30 days retention, ~10GB storage
- **Grafana**: Dashboards in ConfigMaps (IaC), preferences in SQLite
- **Logs**: Continue using Elasticsearch (separate system)

### 9. Upgrade Path
All components use specific version tags (not :latest):
- Prometheus: v2.54.1 → Check for breaking changes in scrape configs
- Grafana: 11.4.0 → Usually backward compatible
- Meshery: v0.7.159 → Rapid development, check changelog

### 10. Constitution Compliance ✅
- **I. Infrastructure as Code**: All resources via Terraform
- **II. Simplicity First**: Native K8s resources, no Helm
- **III. High Availability**: Appropriate for scale, HA path documented
- **IV. Storage Patterns**: Correct use of PVCs, no high-write SQLite on network
- **V. Security & Secrets**: Vault integration, per-service credentials
- **VI. Service Mesh**: N/A (using Cilium CNI, not Consul)

## Risk Analysis

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| GlusterFS TSDB latency | Medium | Medium | Monitor, prepare local-path migration |
| Memory exhaustion on ARM | Low | High | Resource limits, monitor usage |
| Prometheus cardinality explosion | Low | High | Configure metric relabeling |
| Keycloak downtime blocks Grafana | Low | Low | Document admin password bypass |
| Meshery security exposure | Low | Medium | Document, monitor API access |

## Summary

The task breakdown successfully implements all requirements from the plan while maintaining consistency with existing patterns. The architecture is sound, scalable within homelab constraints, and provides comprehensive observability for the cluster. Minor additions recommended for testing and performance validation, but the core implementation tasks are complete and well-structured.