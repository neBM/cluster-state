#!/bin/sh
set -eu

export RESTIC_REPOSITORY=${RESTIC_REPOSITORY:-/repo}
export RESTIC_PASSWORD_FILE=${RESTIC_PASSWORD_FILE:-/secrets/password}

LOCK_WAIT=${LOCK_WAIT:-5m}
FORGET_TAG=${FORGET_TAG:-seaweedfs}

echo "Starting restic repository maintenance for tag=$FORGET_TAG"

restic forget \
  --retry-lock "$LOCK_WAIT" \
  --tag "$FORGET_TAG" \
  --group-by host,paths,tags \
  --keep-within 14d \
  --keep-within-weekly 84d \
  --keep-within-monthly 18m \
  --keep-yearly 5 \
  --prune

echo "Checking repository metadata integrity"
restic check --retry-lock "$LOCK_WAIT"

echo "Restic repository maintenance finished successfully"
