# Feature Specification: Nomad Vertical Autoscaling Investigation

**Feature Branch**: `002-nomad-vertical-autoscaling`  
**Created**: 2026-01-21  
**Status**: Draft  
**Input**: User description: "Kubernetes added support for vertical pod autoscaling: modifying pod resource request limit (CPU and MEMORY). Investigate whether Nomad supports this and implement if possible."

## Executive Summary

**Investigation Result**: Nomad does support vertical autoscaling (called "Dynamic Application Sizing" or DAS), but this feature is **only available in Nomad Autoscaler Enterprise**, not the open-source Community Edition.

### Available Options

| Option | Description | Availability |
|--------|-------------|--------------|
| Dynamic Application Sizing | Automatic CPU/memory adjustment based on usage | Enterprise only |
| Horizontal Application Autoscaling | Scale task group count based on metrics | Community Edition |
| Horizontal Cluster Autoscaling | Add/remove Nomad clients based on capacity | Community Edition |
| Manual Resource Tuning | Use `memory_max` for memory oversubscription | Community Edition |

### Recommendation

Since we're running open-source Nomad, true vertical autoscaling is not available. However, we can achieve similar benefits through:

1. **Memory oversubscription** using `memory` (soft limit) and `memory_max` (hard limit)
2. **Horizontal autoscaling** for workloads that scale horizontally
3. **Manual resource tuning** based on monitoring data from Elasticsearch/Prometheus

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Optimize Resource Allocation (Priority: P1)

As a cluster operator, I want services to use appropriate CPU and memory resources so that cluster capacity is efficiently utilized without over-provisioning or service degradation.

**Why this priority**: Resource optimization directly impacts cluster capacity and service reliability. Over-provisioned services waste resources; under-provisioned services cause failures.

**Independent Test**: Can be verified by reviewing resource utilization metrics in Elasticsearch and comparing actual usage vs allocated resources.

**Acceptance Scenarios**:

1. **Given** a service with allocated 512MB memory, **When** the service consistently uses only 200MB, **Then** the operator should be able to identify this discrepancy and adjust the allocation.
2. **Given** a service that occasionally spikes to 400MB memory but is allocated 256MB, **When** memory oversubscription is configured, **Then** the service can burst beyond its soft limit without being OOM-killed.

---

### User Story 2 - Memory Oversubscription (Priority: P2)

As a cluster operator, I want to configure memory oversubscription for services so that they can burst beyond their baseline allocation when needed, improving resource efficiency.

**Why this priority**: Memory oversubscription is available in open-source Nomad and provides partial vertical scaling benefits without requiring Enterprise.

**Independent Test**: Can be tested by deploying a service with `memory` set lower than `memory_max` and observing it successfully use more memory during load spikes.

**Acceptance Scenarios**:

1. **Given** a service configured with `memory = 256` and `memory_max = 512`, **When** the service load increases, **Then** the service can use up to 512MB without being killed.
2. **Given** a node with limited free memory, **When** multiple services try to burst simultaneously, **Then** services are scheduled based on their base `memory` allocation, not `memory_max`.

---

### User Story 3 - Resource Usage Visibility (Priority: P3)

As a cluster operator, I want to view historical resource usage for services so that I can make informed decisions about resource allocation adjustments.

**Why this priority**: Without automated vertical scaling, visibility into actual usage is essential for manual optimization. This leverages existing Elasticsearch infrastructure.

**Independent Test**: Can be tested by querying Elasticsearch for container resource metrics and visualizing trends.

**Acceptance Scenarios**:

1. **Given** services running in Nomad, **When** I query Elasticsearch, **Then** I can see CPU and memory utilization trends over time.
2. **Given** historical resource data, **When** I analyze a service's usage pattern, **Then** I can identify optimal resource settings.

---

### Edge Cases

- What happens when a service with `memory_max` tries to exceed the hard limit? (OOM killed)
- How does memory oversubscription interact with cgroups v1 vs v2?
- What happens to scheduling when many services have high `memory_max` but low base `memory`?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Documentation MUST explain the difference between `memory` (soft limit) and `memory_max` (hard limit) in Nomad
- **FR-002**: Services using memory-intensive workloads SHOULD be configured with appropriate `memory_max` to allow bursting
- **FR-003**: Resource allocation decisions MUST be informed by actual usage data from monitoring
- **FR-004**: System MUST log resource usage metrics to Elasticsearch for analysis
- **FR-005**: Operators MUST be able to query historical resource usage per service

### Key Entities

- **Task Resources**: CPU and memory allocations defined in jobspec (`cpu`, `memory`, `memory_max`)
- **Resource Metrics**: Historical CPU/memory usage data collected by the monitoring stack
- **Nomad Autoscaler**: External daemon that can adjust resources (Enterprise: vertical, Community: horizontal)

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Memory oversubscription is documented and applied to at least 3 memory-variable services
- **SC-002**: Resource utilization data is queryable from Elasticsearch for all Nomad services
- **SC-003**: Services with `memory_max` configured can successfully burst beyond base allocation without OOM errors
- **SC-004**: Cluster memory efficiency improves by allowing tighter base allocations with headroom via `memory_max`

## Assumptions

1. We are running open-source Nomad, not Nomad Enterprise
2. Nomad Autoscaler Enterprise license is not available or cost-prohibitive
3. Elasticsearch is already collecting container metrics (confirmed - logs are being collected)
4. Manual resource tuning based on metrics is acceptable as an alternative to automated vertical scaling

## Out of Scope

- Purchasing Nomad Autoscaler Enterprise license
- Implementing custom vertical autoscaling logic outside of Nomad's capabilities
- Horizontal application autoscaling (separate feature if needed)
- Cluster autoscaling (adding/removing nodes)

## Technical Context (For Reference)

### Nomad Memory Oversubscription

```hcl
task "example" {
  resources {
    cpu    = 200      # MHz reserved
    memory = 256      # MB soft limit (used for scheduling)
    memory_max = 512  # MB hard limit (cgroup limit)
  }
}
```

- `memory`: Base allocation used for bin-packing/scheduling decisions
- `memory_max`: Maximum memory the task can use before being OOM-killed
- Tasks can burst between `memory` and `memory_max` if node has available memory

### Enterprise Dynamic Application Sizing (Not Available)

The Enterprise version would allow:
- Automatic CPU/memory adjustment based on historical usage
- Strategies: `app-sizing-percentile` (e.g., 95th percentile), `app-sizing-max`
- Continuous optimization without manual intervention

### Current Monitoring Stack

- Docker container logs -> Filebeat -> Elasticsearch
- Can query container resource metrics via Elasticsearch API
- Kibana available for visualization at https://kibana.brmartin.co.uk
