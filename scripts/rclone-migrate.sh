#!/usr/bin/env bash
#
# rclone-migrate.sh — Migrate Gluster data to SeaweedFS PVCs via S3 API
#
# Bypasses FUSE entirely: writes go through the SeaweedFS S3 gateway.
# Each CSI PVC maps to an S3 bucket named after its PV (pvc-<uuid>).
# Run from a machine with kubectl access.
#
set -euo pipefail

S3_ENDPOINT="http://seaweedfs-s3:8333"
NAMESPACE="default"
IMAGE="rclone/rclone:latest"
NODE="hestia"  # Where /storage/v/ lives

# PVC migration map: pvc_name|gluster_source_dir|owner_uid:gid
# Owner is applied post-sync to match what the service expects.
MIGRATIONS=(
  "gitlab-registry-sw|glusterfs_gitlab_registry|1000:1000"
  "gitlab-shared-sw|glusterfs_gitlab_shared|1000:1000"
  "gitlab-repositories-sw|glusterfs_gitlab_repositories|1000:1000"
  "gitlab-uploads-sw|glusterfs_gitlab_uploads|1000:1000"
  "laurens-dissertation-archive-sw|glusterfs_laurens_dissertation_archive|0:0"
  "matrix-media-store-sw|glusterfs_matrix_media_store|0:0"
  "matrix-config-sw|glusterfs_matrix_config|0:0"
  "matrix-synapse-data-sw|glusterfs_matrix_synapse_data|0:0"
  "matrix-whatsapp-data-sw|glusterfs_matrix_whatsapp_data|0:0"
  "vaultwarden-data-sw|glusterfs_vaultwarden_data|0:0"
  "searxng-config-sw|glusterfs_searxng_config|0:0"
  "iris-image-cache-sw|glusterfs_iris_image_cache|0:0"
)

# Mail PVCs
MAIL_MIGRATIONS=(
  "rspamd-data-sw|glusterfs_rspamd_data|0:0"
  "postfix-spool-sw|glusterfs_postfix_spool|0:0"
)

usage() {
  echo "Usage: $0 [--dry-run] [--pvc <name>] [--list]"
  echo ""
  echo "  --dry-run   Show what would be synced without doing it"
  echo "  --pvc NAME  Migrate a single PVC instead of all"
  echo "  --list      List all PVCs and their S3 bucket mappings"
  exit 1
}

DRY_RUN=""
SINGLE_PVC=""
LIST_ONLY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN="--dry-run"; shift ;;
    --pvc) SINGLE_PVC="$2"; shift 2 ;;
    --list) LIST_ONLY=1; shift ;;
    *) usage ;;
  esac
done

# Get the S3 bucket name for a PVC (= the PV name, which is also the filer dir under /buckets/)
get_s3_bucket() {
  local pvc="$1"
  kubectl -n "$NAMESPACE" get pvc "$pvc" -o jsonpath='{.spec.volumeName}' 2>/dev/null || return 1
}

# Read S3 credentials from an existing service secret
S3_ACCESS_KEY=$(kubectl -n "$NAMESPACE" get secret loki-s3 -o jsonpath='{.data.MINIO_ACCESS_KEY}' | base64 -d)
S3_SECRET_KEY=$(kubectl -n "$NAMESPACE" get secret loki-s3 -o jsonpath='{.data.MINIO_SECRET_KEY}' | base64 -d)

if [[ -z "$S3_ACCESS_KEY" || -z "$S3_SECRET_KEY" ]]; then
  echo "ERROR: Could not read S3 credentials from secret loki-s3"
  exit 1
fi

if [[ -n "$LIST_ONLY" ]]; then
  echo "PVC -> S3 Bucket Mapping:"
  echo "========================="
  for entry in "${MIGRATIONS[@]}" "${MAIL_MIGRATIONS[@]}"; do
    IFS='|' read -r pvc src owner <<< "$entry"
    bucket=$(get_s3_bucket "$pvc" 2>/dev/null || echo "(not bound)")
    status=$(kubectl -n "$NAMESPACE" get pvc "$pvc" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Missing")
    echo "  $pvc -> s3://$bucket [$status]"
  done
  exit 0
fi

run_migration() {
  local pvc="$1"
  local src_dir="$2"
  local owner="$3"

  local bucket
  bucket=$(get_s3_bucket "$pvc") || {
    echo "ERROR: PVC $pvc not found or not bound"
    return 1
  }

  echo ""
  echo "=== Migrating $pvc ==="
  echo "  Source:  /storage/v/$src_dir/"
  echo "  Dest:   s3://$bucket/"
  echo "  Owner:  $owner"
  echo ""

  local pod_name="migrator-${pvc%-sw}"

  # Delete any leftover pod from previous attempt
  kubectl -n "$NAMESPACE" delete pod "$pod_name" --ignore-not-found --wait=false 2>/dev/null || true
  sleep 2

  # Build rclone args as a JSON array for the pod spec
  local rclone_args=(
    "sync" "/src/" ":s3:${bucket}/"
    "--s3-provider" "Other"
    "--s3-endpoint" "$S3_ENDPOINT"
    "--s3-access-key-id" "$S3_ACCESS_KEY"
    "--s3-secret-access-key" "$S3_SECRET_KEY"
    "--s3-no-check-bucket"
    "--transfers" "4"
    "--checkers" "8"
    "--s3-chunk-size" "16M"
    "--s3-upload-concurrency" "2"
    "--buffer-size" "0"
    "--progress"
    "--stats" "10s"
  )

  if [[ -n "$DRY_RUN" ]]; then
    rclone_args+=("--dry-run")
  fi

  # Convert bash array to JSON array
  local args_json
  args_json=$(printf '%s\n' "${rclone_args[@]}" | jq -R . | jq -s .)

  kubectl -n "$NAMESPACE" run "$pod_name" --rm -i --restart=Never \
    --image="$IMAGE" \
    --overrides="$(cat <<EOF
{
  "spec": {
    "nodeSelector": {"kubernetes.io/hostname": "${NODE}"},
    "containers": [{
      "name": "rclone",
      "image": "${IMAGE}",
      "args": ${args_json},
      "volumeMounts": [
        {"name": "src", "mountPath": "/src", "readOnly": true}
      ],
      "resources": {
        "requests": {"memory": "128Mi", "cpu": "100m"},
        "limits": {"memory": "512Mi", "cpu": "1000m"}
      }
    }],
    "volumes": [
      {"name": "src", "hostPath": {"path": "/storage/v/${src_dir}", "type": "Directory"}}
    ]
  }
}
EOF
    )"

  local exit_code=$?

  if [[ $exit_code -ne 0 ]]; then
    echo "ERROR: rclone sync failed for $pvc (exit $exit_code)"
    return 1
  fi

  # Chown if needed (skip for 0:0)
  # This still uses a PVC mount (FUSE), but it's a quick metadata-only operation
  if [[ "$owner" != "0:0" && -z "$DRY_RUN" ]]; then
    echo "  Setting ownership to $owner on $pvc..."
    kubectl -n "$NAMESPACE" delete pod "chown-${pvc%-sw}" --ignore-not-found --wait=false 2>/dev/null || true
    sleep 1
    kubectl -n "$NAMESPACE" run "chown-${pvc%-sw}" --rm -i --restart=Never \
      --image=busybox \
      --overrides="$(cat <<EOF
{
  "spec": {
    "containers": [{
      "name": "chown",
      "image": "busybox",
      "command": ["chown", "-R", "${owner}", "/data"],
      "securityContext": {"runAsUser": 0},
      "volumeMounts": [
        {"name": "dst", "mountPath": "/data"}
      ]
    }],
    "volumes": [
      {"name": "dst", "persistentVolumeClaim": {"claimName": "${pvc}"}}
    ]
  }
}
EOF
      )"
  fi

  echo "  DONE: $pvc"
}

# Combine all migrations
ALL_MIGRATIONS=("${MIGRATIONS[@]}" "${MAIL_MIGRATIONS[@]}")

if [[ -n "$SINGLE_PVC" ]]; then
  found=0
  for entry in "${ALL_MIGRATIONS[@]}"; do
    IFS='|' read -r pvc src owner <<< "$entry"
    if [[ "$pvc" == "$SINGLE_PVC" ]]; then
      run_migration "$pvc" "$src" "$owner"
      found=1
      break
    fi
  done
  if [[ $found -eq 0 ]]; then
    echo "ERROR: PVC $SINGLE_PVC not found in migration map"
    exit 1
  fi
else
  echo "Migrating all PVCs via rclone -> SeaweedFS S3 (no FUSE)"
  echo "======================================================="
  for entry in "${ALL_MIGRATIONS[@]}"; do
    IFS='|' read -r pvc src owner <<< "$entry"
    run_migration "$pvc" "$src" "$owner" || echo "FAILED: $pvc — continuing..."
  done
  echo ""
  echo "All migrations complete."
fi
