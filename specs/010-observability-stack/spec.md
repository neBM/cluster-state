# Feature Specification: Observability Stack (Prometheus, Grafana, Meshery)

**Feature Branch**: `010-observability-stack`  
**Created**: 2026-01-26  
**Status**: Draft  
**Input**: User description: "Add comprehensive observability stack with Prometheus for metrics, Grafana for visualization with Keycloak SSO, and Meshery for Cilium service mesh visualization. Follow existing Terraform module patterns."

## Overview

This feature adds a metrics-based observability layer to complement the existing ELK logging stack. The stack consists of:

- **Prometheus**: Metrics collection and time-series database
- **Grafana**: Visualization dashboards with Keycloak SSO integration
- **Meshery**: Service mesh visualization for Cilium/Hubble

All services follow existing patterns: Terraform modules in `modules-k8s/`, secrets via Vault/External Secrets Operator, Traefik ingress with OAuth middleware, GlusterFS for persistent storage, VPA in Off mode.

## Current State

- **Logging**: ELK stack (Elasticsearch + Kibana) handles logs
- **Service Mesh**: Cilium CNI with Hubble UI for basic flow visualization
- **Gaps**: No metrics collection, no historical resource usage data, no unified dashboards combining logs + metrics, Goldilocks VPA recommendations lack historical metrics context

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Cluster Metrics Collection (Priority: P1)

As a cluster administrator, I need to collect metrics from all Kubernetes nodes and pods, so that I can monitor resource usage and identify performance issues.

**Why this priority**: Metrics collection is foundational - Grafana and alerting depend on Prometheus having data.

**Independent Test**: Can be tested by deploying Prometheus and querying `node_*` and `container_*` metrics via PromQL.

**Acceptance Scenarios**:

1. **Given** Prometheus is deployed, **When** I query `node_cpu_seconds_total`, **Then** I see CPU metrics for all 3 nodes (Hestia, Heracles, Nyx)
2. **Given** Prometheus is scraping kube-state-metrics, **When** I query `kube_pod_status_phase`, **Then** I see status for all running pods
3. **Given** Prometheus has retention configured, **When** metrics are older than retention period, **Then** they are automatically cleaned up (homelab-appropriate retention: 15-30 days)
4. **Given** Prometheus storage is on GlusterFS, **When** the pod is rescheduled to a different node, **Then** historical metrics persist

---

### User Story 2 - Metrics Visualization (Priority: P2)

As a cluster administrator, I need dashboards to visualize cluster health, resource usage, and trends, so that I can make informed capacity planning decisions.

**Why this priority**: Visualization makes metrics actionable. Depends on Prometheus being operational.

**Independent Test**: Can be tested by accessing Grafana, importing K8s dashboards, and viewing live data.

**Acceptance Scenarios**:

1. **Given** Grafana is deployed with Prometheus datasource, **When** I access grafana.brmartin.co.uk, **Then** I can authenticate via Keycloak SSO
2. **Given** pre-configured dashboards are deployed, **When** I open the K8s Cluster dashboard, **Then** I see node CPU/memory/disk metrics
3. **Given** Grafana has persistent storage, **When** I create a custom dashboard and restart the pod, **Then** my dashboard persists
4. **Given** Grafana and ELK are both deployed, **When** I configure Elasticsearch as a datasource, **Then** I can create unified dashboards with logs + metrics

---

### User Story 3 - Service Mesh Visualization (Priority: P3)

As a cluster administrator, I need to visualize the Cilium service mesh topology and policies, so that I can understand service dependencies and troubleshoot connectivity issues.

**Why this priority**: Enhances existing Hubble UI with deeper mesh management capabilities. Lower priority as Hubble already provides basic flow visualization.

**Independent Test**: Can be tested by accessing Meshery, connecting to the cluster, and viewing the service topology.

**Acceptance Scenarios**:

1. **Given** Meshery is deployed, **When** I access meshery.brmartin.co.uk, **Then** I can authenticate via Keycloak SSO
2. **Given** Meshery is connected to the cluster, **When** I view the topology, **Then** I see services and their connections
3. **Given** Cilium network policies exist, **When** I view policies in Meshery, **Then** I can see which services can communicate

---

### User Story 4 - Goldilocks Integration (Priority: P4)

As a cluster administrator, I need Prometheus metrics to feed into Goldilocks VPA recommendations, so that resource recommendations are based on historical usage patterns.

**Why this priority**: Enhancement to existing Goldilocks deployment. Depends on Prometheus being operational.

**Independent Test**: Can be tested by verifying Goldilocks reads from Prometheus and recommendations reflect actual usage.

**Acceptance Scenarios**:

1. **Given** Prometheus is collecting container metrics, **When** Goldilocks generates recommendations, **Then** recommendations are based on observed resource usage
2. **Given** a deployment has variable load patterns, **When** I view Goldilocks recommendations after 24h, **Then** recommendations reflect peak usage periods

---

### Edge Cases

- What happens if Prometheus storage fills up?
  - Configure appropriate retention period (15-30 days for homelab)
  - Set storage limits and monitor with alerts
  
- How does the system handle if Grafana loses connection to Prometheus?
  - Dashboards should show "No data" gracefully, not crash
  - Health checks should detect and report the issue

- What happens if Meshery cannot connect to the Kubernetes API?
  - Meshery should report connection status clearly
  - Authentication to K8s API should use a dedicated ServiceAccount with minimal RBAC

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Prometheus MUST scrape node metrics via node-exporter or kubelet endpoints
- **FR-002**: Prometheus MUST scrape pod/container metrics via cAdvisor or kubelet
- **FR-003**: Prometheus MUST scrape kube-state-metrics for Kubernetes object status
- **FR-004**: Prometheus MUST store metrics on GlusterFS for persistence across pod restarts
- **FR-005**: Prometheus MUST have configurable retention period (default: 15 days)
- **FR-006**: Grafana MUST authenticate users via Keycloak OIDC
- **FR-007**: Grafana MUST have Prometheus pre-configured as default datasource
- **FR-008**: Grafana MUST include pre-provisioned K8s cluster dashboards
- **FR-009**: Grafana MUST store dashboards persistently (GlusterFS or database)
- **FR-010**: Meshery MUST authenticate users via Keycloak OIDC
- **FR-011**: Meshery MUST connect to the cluster using a dedicated ServiceAccount
- **FR-012**: All services MUST be accessible via Traefik ingress with TLS
- **FR-013**: All secrets MUST be managed via External Secrets Operator + Vault

### Non-Functional Requirements

- **NFR-001**: Prometheus retention SHOULD be homelab-appropriate (15-30 days, not enterprise 1 year+)
- **NFR-002**: Resource requests SHOULD be modest (homelab, not production scale)
- **NFR-003**: All components MUST support arm64 (Heracles, Nyx) and amd64 (Hestia)

### Key Entities

- **Prometheus**: Time-series database, scrapes metrics endpoints, stores on GlusterFS
- **Grafana**: Dashboard UI, connects to Prometheus + optionally Elasticsearch
- **Meshery**: Service mesh manager, connects to K8s API, visualizes Cilium
- **ServiceMonitor** (if using Prometheus Operator): CRD defining scrape targets

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Prometheus successfully scrapes metrics from all 3 nodes within 5 minutes of deployment
- **SC-002**: Grafana K8s cluster dashboard shows live data for CPU, memory, disk, and network
- **SC-003**: User can log into Grafana via Keycloak SSO without creating a separate account
- **SC-004**: Meshery displays the service topology showing at least 5 services and their connections
- **SC-005**: Metrics persist across pod restarts (verified by seeing historical data after intentional restart)
- **SC-006**: Goldilocks recommendations page shows actual resource usage data from Prometheus
