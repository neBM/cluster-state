#!/bin/sh
set -eu

export RESTIC_REPOSITORY=${RESTIC_REPOSITORY:-/repo}
export RESTIC_PASSWORD_FILE=${RESTIC_PASSWORD_FILE:-/secrets/password}
export RESTIC_READ_CONCURRENCY=${RESTIC_READ_CONCURRENCY:-1}

BACKUP_SCOPE=${BACKUP_SCOPE:-critical-pvc}
BACKUP_PATHS_FILE=${BACKUP_PATHS_FILE:-/config/critical-pvc-paths.txt}
LOCK_WAIT=${LOCK_WAIT:-5m}
EXCLUDES_FILE=${EXCLUDES_FILE:-/config/excludes.txt}

if [ ! -r "$BACKUP_PATHS_FILE" ]; then
  echo "ERROR: backup paths file is missing or unreadable: $BACKUP_PATHS_FILE" >&2
  exit 66
fi

set --
while IFS= read -r path || [ -n "$path" ]; do
  case "$path" in
    ''|'#'*)
      continue
      ;;
  esac

  if [ ! -e "$path" ]; then
    echo "ERROR: configured backup path does not exist: $path" >&2
    exit 66
  fi

  set -- "$@" "$path"
done < "$BACKUP_PATHS_FILE"

if [ "$#" -eq 0 ]; then
  echo "ERROR: no backup paths configured in $BACKUP_PATHS_FILE" >&2
  exit 66
fi

if ! restic snapshots --retry-lock "$LOCK_WAIT" >/dev/null 2>&1; then
  echo "Initializing restic repository..."
  restic init
fi

echo "Starting scoped critical PVC backup for scope=$BACKUP_SCOPE paths=$#"

restic backup \
  --retry-lock "$LOCK_WAIT" \
  --read-concurrency "$RESTIC_READ_CONCURRENCY" \
  --host "restic-$BACKUP_SCOPE" \
  --group-by host,paths,tags \
  --tag seaweedfs \
  --tag "$BACKUP_SCOPE" \
  --tag scheduled \
  --iexclude-file="$EXCLUDES_FILE" \
  --exclude-caches \
  --exclude-if-present .nobackup \
  "$@"

echo "Scoped critical PVC backup finished successfully"
