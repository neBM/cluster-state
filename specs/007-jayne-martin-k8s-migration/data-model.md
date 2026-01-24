# Data Model: Jayne Martin Counselling K8s Migration

**Feature**: 007-jayne-martin-k8s-migration
**Date**: 2026-01-24

## Overview

This feature involves infrastructure migration with no application data model changes. The website is stateless and serves static content.

## Kubernetes Resources

### Deployment: jayne-martin-counselling

| Field | Value | Notes |
|-------|-------|-------|
| replicas | 1 | Single replica sufficient for static site |
| image | registry.brmartin.co.uk/jayne-martin-counselling/website:latest | Existing image |
| port | 80 (http) | Standard HTTP |
| resources.requests.cpu | 10m | Matches Nomad job (10 CPU) |
| resources.requests.memory | 32Mi | Matches Nomad job (32 memory) |
| resources.limits.cpu | 100m | 10x headroom |
| resources.limits.memory | 64Mi | 2x headroom |

### Service: jayne-martin-counselling

| Field | Value |
|-------|-------|
| type | ClusterIP |
| port | 80 |
| targetPort | 80 |

### Ingress: jayne-martin-counselling

| Field | Value |
|-------|-------|
| host | www.jaynemartincounselling.co.uk |
| path | / (Prefix) |
| tls.secretName | wildcard-brmartin-tls |
| ingressClassName | traefik |

### VPA: jayne-martin-counselling-vpa

| Field | Value |
|-------|-------|
| updateMode | Off (recommendations only) |
| minAllowed.cpu | 5m |
| minAllowed.memory | 16Mi |
| maxAllowed.cpu | 200m |
| maxAllowed.memory | 128Mi |

## External Configuration

### Traefik Router (on Hestia)

Location: `/mnt/docker/traefik/traefik/dynamic_conf.yml`

```yaml
k8s-jmc:
  rule: "Host(`www.jaynemartincounselling.co.uk`)"
  service: to-k8s-traefik
  entryPoints:
    - websecure
```

## State Transitions

### Migration State Machine

```
[Nomad Only] → [Both Running] → [K8s Only] → [Nomad Removed]
     │               │               │              │
     │    Deploy K8s │   Cut traffic │   Stop job   │   Uninstall
     └───────────────┴───────────────┴──────────────┘
```

### Rollback Path

At any point before Nomad job removal:
1. Revert Traefik config to remove k8s-jmc router
2. Traffic automatically routes back to Nomad via Consul Catalog
