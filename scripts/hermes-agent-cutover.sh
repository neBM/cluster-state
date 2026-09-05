#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SOURCE_HOME=/home/ben/.hermes
SOURCE_UNIT=hermes-gateway.service
KUBECONFIG=/home/ben/.kube/config
NAMESPACE=default
PVC=hermes-agent-state
DEPLOYMENT=hermes-agent
FLUX_NAMESPACE=flux-system
LOCAL_PATH_PREFIX=/var/lib/rancher/k3s/storage/
DESTINATION=
REVISION=
SOURCE_TOUCHED=false
ACTIVATION_ATTEMPTED=false
SQLITE_LIST=
export KUBECONFIG

usage() {
  printf 'Usage: %s preflight | %s cutover main@sha1:<40-hex-sha>\n' "$0" "$0" >&2
}

die() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
k() { kubectl "$@"; }
sprop() { systemctl --user show "$SOURCE_UNIT" -p "$1" --value; }

source_has_planned_stop_hook() {
  local exec_stop
  exec_stop="$(timeout 10s systemctl --user show "$SOURCE_UNIT" --property=ExecStop --value)" || return 1
  [[ "$exec_stop" =~ \{[[:space:]]+path=([^[:space:]\;]+)[[:space:]]*\;[[:space:]]*argv\[\]=([^[:space:]\;]+)[[:space:]]+-m[[:space:]]+hermes_systemd_planned_stop[[:space:]]+\$MAINPID[[:space:]]*\; ]] || return 1
  [[ "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]]
}

source_active() {
  [[ "$(sprop ActiveState)" == active && "$(sprop MainPID)" =~ ^[1-9][0-9]*$ ]]
}

source_inactive() {
  [[ "$(sprop ActiveState)" == inactive && "$(sprop MainPID)" == 0 ]]
}

wait_for_source_health() {
  local deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    source_active && curl --fail --silent --max-time 1 http://127.0.0.1:8644/health >/dev/null && return 0
    sleep 1
  done
  return 1
}

target_zero() {
  local pods replicas
  replicas="$(k -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o jsonpath='{.spec.replicas}')"
  pods="$(k -n "$NAMESPACE" get pods -l app.kubernetes.io/name=hermes-agent -o name)"
  [[ "$replicas" == 0 && -z "$pods" ]]
}

resolve_destination() {
  local pvc_state pv storage reclaim path pv_storage claim_namespace claim_name nodes relative
  pvc_state="$(k -n "$NAMESPACE" get pvc "$PVC" -o 'jsonpath={.status.phase}{"|"}{.spec.volumeName}{"|"}{.spec.storageClassName}')"
  IFS='|' read -r pvc_state pv storage <<<"$pvc_state"
  [[ "$pvc_state" == Bound && -n "$pv" && "$storage" == local-path-retain ]] || die "PVC is not Bound with local-path-retain"
  reclaim="$(k get pv "$pv" -o 'jsonpath={.spec.persistentVolumeReclaimPolicy}{"|"}{.spec.hostPath.path}{"|"}{.spec.storageClassName}{"|"}{.spec.claimRef.namespace}{"|"}{.spec.claimRef.name}{"|"}{.spec.nodeAffinity.required.nodeSelectorTerms[*].matchExpressions[*].values[*]}')"
  IFS='|' read -r reclaim path pv_storage claim_namespace claim_name nodes <<<"$reclaim"
  [[ "$reclaim" == Retain && "$pv_storage" == local-path-retain ]] || die "PV is not a retained local-path volume"
  [[ "$claim_namespace" == "$NAMESPACE" && "$claim_name" == "$PVC" ]] || die "PV claim reference differs"
  [[ "$nodes" == hestia ]] || die "PV is not placed only on hestia"
  [[ "$path" == "$LOCAL_PATH_PREFIX"* ]] || die "PV hostPath is outside the local-path storage root"
  relative="${path#"$LOCAL_PATH_PREFIX"}"
  [[ "$relative" == pvc-*_default_hermes-agent-state && "$relative" != */* ]] || die "PV hostPath name differs"
  sudo -n test -d "$path" || die "PV hostPath is not an existing directory"
  DESTINATION="$path"
}

preflight() {
  local command
  [[ "$(hostname -s | tr '[:upper:]' '[:lower:]')" == hestia ]] || die "cutover must run on hestia"
  [[ -d "$SOURCE_HOME" && -r "$KUBECONFIG" ]] || die "source home or fixed kubeconfig is unavailable"
  for command in curl hostname kubectl python3 rsync sqlite3 sudo systemctl timeout; do need "$command"; done
  sudo -n true || die "passwordless sudo is unavailable"
  source_active || die "source Hermes service is not active with a nonzero MainPID"
  source_has_planned_stop_hook || die "loaded source unit lacks the planned-stop ExecStop hook"
  curl --fail --silent --show-error --max-time 5 http://127.0.0.1:8644/health >/dev/null || die "source health check failed"
  resolve_destination
  target_zero || die "target Deployment or Pods are not zero"
  printf 'preflight ok: source active with planned-stop hook; target inactive; retained PVC is local on hestia\n'
}

require_cutover_gate() {
  local name
  for name in cluster-state apps observability-ui; do
    [[ "$(k -n "$FLUX_NAMESPACE" get kustomization "$name" -o jsonpath='{.spec.suspend}')" == true ]] || die "Kustomization $name is not suspended"
  done
  [[ "$(k -n "$FLUX_NAMESPACE" get gitrepository cluster-state -o jsonpath='{.status.artifact.revision}')" == "$REVISION" ]] || die "GitRepository artifact revision differs from $REVISION"
}

suspend() {
  k -n "$FLUX_NAMESPACE" patch kustomization "$1" --type=merge -p '{"spec":{"suspend":true}}' >/dev/null
}

reconcile() {
  local name=$1 token
  token="cutover-$(date -u +%s%N)"
  k -n "$FLUX_NAMESPACE" patch kustomization "$name" --type=merge -p '{"spec":{"suspend":false}}' >/dev/null
  k -n "$FLUX_NAMESPACE" annotate --overwrite kustomization "$name" "reconcile.fluxcd.io/requestedAt=$token" >/dev/null
  k -n "$FLUX_NAMESPACE" wait kustomization "$name" --for=jsonpath='{.status.lastHandledReconcileAt}'="$token" --timeout=10m >/dev/null
  k -n "$FLUX_NAMESPACE" wait kustomization "$name" --for=condition=ready --timeout=10m >/dev/null
}

wait_for_zero() {
  local attempt pods replicas
  for ((attempt=0; attempt<60; attempt++)); do
    replicas="$(k -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o jsonpath='{.spec.replicas}' 2>/dev/null)" || return 1
    pods="$(k -n "$NAMESPACE" get pods -l app.kubernetes.io/name=hermes-agent -o name 2>/dev/null)" || return 1
    [[ "$replicas" == 0 && -z "$pods" ]] && return 0
    sleep 2
  done
  return 1
}

rollback() {
  local status=${1:-1} restored=false target_fenced=true target_zero_proven=false
  trap - ERR INT TERM
  set +e
  [[ -z "$SQLITE_LIST" ]] || rm -f -- "$SQLITE_LIST"
  if [[ "$SOURCE_TOUCHED" == true ]]; then
    suspend cluster-state || target_fenced=false
    suspend apps || target_fenced=false
    suspend observability-ui || target_fenced=false
    k -n "$NAMESPACE" scale deployment "$DEPLOYMENT" --replicas=0 >/dev/null || target_fenced=false
    if wait_for_zero; then
      target_zero_proven=true
    fi
    if [[ "$target_fenced" == true && "$target_zero_proven" == true ]]; then
      if [[ "$ACTIVATION_ATTEMPTED" == false ]]; then
        if systemctl --user start "$SOURCE_UNIT" && wait_for_source_health; then
          restored=true
        fi
      fi
    fi
  fi
  if [[ "$restored" == true ]]; then
    printf 'cutover failed before Kubernetes activation; target is stopped and Hestia Hermes was restarted with its static route unchanged\n' >&2
  elif [[ "$ACTIVATION_ATTEMPTED" == true && "$target_zero_proven" == true ]]; then
    printf 'cutover failed after Kubernetes activation attempt; target and Hestia Hermes are stopped; controller recovery must reconcile target writes and restore the Hestia webhook route before source restart\n' >&2
  elif [[ "$ACTIVATION_ATTEMPTED" == true ]]; then
    printf 'cutover failed after Kubernetes activation attempt; Hestia Hermes remains stopped and target zero is unproven; controller recovery must stop and reconcile target writes and restore the Hestia webhook route before source restart\n' >&2
  elif [[ "$SOURCE_TOUCHED" == true ]]; then
    printf 'cutover failed before Kubernetes activation; Hestia Hermes remains stopped because target-zero or restart proof failed\n' >&2
  else
    printf 'cutover failed before the source was stopped\n' >&2
  fi
  (( status == 0 )) && status=1
  exit "$status"
}

copy_state() {
  local database result count=0
  local excludes=(
    --exclude='/.git/' --exclude='/node_modules/' --exclude='.venv/' --exclude='venv/' --exclude='venvs/'
    --exclude='/source/' --exclude='/sources/' --exclude='/repo/' --exclude='/repos/' --exclude='/repositories/' --exclude='/checkout/' --exclude='/checkouts/' --exclude='/hermes-agent/' --exclude='/hermes-agent-*/'
    --exclude='.cache/' --exclude='cache/' --exclude='caches/' --exclude='audio_cache/' --exclude='image_cache/' --exclude='__pycache__/' --exclude='.pytest_cache/' --exclude='.mypy_cache/' --exclude='.ruff_cache/'
    --exclude='logs/' --exclude='*.log' --exclude='.curator_backups/' --exclude='backup/' --exclude='backups/' --exclude='snapshots/' --exclude='state-snapshots/' --exclude='checkpoints/' --exclude='review-packages/'
    --exclude='/.worktrees/' --exclude='/worktree/' --exclude='/worktrees/' --exclude='/workspace/' --exclude='/workspaces/' --exclude='/sandboxes/' --exclude='terminal-sessions/'
    --exclude='.local/share/containers/' --exclude='containers/storage/' --exclude='profiles/*/home/.cache/' --exclude='profiles/*/home/.local/' --exclude='profiles/*/home/.hermes/'
    --exclude='/state.db.corrupt-*' --exclude='/state.db.malformed-*' --exclude='/state.db.rebuilt-*' --exclude='/state-db-cutover-*' --exclude='/repair_state_db_cutover.sh'
    --exclude='tmp/' --exclude='lsp/' --exclude='bin/' --exclude='*.pid' --exclude='*.lock' --exclude='k8s-cutover-result.json'
  )
  sudo -n rsync -aHAX --delete --delete-excluded "${excludes[@]}" "$SOURCE_HOME/" "$DESTINATION/"
  SQLITE_LIST="$(mktemp)"
  sudo -n python3 - "$DESTINATION" >"$SQLITE_LIST" <<'PY'
import os, stat, sys
root = sys.argv[1]
def walk_error(error):
    raise error
for directory, directories, files in os.walk(root, onerror=walk_error, followlinks=False):
    directories[:] = [name for name in directories if not os.path.islink(os.path.join(directory, name))]
    for name in files:
        path = os.path.join(directory, name)
        if stat.S_ISREG(os.lstat(path).st_mode):
            with open(path, "rb") as stream:
                if stream.read(16) == b"SQLite format 3\0":
                    sys.stdout.buffer.write(os.fsencode(path) + b"\0")
PY
  while IFS= read -r -d '' database; do
    result="$(sudo -n sqlite3 "$database" 'PRAGMA quick_check;')"
    [[ "$result" == ok ]] || die "SQLite quick_check failed: $database"
    ((count+=1))
  done <"$SQLITE_LIST"
  rm -f -- "$SQLITE_LIST"
  SQLITE_LIST=
  sudo -n chown -R 10000:10000 "$DESTINATION"
  printf 'copied durable Hermes state; validated %d SQLite database(s)\n' "$count"
}

case "${1:-}" in
  preflight)
    [[ "$#" == 1 ]] || { usage; exit 64; }
    preflight
    ;;
  cutover)
    [[ "$#" == 2 && "$2" =~ ^main@sha1:[0-9a-f]{40}$ ]] || { usage; exit 64; }
    REVISION=$2
    preflight
    require_cutover_gate
    trap 'rollback $?' ERR
    trap 'rollback 130' INT
    trap 'rollback 143' TERM
    SOURCE_TOUCHED=true
    systemctl --user stop "$SOURCE_UNIT"
    source_inactive || die "source did not become inactive with MainPID=0"
    target_zero || die "target changed before copy"
    copy_state
    require_cutover_gate
    ACTIVATION_ATTEMPTED=true
    reconcile apps
    kubectl rollout status -n "$NAMESPACE" deployment/"$DEPLOYMENT" --timeout=10m
    cluster_ip="$(k -n "$NAMESPACE" get service "$DEPLOYMENT" -o jsonpath='{.spec.clusterIP}')"
    [[ -n "$cluster_ip" && "$cluster_ip" != None ]] || die "Hermes ClusterIP is unavailable"
    curl --fail --silent --show-error --max-time 15 "http://$cluster_ip:8644/health" >/dev/null
    reconcile observability-ui
    cluster_ip="$(k -n "$NAMESPACE" get service hermes-webhook -o jsonpath='{.spec.clusterIP}')"
    [[ -n "$cluster_ip" && "$cluster_ip" != None ]] || die "Hermes webhook ClusterIP is unavailable"
    curl --fail --silent --show-error --retry 30 --retry-all-errors --retry-delay 1 --max-time 120 "http://$cluster_ip:8644/health" >/dev/null
    reconcile cluster-state
    trap - ERR INT TERM
    printf 'cutover success: Kubernetes Hermes is healthy at %s; Hestia Hermes remains stopped\n' "$REVISION"
    ;;
  *) usage; exit 64 ;;
esac
