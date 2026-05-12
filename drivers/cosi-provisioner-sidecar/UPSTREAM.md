# COSI Provisioner Sidecar

This source tree is pinned to:

- repository: `kubernetes-sigs/container-object-storage-interface-provisioner-sidecar`
- version: `v0.1.0`

Local patch:

- `pkg/bucket/bucket_controller.go` updates `BucketClaim` readiness with
  `UpdateStatus` instead of a normal `Update`, because the v1alpha1 COSI CRDs
  installed from `container-object-storage-interface@release-0.2` expose
  `BucketClaim.status` as a status subresource.
- The same path also resynchronizes a claim when a `Bucket` is already Ready,
  which repairs claims created before the sidecar fix and covers imported
  brownfield buckets.
