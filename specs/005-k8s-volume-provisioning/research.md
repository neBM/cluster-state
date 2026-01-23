# Research: Kubernetes Volume Provisioning

**Feature**: 005-k8s-volume-provisioning  
**Date**: 2026-01-23

## Executive Summary

Researched 5 approaches for enabling Kubernetes to automatically create storage volumes on NFS-backed GlusterFS. **Recommended approach: NFS Subdir External Provisioner** for its simplicity, support for custom directory naming patterns, and alignment with existing infrastructure.

## Approaches Evaluated

### 1. hostPath with DirectoryOrCreate

**How it works**: Kubernetes hostPath volumes support a `type: DirectoryOrCreate` option that creates the directory if it doesn't exist.

**Findings**:
- Creates directory on the **node** when pod starts
- NOT dynamic provisioning - requires manual PV creation for each volume
- Cannot be used with PVC without pre-creating PersistentVolume resources
- Would require each module to define PV + PVC instead of simple hostPath

**Decision**: REJECTED - Doesn't solve the automation problem, just shifts manual work.

---

### 2. NFS CSI Driver (kubernetes-csi/csi-driver-nfs)

**How it works**: Official CSI driver that provides dynamic provisioning for NFS storage. Creates subdirectories automatically when PVCs are created.

**Findings**:
- Official Kubernetes SIG project, well-maintained
- Supports dynamic provisioning via StorageClass
- Default naming: `${namespace}-${pvcName}-${pvName}` (not customizable to match existing convention)
- Requires CSI node plugin daemonset on all nodes
- Supports snapshots, cloning (features we don't need)

**Decision**: CONSIDERED - More complex than needed, directory naming doesn't match existing convention.

---

### 3. NFS Subdir External Provisioner

**How it works**: Lightweight provisioner that creates subdirectories on existing NFS shares when PVCs are created.

**Findings**:
- Supports `pathPattern` parameter for custom directory naming
- Can use PVC name, namespace, and annotations in path templates
- Simpler than full CSI driver
- 3k+ GitHub stars, widely used in homelab/small clusters
- No capacity enforcement (acceptable - GlusterFS doesn't support per-directory quotas anyway)

**Key capability**: Can configure `pathPattern: "glusterfs_${.PVC.name}"` to match existing naming convention.

**Decision**: **RECOMMENDED** - Best fit for requirements.

---

### 4. Init Containers

**How it works**: Add init container to each deployment that creates the directory before main container starts.

**Findings**:
- Works with existing hostPath volumes
- Requires modifying every deployment
- Adds complexity and startup latency
- Not idiomatic Kubernetes
- Directory creation logic duplicated across modules

**Decision**: REJECTED - Too much per-module overhead, not maintainable.

---

### 5. Terraform null_resource with SSH

**How it works**: Use Terraform `null_resource` with `remote-exec` provisioner to SSH to nodes and create directories.

**Findings**:
- Breaks Kubernetes declarative model
- Requires SSH key management in Terraform
- Creates tight coupling between Terraform and node access
- Race conditions possible with pod scheduling
- Anti-pattern for IaC

**Decision**: REJECTED - Anti-pattern, operational complexity.

---

### 6. K3s Local Path Provisioner (Rancher)

**How it works**: Built into K3s, creates local volumes dynamically using helper pods.

**Findings**:
- Designed for **local node storage**, not network mounts
- Would conflict with NFS-mounted `/storage/v/`
- Helper pods would try to create directories on local disk
- Not compatible with GlusterFS/NFS architecture

**Decision**: REJECTED - Incompatible with NFS-backed storage.

---

## Comparison Matrix

| Approach | Auto-Create | Custom Naming | Terraform Managed | Complexity | Breaking Change |
|----------|-------------|---------------|-------------------|------------|-----------------|
| hostPath DirectoryOrCreate | Partial | Yes | No | Low | No |
| NFS CSI Driver | Yes | No | Yes | High | Yes (PVC migration) |
| **NFS Subdir Provisioner** | **Yes** | **Yes** | **Yes** | **Medium** | **Yes (PVC migration)** |
| Init Containers | Yes | Yes | No | High | Yes (all modules) |
| Terraform SSH | Yes | Yes | Yes | Very High | Yes (all modules) |
| K3s Local Path | Yes | No | Yes | Medium | N/A (incompatible) |

## Recommended Approach: NFS Subdir External Provisioner

### Why This Approach

1. **Supports custom directory naming** via `pathPattern` - can match `glusterfs_<service>_<type>` convention
2. **Works with existing NFS-Ganesha** - just needs server address and path
3. **Terraform-manageable** - StorageClass and provisioner deployed via Terraform
4. **Gradual migration** - existing hostPath services continue working
5. **Simple architecture** - single deployment, no daemonset required

### Implementation Outline

1. **Deploy provisioner** as K8s Deployment (via Terraform)
2. **Create StorageClass** with `pathPattern: "glusterfs_${.PVC.annotations.volume-name}"`
3. **Update modules** to use PVC with annotation for directory name
4. **Test** with new whoami-like service first
5. **Migrate** existing services gradually (optional - hostPath still works)

### Configuration Example

```yaml
# StorageClass
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: glusterfs-nfs
provisioner: nfs.io/nfs-subdir-external-provisioner
parameters:
  pathPattern: "glusterfs_${.PVC.annotations.volume-name}"
  onDelete: retain  # Don't delete data when PVC removed
reclaimPolicy: Retain
volumeBindingMode: Immediate
```

```yaml
# PVC Example
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: myapp-data
  annotations:
    volume-name: myapp_data  # Results in /storage/v/glusterfs_myapp_data
spec:
  storageClassName: glusterfs-nfs
  accessModes: [ReadWriteMany]
  resources:
    requests:
      storage: 1Gi  # Ignored by provisioner (no quota support)
```

## Alternatives Considered

### Alternative A: Keep hostPath, Add Init Container Module

Create a shared Terraform module that adds init container to any deployment.

**Pros**: No infrastructure changes, works immediately
**Cons**: Duplicated logic, increased pod complexity, not idiomatic

### Alternative B: NFS CSI Driver

Use the official CSI driver for more features.

**Pros**: Official, well-supported, snapshot support
**Cons**: Overkill for requirements, can't customize directory naming easily

## Assumptions

- NFS-Ganesha is accessible at `127.0.0.1:/storage/v` on all nodes (verified)
- Directory naming convention `glusterfs_<service>_<type>` should be maintained
- Existing hostPath services should continue working during migration
- Data retention is preferred over automatic cleanup

## References

- [NFS Subdir External Provisioner](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner)
- [NFS CSI Driver](https://github.com/kubernetes-csi/csi-driver-nfs)
- [Kubernetes Storage Classes](https://kubernetes.io/docs/concepts/storage/storage-classes/)
- [hostPath Volume Types](https://kubernetes.io/docs/concepts/storage/volumes/#hostpath)
