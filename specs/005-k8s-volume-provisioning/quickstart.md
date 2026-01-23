# Quickstart: Kubernetes Volume Provisioning

**Feature**: 005-k8s-volume-provisioning  
**Date**: 2026-01-23

## Prerequisites

- K3s cluster running (v1.34+)
- NFS-Ganesha accessible at `127.0.0.1:/storage/v` on all nodes
- Terraform 1.12+ with environment loaded (`set -a && source .env && set +a`)
- kubectl configured (`export KUBECONFIG=~/.kube/k3s-config`)

## Quick Verification

```bash
# Verify NFS is mounted on all nodes
/usr/bin/ssh 192.168.1.5 "mount | grep storage"
/usr/bin/ssh 192.168.1.6 "mount | grep storage"
/usr/bin/ssh 192.168.1.7 "mount | grep storage"

# Expected output (each node):
# 127.0.0.1:/storage on /storage/v type nfs4 (...)
```

## Deploy Provisioner

### 1. Apply Terraform

```bash
# Load environment
set -a && source .env && set +a

# Plan changes
terraform plan -var="nomad_address=https://nomad.brmartin.co.uk:443" -out=tfplan

# Apply
terraform apply tfplan
```

### 2. Verify Provisioner

```bash
# Check provisioner is running
kubectl get pods -n default | grep nfs-provisioner

# Check StorageClass exists
kubectl get storageclass glusterfs-nfs

# Expected output:
# NAME            PROVISIONER                                   RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION
# glusterfs-nfs   nfs.io/nfs-subdir-external-provisioner        Retain          Immediate           false
```

## Test Volume Creation

### 1. Create Test PVC

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-volume
  annotations:
    volume-name: test_data
spec:
  storageClassName: glusterfs-nfs
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
EOF
```

### 2. Verify Directory Created

```bash
# Check PVC is bound
kubectl get pvc test-volume
# Expected: STATUS = Bound

# Verify directory exists
/usr/bin/ssh 192.168.1.5 "ls -la /storage/v/ | grep test"
# Expected: drwxrwxrwx ... glusterfs_test_data
```

### 3. Test Pod Mount

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
spec:
  containers:
  - name: test
    image: busybox
    command: ["sleep", "3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: test-volume
EOF

# Wait for pod to start
kubectl wait --for=condition=Ready pod/test-pod --timeout=60s

# Test write
kubectl exec test-pod -- sh -c "echo 'Hello from K8s' > /data/test.txt"

# Verify on filesystem
/usr/bin/ssh 192.168.1.5 "cat /storage/v/glusterfs_test_data/test.txt"
# Expected: Hello from K8s
```

### 4. Cleanup Test Resources

```bash
kubectl delete pod test-pod
kubectl delete pvc test-volume

# Directory should still exist (Retain policy)
/usr/bin/ssh 192.168.1.5 "ls -la /storage/v/glusterfs_test_data"

# Manual cleanup (optional)
/usr/bin/ssh 192.168.1.5 "sudo rm -rf /storage/v/glusterfs_test_data"
```

## Usage in Terraform Modules

### New Service with PVC

```hcl
# In modules-k8s/myapp/main.tf

resource "kubernetes_persistent_volume_claim" "data" {
  metadata {
    name      = "${local.app_name}-data"
    namespace = var.namespace
    annotations = {
      "volume-name" = "${local.app_name}_data"  # Creates glusterfs_myapp_data
    }
  }

  spec {
    storage_class_name = "glusterfs-nfs"
    access_modes       = ["ReadWriteMany"]

    resources {
      requests = {
        storage = "1Gi"  # Cosmetic - no quota enforcement
      }
    }
  }
}

# Reference in deployment
volume {
  name = "data"
  persistent_volume_claim {
    claim_name = kubernetes_persistent_volume_claim.data.metadata[0].name
  }
}
```

### Existing Service (hostPath - unchanged)

```hcl
# Existing hostPath mounts continue to work
volume {
  name = "config"
  host_path {
    path = "/storage/v/glusterfs_myapp_config"
    type = "Directory"
  }
}
```

## Troubleshooting

### PVC Stuck in Pending

```bash
# Check provisioner logs
kubectl logs -l app=nfs-subdir-external-provisioner -n default

# Common issues:
# - NFS server unreachable
# - Missing volume-name annotation
# - StorageClass not found
```

### Directory Not Created

```bash
# Check provisioner events
kubectl describe pvc <pvc-name>

# Verify NFS mount on provisioner node
kubectl get pod -l app=nfs-subdir-external-provisioner -o wide
# Note the NODE column, then check that node's NFS mount
```

### Permission Denied

```bash
# Check directory permissions
/usr/bin/ssh 192.168.1.5 "ls -la /storage/v/glusterfs_<name>"

# Should be: drwxrwxrwx root root
# Fix if needed:
/usr/bin/ssh 192.168.1.5 "sudo chmod 777 /storage/v/glusterfs_<name>"
```

## Success Criteria Verification

| Criterion | Test Command | Expected Result |
|-----------|--------------|-----------------|
| SC-001: Single terraform apply | `terraform apply` with new service | Pod starts without manual SSH |
| SC-002: Creation < 30s | `time kubectl apply -f pvc.yaml && kubectl wait --for=condition=Bound pvc/test` | < 30 seconds |
| SC-003: No breaking changes | `kubectl get pods -n default` | All existing services Running |
| SC-004: Naming convention | `ls /storage/v/ | grep glusterfs_` | New volumes follow pattern |
