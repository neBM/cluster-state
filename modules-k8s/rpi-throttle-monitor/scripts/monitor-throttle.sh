#!/bin/bash
# Periodically reads the Raspberry Pi 5 throttle/undervoltage flags via
# vcgencmd (run on the host via nsenter) and logs them to stdout.
#
# Logs are collected by Grafana Alloy and shipped to Loki. Create a Grafana
# alert on container="rpi-throttle-monitor" with log line |= "throttle_warning"
# to get notified of power supply issues before they cause an unclean reboot.
#
# Throttle flag bits (Pi 4 and Pi 5):
#   0x00001  Under-voltage detected (currently)
#   0x00002  ARM frequency capped (currently)
#   0x00004  Currently throttled
#   0x00008  Soft temperature limit active (currently)
#   0x10000  Under-voltage has occurred since last reboot
#   0x20000  ARM frequency capping has occurred since last reboot
#   0x40000  Throttling has occurred since last reboot
#   0x80000  Soft temperature limit has occurred since last reboot

set -uo pipefail

INTERVAL=60

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

decode_flags() {
  local val=$1
  local events=""
  [ $(( val & 0x00001 )) -ne 0 ] && events="${events} under-voltage-now"
  [ $(( val & 0x00002 )) -ne 0 ] && events="${events} freq-capped-now"
  [ $(( val & 0x00004 )) -ne 0 ] && events="${events} throttled-now"
  [ $(( val & 0x00008 )) -ne 0 ] && events="${events} temp-limit-now"
  [ $(( val & 0x10000 )) -ne 0 ] && events="${events} under-voltage-occurred"
  [ $(( val & 0x20000 )) -ne 0 ] && events="${events} freq-cap-occurred"
  [ $(( val & 0x40000 )) -ne 0 ] && events="${events} throttled-occurred"
  [ $(( val & 0x80000 )) -ne 0 ] && events="${events} temp-limit-occurred"
  echo "${events:-none}"
}

log "Starting RPi throttle monitor (interval=${INTERVAL}s)"

while true; do
  raw=$(nsenter -t 1 -m -u -i -n -- vcgencmd get_throttled 2>&1) || {
    log "throttle_error: vcgencmd failed: ${raw}"
    sleep "${INTERVAL}"
    continue
  }

  # raw is "throttled=0xXXXXX"; strip the key to get the hex value
  flags="${raw#throttled=}"
  val=$(( flags ))

  if [ "${val}" -eq 0 ]; then
    log "throttle_ok flags=0x0"
  else
    events=$(decode_flags "${val}")
    log "throttle_warning flags=${flags} events=${events}"
  fi

  sleep "${INTERVAL}"
done
