#!/bin/sh
set -e

export RESTIC_REPOSITORY=/repo
export RESTIC_PASSWORD_FILE=/secrets/password

# Initialize repo if needed
if ! restic snapshots >/dev/null 2>&1; then
  echo "Initializing restic repository..."
  restic init
fi

echo "Starting backup of SeaweedFS volumes..."

backup_status=0
restic backup /data-seaweedfs \
  --host restic-backup \
  --group-by paths,tags \
  --tag seaweedfs \
  --tag scheduled \
  --iexclude-file=/config/excludes.txt \
  --exclude-caches \
  --exclude-if-present .nobackup \
  --skip-if-unchanged || backup_status=$?

case "$backup_status" in
  0)
    ;;
  3)
    echo "Backup completed with unreadable source files; continuing after restic warning exit code 3."
    ;;
  *)
    exit "$backup_status"
    ;;
esac

echo "Backup complete. Running cleanup..."

restic forget \
  --group-by paths,tags \
  --keep-within 14d \
  --keep-within-weekly 12w \
  --keep-within-monthly 18m \
  --keep-yearly 5 \
  --prune

echo "Checking repository integrity..."
restic check

echo "Backup job finished successfully"
