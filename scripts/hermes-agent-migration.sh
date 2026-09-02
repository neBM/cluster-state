#!/usr/bin/env bash
# Guarded, host-local state migration for the singleton Hermes gateway.
set -euo pipefail

SOURCE_HOME="/home/ben/.hermes"
SOURCE_UNIT="hermes-gateway.service"
NAMESPACE="default"
DEPLOYMENT="hermes-agent"
PVC_NAME="hermes-agent-state"
SELECTOR="app.kubernetes.io/name=hermes-agent"
IMAGE="nousresearch/hermes-agent:v2026.8.16.2@sha256:a39fc11620213e3669a327aff5c6cb1eb2b8a238c6044e33e7ef8885833d89a7"
MIGRATION_POD=""
MIGRATION_POD_UID=""
MIGRATION_OPERATION_ID=""
SQLITE_STAGING_ROOT="/var/tmp"
SQLITE_STAGING_DIR=""
KUBECTL_REQUEST_TIMEOUT="15s"
KUBECTL_OUTER_TIMEOUT="25s"
KUBECTL_WAIT_OUTER_TIMEOUT="140s"
KUBECTL_DELETE_OUTER_TIMEOUT="25s"
KUBECTL_DELETE_VERIFY_OUTER_TIMEOUT="40s"
KUBECONFIG="${HERMES_MIGRATION_KUBECONFIG:-/home/ben/.kube/config}"
export KUBECONFIG

usage() {
  cat >&2 <<'EOF'
Usage: scripts/hermes-agent-migration.sh COMMAND

Read-only:
  preflight       Check host, source unit, target resources, and singleton state
  verify-target   Require source stopped and verify the active Kubernetes target

Mutating:
  initial-sync    Copy selected mutable state; use SQLite online backups
  final-sync      Stop the source, prove it inactive, then copy final exact state
  rollback        Require candidate GitOps mode, stop target, then start source
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

check_prerequisites() {
  need_command kubectl
  need_command python3
  need_command systemctl
  need_command timeout
  need_command mktemp
  local host
  host="$(hostname -s | tr '[:upper:]' '[:lower:]')"
  [ "$host" = "hestia" ] || die "this command must run on hestia (found $host)"
  [ -d "$SOURCE_HOME" ] || die "source directory is missing: $SOURCE_HOME"
  [ -r "$KUBECONFIG" ] || die "kubeconfig is not readable: $KUBECONFIG"
  [ "$(systemctl --user show "$SOURCE_UNIT" -p LoadState --value 2>/dev/null || true)" = "loaded" ] \
    || die "source user unit is not loaded: $SOURCE_UNIT"
  kubectl get namespace "$NAMESPACE" >/dev/null
}

source_active_state() {
  local state
  state="$(systemctl --user show "$SOURCE_UNIT" -p ActiveState --value 2>/dev/null || true)"
  case "$state" in
    active|activating|reloading|deactivating|inactive|failed) printf '%s\n' "$state" ;;
    *) printf '%s\n' "unknown" ;;
  esac
}

source_may_be_active() {
  case "$(source_active_state)" in
    inactive|failed) return 1 ;;
    *) return 0 ;;
  esac
}

current_target_mode() {
  local configmap mode
  configmap="$(
    kubectl -n "$NAMESPACE" get deployment "$DEPLOYMENT" \
      -o 'jsonpath={.spec.template.spec.volumes[?(@.name=="mode")].configMap.name}' \
      2>/dev/null || true
  )"
  [ -n "$configmap" ] || { printf '%s\n' "absent"; return; }
  mode="$(
    kubectl -n "$NAMESPACE" get configmap "$configmap" \
      -o 'jsonpath={.data.mode}' 2>/dev/null || true
  )"
  case "$mode" in
    candidate|active) printf '%s\n' "$mode" ;;
    *) printf '%s\n' "unknown" ;;
  esac
}

pod_target_may_be_active() {
  local rows name phase deletion configmap mode
  if ! rows="$(
    kubectl -n "$NAMESPACE" get pods -l "$SELECTOR" \
      -o 'jsonpath={range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{.metadata.deletionTimestamp}{"|"}{.spec.volumes[?(@.name=="mode")].configMap.name}{"\n"}{end}' \
      2>/dev/null
  )"; then
    return 0
  fi
  while IFS='|' read -r name phase deletion configmap; do
    [ -n "$name" ] || continue
    case "$phase" in
      Succeeded|Failed) continue ;;
    esac
    [ -n "$configmap" ] || return 0
    mode="$(
      kubectl -n "$NAMESPACE" get configmap "$configmap" \
        -o 'jsonpath={.data.mode}' 2>/dev/null || true
    )"
    [ "$mode" = "candidate" ] || return 0
  done <<<"$rows"
  return 1
}

target_authority_may_be_active() {
  [ "$(current_target_mode)" = "active" ] && return 0
  pod_target_may_be_active
}

assert_no_dual_authority() {
  if source_may_be_active && target_authority_may_be_active; then
    die "both source and Kubernetes gateway authority are active or may be active"
  fi
}

require_target_resources() {
  kubectl -n "$NAMESPACE" get deployment "$DEPLOYMENT" >/dev/null
  kubectl -n "$NAMESPACE" get pvc "$PVC_NAME" >/dev/null
}

require_candidate_target() {
  local mode
  mode="$(current_target_mode)"
  [ "$mode" = "candidate" ] \
    || die "GitOps target mode must be candidate (found $mode)"
}

require_candidate_pods_inert() {
  if pod_target_may_be_active; then
    die "a target pod is active or has an unknown mode; refusing state copy"
  fi
}

wait_for_source_inactive() {
  local attempt state main_pid
  for attempt in $(seq 1 60); do
    state="$(source_active_state)"
    main_pid="$(systemctl --user show "$SOURCE_UNIT" -p MainPID --value 2>/dev/null || true)"
    if { [ "$state" = "inactive" ] || [ "$state" = "failed" ]; } \
      && [ "${main_pid:-unknown}" = "0" ]; then
      return 0
    fi
    sleep 1
  done
  die "source unit did not reach inactive with MainPID=0"
}

create_sqlite_staging() {
  SQLITE_STAGING_DIR="$(mktemp -d -- "${SQLITE_STAGING_ROOT}/hermes-agent-sqlite.XXXXXXXX")"
  chmod 0700 "$SQLITE_STAGING_DIR"
  timeout --foreground 3300s python3 - "$SOURCE_HOME" "$SQLITE_STAGING_DIR" <<'STAGE_SQLITE_PY'
from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import stat
import sys
from pathlib import Path

if len(sys.argv) != 3:
    raise SystemExit("source and staging paths are required")

SOURCE = Path(os.path.abspath(sys.argv[1]))
STAGING = Path(os.path.abspath(sys.argv[2]))
DATABASES = (
    "state.db",
    "hermes_state.db",
    "projects.db",
    "kanban.db",
    "memory_store.db",
    "verification_evidence.db",
    "response_store.db",
)
PROFILES = ("codexlane", "implementer", "observer", "orchestrator", "reviewer")
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
REGULAR_FLAGS = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW


def open_absolute_directory(path: Path, description: str) -> int:
    if not path.is_absolute() or any(part in {".", ".."} for part in path.parts):
        raise RuntimeError(f"{description} must be an absolute normalized path")
    descriptor = os.open("/", DIRECTORY_FLAGS)
    try:
        for part in path.parts[1:]:
            next_descriptor = os.open(part, DIRECTORY_FLAGS, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor


def classify_at(directory_fd: int, name: str) -> dict[str, object]:
    try:
        mode = os.stat(name, dir_fd=directory_fd, follow_symlinks=False).st_mode
    except FileNotFoundError:
        return {"state": "absent", "type": None}
    if stat.S_ISLNK(mode):
        path_type = "symlink"
    elif stat.S_ISREG(mode):
        path_type = "regular_file"
    elif stat.S_ISDIR(mode):
        path_type = "directory"
    else:
        path_type = "other"
    return {"state": "present", "type": path_type}


def open_directory_at(directory_fd: int, name: str, description: str) -> int:
    try:
        descriptor = os.open(name, DIRECTORY_FLAGS, dir_fd=directory_fd)
    except OSError as exc:
        raise RuntimeError(f"{description} is not a no-follow directory") from exc
    if not stat.S_ISDIR(os.fstat(descriptor).st_mode):
        os.close(descriptor)
        raise RuntimeError(f"{description} is not a directory")
    return descriptor


def open_regular_at(directory_fd: int, name: str, description: str) -> int:
    try:
        descriptor = os.open(name, REGULAR_FLAGS, dir_fd=directory_fd)
    except OSError as exc:
        raise RuntimeError(f"{description} is not a no-follow regular file") from exc
    if not stat.S_ISREG(os.fstat(descriptor).st_mode):
        os.close(descriptor)
        raise RuntimeError(f"{description} is not a regular file")
    return descriptor


def digest_descriptor(descriptor: int) -> str:
    value = hashlib.sha256()
    position = os.lseek(descriptor, 0, os.SEEK_CUR)
    try:
        os.lseek(descriptor, 0, os.SEEK_SET)
        while chunk := os.read(descriptor, 1024 * 1024):
            value.update(chunk)
    finally:
        os.lseek(descriptor, position, os.SEEK_SET)
    return value.hexdigest()


def absent_database_record() -> dict[str, object]:
    return {"state": "absent", "type": None, "size": None, "sha256": None}


def present_database_record(descriptor: int) -> dict[str, object]:
    size = os.fstat(descriptor).st_size
    if size < 0:
        raise RuntimeError("staged database has a negative size")
    return {
        "state": "present",
        "type": "regular_file",
        "size": size,
        "sha256": digest_descriptor(descriptor),
    }


source_fd = open_absolute_directory(SOURCE, "source home")
staging_fd = open_absolute_directory(STAGING, "SQLite staging directory")
try:
    try:
        STAGING.relative_to(SOURCE)
    except ValueError:
        pass
    else:
        raise RuntimeError("SQLite staging directory must be outside the source home")
    if stat.S_IMODE(os.fstat(staging_fd).st_mode) != 0o700:
        raise RuntimeError("SQLite staging directory must have mode 0700")

    def backup_database(
        source_parent_fd: int, name: str, relative: Path
    ) -> dict[str, object]:
        record = classify_at(source_parent_fd, name)
        if record["state"] == "absent":
            return absent_database_record()
        if record["type"] != "regular_file":
            raise RuntimeError(f"database is not a regular file: {relative}")
        source_database_fd = open_regular_at(
            source_parent_fd, name, f"database {relative}"
        )
        try:
            target = STAGING / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            current = target.parent
            while current != STAGING:
                os.chmod(current, 0o700)
                current = current.parent
            temporary = target.with_name(f".{target.name}.backup")
            source_db = sqlite3.connect(
                f"file:/proc/self/fd/{source_database_fd}?mode=ro",
                uri=True,
                timeout=30,
            )
            target_db = sqlite3.connect(temporary)
            try:
                source_db.backup(target_db)
                if target_db.execute("PRAGMA journal_mode=DELETE").fetchone() != (
                    "delete",
                ):
                    raise RuntimeError(
                        f"SQLite backup is not self-contained: {relative}"
                    )
                if target_db.execute("PRAGMA quick_check").fetchone() != ("ok",):
                    raise RuntimeError(f"SQLite backup quick_check failed: {relative}")
            finally:
                target_db.close()
                source_db.close()
            os.chmod(temporary, 0o600)
            os.replace(temporary, target)
            target_parent_fd = open_absolute_directory(
                target.parent, "staging database parent"
            )
            try:
                for suffix in ("-wal", "-shm"):
                    if (
                        classify_at(target_parent_fd, f"{target.name}{suffix}")["state"]
                        != "absent"
                    ):
                        raise RuntimeError(
                            f"SQLite backup retained a {suffix} sidecar: {relative}"
                        )
                target_fd = open_regular_at(
                    target_parent_fd, target.name, f"staged database {relative}"
                )
                try:
                    return present_database_record(target_fd)
                finally:
                    os.close(target_fd)
            finally:
                os.close(target_parent_fd)
        finally:
            os.close(source_database_fd)

    top_database_records: dict[str, object] = {}
    profile_records: dict[str, object] = {}
    manifest: dict[str, object] = {
        "version": 1,
        "databases": top_database_records,
        "profiles": profile_records,
    }
    for name in DATABASES:
        top_database_records[name] = backup_database(source_fd, name, Path(name))

    profiles_parent_record = classify_at(source_fd, "profiles")
    profiles_fd: int | None = None
    if profiles_parent_record["state"] == "present":
        if profiles_parent_record["type"] != "directory":
            raise RuntimeError("source profiles parent is not a regular directory")
        profiles_fd = open_directory_at(source_fd, "profiles", "source profiles parent")
    try:
        for profile in PROFILES:
            profile_record = (
                classify_at(profiles_fd, profile)
                if profiles_fd is not None
                else {"state": "absent", "type": None}
            )
            if (
                profile_record["state"] == "present"
                and profile_record["type"] != "directory"
            ):
                raise RuntimeError(f"profile is not a regular directory: {profile}")
            database_records = {}
            if profile_record["state"] == "present":
                if profiles_fd is None:
                    raise RuntimeError("present profile lacks its contained parent")
                profile_fd = open_directory_at(
                    profiles_fd, profile, f"source profile {profile}"
                )
                try:
                    for name in DATABASES:
                        relative = Path("profiles") / profile / name
                        database_records[name] = backup_database(
                            profile_fd, name, relative
                        )
                finally:
                    os.close(profile_fd)
            else:
                database_records = {
                    name: absent_database_record() for name in DATABASES
                }
            profile_records[profile] = {
                **profile_record,
                "databases": database_records,
            }
    finally:
        if profiles_fd is not None:
            os.close(profiles_fd)

    manifest_path = STAGING / ".manifest.json"
    manifest_temporary = STAGING / ".manifest.json.tmp"
    with manifest_temporary.open("x", encoding="utf-8") as stream:
        json.dump(
            manifest,
            stream,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        )
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(manifest_temporary, 0o600)
    os.replace(manifest_temporary, manifest_path)
    os.fsync(staging_fd)
    complete_fd = os.open(
        ".complete",
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
        0o600,
        dir_fd=staging_fd,
    )
    try:
        os.fsync(complete_fd)
    finally:
        os.close(complete_fd)
    os.fsync(staging_fd)
finally:
    os.close(staging_fd)
    os.close(source_fd)
STAGE_SQLITE_PY
}

new_migration_operation_id() {
  python3 -c 'import secrets; print(secrets.token_hex(16))'
}

create_migration_pod() {
  local sqlite_mount_yaml="" sqlite_volume_yaml=""
  local create_succeeded=0 identity uid operation extra
  [ -z "$MIGRATION_POD" ] || die "migration Pod ownership handle is already assigned"
  [ -z "$MIGRATION_POD_UID" ] || die "migration Pod UID handle is already assigned"
  [ -z "$MIGRATION_OPERATION_ID" ] || die "migration operation handle is already assigned"
  MIGRATION_OPERATION_ID="$(new_migration_operation_id)"
  [[ "$MIGRATION_OPERATION_ID" =~ ^[0-9a-f]{32}$ ]] \
    || die "failed to create a cryptographic migration operation identity"
  MIGRATION_POD="hermes-agent-migration-${MIGRATION_OPERATION_ID}"
  if [ -n "$SQLITE_STAGING_DIR" ]; then
    sqlite_mount_yaml='    - name: sqlite-backups
      mountPath: /sqlite-backups
      readOnly: true'
    sqlite_volume_yaml="  - name: sqlite-backups
    hostPath:
      path: ${SQLITE_STAGING_DIR}
      type: Directory"
  fi
  if timeout --foreground "$KUBECTL_OUTER_TIMEOUT" \
    kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" create -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${MIGRATION_POD}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: hermes-agent-migration
    hermes-agent-migration-operation: ${MIGRATION_OPERATION_ID}
spec:
  activeDeadlineSeconds: 3600
  automountServiceAccountToken: false
  nodeSelector:
    kubernetes.io/hostname: hestia
  restartPolicy: Never
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: migration
    image: ${IMAGE}
    imagePullPolicy: IfNotPresent
    command:
    - /bin/sh
    - -ec
    - exec sleep 3600
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      runAsUser: 0
      capabilities:
        drop:
        - ALL
        add:
        - CHOWN
        - DAC_OVERRIDE
        - FOWNER
        - FSETID
    volumeMounts:
    - name: source
      mountPath: /source
      readOnly: true
    - name: target
      mountPath: /target
    - name: tmp
      mountPath: /tmp
${sqlite_mount_yaml}
  volumes:
  - name: source
    hostPath:
      path: ${SOURCE_HOME}
      type: Directory
  - name: target
    persistentVolumeClaim:
      claimName: ${PVC_NAME}
  - name: tmp
    emptyDir: {}
${sqlite_volume_yaml}
EOF
  then
    create_succeeded=1
  fi
  if ! identity="$(
    timeout --foreground "$KUBECTL_OUTER_TIMEOUT" \
      kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" -n "$NAMESPACE" \
      get pod "$MIGRATION_POD" --ignore-not-found \
      -o 'go-template={{.metadata.uid}}{{"|"}}{{index .metadata.labels "hermes-agent-migration-operation"}}'
  )"; then
    die "migration Pod create result is ambiguous; retained operation identity: $MIGRATION_POD"
  fi
  if [ -z "$identity" ]; then
    die "migration Pod create did not produce an observable owned Pod: $MIGRATION_POD"
  fi
  IFS='|' read -r uid operation extra <<<"$identity"
  if [ -z "$uid" ] || [ "$operation" != "$MIGRATION_OPERATION_ID" ] || [ -n "$extra" ]; then
    die "migration Pod identity differs from the retained operation: $MIGRATION_POD"
  fi
  MIGRATION_POD_UID="$uid"
  if [ "$create_succeeded" -ne 1 ]; then
    die "migration Pod create failed after admission; cleanup owns $MIGRATION_POD"
  fi
  if ! timeout --foreground "$KUBECTL_WAIT_OUTER_TIMEOUT" \
    kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" -n "$NAMESPACE" \
      wait --for=condition=Ready "pod/$MIGRATION_POD" --timeout=120s; then
    timeout --foreground "$KUBECTL_OUTER_TIMEOUT" \
      kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" -n "$NAMESPACE" \
        describe "pod/$MIGRATION_POD" >&2 || true
    die "migration pod did not become ready"
  fi
}

delete_migration_pod_uid_precondition() {
  local pod="$1" uid="$2"
  [[ "$pod" =~ ^hermes-agent-migration-[0-9a-f]{32}$ ]] \
    || { printf 'WARNING: refusing invalid migration Pod name for UID deletion\n' >&2; return 1; }
  [[ "$uid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    || { printf 'WARNING: refusing invalid migration Pod UID\n' >&2; return 1; }
  if timeout --foreground "$KUBECTL_OUTER_TIMEOUT" kubectl delete --help 2>/dev/null \
    | python3 -c 'import sys; raise SystemExit(0 if "--preconditions" in sys.stdin.read() else 1)'; then
    timeout --foreground "$KUBECTL_DELETE_OUTER_TIMEOUT" \
      kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" -n "$NAMESPACE" \
      delete pod "$pod" --preconditions="uid=$uid" \
      --grace-period=0 --force --wait=false >/dev/null
  else
    printf '{"apiVersion":"v1","kind":"DeleteOptions","gracePeriodSeconds":0,"preconditions":{"uid":"%s"},"propagationPolicy":"Foreground"}\n' "$uid" \
      | timeout --foreground "$KUBECTL_DELETE_OUTER_TIMEOUT" \
        kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" \
        delete --raw="/api/v1/namespaces/${NAMESPACE}/pods/${pod}" -f - >/dev/null
  fi
}

cleanup_migration_pod() {
  local pod identity uid operation extra remaining
  [ -n "$MIGRATION_POD" ] || return 0
  pod="$MIGRATION_POD"
  if ! identity="$(
    timeout --foreground "$KUBECTL_OUTER_TIMEOUT" \
      kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" -n "$NAMESPACE" \
      get pod "$pod" --ignore-not-found \
      -o 'go-template={{.metadata.uid}}{{"|"}}{{index .metadata.labels "hermes-agent-migration-operation"}}'
  )"; then
    printf 'WARNING: unable to read migration Pod identity before deletion: %s\n' "$pod" >&2
    return 1
  fi
  if [ -z "$identity" ]; then
    MIGRATION_POD=""
    MIGRATION_POD_UID=""
    MIGRATION_OPERATION_ID=""
    return 0
  fi
  IFS='|' read -r uid operation extra <<<"$identity"
  if [ -z "$uid" ] || [ -n "$extra" ] \
    || [ -z "$MIGRATION_OPERATION_ID" ] \
    || [ "$operation" != "$MIGRATION_OPERATION_ID" ]; then
    printf 'WARNING: migration Pod operation identity differs; refusing deletion: %s\n' "$pod" >&2
    return 1
  fi
  if [ -n "$MIGRATION_POD_UID" ] && [ "$uid" != "$MIGRATION_POD_UID" ]; then
    printf 'WARNING: migration Pod UID differs; refusing deletion: %s\n' "$pod" >&2
    return 1
  fi
  MIGRATION_POD_UID="$uid"
  if ! delete_migration_pod_uid_precondition "$pod" "$MIGRATION_POD_UID"; then
    printf 'WARNING: migration Pod UID-preconditioned deletion failed: %s\n' "$pod" >&2
  fi
  timeout --foreground "$KUBECTL_DELETE_VERIFY_OUTER_TIMEOUT" \
    kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" -n "$NAMESPACE" \
      wait --for=delete "pod/$pod" --timeout=30s >/dev/null 2>&1 || true
  if ! remaining="$(
    timeout --foreground "$KUBECTL_OUTER_TIMEOUT" \
      kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" -n "$NAMESPACE" \
      get pod "$pod" --ignore-not-found \
      -o 'go-template={{.metadata.uid}}{{"|"}}{{index .metadata.labels "hermes-agent-migration-operation"}}'
  )"; then
    printf 'WARNING: unable to verify migration Pod absence: %s\n' "$pod" >&2
    return 1
  fi
  if [ -n "$remaining" ]; then
    printf 'WARNING: migration Pod still exists or was replaced: %s\n' "$pod" >&2
    return 1
  fi
  MIGRATION_POD=""
  MIGRATION_POD_UID=""
  MIGRATION_OPERATION_ID=""
}

cleanup_sqlite_staging() {
  [ -n "$SQLITE_STAGING_DIR" ] || return 0
  case "$SQLITE_STAGING_DIR" in
    "$SQLITE_STAGING_ROOT"/hermes-agent-sqlite.*)
      if ! rm -rf -- "$SQLITE_STAGING_DIR"; then
        printf 'WARNING: failed to remove SQLite staging directory\n' >&2
        return 1
      fi
      ;;
    *)
      printf 'WARNING: refusing unexpected SQLite staging cleanup path\n' >&2
      return 1
      ;;
  esac
  SQLITE_STAGING_DIR=""
}

cleanup_migration_resources() {
  local status=0
  if ! cleanup_migration_pod; then
    status=1
  fi
  if ! cleanup_sqlite_staging; then
    status=1
  fi
  return "$status"
}

arm_cleanup_traps() {
  trap cleanup_migration_resources EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

run_sync() {
  local phase="$1"
  timeout --foreground 3300s \
    kubectl -n "$NAMESPACE" exec -i "$MIGRATION_POD" -- python3 - "$phase" <<'SYNC_STATE_PY'
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import sqlite3
import stat
import sys
from pathlib import Path

SOURCE = Path("/source")
TARGET = Path("/target")
SQLITE_BACKUPS = Path("/sqlite-backups")
RUNTIME_UID = 10000
RUNTIME_GID = 10000
TOP_FILES = (
    "config.yaml",
    ".env",
    "auth.json",
    "SOUL.md",
    "mcp.json",
    "channel_directory.json",
    "channel_aliases.json",
    "feishu_comment_pairing.json",
    "webhook_subscriptions.json",
    "matrix_threads.json",
    "grafana_webhook_hmac.secret",
)
DATABASES = (
    "state.db",
    "hermes_state.db",
    "projects.db",
    "kanban.db",
    "memory_store.db",
    "verification_evidence.db",
    "response_store.db",
)
TOP_DIRS = (
    "sessions",
    "skills",
    "plugins",
    "cron",
    "memories",
    "platforms",
    "mcp-tokens",
    "scripts",
    "plans",
    "workflows",
    "kanban",
    "pairing",
    "pending_messages",
    "hooks",
)
PROFILES = ("codexlane", "implementer", "observer", "orchestrator", "reviewer")
PROFILE_FILES = (
    "config.yaml",
    "profile.yaml",
    "profile.json",
    "SOUL.md",
    ".env",
    "auth.json",
    "secrets.yaml",
    "secrets.json",
    "mcp.json",
    "channel_directory.json",
    "channel_aliases.json",
    "feishu_comment_pairing.json",
    "webhook_subscriptions.json",
    "matrix_threads.json",
    "grafana_webhook_hmac.secret",
)
PROFILE_DIRS = (
    "sessions",
    "skills",
    "plugins",
    "cron",
    "memories",
    "platforms",
    "mcp-tokens",
    "scripts",
    "plans",
    "workflows",
    "kanban",
    "pairing",
    "pending_messages",
    "hooks",
    "secrets",
)
FORBIDDEN_NAMES = {
    ".venv",
    "venv",
    "source",
    "home",
    "cache",
    "logs",
    "backups",
    "checkpoints",
    "bin",
    "lsp",
    ".git",
    "node_modules",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    "repo",
    "repos",
    "worktree",
    "worktrees",
    "workspace",
    "workspaces",
    "tmp",
}


DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
REGULAR_FLAGS = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
MAX_MANIFEST_BYTES = 1024 * 1024
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")


def classify_path(path: Path) -> dict[str, object]:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        return {"state": "absent", "type": None}
    if stat.S_ISLNK(mode):
        path_type = "symlink"
    elif stat.S_ISREG(mode):
        path_type = "regular_file"
    elif stat.S_ISDIR(mode):
        path_type = "directory"
    else:
        path_type = "other"
    return {"state": "present", "type": path_type}


def open_absolute_directory(path: Path, description: str) -> int:
    absolute = Path(os.path.abspath(path))
    if not absolute.is_absolute() or any(
        part in {".", ".."} for part in absolute.parts
    ):
        raise RuntimeError(f"{description} must be an absolute normalized path")
    descriptor = os.open("/", DIRECTORY_FLAGS)
    try:
        for part in absolute.parts[1:]:
            next_descriptor = os.open(part, DIRECTORY_FLAGS, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor


def classify_at(directory_fd: int, name: str) -> dict[str, object]:
    try:
        mode = os.stat(name, dir_fd=directory_fd, follow_symlinks=False).st_mode
    except FileNotFoundError:
        return {"state": "absent", "type": None}
    if stat.S_ISLNK(mode):
        path_type = "symlink"
    elif stat.S_ISREG(mode):
        path_type = "regular_file"
    elif stat.S_ISDIR(mode):
        path_type = "directory"
    else:
        path_type = "other"
    return {"state": "present", "type": path_type}


def open_directory_at(directory_fd: int, name: str, description: str) -> int:
    try:
        descriptor = os.open(name, DIRECTORY_FLAGS, dir_fd=directory_fd)
    except OSError as exc:
        raise RuntimeError(f"{description} is not a no-follow directory") from exc
    if not stat.S_ISDIR(os.fstat(descriptor).st_mode):
        os.close(descriptor)
        raise RuntimeError(f"{description} is not a directory")
    return descriptor


def open_relative_regular(root_fd: int, relative: Path, description: str) -> int:
    if (
        relative.is_absolute()
        or not relative.parts
        or any(part in {"", ".", ".."} for part in relative.parts)
    ):
        raise RuntimeError(f"invalid contained path for {description}")
    parent_fd = os.dup(root_fd)
    try:
        for part in relative.parts[:-1]:
            next_fd = open_directory_at(parent_fd, part, description)
            os.close(parent_fd)
            parent_fd = next_fd
        try:
            descriptor = os.open(relative.name, REGULAR_FLAGS, dir_fd=parent_fd)
        except OSError as exc:
            raise RuntimeError(
                f"{description} is not a no-follow regular file"
            ) from exc
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            os.close(descriptor)
            raise RuntimeError(f"{description} is not a regular file")
        return descriptor
    finally:
        os.close(parent_fd)


def digest_descriptor(descriptor: int) -> str:
    value = hashlib.sha256()
    position = os.lseek(descriptor, 0, os.SEEK_CUR)
    try:
        os.lseek(descriptor, 0, os.SEEK_SET)
        while chunk := os.read(descriptor, 1024 * 1024):
            value.update(chunk)
    finally:
        os.lseek(descriptor, position, os.SEEK_SET)
    return value.hexdigest()


def read_bounded_descriptor(descriptor: int, maximum: int) -> bytes:
    size = os.fstat(descriptor).st_size
    if size < 0 or size > maximum:
        raise RuntimeError("SQLite staging manifest size is invalid")
    os.lseek(descriptor, 0, os.SEEK_SET)
    chunks = []
    remaining = maximum + 1
    while remaining:
        chunk = os.read(descriptor, min(64 * 1024, remaining))
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    payload = b"".join(chunks)
    if len(payload) > maximum:
        raise RuntimeError("SQLite staging manifest exceeds its size bound")
    return payload


def reject_duplicate_object_pairs(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def reject_nonfinite_constant(value: str) -> object:
    raise ValueError(f"non-finite JSON constant: {value}")


def database_record_identity(record: dict[str, object]) -> dict[str, object]:
    return {"state": record["state"], "type": record["type"]}


def require_manifest_database_record(
    value: object, description: str
) -> dict[str, object]:
    if type(value) is not dict or set(value) != {"state", "type", "size", "sha256"}:
        raise RuntimeError(f"invalid SQLite staging manifest record: {description}")
    state = value["state"]
    path_type = value["type"]
    size = value["size"]
    sha256 = value["sha256"]
    if state == "absent" and path_type is None and size is None and sha256 is None:
        return {"state": "absent", "type": None, "size": None, "sha256": None}
    if (
        state == "present"
        and path_type == "regular_file"
        and type(path_type) is str
        and type(size) is int
        and size >= 0
        and type(sha256) is str
        and SHA256_PATTERN.fullmatch(sha256) is not None
    ):
        return {
            "state": "present",
            "type": "regular_file",
            "size": size,
            "sha256": sha256,
        }
    raise RuntimeError(f"invalid SQLite staging manifest state: {description}")


def require_manifest_profile_record(
    state: object, path_type: object, description: str
) -> dict[str, object]:
    if state == "absent" and path_type is None:
        return {"state": "absent", "type": None}
    if state == "present" and type(path_type) is str and path_type == "directory":
        return {"state": "present", "type": "directory"}
    raise RuntimeError(f"invalid SQLite staging manifest state: {description}")


def load_staging_manifest(staging_fd: int) -> dict[str, object]:
    manifest_fd = open_relative_regular(
        staging_fd, Path(".manifest.json"), "SQLite staging manifest"
    )
    try:
        try:
            manifest_text = read_bounded_descriptor(
                manifest_fd, MAX_MANIFEST_BYTES
            ).decode("utf-8")
            manifest = json.loads(
                manifest_text,
                object_pairs_hook=reject_duplicate_object_pairs,
                parse_constant=reject_nonfinite_constant,
            )
        except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
            raise RuntimeError("SQLite staging manifest is unreadable") from exc
    finally:
        os.close(manifest_fd)
    if type(manifest) is not dict or set(manifest) != {
        "version",
        "databases",
        "profiles",
    }:
        raise RuntimeError("SQLite staging manifest shape differs")
    if type(manifest["version"]) is not int or manifest["version"] != 1:
        raise RuntimeError("SQLite staging manifest version differs")
    database_values = manifest["databases"]
    if type(database_values) is not dict or set(database_values) != set(DATABASES):
        raise RuntimeError("SQLite staging top-level database membership differs")
    databases = {
        name: require_manifest_database_record(
            database_values[name], f"database {name}"
        )
        for name in DATABASES
    }
    profile_values = manifest["profiles"]
    if type(profile_values) is not dict or set(profile_values) != set(PROFILES):
        raise RuntimeError("SQLite staging profile membership differs")
    profiles = {}
    for profile in PROFILES:
        profile_value = profile_values[profile]
        if type(profile_value) is not dict or set(profile_value) != {
            "state",
            "type",
            "databases",
        }:
            raise RuntimeError(f"SQLite staging profile record differs: {profile}")
        profile_record = require_manifest_profile_record(
            profile_value["state"], profile_value["type"], f"profile {profile}"
        )
        profile_database_values = profile_value["databases"]
        if type(profile_database_values) is not dict or set(
            profile_database_values
        ) != set(DATABASES):
            raise RuntimeError(
                f"SQLite staging profile database membership differs: {profile}"
            )
        profile_databases = {
            name: require_manifest_database_record(
                profile_database_values[name], f"profile database {profile}/{name}"
            )
            for name in DATABASES
        }
        if profile_record["state"] == "absent" and any(
            record["state"] != "absent" for record in profile_databases.values()
        ):
            raise RuntimeError(
                f"absent profile has present staged databases: {profile}"
            )
        profiles[profile] = {**profile_record, "databases": profile_databases}
    return {"version": 1, "databases": databases, "profiles": profiles}


def validate_sqlite_descriptor(descriptor: int, relative: Path) -> None:
    if not stat.S_ISREG(os.fstat(descriptor).st_mode):
        raise RuntimeError(f"staged database is not regular: {relative}")
    connection = sqlite3.connect(
        f"file:/proc/self/fd/{descriptor}?mode=ro", uri=True, timeout=30
    )
    try:
        if connection.execute("PRAGMA quick_check").fetchone() != ("ok",):
            raise RuntimeError(f"staged database quick_check failed: {relative}")
        if connection.execute("PRAGMA journal_mode").fetchone() != ("delete",):
            raise RuntimeError(f"staged database is not self-contained: {relative}")
    finally:
        connection.close()


def validate_database_descriptor(
    descriptor: int, relative: Path, record: dict[str, object]
) -> None:
    stat_result = os.fstat(descriptor)
    if not stat.S_ISREG(stat_result.st_mode):
        raise RuntimeError(f"staged database is not regular: {relative}")
    if stat_result.st_size != record["size"]:
        raise RuntimeError(f"staged database size differs from manifest: {relative}")
    if digest_descriptor(descriptor) != record["sha256"]:
        raise RuntimeError(f"staged database digest differs from manifest: {relative}")
    validate_sqlite_descriptor(descriptor, relative)


def validate_source_layout(manifest: dict[str, object] | None) -> None:
    source_fd = open_absolute_directory(SOURCE, "source mount")
    try:
        for name in DATABASES:
            record = classify_at(source_fd, name)
            if record["state"] == "present" and record["type"] != "regular_file":
                raise RuntimeError(f"source database is not regular: {name}")
            if manifest is not None and record != database_record_identity(
                manifest["databases"][name]
            ):
                raise RuntimeError(f"source database drifted after staging: {name}")

        profiles_parent = classify_at(source_fd, "profiles")
        profiles_fd: int | None = None
        if profiles_parent["state"] == "present":
            if profiles_parent["type"] != "directory":
                raise RuntimeError("source profiles parent is not a regular directory")
            profiles_fd = open_directory_at(
                source_fd, "profiles", "source profiles parent"
            )
        try:
            for profile in PROFILES:
                profile_record = (
                    classify_at(profiles_fd, profile)
                    if profiles_fd is not None
                    else {"state": "absent", "type": None}
                )
                if (
                    profile_record["state"] == "present"
                    and profile_record["type"] != "directory"
                ):
                    raise RuntimeError(f"profile is not a regular directory: {profile}")
                expected_profile = manifest["profiles"][profile] if manifest else None
                if expected_profile is not None and profile_record != {
                    "state": expected_profile["state"],
                    "type": expected_profile["type"],
                }:
                    raise RuntimeError(
                        f"source profile drifted after staging: {profile}"
                    )
                if profile_record["state"] == "absent":
                    continue
                if profiles_fd is None:
                    raise RuntimeError("present profile lacks its contained parent")
                profile_fd = open_directory_at(
                    profiles_fd, profile, f"source profile {profile}"
                )
                try:
                    for name in DATABASES:
                        relative = Path("profiles") / profile / name
                        database_record = classify_at(profile_fd, name)
                        if (
                            database_record["state"] == "present"
                            and database_record["type"] != "regular_file"
                        ):
                            raise RuntimeError(
                                f"source profile database is not regular: {relative}"
                            )
                        if expected_profile is not None and database_record != (
                            database_record_identity(
                                expected_profile["databases"][name]
                            )
                        ):
                            raise RuntimeError(
                                "source profile database drifted after staging: "
                                f"{relative}"
                            )
                finally:
                    os.close(profile_fd)
        finally:
            if profiles_fd is not None:
                os.close(profiles_fd)
    finally:
        os.close(source_fd)


def scan_staging_tree(
    directory_fd: int,
    prefix: Path = Path("."),
) -> tuple[set[Path], set[Path]]:
    files: set[Path] = set()
    directories: set[Path] = set()
    for name in os.listdir(directory_fd):
        relative = Path(name) if prefix == Path(".") else prefix / name
        mode = os.stat(name, dir_fd=directory_fd, follow_symlinks=False).st_mode
        if stat.S_ISREG(mode):
            files.add(relative)
        elif stat.S_ISDIR(mode):
            directories.add(relative)
            child_fd = open_directory_at(
                directory_fd, name, f"SQLite staging directory {relative}"
            )
            try:
                child_files, child_directories = scan_staging_tree(child_fd, relative)
                files.update(child_files)
                directories.update(child_directories)
            finally:
                os.close(child_fd)
        else:
            raise RuntimeError(f"unexpected SQLite staging path type: {relative}")
    return files, directories


def verify_initial_staging() -> tuple[dict[str, object], dict[Path, int]]:
    staging_fd = open_absolute_directory(SQLITE_BACKUPS, "SQLite backup mount")
    staged_descriptors: dict[Path, int] = {}
    try:
        complete_fd = open_relative_regular(
            staging_fd, Path(".complete"), "SQLite staging completion marker"
        )
        try:
            if os.fstat(complete_fd).st_size != 0:
                raise RuntimeError("SQLite staging completion marker is not empty")
        finally:
            os.close(complete_fd)
        manifest = load_staging_manifest(staging_fd)
        validate_source_layout(manifest)

        expected_files = {Path(".complete"), Path(".manifest.json")}
        expected_directories: set[Path] = set()
        present_records: list[tuple[Path, dict[str, object]]] = []
        for name in DATABASES:
            relative = Path(name)
            record = manifest["databases"][name]
            if record["state"] == "present":
                expected_files.add(relative)
                present_records.append((relative, record))
        for profile in PROFILES:
            profile_record = manifest["profiles"][profile]
            for name in DATABASES:
                relative = Path("profiles") / profile / name
                record = profile_record["databases"][name]
                if record["state"] == "present":
                    expected_files.add(relative)
                    present_records.append((relative, record))
        for relative in expected_files:
            parent = relative.parent
            while parent != Path("."):
                expected_directories.add(parent)
                parent = parent.parent
        actual_files, actual_directories = scan_staging_tree(staging_fd)
        if actual_files != expected_files or actual_directories != expected_directories:
            raise RuntimeError("SQLite staging contents differ from manifest")

        for relative, record in present_records:
            descriptor = open_relative_regular(
                staging_fd, relative, f"staged database {relative}"
            )
            try:
                validate_database_descriptor(descriptor, relative, record)
            except BaseException:
                os.close(descriptor)
                raise
            staged_descriptors[relative] = descriptor
        return manifest, staged_descriptors
    except BaseException:
        for descriptor in staged_descriptors.values():
            os.close(descriptor)
        raise
    finally:
        os.close(staging_fd)


def remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink(missing_ok=True)
    elif path.exists():
        shutil.rmtree(path)


def ensure_target_directory(path: Path) -> None:
    try:
        relative = path.relative_to(TARGET)
    except ValueError as exc:
        raise RuntimeError(f"target path escapes PVC: {path}") from exc
    current = TARGET
    for part in relative.parts:
        current /= part
        if current.is_symlink():
            raise RuntimeError(
                f"refusing symlinked target directory: {current.relative_to(TARGET)}"
            )
        if current.exists() and not current.is_dir():
            raise RuntimeError(
                f"target parent is not a directory: {current.relative_to(TARGET)}"
            )
        current.mkdir(exist_ok=True)


def ignored_names(_directory: str, names: list[str]) -> set[str]:
    return {name for name in names if name.lower() in FORBIDDEN_NAMES}


def chown_tree(path: Path) -> None:
    os.chown(path, RUNTIME_UID, RUNTIME_GID, follow_symlinks=False)
    if path.is_dir():
        for root, directories, files in os.walk(path, followlinks=False):
            for name in directories + files:
                os.chown(
                    Path(root) / name, RUNTIME_UID, RUNTIME_GID, follow_symlinks=False
                )


def digest(path: Path) -> bytes:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.digest()


def copy_file(source: Path, target: Path) -> None:
    if source.is_symlink():
        raise RuntimeError(f"refusing symlinked file: {source.relative_to(SOURCE)}")
    if not source.exists():
        remove_path(target)
        return
    if not source.is_file():
        raise RuntimeError(
            f"selected file is not regular: {source.relative_to(SOURCE)}"
        )
    ensure_target_directory(target.parent)
    temporary = target.with_name(f".{target.name}.migration")
    remove_path(temporary)
    shutil.copy2(source, temporary)
    os.chown(temporary, RUNTIME_UID, RUNTIME_GID)
    if source.stat().st_size != temporary.stat().st_size or digest(source) != digest(
        temporary
    ):
        raise RuntimeError(f"copy verification failed: {source.relative_to(SOURCE)}")
    os.replace(temporary, target)


def copy_tree(source: Path, target: Path) -> None:
    if source.is_symlink():
        raise RuntimeError(
            f"selected directory is not a directory: {source.relative_to(SOURCE)}"
        )
    if not source.exists():
        remove_path(target)
        return
    if not source.is_dir():
        raise RuntimeError(
            f"selected directory is not a directory: {source.relative_to(SOURCE)}"
        )
    temporary = target.with_name(f".{target.name}.migration")
    remove_path(temporary)
    ensure_target_directory(temporary.parent)
    # Preserve nested links as links: never follow them into external trees.
    shutil.copytree(source, temporary, symlinks=True, ignore=ignored_names)
    chown_tree(temporary)
    remove_path(target)
    os.replace(temporary, target)


def copy_staged_descriptor(source_fd: int, target_fd: int) -> None:
    offset = 0
    while chunk := os.pread(source_fd, 1024 * 1024, offset):
        offset += len(chunk)
        view = memoryview(chunk)
        while view:
            written = os.write(target_fd, view)
            if written <= 0:
                raise RuntimeError("staged database copy made no progress")
            view = view[written:]
    os.fsync(target_fd)


def install_staged_database(
    relative: Path,
    target: Path,
    record: dict[str, object],
    staged_descriptors: dict[Path, int],
) -> None:
    if record["state"] == "absent":
        remove_path(target)
        for suffix in ("-wal", "-shm"):
            remove_path(Path(f"{target}{suffix}"))
        return
    try:
        staged_fd = staged_descriptors[relative]
    except KeyError as exc:
        raise RuntimeError(
            f"staged database descriptor is missing: {relative}"
        ) from exc
    validate_database_descriptor(staged_fd, relative, record)
    ensure_target_directory(target.parent)
    temporary = target.with_name(f".{target.name}.migration")
    remove_path(temporary)
    temporary_fd = os.open(
        temporary,
        os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
        0o600,
    )
    replaced = False
    try:
        copy_staged_descriptor(staged_fd, temporary_fd)
        validate_database_descriptor(temporary_fd, relative, record)
        os.fchmod(temporary_fd, 0o600)
        os.fchown(temporary_fd, RUNTIME_UID, RUNTIME_GID)
        os.close(temporary_fd)
        temporary_fd = -1
        os.replace(temporary, target)
        replaced = True
    finally:
        if temporary_fd >= 0:
            os.close(temporary_fd)
        if not replaced:
            remove_path(temporary)
    for suffix in ("-wal", "-shm"):
        remove_path(Path(f"{target}{suffix}"))


def copy_profile(
    profile: str,
    phase: str,
    staging_manifest: dict[str, object] | None,
    staged_descriptors: dict[Path, int],
) -> None:
    source_profile = SOURCE / "profiles" / profile
    target_profile = TARGET / "profiles" / profile
    source_record = classify_path(source_profile)
    if phase == "initial":
        if staging_manifest is None:
            raise RuntimeError("initial sync is missing its verified staging manifest")
        expected_profile = staging_manifest["profiles"][profile]
        expected_record = {
            "state": expected_profile["state"],
            "type": expected_profile["type"],
        }
        if source_record != expected_record:
            raise RuntimeError(f"source profile drifted during sync: {profile}")
    else:
        expected_profile = None
    if source_record["state"] == "absent":
        remove_path(target_profile)
        return
    if source_record["type"] != "directory":
        raise RuntimeError(f"profile is not a regular directory: {profile}")
    ensure_target_directory(target_profile.parent)
    temporary = TARGET / "profiles" / f".{profile}.migration"
    ensure_target_directory(temporary.parent)
    remove_path(temporary)
    temporary.mkdir()
    for name in PROFILE_FILES:
        copy_file(source_profile / name, temporary / name)
    for name in PROFILE_DIRS:
        copy_tree(source_profile / name, temporary / name)
    for name in DATABASES:
        if phase == "initial":
            relative = Path("profiles") / profile / name
            install_staged_database(
                relative,
                temporary / name,
                expected_profile["databases"][name],
                staged_descriptors,
            )
        else:
            for suffix in ("", "-wal", "-shm"):
                copy_file(
                    Path(f"{source_profile / name}{suffix}"),
                    Path(f"{temporary / name}{suffix}"),
                )
    chown_tree(temporary)
    remove_path(target_profile)
    os.replace(temporary, target_profile)


def copy_mutable_state(phase: str) -> None:
    if TARGET.is_symlink() or not TARGET.is_dir():
        raise RuntimeError("target PVC mount is not a regular directory")
    if phase == "initial":
        staging_manifest, staged_descriptors = verify_initial_staging()
    else:
        validate_source_layout(None)
        staging_manifest = None
        staged_descriptors = {}
    try:
        os.chown(TARGET, RUNTIME_UID, RUNTIME_GID)
        for name in TOP_FILES:
            copy_file(SOURCE / name, TARGET / name)
        for name in TOP_DIRS:
            copy_tree(SOURCE / name, TARGET / name)
        profiles_target = TARGET / "profiles"
        ensure_target_directory(profiles_target)
        os.chown(profiles_target, RUNTIME_UID, RUNTIME_GID)
        for profile in PROFILES:
            copy_profile(profile, phase, staging_manifest, staged_descriptors)
        for name in DATABASES:
            if phase == "initial":
                install_staged_database(
                    Path(name),
                    TARGET / name,
                    staging_manifest["databases"][name],
                    staged_descriptors,
                )
            else:
                for suffix in ("", "-wal", "-shm"):
                    copy_file(
                        Path(f"{SOURCE / name}{suffix}"),
                        Path(f"{TARGET / name}{suffix}"),
                    )
        os.sync()
    finally:
        for descriptor in staged_descriptors.values():
            os.close(descriptor)


phase = sys.argv[1] if len(sys.argv) == 2 else ""
if phase not in {"initial", "final"}:
    raise SystemExit("phase must be initial or final")
copy_mutable_state(phase)
print(f"selected {phase} state sync completed")
SYNC_STATE_PY
}

preflight() {
  check_prerequisites
  require_target_resources
  assert_no_dual_authority
  local source_state target_mode
  source_state="$(source_active_state)"
  target_mode="$(current_target_mode)"
  printf 'preflight ok: source=%s target-mode=%s pvc=%s/%s\n' \
    "$source_state" "$target_mode" "$NAMESPACE" "$PVC_NAME"
}

initial_sync() {
  check_prerequisites
  require_target_resources
  require_candidate_target
  require_candidate_pods_inert
  assert_no_dual_authority
  arm_cleanup_traps
  create_sqlite_staging
  require_candidate_target
  require_candidate_pods_inert
  assert_no_dual_authority
  create_migration_pod
  require_candidate_target
  require_candidate_pods_inert
  run_sync initial
  cleanup_migration_resources
  trap - EXIT INT TERM
}

final_sync() {
  check_prerequisites
  require_target_resources
  require_candidate_target
  require_candidate_pods_inert
  assert_no_dual_authority
  arm_cleanup_traps
  create_migration_pod
  require_candidate_target
  require_candidate_pods_inert
  timeout 60s systemctl --user stop "$SOURCE_UNIT"
  wait_for_source_inactive
  require_candidate_target
  require_candidate_pods_inert
  assert_no_dual_authority
  run_sync final
  cleanup_migration_resources
  trap - EXIT INT TERM
  printf 'final sync complete; source remains stopped and target remains candidate\n'
}

active_target_pod() {
  local rows name phase ready configmap mode
  rows="$(
    kubectl -n "$NAMESPACE" get pods -l "$SELECTOR" \
      -o 'jsonpath={range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"|"}{.spec.volumes[?(@.name=="mode")].configMap.name}{"\n"}{end}'
  )"
  while IFS='|' read -r name phase ready configmap; do
    [ "$phase" = "Running" ] && [ "$ready" = "True" ] || continue
    mode="$(kubectl -n "$NAMESPACE" get configmap "$configmap" -o 'jsonpath={.data.mode}' 2>/dev/null || true)"
    if [ "$mode" = "active" ]; then
      printf '%s\n' "$name"
      return 0
    fi
  done <<<"$rows"
  return 1
}

verify_target() {
  check_prerequisites
  require_target_resources
  if source_may_be_active; then
    die "source unit is active or its state is unknown"
  fi
  [ "$(current_target_mode)" = "active" ] || die "target mode is not active"
  timeout 180s kubectl -n "$NAMESPACE" rollout status "deployment/$DEPLOYMENT" --timeout=170s
  local pod
  pod="$(active_target_pod)" || die "no Ready pod is mounted to the active mode ConfigMap"
  timeout 30s kubectl -n "$NAMESPACE" exec "$pod" -- python3 -c \
    'import urllib.request; r=urllib.request.urlopen("http://127.0.0.1:8644/health", timeout=5); raise SystemExit(0 if 200 <= r.status < 300 else 1)'
  timeout 30s kubectl -n "$NAMESPACE" exec "$pod" -- /opt/hermes/.venv/bin/python -c \
    'import json, pathlib, urllib.request, yaml; config=yaml.safe_load(pathlib.Path("/opt/data/config.yaml").read_text()) or {}; key=config.get("API_SERVER_KEY"); assert key, "API_SERVER_KEY is unavailable"; request=urllib.request.Request("http://127.0.0.1:8642/health/detailed", headers={"Authorization": "Bearer "+key}); health=json.load(urllib.request.urlopen(request, timeout=5)); expected={"api_server", "feishu", "matrix", "webhook"}; states={name: (health.get("platforms", {}).get(name, {}) or {}).get("state") for name in expected}; assert health.get("status") == "ok" and all(state == "connected" for state in states.values()), f"platform health differs: {states}"'
  timeout 30s kubectl -n "$NAMESPACE" exec "$pod" -- /bin/sh -ec \
    'test -f /opt/data/config.yaml && test -d /opt/data/sessions && test -d /opt/data/cron'
  local service_type ports
  service_type="$(kubectl -n "$NAMESPACE" get service "$DEPLOYMENT" -o 'jsonpath={.spec.type}')"
  ports="$(kubectl -n "$NAMESPACE" get service "$DEPLOYMENT" -o 'jsonpath={range .spec.ports[*]}{.name}{"="}{.port}{"\n"}{end}')"
  [ "$service_type" = "ClusterIP" ] || die "target Service is not ClusterIP"
  [ "$ports" = $'api=8642\nwebhook=8644' ] || die "target Service ports differ from api=8642 and webhook=8644"
  printf 'target verified: source=inactive pod=%s webhook=healthy state=present\n' "$pod"
}

scale_target_to_zero() {
  kubectl -n "$NAMESPACE" scale "deployment/$DEPLOYMENT" --replicas=0
}

wait_for_no_target_pods() {
  if kubectl -n "$NAMESPACE" get pods -l "$SELECTOR" -o name | grep -q .; then
    kubectl -n "$NAMESPACE" wait --for=delete pod -l "$SELECTOR" --timeout=120s
  fi
  [ -z "$(kubectl -n "$NAMESPACE" get pods -l "$SELECTOR" -o name)" ] \
    || die "target pods still exist"
}

wait_for_source_active() {
  local attempt
  for attempt in $(seq 1 60); do
    [ "$(source_active_state)" = "active" ] && return 0
    sleep 1
  done
  die "source unit did not become active"
}

wait_for_source_healthy() {
  local attempt
  for attempt in $(seq 1 120); do
    if python3 -c 'import urllib.request; response=urllib.request.urlopen("http://127.0.0.1:8644/health", timeout=2); raise SystemExit(0 if 200 <= response.status < 300 else 1)' \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  die "source webhook did not become healthy"
}

rollback() {
  check_prerequisites
  require_target_resources
  require_candidate_target
  scale_target_to_zero
  wait_for_no_target_pods
  target_authority_may_be_active && die "target authority may still be active"
  timeout 60s systemctl --user start "$SOURCE_UNIT"
  wait_for_source_active
  wait_for_source_healthy
  assert_no_dual_authority
  printf 'rollback complete: target stopped in candidate mode; source active\n'
}

[ "$#" -eq 1 ] || { usage; exit 64; }
case "$1" in
  preflight) preflight ;;
  initial-sync) initial_sync ;;
  final-sync) final_sync ;;
  verify-target) verify_target ;;
  rollback) rollback ;;
  -h|--help|help) usage ;;
  *) usage; exit 64 ;;
esac
