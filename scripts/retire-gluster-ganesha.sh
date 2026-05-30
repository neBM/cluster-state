#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/retire-gluster-ganesha.sh --node <hestia|heracles|nyx|ip> [--execute]

Dry-run is the default. With --execute, the script disables residual
Gluster/Ganesha units, removes Ganesha build artifacts/logs, purges
package-managed Gluster bits, and deletes retired /data/glusterfs brick data.

Safety guards fail execution if live Kubernetes still references glusterfs-nfs,
or if the target node has active Gluster/Ganesha processes, mounts, or listener
ports.
USAGE
}

NODE=""
EXECUTE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node)
      NODE="${2:-}"
      shift 2
      ;;
    --execute)
      EXECUTE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$NODE" ]]; then
  echo "ERROR: --node is required" >&2
  usage >&2
  exit 1
fi

case "$NODE" in
  hestia|Hestia|192.168.1.5) NODE_NAME="hestia"; HOST="192.168.1.5" ;;
  heracles|Heracles|192.168.1.6) NODE_NAME="heracles"; HOST="192.168.1.6" ;;
  nyx|Nyx|192.168.1.7) NODE_NAME="nyx"; HOST="192.168.1.7" ;;
  *)
    echo "ERROR: unknown node '$NODE'; expected hestia, heracles, nyx, or their IPs" >&2
    exit 1
    ;;
esac

SSH=(/usr/bin/ssh -F /dev/null)

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

echo "=== Kubernetes storage guard ==="
require_command kubectl

if kubectl get storageclass glusterfs-nfs >/dev/null 2>&1; then
  fail "StorageClass glusterfs-nfs still exists"
fi
echo "  [ok] glusterfs-nfs StorageClass absent"

if kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.storageClassName}{"\n"}{end}' \
  | awk '$2 == "glusterfs-nfs" { found = 1 } END { exit found ? 0 : 1 }'; then
  fail "one or more PVs still use storageClassName=glusterfs-nfs"
fi
echo "  [ok] no PVs use glusterfs-nfs"

if kubectl get pvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" "}{.spec.storageClassName}{"\n"}{end}' \
  | awk '$2 == "glusterfs-nfs" { found = 1 } END { exit found ? 0 : 1 }'; then
  fail "one or more PVCs still use storageClassName=glusterfs-nfs"
fi
echo "  [ok] no PVCs use glusterfs-nfs"

if kubectl get pods -A -o yaml | grep -E 'path: (/data/glusterfs|/storage)(/|$)' >/tmp/retire-gluster-pods.$$; then
  cat /tmp/retire-gluster-pods.$$ >&2
  rm -f /tmp/retire-gluster-pods.$$
  fail "live pod hostPath references /data/glusterfs or /storage"
fi
rm -f /tmp/retire-gluster-pods.$$
echo "  [ok] no live pod hostPath references /data/glusterfs or /storage"

echo "=== Remote node guard: $NODE_NAME ($HOST) ==="
"${SSH[@]}" "$HOST" "sudo NODE_NAME='$NODE_NAME' EXECUTE='$EXECUTE' bash -s" <<'REMOTE'
set -euo pipefail

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

lower_hostname="$(hostname -s | tr '[:upper:]' '[:lower:]')"
if [[ "$lower_hostname" != "$NODE_NAME" ]]; then
  fail "connected to $lower_hostname, expected $NODE_NAME"
fi

echo "  [node] $(hostname -f 2>/dev/null || hostname)"

echo "  [check] services inactive"
active_services=()
for unit in glusterd nfs-ganesha nfs-ganesha-local; do
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    active_services+=("$unit")
  fi
done
if [[ ${#active_services[@]} -gt 0 ]]; then
  printf 'Active retired service: %s\n' "${active_services[@]}" >&2
  fail "retired services are active"
fi
echo "    ok"

echo "  [check] no Gluster/Ganesha processes"
if pgrep -af '(^|/)(glusterd|glusterfsd|ganesha\.nfsd)( |$)' >/tmp/retired-storage-procs 2>/dev/null; then
  cat /tmp/retired-storage-procs >&2
  rm -f /tmp/retired-storage-procs
  fail "retired storage processes are running"
fi
rm -f /tmp/retired-storage-procs
echo "    ok"

echo "  [check] no retired storage mounts"
if findmnt /storage >/dev/null 2>&1; then
  findmnt /storage >&2
  fail "/storage is still mounted"
fi
if mount | grep -Ei 'gluster|ganesha' >/tmp/retired-storage-mounts; then
  cat /tmp/retired-storage-mounts >&2
  rm -f /tmp/retired-storage-mounts
  fail "Gluster/Ganesha mount still present"
fi
rm -f /tmp/retired-storage-mounts
echo "    ok"

echo "  [check] no retired storage listener ports"
if ss -ltnup | grep -E ':(2049|24007|24008|38465|38466|38467)\b' >/tmp/retired-storage-listeners; then
  cat /tmp/retired-storage-listeners >&2
  rm -f /tmp/retired-storage-listeners
  fail "retired storage listener ports are active"
fi
rm -f /tmp/retired-storage-listeners
echo "    ok"

echo "  [inventory] disk use before cleanup"
df -h /
for path in /data/glusterfs /var/log/ganesha /etc/ganesha /usr/local/bin/ganesha.nfsd; do
  if [[ -e "$path" ]]; then
    du -sh "$path" 2>/dev/null || ls -ld "$path"
  fi
done

if [[ "$EXECUTE" != "true" ]]; then
  echo "  [dry-run] would disable retired units, remove Ganesha artifacts/logs, purge Gluster packages, and delete /data/glusterfs if present"
  exit 0
fi

echo "  [execute] disabling retired units"
for unit in \
  nfs-ganesha nfs-ganesha-local glusterd glustereventsd gluster-ta-volume \
  glusterfssharedstorage glusterfs-metrics glusterfs-snapshot \
  glusterfs-metrics.timer glusterfs-snapshot.timer; do
  systemctl disable --now "$unit" >/dev/null 2>&1 || true
done

echo "  [execute] removing Ganesha artifacts and logs"
rm -rf \
  /etc/ganesha \
  /var/log/ganesha \
  /usr/local/bin/ganesha.nfsd \
  /usr/local/sbin/ganesha.nfsd \
  /usr/local/var/run/ganesha \
  /usr/local/var/lib/nfs/ganesha \
  /usr/local/lib/ganesha \
  /usr/local/lib64/ganesha \
  /usr/local/etc/ganesha

if [[ -e /data/glusterfs ]]; then
  echo "  [execute] deleting retired /data/glusterfs"
  if command -v btrfs >/dev/null 2>&1 && btrfs subvolume show /data/glusterfs >/dev/null 2>&1; then
    btrfs subvolume delete /data/glusterfs
  else
    rm -rf --one-file-system /data/glusterfs
  fi
fi

echo "  [execute] purging package-managed Gluster components where installed"
if command -v apt-get >/dev/null 2>&1; then
  installed=()
  for pkg in \
    glusterfs-cli glusterfs-client glusterfs-common glusterfs-server \
    libgfapi0 libgfchangelog0 libgfrpc0 libgfxdr0 libglusterfs-dev libglusterfs0; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
      installed+=("$pkg")
    fi
  done
  if [[ ${#installed[@]} -gt 0 ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "${installed[@]}"
  fi
elif command -v dnf >/dev/null 2>&1; then
  installed=()
  for pkg in glusterfs glusterfs-client-xlators glusterfs-fuse libglusterfs-devel libglusterfs0; do
    if rpm -q "$pkg" >/dev/null 2>&1; then
      installed+=("$pkg")
    fi
  done
  if [[ ${#installed[@]} -gt 0 ]]; then
    dnf remove -y "${installed[@]}"
  fi
fi

echo "  [verify] final state"
if pgrep -af '(^|/)(glusterd|glusterfsd|ganesha\.nfsd)( |$)' >/tmp/retired-storage-procs 2>/dev/null; then
  cat /tmp/retired-storage-procs >&2
  rm -f /tmp/retired-storage-procs
  fail "retired storage processes remain after cleanup"
fi
rm -f /tmp/retired-storage-procs

if [[ -e /data/glusterfs ]]; then
  fail "/data/glusterfs still exists after cleanup"
fi

df -h /
echo "  [done] $NODE_NAME retired storage cleanup complete"
REMOTE
