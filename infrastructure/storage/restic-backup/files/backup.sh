#!/bin/sh
set -e

export RESTIC_REPOSITORY=/repo
export RESTIC_PASSWORD_FILE=/secrets/password
LOCK_WAIT=30m

# Initialize repo if needed
if ! restic snapshots >/dev/null 2>&1; then
  echo "Initializing restic repository..."
  restic init
fi

echo "Starting backup of SeaweedFS volumes..."

restic backup /data-seaweedfs \
  --retry-lock "$LOCK_WAIT" \
  --host restic-backup \
  --group-by paths,tags \
  --tag seaweedfs \
  --tag scheduled \
  --iexclude-file=/config/excludes.txt \
  --exclude-caches \
  --exclude-if-present .nobackup \
  --skip-if-unchanged

echo "Backup complete. Running cleanup..."

restic forget \
  --retry-lock "$LOCK_WAIT" \
  --group-by paths,tags \
  --keep-within 14d \
  --keep-within-weekly 84d \
  --keep-within-monthly 18m \
  --keep-yearly 5 \
  --prune

echo "Checking repository integrity..."
restic check --retry-lock "$LOCK_WAIT"

echo "Backup job finished successfully"
