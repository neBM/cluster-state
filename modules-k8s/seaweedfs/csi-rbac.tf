# -----------------------------------------------------------------------------
# CSI Driver RBAC
# -----------------------------------------------------------------------------

resource "kubernetes_service_account" "csi" {
  metadata {
    name      = "seaweedfs-csi"
    namespace = var.namespace
    labels    = local.labels
  }
}

# Leader election requires namespaced Lease access
resource "kubernetes_role" "csi_leader_election" {
  metadata {
    name      = "seaweedfs-csi-leader-election"
    namespace = var.namespace
    labels    = local.labels
  }

  rule {
    api_groups = ["coordination.k8s.io"]
    resources  = ["leases"]
    verbs      = ["get", "watch", "list", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_role_binding" "csi_leader_election" {
  metadata {
    name      = "seaweedfs-csi-leader-election"
    namespace = var.namespace
    labels    = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.csi_leader_election.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.csi.metadata[0].name
    namespace = var.namespace
  }
}

resource "kubernetes_cluster_role" "csi_provisioner" {
  metadata {
    name   = "seaweedfs-csi-provisioner"
    labels = local.labels
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "list"]
  }

  rule {
    api_groups = [""]
    resources  = ["persistentvolumes"]
    verbs      = ["get", "list", "watch", "create", "delete"]
  }

  rule {
    api_groups = [""]
    resources  = ["persistentvolumeclaims"]
    verbs      = ["get", "list", "watch", "update"]
  }

  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["list", "watch", "create", "update", "patch"]
  }

  rule {
    api_groups = ["snapshot.storage.k8s.io"]
    resources  = ["volumesnapshots"]
    verbs      = ["get", "list"]
  }

  rule {
    api_groups = ["snapshot.storage.k8s.io"]
    resources  = ["volumesnapshotcontents"]
    verbs      = ["get", "list"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "csi_provisioner" {
  metadata {
    name   = "seaweedfs-csi-provisioner"
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.csi_provisioner.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.csi.metadata[0].name
    namespace = var.namespace
  }
}

resource "kubernetes_cluster_role" "csi_attacher" {
  metadata {
    name   = "seaweedfs-csi-attacher"
    labels = local.labels
  }

  rule {
    api_groups = [""]
    resources  = ["persistentvolumes"]
    verbs      = ["get", "list", "watch", "update", "patch"]
  }

  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["csinodes"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["volumeattachments"]
    verbs      = ["get", "list", "watch", "update", "patch"]
  }

  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["volumeattachments/status"]
    verbs      = ["patch"]
  }
}

resource "kubernetes_cluster_role_binding" "csi_attacher" {
  metadata {
    name   = "seaweedfs-csi-attacher"
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.csi_attacher.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.csi.metadata[0].name
    namespace = var.namespace
  }
}

resource "kubernetes_cluster_role" "csi_node" {
  metadata {
    name   = "seaweedfs-csi-node"
    labels = local.labels
  }

  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["get", "list", "watch", "create", "update", "patch"]
  }

  rule {
    api_groups = [""]
    resources  = ["persistentvolumes"]
    verbs      = ["get", "list", "watch", "create", "update", "patch"]
  }

  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["csinodes"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["csidrivers"]
    verbs      = ["get", "list", "watch", "create", "delete"]
  }

  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "csi_node" {
  metadata {
    name   = "seaweedfs-csi-node"
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.csi_node.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.csi.metadata[0].name
    namespace = var.namespace
  }
}

resource "kubernetes_cluster_role" "csi_resizer" {
  metadata {
    name   = "seaweedfs-csi-resizer"
    labels = local.labels
  }

  rule {
    api_groups = [""]
    resources  = ["persistentvolumes"]
    verbs      = ["get", "list", "watch", "update", "patch"]
  }

  rule {
    api_groups = [""]
    resources  = ["persistentvolumeclaims"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["persistentvolumeclaims/status"]
    verbs      = ["update", "patch"]
  }

  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["list", "watch", "create", "update", "patch"]
  }

  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "csi_resizer" {
  metadata {
    name   = "seaweedfs-csi-resizer"
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.csi_resizer.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.csi.metadata[0].name
    namespace = var.namespace
  }
}
