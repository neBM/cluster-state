#!/bin/bash
# Watches the GlusterFS client log for brick reconnection events.
# When a brick reconnects, restarts nfs-ganesha-local.service on the host
# (via nsenter into PID 1's namespaces) to reset the libgfapi connection.
#
# Why this is needed:
#   NFS-Ganesha's FSAL_GLUSTER uses libgfapi to talk directly to GlusterFS.
#   When a brick disconnects and reconnects, the FUSE-mounted client recovers
#   automatically, but libgfapi gets stuck in a bad state. The stale connection
#   causes NFS4ERR_IO on cross-directory hard link operations (nfs4_op_link),
#   which breaks git's quarantine object promotion and appears to callers as
#   "unable to migrate objects to permanent storage".
#
#   Restarting NFS-Ganesha forces a fresh libgfapi reconnect to all bricks.
#
# Health watchdog (background):
#   A second failure mode exists where Ganesha's FSAL_GLUSTER thread hangs on
#   a libgfapi call without any brick disconnecting — so no reconnect event is
#   logged and the watcher above never fires. Processes waiting on NFS I/O enter
#   uninterruptible D state; SIGKILL cannot reach them; load average spikes.
#
#   The watchdog detects this by counting D-state processes on the host (visible
#   via /proc because the pod runs with host_pid=true). More than D_STATE_THRESHOLD
#   processes persisting in D state across D_STATE_DURATION_S consecutive seconds
#   indicates a node-level I/O hang rather than transient disk activity, and
#   triggers a Ganesha restart.

set -uo pipefail

GLUSTER_LOG=/host/var/log/glusterfs/storage.log
COOLDOWN=30
LAST_RESTART_FILE=/tmp/last_restart

# Watchdog tuning:
# Require more than this many D-state processes before treating it as a hang.
# Normal transient disk I/O rarely exceeds 2-3 simultaneous D-state processes.
D_STATE_THRESHOLD=3
# Require D-state count to remain elevated for this many seconds before acting.
# This filters out legitimate bursts (e.g. fsync storms, backup I/O).
D_STATE_DURATION_S=300

echo 0 > "${LAST_RESTART_FILE}"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

restart_ganesha() {
  local reason="$1"
  local now
  now=$(date +%s)
  local last
  last=$(cat "${LAST_RESTART_FILE}")
  local elapsed=$(( now - last ))

  if [ "${elapsed}" -lt "${COOLDOWN}" ]; then
    log "Restart requested (${reason}) but in cooldown (${elapsed}s < ${COOLDOWN}s), skipping"
    return
  fi

  log "Restarting nfs-ganesha-local.service: ${reason}"
  if nsenter -t 1 -m -u -i -n -- systemctl restart nfs-ganesha-local.service; then
    date +%s > "${LAST_RESTART_FILE}"
    log "nfs-ganesha-local.service restarted successfully"
  else
    log "ERROR: failed to restart nfs-ganesha-local.service (exit $?)"
  fi
}

# ---------------------------------------------------------------------------
# Background health watchdog
# ---------------------------------------------------------------------------
# Counts D-state (uninterruptible sleep) processes on the host via /proc.
# /proc is the host's proc because the pod runs with host_pid=true.
# Does NOT probe the NFS mount — any such probe would itself enter D state
# if Ganesha is hung, defeating the purpose.
# ---------------------------------------------------------------------------
watchdog() {
  local elevated_since=0

  log "Health watchdog started (threshold=${D_STATE_THRESHOLD} procs, duration=${D_STATE_DURATION_S}s)"

  while true; do
    sleep 60

    # Count processes currently in D (uninterruptible sleep) state.
    # /proc/PID/stat field 3 is the single-character state.
    local d_count
    d_count=$(awk '{if ($3 == "D") count++} END {print count+0}' /proc/[0-9]*/stat 2>/dev/null)

    if [ "${d_count}" -gt "${D_STATE_THRESHOLD}" ]; then
      if [ "${elevated_since}" -eq 0 ]; then
        elevated_since=$(date +%s)
        log "Watchdog: D-state count elevated (${d_count} > ${D_STATE_THRESHOLD}), monitoring..."
      else
        local now
        now=$(date +%s)
        local duration=$(( now - elevated_since ))
        log "Watchdog: D-state count still elevated (${d_count} procs, ${duration}s)"

        if [ "${duration}" -ge "${D_STATE_DURATION_S}" ]; then
          restart_ganesha "D-state count ${d_count} elevated for ${duration}s"
          elevated_since=0
        fi
      fi
    else
      if [ "${elevated_since}" -ne 0 ]; then
        log "Watchdog: D-state count back to normal (${d_count}), resetting"
      fi
      elevated_since=0
    fi
  done
}

watchdog &
WATCHDOG_PID=$!
log "Health watchdog running (pid=${WATCHDOG_PID})"

# ---------------------------------------------------------------------------
# Main loop: GlusterFS reconnect watcher
# ---------------------------------------------------------------------------
log "Starting GlusterFS reconnect watcher (log=${GLUSTER_LOG}, cooldown=${COOLDOWN}s)"

# Wait for the log file to appear (GlusterFS client may not be running yet)
while [ ! -f "${GLUSTER_LOG}" ]; do
  log "Waiting for ${GLUSTER_LOG} to appear..."
  sleep 10
done

log "Watching ${GLUSTER_LOG}"

# -n 0: start from end so historical entries at startup don't trigger restarts
# -F:   follow by name so log rotation is handled transparently
tail -n 0 -F "${GLUSTER_LOG}" 2>/dev/null | while IFS= read -r line; do
  if echo "${line}" | grep -q "Connected, attached to remote volume"; then
    log "Brick reconnect detected: ${line}"
    log "Sleeping 5s to allow GlusterFS to stabilise..."
    sleep 5
    restart_ganesha "GlusterFS brick reconnect"
  fi
done
