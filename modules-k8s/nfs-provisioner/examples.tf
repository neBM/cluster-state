# Example PVC using the NFS provisioner
#
# This file documents how to create PVCs using the glusterfs-nfs StorageClass.
# These examples are commented out - copy into your service module to use.
#
# IMPORTANT: Data is RETAINED when PVC is deleted (reclaimPolicy: Retain)
# The directory on /storage/v/ will persist and must be manually deleted if desired.

# Example 1: Basic PVC with custom volume name
#
# resource "kubernetes_persistent_volume_claim" "myservice_data" {
#   metadata {
#     name      = "myservice-data"
#     namespace = "default"
#     annotations = {
#       # This annotation controls the directory name on disk
#       # Results in: /storage/v/glusterfs_myservice_data
#       "volume-name" = "myservice_data"
#     }
#   }
#   spec {
#     access_modes       = ["ReadWriteMany"]
#     storage_class_name = "glusterfs-nfs"
#     resources {
#       requests = {
#         storage = "1Gi"  # Size is advisory only for NFS
#       }
#     }
#   }
# }

# Example 2: Multiple volumes for a service (data + config)
#
# resource "kubernetes_persistent_volume_claim" "myservice_config" {
#   metadata {
#     name      = "myservice-config"
#     namespace = "default"
#     annotations = {
#       "volume-name" = "myservice_config"
#     }
#   }
#   spec {
#     access_modes       = ["ReadWriteMany"]
#     storage_class_name = "glusterfs-nfs"
#     resources {
#       requests = {
#         storage = "100Mi"
#       }
#     }
#   }
# }

# Example 3: Using PVC in a Deployment
#
# resource "kubernetes_deployment" "myservice" {
#   metadata {
#     name      = "myservice"
#     namespace = "default"
#   }
#   spec {
#     selector {
#       match_labels = {
#         app = "myservice"
#       }
#     }
#     template {
#       metadata {
#         labels = {
#           app = "myservice"
#         }
#       }
#       spec {
#         container {
#           name  = "myservice"
#           image = "myimage:latest"
#           volume_mount {
#             name       = "data"
#             mount_path = "/data"
#           }
#         }
#         volume {
#           name = "data"
#           persistent_volume_claim {
#             claim_name = "myservice-data"
#           }
#         }
#       }
#     }
#   }
# }
