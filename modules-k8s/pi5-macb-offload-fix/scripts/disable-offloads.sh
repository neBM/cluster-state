#!/bin/bash
# Disables TSO and scatter-gather on eth0 as a mitigation for LP#2133877:
#
#   https://bugs.launchpad.net/ubuntu/+source/linux-raspi/+bug/2133877
#
# Symptom: the Cadence GEM (macb driver) on Raspberry Pi 5 silently wedges
# its TX descriptor ring across the non-coherent RP1 PCIe link when TSO is
# used with scatter-gather. Link stays reported as up at 1Gbps/Full, ethtool
# counters show zero errors, but packets stop flowing until physical reboot.
# Affects kernel 6.17.0-1004/1006-raspi. Not present on 6.14.0-1017-raspi.
#
# Disabling both tso and sg avoids the stall path. Both are required —
# tso alone is insufficient per the LP thread.
#
# Remove this module when upstream macb fix lands and nodes are upgraded.

set -uo pipefail

INTERVAL=300
IFACE="${IFACE:-eth0}"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

# Use nsenter to run the host's ethtool in the host's network namespace,
# same pattern as rpi-throttle-monitor's vcgencmd invocation. Keeps the
# container image minimal (no need to install ethtool).
run_ethtool() {
  nsenter -t 1 -m -u -i -n -- ethtool "$@" 2>&1
}

apply_offloads() {
  run_ethtool -K "${IFACE}" tso off sg off
}

# Returns "ok" if both offloads are currently off, "drift" otherwise.
check_offloads() {
  local state
  state=$(run_ethtool -k "${IFACE}" | grep -E "^(tcp-segmentation-offload|scatter-gather):" | tr '\n' ' ')
  if echo "${state}" | grep -qE "(tcp-segmentation-offload|scatter-gather):\s+on"; then
    echo "drift: ${state}"
  else
    echo "ok: ${state}"
  fi
}

log "Starting Pi5 macb offload fix (iface=${IFACE}, interval=${INTERVAL}s, bug=LP#2133877)"

# Apply on startup.
if out=$(apply_offloads); then
  log "initial_apply: ${out:-noop}"
else
  log "initial_apply_error: ${out}"
  exit 1
fi

log "initial_state: $(check_offloads)"

# Re-apply if offloads ever drift back on (e.g. after a link reset or
# manual ethtool change). Cheap to verify; 5-minute cadence.
while sleep "${INTERVAL}"; do
  state=$(check_offloads)
  case "${state}" in
    ok:*)
      # Quiet steady-state — no log spam.
      ;;
    drift:*)
      log "drift_detected: ${state}; re-applying"
      if out=$(apply_offloads); then
        log "reapply_ok: ${out:-noop}"
      else
        log "reapply_error: ${out}"
      fi
      log "post_reapply_state: $(check_offloads)"
      ;;
  esac
done
