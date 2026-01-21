# Data Model: Kubernetes Resources for PoC

**Date**: 2026-01-21
**Status**: Draft

This document defines the Kubernetes resource patterns for the PoC migration.

## Core Entities

### 1. Deployment

Represents a stateless application workload.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <service-name>
  namespace: default
  labels:
    app: <service-name>
spec:
  replicas: 1
  selector:
    matchLabels:
      app: <service-name>
  template:
    metadata:
      labels:
        app: <service-name>
    spec:
      containers:
        - name: <service-name>
          image: <image>:<tag>
          ports:
            - containerPort: <port>
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
          env:
            - name: TZ
              value: "Europe/London"
          # Environment from secrets
          envFrom:
            - secretRef:
                name: <service-name>-secrets
      # For arm64/amd64 mixed cluster
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/arch
                    operator: In
                    values:
                      - amd64
                      - arm64
```

### 2. StatefulSet

Represents a stateful application with persistent storage.

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: <service-name>
  namespace: default
spec:
  serviceName: <service-name>
  replicas: 1
  selector:
    matchLabels:
      app: <service-name>
  template:
    metadata:
      labels:
        app: <service-name>
    spec:
      containers:
        - name: <service-name>
          image: <image>:<tag>
          ports:
            - containerPort: <port>
          volumeMounts:
            - name: data
              mountPath: /data
            - name: config
              mountPath: /config
      # Litestream sidecar for SQLite backup
        - name: litestream
          image: litestream/litestream:0.5
          args: ["replicate", "-config", "/etc/litestream.yml"]
          volumeMounts:
            - name: data
              mountPath: /data
            - name: litestream-config
              mountPath: /etc/litestream.yml
              subPath: litestream.yml
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: local-path
        resources:
          requests:
            storage: 1Gi
```

### 3. Service

Exposes a deployment within the cluster.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: <service-name>
  namespace: default
spec:
  selector:
    app: <service-name>
  ports:
    - port: 80
      targetPort: <container-port>
      protocol: TCP
  type: ClusterIP
```

### 4. Ingress

Exposes a service externally via Traefik.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: <service-name>
  namespace: default
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - <service-name>.brmartin.co.uk
      secretName: wildcard-brmartin-tls
  rules:
    - host: <service-name>.brmartin.co.uk
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: <service-name>
                port:
                  number: 80
```

### 5. VerticalPodAutoscaler

Automatically adjusts resource requests.

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: <service-name>-vpa
  namespace: default
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment  # or StatefulSet
    name: <service-name>
  updatePolicy:
    updateMode: "Auto"  # or "Off" for recommendations only
  resourcePolicy:
    containerPolicies:
      - containerName: <service-name>
        minAllowed:
          cpu: "50m"
          memory: "64Mi"
        maxAllowed:
          cpu: "2"
          memory: "2Gi"
```

### 6. ExternalSecret

Syncs secrets from Vault.

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: <service-name>-secrets
  namespace: default
spec:
  refreshInterval: "1h"
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: <service-name>-secrets
    creationPolicy: Owner
  data:
    - secretKey: <SECRET_KEY>
      remoteRef:
        key: nomad/default/<service-name>
        property: <SECRET_KEY>
```

### 7. CiliumNetworkPolicy

Controls service-to-service communication (replacing Consul intentions).

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-<source>-to-<destination>
  namespace: default
spec:
  endpointSelector:
    matchLabels:
      app: <destination>
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: <source>
      toPorts:
        - ports:
            - port: "<port>"
              protocol: TCP
```

## Entity Relationships

```
┌─────────────────────────────────────────────────────────────────┐
│                         External Traffic                         │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Traefik Ingress Controller                  │
│                      (reads Ingress resources)                   │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                           Ingress                                │
│              (routes traffic to Service by hostname)             │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                            Service                               │
│                  (load balances to Pod endpoints)                │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Deployment / StatefulSet                     │
│                        (manages Pod lifecycle)                   │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                              Pod                                 │
│    ┌─────────────────┐    ┌─────────────────┐                   │
│    │  App Container  │    │    Sidecar      │                   │
│    │                 │    │  (Litestream)   │                   │
│    └─────────────────┘    └─────────────────┘                   │
│              │                     │                             │
│              ▼                     ▼                             │
│    ┌─────────────────────────────────────────┐                  │
│    │        PersistentVolumeClaim            │                  │
│    │           (local-path storage)          │                  │
│    └─────────────────────────────────────────┘                  │
└─────────────────────────────────────────────────────────────────┘
         │                              │
         ▼                              ▼
┌─────────────────┐          ┌─────────────────────┐
│  ExternalSecret │          │ VerticalPodAutoscaler│
│  (Vault → K8s)  │          │  (adjusts resources) │
└─────────────────┘          └─────────────────────┘
         │
         ▼
┌─────────────────┐
│   Vault (ext)   │
└─────────────────┘
```

## Mapping: Nomad → Kubernetes

| Nomad Concept | Kubernetes Equivalent |
|---------------|----------------------|
| Job | Deployment or StatefulSet |
| Task Group | Pod |
| Task | Container |
| Service (Consul) | Service + Ingress |
| CSI Volume | PersistentVolumeClaim |
| Consul intention | CiliumNetworkPolicy |
| Vault template | ExternalSecret |
| `memory` / `memory_max` | `resources.requests` / `resources.limits` |
| Ephemeral disk (sticky) | emptyDir or local-path PVC |
| Litestream sidecar | Sidecar container in Pod |

## PoC Services Data Model

### Whoami (Stateless Demo)

```yaml
# Minimal stateless service for testing ingress
Resources:
  - Deployment (1 replica, traefik/whoami image)
  - Service (ClusterIP, port 80)
  - Ingress (whoami.brmartin.co.uk)
  - VPA (recommendations only)
```

### Overseerr (Stateful with Litestream)

```yaml
# Demonstrates: storage, secrets, litestream backup, VPA
Resources:
  - StatefulSet (1 replica, sctx/overseerr + litestream sidecar)
  - Service (ClusterIP, port 5055)
  - Ingress (overseerr-k8s.brmartin.co.uk)  # Different URL during PoC
  - PVC (local-path, 1Gi for SQLite)
  - ExternalSecret (MINIO credentials from Vault)
  - VPA (auto mode)
  - ConfigMap (litestream.yml)
```

### Echo Server (For Mesh Testing)

```yaml
# Demonstrates: service mesh mTLS
Resources:
  - Deployment (1 replica, ealen/echo-server)
  - Service (ClusterIP, port 80)
  - CiliumNetworkPolicy (allow from whoami only)
```
