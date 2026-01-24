# API Contracts

**Feature**: 007-jayne-martin-k8s-migration

## Overview

This feature involves infrastructure migration of a static website. There are no application-level API contracts to define.

## HTTP Endpoints

The website serves static content over HTTP:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/` | GET | Homepage and all static content |
| `/health` | GET | Health check (implicit - any 2xx response) |

## Health Check Contract

The K8s deployment uses HTTP health probes:

```yaml
livenessProbe:
  httpGet:
    path: /
    port: 80
  initialDelaySeconds: 5
  periodSeconds: 30
  timeoutSeconds: 5

readinessProbe:
  httpGet:
    path: /
    port: 80
  initialDelaySeconds: 5
  periodSeconds: 10
  timeoutSeconds: 5
```

**Expected Response**: HTTP 200 with HTML content

## External Routing Contract

External Traefik routes traffic based on Host header:

| Host | Target |
|------|--------|
| `www.jaynemartincounselling.co.uk` | K8s Traefik (port 30443) |
| `jaynemartincounselling.co.uk` | Redirect to www variant |
