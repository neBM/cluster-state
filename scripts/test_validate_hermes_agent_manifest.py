#!/usr/bin/env python3
"""Focused migration-critical checks for the Hermes Agent Kubernetes slice."""

from __future__ import annotations

import hashlib
import http.server
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import urllib.parse
from pathlib import Path
from typing import NoReturn

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "apps/hermes-agent"
MIGRATION = ROOT / "scripts/hermes-agent-migration.sh"
IMAGE = (
    "nousresearch/hermes-agent:v2026.8.16.2@"
    "sha256:a39fc11620213e3669a327aff5c6cb1eb2b8a238c6044e33e7ef8885833d89a7"
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
PROFILES = ("codexlane", "implementer", "observer", "orchestrator", "reviewer")


def fail(message: str) -> NoReturn:
    raise AssertionError(message)


def require(text: str, needle: str, description: str) -> None:
    if needle not in text:
        fail(f"missing {description}: {needle!r}")


def ordered(text: str, needles: list[str], description: str) -> None:
    cursor = 0
    for needle in needles:
        position = text.find(needle, cursor)
        if position < 0:
            fail(f"incorrect {description} ordering: {needles!r}")
        cursor = position + len(needle)


def function_body(script: str, name: str) -> str:
    match = re.search(
        rf"^{re.escape(name)}\(\) \{{\n(?P<body>.*?)(?=^\}}\n)",
        script,
        flags=re.MULTILINE | re.DOTALL,
    )
    if match is None:
        fail(f"missing shell function {name}")
    return match.group("body")


def heredoc_body(script: str, delimiter: str) -> str:
    match = re.search(
        rf"<<'{re.escape(delimiter)}'\n(?P<body>.*?)\n{re.escape(delimiter)}$",
        script,
        flags=re.MULTILINE | re.DOTALL,
    )
    if match is None:
        fail(f"missing embedded Python block {delimiter}")
    return match.group("body")


def shell_function(script: str, name: str) -> str:
    return f"{name}() {{\n{function_body(script, name)}}}\n"


def directory_identity(path: Path) -> tuple[int, int]:
    metadata = path.stat(follow_symlinks=False)
    return metadata.st_dev, metadata.st_ino


def manifest_identity(path: Path) -> dict[str, int]:
    device, inode = directory_identity(path)
    return {"st_dev": device, "st_ino": inode}


def run_stage(
    source: Path,
    staging: Path,
    expected_source_identity: tuple[int, int] | None = None,
) -> subprocess.CompletedProcess[str]:
    stage_python = heredoc_body(MIGRATION.read_text(), "STAGE_SQLITE_PY")
    command = [sys.executable, "-", str(source), str(staging)]
    if "source device and inode are required" in stage_python:
        device, inode = expected_source_identity or directory_identity(source)
        command.extend((str(device), str(inode)))
    return subprocess.run(
        command,
        input=stage_python,
        text=True,
        capture_output=True,
        check=False,
    )


def run_sync(
    source: Path,
    staging: Path,
    target: Path,
    phase: str = "initial",
    expected_source_identity: tuple[int, int] | None = None,
    before_target_mutation: str | None = None,
) -> subprocess.CompletedProcess[str]:
    sync_python = heredoc_body(MIGRATION.read_text(), "SYNC_STATE_PY")
    replacements = {
        'SOURCE = Path("/source")': f"SOURCE = Path({str(source)!r})",
        'TARGET = Path("/target")': f"TARGET = Path({str(target)!r})",
        'SQLITE_BACKUPS = Path("/sqlite-backups")': (
            f"SQLITE_BACKUPS = Path({str(staging)!r})"
        ),
        "RUNTIME_UID = 10000": f"RUNTIME_UID = {os.getuid()}",
        "RUNTIME_GID = 10000": f"RUNTIME_GID = {os.getgid()}",
    }
    for old, new in replacements.items():
        if sync_python.count(old) != 1:
            fail(f"embedded sync test seam differs: {old!r}")
        sync_python = sync_python.replace(old, new)
    if before_target_mutation is not None:
        anchors = (
            ("        try:\n            os.chown(TARGET, RUNTIME_UID, RUNTIME_GID)", 12),
            ("    try:\n        os.chown(TARGET, RUNTIME_UID, RUNTIME_GID)", 8),
        )
        for anchor, indentation in anchors:
            if sync_python.count(anchor) == 1:
                prefix = " " * indentation
                indented_hook = "\n".join(
                    f"{prefix}{line}" if line else ""
                    for line in before_target_mutation.splitlines()
                )
                try_indent = " " * (indentation - 4)
                sync_python = sync_python.replace(
                    anchor,
                    f"{try_indent}try:\n{indented_hook}\n"
                    f"{prefix}os.chown(TARGET, RUNTIME_UID, RUNTIME_GID)",
                )
                break
        else:
            fail("embedded sync pre-mutation race seam differs")
    command = [sys.executable, "-", phase]
    if "expected source device and inode are required" in sync_python:
        device, inode = expected_source_identity or directory_identity(source)
        command.extend((str(device), str(inode)))
    return subprocess.run(
        command,
        input=sync_python,
        text=True,
        capture_output=True,
        check=False,
    )


def create_database(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(path) as connection:
        connection.execute("CREATE TABLE retained(value TEXT NOT NULL)")
        connection.execute("INSERT INTO retained VALUES (?)", (value,))
        connection.commit()


def seed_target_sentinel(target: Path) -> Path:
    target.mkdir()
    sentinel = target / "config.yaml"
    sentinel.write_text("target-must-remain-unchanged")
    return sentinel


def assert_rejected_before_target_mutation(
    result: subprocess.CompletedProcess[str], sentinel: Path, description: str
) -> None:
    if result.returncode == 0:
        fail(f"{description} was accepted")
    if not sentinel.is_file() or sentinel.read_text() != "target-must-remain-unchanged":
        fail(f"{description} mutated target state before rejection")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def staged_database_record(path: Path) -> dict[str, object]:
    return {
        "state": "present",
        "type": "regular_file",
        "size": path.stat().st_size,
        "sha256": sha256_file(path),
    }


def render(relative: str) -> str:
    executable = shutil.which("kustomize")
    command = (
        [executable, "build", relative]
        if executable
        else ["kubectl", "kustomize", relative]
    )
    env = os.environ.copy()
    env["KUBECONFIG"] = "/dev/null"
    result = subprocess.run(
        command,
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )
    if result.returncode:
        fail(f"{' '.join(command)} failed:\n{result.stderr}")
    return result.stdout


def validate_manifests() -> None:
    if not (APP / "kustomization.yaml").is_file():
        fail("apps/hermes-agent Kustomize package is missing")

    rendered = render("apps/hermes-agent")
    apps_rendered = render("apps")
    sources = "\n".join(path.read_text() for path in sorted(APP.glob("*.yaml")))
    deployment = (APP / "deployment-default-hermes-agent.yaml").read_text()
    service = (APP / "service-default-hermes-agent.yaml").read_text()
    pvc = (APP / "persistentvolumeclaim-default-hermes-agent-state.yaml").read_text()
    kustomization = (APP / "kustomization.yaml").read_text()

    require(apps_rendered, IMAGE, "immutable Hermes image in apps render")
    if apps_rendered.count(IMAGE) != 1:
        fail("apps render must contain the immutable Hermes image exactly once")
    require((ROOT / "apps/kustomization.yaml").read_text(), "- hermes-agent\n", "apps registration")
    if re.search(r"^kind: (Ingress|IngressRoute)\b", rendered, re.MULTILINE):
        fail("Hermes package must not render an Ingress or IngressRoute")

    require(kustomization, "- mode=candidate", "candidate default")
    if len(re.findall(r"^\s*- mode=", kustomization, re.MULTILINE)) != 1:
        fail("deployment mode must be one GitOps literal")
    require(kustomization, "name: hermes-agent-state", "generated state ConfigMap")
    require(deployment, "replicas: 1", "singleton replica count")
    require(deployment, "type: Recreate", "Recreate strategy")
    require(deployment, "kubernetes.io/hostname: hestia", "Hestia node pin")
    require(deployment, IMAGE, "immutable image")
    require(deployment, "mountPath: /opt/data", "persistent state mount")
    require(deployment, "claimName: hermes-agent-state", "state PVC binding")
    require(deployment, "exec /opt/hermes/docker/entrypoint-dispatch.sh gateway run", "active dispatcher exec")
    require(deployment, "exec sleep infinity", "inert candidate command")
    require(deployment, 'http://127.0.0.1:8644/health', "active local webhook probe")
    require(deployment, '"candidate"', "candidate probe branch")
    if re.search(r"API_SERVER_KEY|api[_-]?key|secretKeyRef", deployment, re.IGNORECASE):
        fail("Deployment probes must not embed or reference API secrets")

    require(deployment, "allowPrivilegeEscalation: false", "no privilege escalation")
    if not re.search(r"drop:\n\s+- ALL", deployment):
        fail("missing all capability drop")
    require(deployment, "type: RuntimeDefault", "RuntimeDefault seccomp")
    require(deployment, 'name: HERMES_UID\n          value: "10000"', "Hermes UID")
    require(deployment, 'name: HERMES_GID\n          value: "10000"', "Hermes GID")
    require(deployment, 'name: API_SERVER_HOST\n          value: 0.0.0.0', "ClusterIP API bind host")
    require(deployment, "mountPath: /tmp", "tmp emptyDir mount")
    require(deployment, "mountPath: /run", "run emptyDir mount")
    require(deployment, "mountPath: /dev/shm", "bounded browser shared-memory mount")
    require(deployment, "readOnlyRootFilesystem: true", "read-only image root")
    for capability in ("CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID", "KILL", "SETGID", "SETUID"):
        require(deployment, f"- {capability}", f"s6 bootstrap capability {capability}")

    require(pvc, "storageClassName: local-path-retain", "retained local storage class")
    require(pvc, "- ReadWriteOnce", "RWO access mode")
    require(pvc, "storage: 20Gi", "20Gi state request")
    storage_class = (ROOT / "infrastructure/storage/storage-classes/storageclass-local-path-retain.yaml").read_text()
    require(storage_class, "reclaimPolicy: Retain", "storage-class retention")
    require(storage_class, "volumeBindingMode: WaitForFirstConsumer", "WFFC binding")

    require(service, "type: ClusterIP", "ClusterIP service")
    expected_ports = {
        ("api", "8642", "8642"),
        ("webhook", "8644", "8644"),
    }
    actual_ports = set(
        re.findall(
            r"- name: (\w+)\n\s+port: (\d+)\n\s+protocol: TCP\n\s+targetPort: (\d+)",
            service,
        )
    )
    if actual_ports != expected_ports:
        fail(f"Service ports differ: {actual_ports!r}")
    if re.search(r"NodePort|LoadBalancer|externalIPs|hostPort", sources):
        fail("Hermes package exposes a non-ClusterIP surface")


def validate_migration_script() -> None:
    if not MIGRATION.is_file():
        fail("scripts/hermes-agent-migration.sh is missing")
    script = MIGRATION.read_text()

    for command in ("preflight", "initial-sync", "final-sync", "verify-target", "rollback"):
        require(script, f"{command})", f"{command} subcommand")
    require(script, 'SOURCE_HOME="/home/ben/.hermes"', "fixed source home")
    require(script, 'SOURCE_UNIT="hermes-gateway.service"', "source systemd unit")
    require(script, 'PVC_NAME="hermes-agent-state"', "target PVC")
    require(script, '/home/ben/.kube/config', "explicit Hestia kubeconfig")
    require(script, IMAGE, "pinned migration image")
    require(script, 'sqlite3.connect', "SQLite backup API")
    require(script, '.backup(', "SQLite online backup")
    require(script, 'SQLITE_STAGING_ROOT="/var/tmp"', "host SQLite staging root")
    require(
        function_body(script, "create_sqlite_staging"),
        'timeout --foreground 3300s python3 - \\\n'
        '    "$SOURCE_HOME" "$SQLITE_STAGING_DIR" \\\n'
        '    "$SOURCE_ROOT_DEVICE" "$SOURCE_ROOT_INODE"',
        "bounded host SQLite staging",
    )
    require(script, "mountPath: /sqlite-backups", "staged SQLite backup mount")
    require(script, "path: ${SQLITE_STAGING_DIR}", "exact staging-directory hostPath")
    if "immutable=1" in script:
        fail("migration must not bypass SQLite locking with immutable mode")
    require(script, 'state.db', "state database allowlist")
    require(script, 'verification_evidence.db', "evidence database allowlist")
    require(script, 'response_store.db', "response-store database allowlist")
    require(script, 'memory_store.db', "memory-store database allowlist")
    require(script, 'channel_directory.json', "channel directory allowlist")
    require(script, 'webhook_subscriptions.json', "webhook subscription allowlist")
    require(script, 'matrix_threads.json', "Matrix thread-state allowlist")
    require(script, 'grafana_webhook_hmac.secret', "Grafana webhook HMAC allowlist")
    for directory in (
        "sessions", "skills", "plugins", "cron", "memories", "platforms",
        "mcp-tokens", "scripts", "plans", "workflows", "kanban", "pairing",
        "pending_messages", "hooks",
    ):
        require(script, f'"{directory}"', f"durable directory {directory}")
    for profile in ("codexlane", "implementer", "observer", "orchestrator", "reviewer"):
        require(script, f'"{profile}"', f"profile {profile}")
    for excluded in (
        ".venv", "venv", "source", "home", "cache", "logs", "backups",
        "checkpoints", "bin", "lsp", ".git", "node_modules", "repo", "repos",
        "worktree", "worktrees", "workspace", "workspaces", "tmp",
    ):
        require(script, f'"{excluded}"', f"selective exclusion {excluded}")
    if re.search(r"cp\s+-a\s+[^\n]*(/source/?\.|\$SOURCE_HOME/?\.)", script):
        fail("migration script must not copy the whole source tree")

    final_sync = function_body(script, "final_sync")
    ordered(
        final_sync,
        ['systemctl --user stop "$SOURCE_UNIT"', "wait_for_source_inactive", "require_candidate_target", "run_sync final"],
        "final-sync stop/proof/copy",
    )
    rollback = function_body(script, "rollback")
    ordered(
        rollback,
        ["require_candidate_target", "scale_target_to_zero", "wait_for_no_target_pods", 'systemctl --user start "$SOURCE_UNIT"'],
        "target-first rollback",
    )
    require(script, "assert_no_dual_authority", "dual-authority fail-closed guard")
    require(script, "persistentVolumeClaim:", "migration PVC mount")
    require(script, "hostPath:", "read-only source hostPath")
    if script.count("mountPath: /source") != 1 or not re.search(
        r"- name: source\n\s+mountPath: /source\n\s+readOnly: true", script
    ):
        fail("source hostPath must remain one read-only mount")
    if script.count("mountPath: /sqlite-backups") != 1 or not re.search(
        r"- name: sqlite-backups\n\s+mountPath: /sqlite-backups\n\s+readOnly: true", script
    ):
        fail("SQLite staging hostPath must remain one read-only mount")
    require(script, "activeDeadlineSeconds:", "bounded migration pod")
    for name in (
        "KUBECTL_REQUEST_TIMEOUT",
        "KUBECTL_OUTER_TIMEOUT",
        "KUBECTL_WAIT_OUTER_TIMEOUT",
        "KUBECTL_CREATE_RECONCILE_OUTER_TIMEOUT",
        "KUBECTL_DELETE_OUTER_TIMEOUT",
        "KUBECTL_DELETE_VERIFY_OUTER_TIMEOUT",
    ):
        if not re.search(rf'^{name}="[1-9][0-9]*s"$', script, re.MULTILINE):
            fail(f"{name} must be a fixed positive production bound")
    reconcile_window = re.search(
        r'^MIGRATION_CREATE_RECONCILE_WINDOW_SECONDS="([1-9][0-9]*)"$',
        script,
        re.MULTILINE,
    )
    if reconcile_window is None or int(reconcile_window.group(1)) <= 15:
        fail("create reconciliation window must be fixed and exceed request timeout")
    operation_delete = function_body(script, "delete_migration_pod_owned_collection")
    if " -f -" in operation_delete:
        fail("migration cleanup must not claim a kubectl raw UID body is transmitted")
    require(
        operation_delete,
        'delete --raw="/api/v1/namespaces/${NAMESPACE}/pods?',
        "operation-owned DeleteCollection transport",
    )
    require(
        operation_delete,
        "labelSelector=hermes-agent-migration-operation%3D${operation}",
        "operation-label DeleteCollection selector",
    )
    require(
        operation_delete,
        "fieldSelector=metadata.name%3D${pod}",
        "exact-name DeleteCollection field selector",
    )
    require(
        operation_delete,
        'kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT"',
        "bounded DeleteCollection request",
    )
    require(
        script,
        "MIGRATION_CREATE_ABSENCE_RECONCILED",
        "dedicated create-absence reconciliation state",
    )
    require(
        function_body(script, "create_migration_pod"),
        "reject_preexisting_migration_pods",
        "stale migration operation rejection",
    )
    require(script, "trap cleanup_migration_resources", "migration resource cleanup")
    cleanup = function_body(script, "cleanup_migration_resources")
    require(cleanup, "cleanup_migration_pod", "combined pod cleanup")
    require(cleanup, "cleanup_sqlite_staging", "combined SQLite staging cleanup")
    staging_cleanup = function_body(script, "cleanup_sqlite_staging")
    if 'rm -rf -- "$SQLITE_STAGING_DIR" || true' in staging_cleanup:
        fail("SQLite staging cleanup failures must not be silently ignored")
    require(staging_cleanup, "return 1", "failed SQLite staging cleanup status")
    initial_sync = function_body(script, "initial_sync")
    ordered(
        initial_sync,
        [
            "arm_cleanup_traps",
            "capture_source_root_identity",
            "create_sqlite_staging",
            "require_candidate_target",
            "recheck_source_root_identity",
            "create_migration_pod",
            "run_sync initial",
            "cleanup_migration_resources",
        ],
        "initial-sync staging/guard/copy/cleanup",
    )
    ordered(
        final_sync,
        [
            "arm_cleanup_traps",
            "capture_source_root_identity",
            "recheck_source_root_identity",
            "create_migration_pod",
            'systemctl --user stop "$SOURCE_UNIT"',
            "wait_for_source_inactive",
            "run_sync final",
        ],
        "final-sync source proof/stop/copy",
    )
    require(script, '"api_server", "feishu", "matrix", "webhook"', "connected platform verification")
    require(script, "wait_for_source_healthy", "rollback source health verification")
    require(script, "symlinks=True", "nested symlinks preserved without following")
    if "def reject_symlinks" in script:
        fail("selected trees must not reject preserved nested symlinks")


def validate_cleanup_failure_is_aggregated() -> None:
    script = MIGRATION.read_text()
    functions = "".join(
        shell_function(script, name)
        for name in (
            "cleanup_migration_pod",
            "cleanup_sqlite_staging",
            "cleanup_migration_resources",
        )
    )
    with tempfile.TemporaryDirectory(prefix="hermes-cleanup-regression-") as temporary:
        root = Path(temporary)
        staging = root / "hermes-agent-sqlite.forced-failure"
        staging.mkdir()
        call_log = root / "kubectl.calls"
        harness = f"""set -uo pipefail
NAMESPACE=default
MIGRATION_POD=migration-pod
MIGRATION_POD_UID=11111111-2222-3333-4444-555555555555
MIGRATION_OPERATION_ID=0123456789abcdef0123456789abcdef
MIGRATION_CREATE_ABSENCE_RECONCILED=0
SQLITE_STAGING_ROOT="$TEST_ROOT"
SQLITE_STAGING_DIR="$TEST_STAGING"
KUBECTL_REQUEST_TIMEOUT=15s
KUBECTL_OUTER_TIMEOUT=25s
KUBECTL_DELETE_VERIFY_OUTER_TIMEOUT=40s
: >"$CALL_LOG"
timeout() {{
  if [ "${{1:-}}" = --foreground ]; then shift; fi
  shift
  "$@"
}}
kubectl() {{
  printf '%s\\n' "$*" >>"$CALL_LOG"
  case " $* " in
    *" delete pod migration-pod "*) return 1 ;;
    *" get pod migration-pod "*)
      printf '%s|%s\\n' "$MIGRATION_POD_UID" "$MIGRATION_OPERATION_ID"
      return 0
      ;;
    *) return 64 ;;
  esac
}}
delete_migration_pod_owned_collection() {{
  printf 'uid-delete %s\\n' "$*" >>"$CALL_LOG"
  return 1
}}
delete_migration_pod_uid_precondition() {{
  delete_migration_pod_owned_collection "$@"
}}
{functions}
cleanup_migration_resources
cleanup_status=$?
failed=0
if [ "$cleanup_status" -eq 0 ]; then
  printf '%s\\n' 'cleanup unexpectedly succeeded while migration Pod survived' >&2
  failed=1
fi
if [ "$MIGRATION_POD" != migration-pod ]; then
  printf '%s\\n' 'cleanup discarded the surviving migration Pod handle' >&2
  failed=1
fi
if [ -e "$TEST_STAGING" ]; then
  printf '%s\\n' 'combined cleanup did not attempt SQLite staging cleanup' >&2
  failed=1
fi
calls="$(<"$CALL_LOG")"
case "$calls" in
  *"uid-delete migration-pod 11111111-2222-3333-4444-555555555555"*) ;;
  *) printf '%s\\n' 'cleanup did not attempt migration Pod deletion' >&2; failed=1 ;;
esac
case "$calls" in
  *"get pod migration-pod"*) ;;
  *) printf '%s\\n' 'cleanup did not authoritatively verify migration Pod absence' >&2; failed=1 ;;
esac
exit "$failed"
"""
        result = subprocess.run(
            ["bash", "-c", harness],
            text=True,
            capture_output=True,
            check=False,
            env={
                **os.environ,
                "TEST_ROOT": str(root),
                "TEST_STAGING": str(staging),
                "CALL_LOG": str(call_log),
            },
        )
        if result.returncode:
            fail(f"migration cleanup failure handling is unsafe:\n{result.stderr}")


def validate_cleanup_success_control() -> None:
    script = MIGRATION.read_text()
    functions = "".join(
        shell_function(script, name)
        for name in (
            "cleanup_migration_pod",
            "cleanup_sqlite_staging",
            "cleanup_migration_resources",
        )
    )
    with tempfile.TemporaryDirectory(prefix="hermes-cleanup-control-") as temporary:
        root = Path(temporary)
        staging = root / "hermes-agent-sqlite.success"
        staging.mkdir()
        call_log = root / "kubectl.calls"
        harness = f"""set -uo pipefail
NAMESPACE=default
MIGRATION_POD=migration-pod
MIGRATION_POD_UID=11111111-2222-3333-4444-555555555555
MIGRATION_OPERATION_ID=0123456789abcdef0123456789abcdef
MIGRATION_CREATE_ABSENCE_RECONCILED=0
SQLITE_STAGING_ROOT="$TEST_ROOT"
SQLITE_STAGING_DIR="$TEST_STAGING"
KUBECTL_REQUEST_TIMEOUT=15s
KUBECTL_OUTER_TIMEOUT=25s
KUBECTL_DELETE_VERIFY_OUTER_TIMEOUT=40s
POD_PRESENT=1
: >"$CALL_LOG"
timeout() {{
  if [ "${{1:-}}" = --foreground ]; then shift; fi
  shift
  "$@"
}}
kubectl() {{
  printf '%s\\n' "$*" >>"$CALL_LOG"
  case " $* " in
    *" delete pod migration-pod "*) POD_PRESENT=0; return 0 ;;
    *" get pod migration-pod "*)
      if [ "$POD_PRESENT" -eq 1 ]; then
        printf '%s|%s\\n' "$MIGRATION_POD_UID" "$MIGRATION_OPERATION_ID"
      fi
      return 0
      ;;
    *) return 64 ;;
  esac
}}
delete_migration_pod_owned_collection() {{
  printf 'uid-delete %s\\n' "$*" >>"$CALL_LOG"
  POD_PRESENT=0
}}
delete_migration_pod_uid_precondition() {{
  delete_migration_pod_owned_collection "$@"
}}
{functions}
cleanup_migration_resources
cleanup_status=$?
failed=0
if [ "$cleanup_status" -ne 0 ]; then
  printf '%s\\n' 'cleanup failed after confirmed migration Pod deletion' >&2
  failed=1
fi
if [ -n "$MIGRATION_POD" ]; then
  printf '%s\\n' 'cleanup retained an absent migration Pod handle' >&2
  failed=1
fi
if [ -e "$TEST_STAGING" ]; then
  printf '%s\\n' 'successful cleanup retained SQLite staging' >&2
  failed=1
fi
calls="$(<"$CALL_LOG")"
case "$calls" in
  *"uid-delete migration-pod 11111111-2222-3333-4444-555555555555"*) ;;
  *) printf '%s\\n' 'cleanup did not attempt migration Pod deletion' >&2; failed=1 ;;
esac
case "$calls" in
  *"get pod migration-pod"*) ;;
  *) printf '%s\\n' 'cleanup did not verify migration Pod absence' >&2; failed=1 ;;
esac
exit "$failed"
"""
        result = subprocess.run(
            ["bash", "-c", harness],
            text=True,
            capture_output=True,
            check=False,
            env={
                **os.environ,
                "TEST_ROOT": str(root),
                "TEST_STAGING": str(staging),
                "CALL_LOG": str(call_log),
            },
        )
        if result.returncode:
            fail(f"migration cleanup success control failed:\n{result.stderr}")


def validate_ambiguous_admitted_create_is_operation_uid_cleaned() -> None:
    script = MIGRATION.read_text()
    functions = "".join(
        shell_function(script, name)
        for name in (
            "die",
            "create_migration_pod",
            "cleanup_migration_pod",
            "cleanup_sqlite_staging",
            "cleanup_migration_resources",
            "arm_cleanup_traps",
        )
    )
    operation = "0123456789abcdef0123456789abcdef"
    expected_pod = f"hermes-agent-migration-{operation}"
    expected_uid = "11111111-2222-3333-4444-555555555555"
    with tempfile.TemporaryDirectory(prefix="hermes-ambiguous-create-") as temporary:
        root = Path(temporary)
        call_log = root / "calls"
        pod_manifest = root / "pod.yaml"
        pod_state = root / "pod.state"
        pod_state.write_text("present")
        harness = f"""set -euo pipefail
NAMESPACE=default
PVC_NAME=hermes-agent-state
SOURCE_HOME=/home/ben/.hermes
SOURCE_ROOT_DEVICE=1
SOURCE_ROOT_INODE=2
IMAGE=test.invalid/hermes@sha256:{"0" * 64}
MIGRATION_POD=""
MIGRATION_POD_UID=""
MIGRATION_OPERATION_ID=""
MIGRATION_CREATE_ABSENCE_RECONCILED=0
SQLITE_STAGING_ROOT="$TEST_ROOT"
SQLITE_STAGING_DIR=""
KUBECTL_REQUEST_TIMEOUT=15s
KUBECTL_OUTER_TIMEOUT=25s
KUBECTL_WAIT_OUTER_TIMEOUT=140s
KUBECTL_CREATE_RECONCILE_OUTER_TIMEOUT=70s
KUBECTL_DELETE_OUTER_TIMEOUT=25s
KUBECTL_DELETE_VERIFY_OUTER_TIMEOUT=40s
MIGRATION_CREATE_RECONCILE_WINDOW_SECONDS=45
: >"$CALL_LOG"
python3() {{ printf '%s\\n' "$EXPECTED_OPERATION"; }}
new_migration_operation_id() {{ printf '%s\\n' "$EXPECTED_OPERATION"; }}
sleep() {{ SECONDS=$((SECONDS + 1)); }}
timeout() {{
  printf 'timeout %s\\n' "$*" >>"$CALL_LOG"
  if [ "${{1:-}}" = --foreground ]; then shift; fi
  shift
  "$@"
}}
kubectl() {{
  printf 'kubectl %s\\n' "$*" >>"$CALL_LOG"
  case " $* " in
    *" get pods -l app.kubernetes.io/name=hermes-agent-migration -o name "*) return 0 ;;
    *" create -f - "*)
      command cat >"$POD_MANIFEST"
      return 1
      ;;
    *" get pod $EXPECTED_POD "*)
      if [ "$(<"$POD_STATE")" = present ]; then
        printf '%s|%s\\n' "$EXPECTED_UID" "$EXPECTED_OPERATION"
      fi
      return 0
      ;;
    *" delete pod $EXPECTED_POD "*)
      printf '%s' absent >"$POD_STATE"
      return 0
      ;;
    *) return 64 ;;
  esac
}}
reject_preexisting_migration_pods() {{
  [ -z "$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=hermes-agent-migration -o name)" ]
}}
reconcile_failed_migration_pod_create() {{
  identity="$(kubectl -n "$NAMESPACE" get pod "$MIGRATION_POD" --ignore-not-found -o ignored)"
  IFS='|' read -r MIGRATION_POD_UID operation extra <<<"$identity"
  [ -n "$MIGRATION_POD_UID" ]
  [ "$operation" = "$MIGRATION_OPERATION_ID" ]
  [ -z "$extra" ]
}}
delete_migration_pod_owned_collection() {{
  printf 'operation-delete %s\\n' "$*" >>"$CALL_LOG"
  [ "$1" = "$EXPECTED_POD" ]
  [ "$2" = "$EXPECTED_UID" ]
  [ "$3" = "$EXPECTED_OPERATION" ]
  printf '%s' absent >"$POD_STATE"
}}
delete_migration_pod_uid_precondition() {{
  delete_migration_pod_owned_collection "$@" "$EXPECTED_OPERATION"
}}
{functions}
arm_cleanup_traps
create_migration_pod
printf '%s\\n' 'ambiguous create unexpectedly returned' >&2
exit 99
"""
        result = subprocess.run(
            ["bash", "-c", harness],
            text=True,
            capture_output=True,
            check=False,
            env={
                **os.environ,
                "TEST_ROOT": str(root),
                "CALL_LOG": str(call_log),
                "POD_MANIFEST": str(pod_manifest),
                "POD_STATE": str(pod_state),
                "EXPECTED_OPERATION": operation,
                "EXPECTED_POD": expected_pod,
                "EXPECTED_UID": expected_uid,
            },
        )
        if result.returncode == 0:
            fail("ambiguous admitted migration Pod create unexpectedly succeeded")
        if not pod_manifest.is_file():
            fail("ambiguous create harness did not receive the Pod manifest")
        manifest = pod_manifest.read_text()
        require(manifest, f"name: {expected_pod}", "preassigned migration Pod name")
        require(
            manifest,
            f"hermes-agent-migration-operation: {operation}",
            "migration operation ownership label",
        )
        if "generateName:" in manifest:
            fail("migration Pod still relies on server-generated ownership identity")
        calls = call_log.read_text()
        require(calls, f"get pod {expected_pod}", "ambiguous create reconciliation GET")
        require(
            calls,
            f"operation-delete {expected_pod} {expected_uid} {operation}",
            "operation-owned cleanup",
        )
        if calls.count(f"get pod {expected_pod}") < 2:
            fail("cleanup did not verify migration Pod absence after UID deletion")
        if pod_state.read_text() != "absent":
            fail("ambiguous admitted migration Pod survived cleanup")


def validate_cleanup_get_is_bounded() -> None:
    script = MIGRATION.read_text()
    cleanup = shell_function(script, "cleanup_migration_pod")
    with tempfile.TemporaryDirectory(prefix="hermes-bounded-cleanup-get-") as temporary:
        call_log = Path(temporary) / "calls"
        harness = f"""set -euo pipefail
NAMESPACE=default
MIGRATION_POD=migration-pod
MIGRATION_POD_UID=11111111-2222-3333-4444-555555555555
MIGRATION_OPERATION_ID=0123456789abcdef0123456789abcdef
MIGRATION_CREATE_ABSENCE_RECONCILED=0
KUBECTL_REQUEST_TIMEOUT=15s
KUBECTL_OUTER_TIMEOUT=25s
KUBECTL_DELETE_VERIFY_OUTER_TIMEOUT=40s
: >"$CALL_LOG"
timeout() {{
  printf 'timeout %s\\n' "$*" >>"$CALL_LOG"
  if [ "${{1:-}}" = --foreground ]; then shift; fi
  shift
  "$@"
}}
kubectl() {{
  printf 'kubectl %s\\n' "$*" >>"$CALL_LOG"
  return 0
}}
delete_migration_pod_owned_collection() {{ return 64; }}
delete_migration_pod_uid_precondition() {{ return 64; }}
delete_migration_pod_with_uid_precondition() {{ return 64; }}
{cleanup}
cleanup_migration_pod
"""
        result = subprocess.run(
            ["bash", "-c", harness],
            text=True,
            capture_output=True,
            check=False,
            env={**os.environ, "CALL_LOG": str(call_log)},
        )
        if result.returncode:
            fail(f"bounded cleanup GET control failed:\n{result.stderr}")
        calls = call_log.read_text()
        if not re.search(
            r"timeout --foreground [1-9][0-9]*s kubectl "
            r"--request-timeout=[1-9][0-9]*s .*get pod migration-pod",
            calls,
        ):
            fail(f"cleanup authoritative GET lacks fixed inner/outer bounds:\n{calls}")


def validate_operation_delete_collection_uses_real_kubectl_transport() -> None:
    script = MIGRATION.read_text()
    functions = "".join(
        shell_function(script, name)
        for name in ("delete_migration_pod_owned_collection", "cleanup_migration_pod")
    )
    operation = "0123456789abcdef0123456789abcdef"
    pod = f"hermes-agent-migration-{operation}"
    uid = "11111111-2222-3333-4444-555555555555"
    replacement_uid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    class FakeKubernetesAPI(http.server.BaseHTTPRequestHandler):
        def log_message(self, format: str, *args: object) -> None:
            del format
            del args

        def send_object(self, status: int, value: dict[str, object]) -> None:
            payload = json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self) -> None:
            parsed = urllib.parse.urlsplit(self.path)
            getattr(self.server, "get_requests").append(parsed)
            if parsed.path == "/api":
                self.send_object(
                    200,
                    {"apiVersion": "v1", "kind": "APIVersions", "versions": ["v1"]},
                )
                return
            if parsed.path == "/apis":
                self.send_object(
                    200,
                    {"apiVersion": "v1", "kind": "APIGroupList", "groups": []},
                )
                return
            if parsed.path == "/api/v1":
                self.send_object(
                    200,
                    {
                        "apiVersion": "v1",
                        "kind": "APIResourceList",
                        "groupVersion": "v1",
                        "resources": [
                            {
                                "name": "pods",
                                "singularName": "pod",
                                "namespaced": True,
                                "kind": "Pod",
                                "verbs": ["delete", "deletecollection", "get", "list", "watch"],
                            }
                        ],
                    },
                )
                return
            if parsed.path == f"/api/v1/namespaces/default/pods/{pod}":
                query = urllib.parse.parse_qs(parsed.query)
                if query.get("watch") == ["true"]:
                    self.send_object(
                        500,
                        {
                            "apiVersion": "v1",
                            "kind": "Status",
                            "status": "Failure",
                            "reason": "InternalError",
                            "code": 500,
                        },
                    )
                    return
                current = getattr(self.server, "pod")
                if current is None:
                    self.send_object(
                        404,
                        {
                            "apiVersion": "v1",
                            "kind": "Status",
                            "status": "Failure",
                            "reason": "NotFound",
                            "code": 404,
                        },
                    )
                else:
                    self.send_object(200, current)
                return
            self.send_object(404, {"kind": "Status", "status": "Failure", "code": 404})

        def do_DELETE(self) -> None:
            parsed = urllib.parse.urlsplit(self.path)
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length)
            getattr(self.server, "delete_requests").append((parsed, body))
            replacement = {
                "apiVersion": "v1",
                "kind": "Pod",
                "metadata": {
                    "name": pod,
                    "namespace": "default",
                    "uid": replacement_uid,
                    "labels": {
                        "app.kubernetes.io/name": "hermes-agent-migration",
                        "hermes-agent-migration-operation": "fedcba9876543210fedcba9876543210",
                    },
                    "resourceVersion": "2",
                },
            }
            setattr(self.server, "pod", replacement)
            selectors = urllib.parse.parse_qs(parsed.query)
            if selectors.get("fieldSelector") == [f"metadata.name={pod}"] and selectors.get(
                "labelSelector"
            ) == [f"hermes-agent-migration-operation={operation}"]:
                current_operation = replacement["metadata"]["labels"][
                    "hermes-agent-migration-operation"
                ]
                if current_operation == operation:
                    setattr(self.server, "pod", None)
            self.send_object(
                200,
                {
                    "apiVersion": "v1",
                    "kind": "Status",
                    "status": "Success",
                    "code": 200,
                },
            )

    with tempfile.TemporaryDirectory(prefix="hermes-operation-delete-") as temporary:
        root = Path(temporary)
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeKubernetesAPI)
        setattr(
            server,
            "pod",
            {
                "apiVersion": "v1",
                "kind": "Pod",
                "metadata": {
                    "name": pod,
                    "namespace": "default",
                    "uid": uid,
                    "labels": {
                        "app.kubernetes.io/name": "hermes-agent-migration",
                        "hermes-agent-migration-operation": operation,
                    },
                    "resourceVersion": "1",
                },
            },
        )
        setattr(server, "delete_requests", [])
        setattr(server, "get_requests", [])
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            kubeconfig = root / "kubeconfig"
            kubeconfig.write_text(
                "apiVersion: v1\n"
                "kind: Config\n"
                "clusters:\n"
                "- name: fake\n"
                "  cluster:\n"
                f"    server: http://127.0.0.1:{server.server_port}\n"
                "contexts:\n"
                "- name: fake\n"
                "  context:\n"
                "    cluster: fake\n"
                "    namespace: default\n"
                "current-context: fake\n"
                "users: []\n"
            )
            harness = f"""set -uo pipefail
NAMESPACE=default
MIGRATION_POD="$EXPECTED_POD"
MIGRATION_POD_UID="$EXPECTED_UID"
MIGRATION_OPERATION_ID="$EXPECTED_OPERATION"
MIGRATION_CREATE_ABSENCE_RECONCILED=0
KUBECTL_REQUEST_TIMEOUT=3s
KUBECTL_OUTER_TIMEOUT=5s
KUBECTL_DELETE_OUTER_TIMEOUT=5s
KUBECTL_DELETE_VERIFY_OUTER_TIMEOUT=5s
{functions}
cleanup_migration_pod
cleanup_status=$?
[ "$cleanup_status" -ne 0 ]
[ "$MIGRATION_POD" = "$EXPECTED_POD" ]
[ "$MIGRATION_POD_UID" = "$EXPECTED_UID" ]
[ "$MIGRATION_OPERATION_ID" = "$EXPECTED_OPERATION" ]
"""
            result = subprocess.run(
                ["bash", "-c", harness],
                text=True,
                capture_output=True,
                check=False,
                env={
                    **os.environ,
                    "KUBECONFIG": str(kubeconfig),
                    "EXPECTED_POD": pod,
                    "EXPECTED_UID": uid,
                    "EXPECTED_OPERATION": operation,
                },
                timeout=20,
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
        if result.returncode:
            fail(f"real-kubectl operation-owned cleanup harness failed:\n{result.stderr}")
        requests = getattr(server, "delete_requests")
        if len(requests) != 1:
            fail(
                f"expected one real kubectl DELETE, observed {len(requests)}; "
                f"GETs={getattr(server, 'get_requests')!r} "
                f"stdout={result.stdout!r} stderr={result.stderr!r}"
            )
        parsed, _body = requests[0]
        if parsed.path != "/api/v1/namespaces/default/pods":
            fail(f"cleanup did not use DeleteCollection: {parsed.path!r}")
        selectors = urllib.parse.parse_qs(parsed.query)
        if selectors.get("fieldSelector") != [f"metadata.name={pod}"]:
            fail(f"DeleteCollection lacks the exact name selector: {selectors!r}")
        if selectors.get("labelSelector") != [
            f"hermes-agent-migration-operation={operation}"
        ]:
            fail(f"DeleteCollection lacks the operation selector: {selectors!r}")
        remaining = getattr(server, "pod")
        if remaining is None or remaining["metadata"]["uid"] != replacement_uid:
            fail("operation-owned DeleteCollection deleted an unowned same-name replacement")


def validate_late_admitted_create_is_found_and_exit_cleaned() -> None:
    script = MIGRATION.read_text()
    functions = "".join(
        shell_function(script, name)
        for name in (
            "die",
            "reject_preexisting_migration_pods",
            "reconcile_failed_migration_pod_create",
            "create_migration_pod",
            "cleanup_migration_pod",
            "cleanup_sqlite_staging",
            "cleanup_migration_resources",
            "arm_cleanup_traps",
        )
    )
    operation = "0123456789abcdef0123456789abcdef"
    pod = f"hermes-agent-migration-{operation}"
    uid = "11111111-2222-3333-4444-555555555555"
    with tempfile.TemporaryDirectory(prefix="hermes-late-admission-") as temporary:
        root = Path(temporary)
        call_log = root / "calls"
        get_count = root / "get-count"
        pod_state = root / "pod-state"
        pod_manifest = root / "pod.yaml"
        get_count.write_text("0")
        pod_state.write_text("late")
        harness = f"""set -euo pipefail
NAMESPACE=default
PVC_NAME=hermes-agent-state
SOURCE_HOME=/home/ben/.hermes
SOURCE_ROOT_DEVICE=1
SOURCE_ROOT_INODE=2
IMAGE=test.invalid/hermes@sha256:{"0" * 64}
MIGRATION_POD=""
MIGRATION_POD_UID=""
MIGRATION_OPERATION_ID=""
MIGRATION_CREATE_ABSENCE_RECONCILED=0
SQLITE_STAGING_ROOT="$TEST_ROOT"
SQLITE_STAGING_DIR=""
KUBECTL_REQUEST_TIMEOUT=15s
KUBECTL_OUTER_TIMEOUT=25s
KUBECTL_WAIT_OUTER_TIMEOUT=140s
KUBECTL_CREATE_RECONCILE_OUTER_TIMEOUT=70s
KUBECTL_DELETE_OUTER_TIMEOUT=25s
KUBECTL_DELETE_VERIFY_OUTER_TIMEOUT=40s
MIGRATION_CREATE_RECONCILE_WINDOW_SECONDS=45
new_migration_operation_id() {{ printf '%s\\n' "$EXPECTED_OPERATION"; }}
sleep() {{ SECONDS=$((SECONDS + 1)); }}
timeout() {{
  if [ "${{1:-}}" = --foreground ]; then shift; fi
  shift
  "$@"
}}
kubectl() {{
  printf 'kubectl %s\\n' "$*" >>"$CALL_LOG"
  case " $* " in
    *" get pods -l app.kubernetes.io/name=hermes-agent-migration -o name "*) return 0 ;;
    *" create -f - "*) command cat >"$POD_MANIFEST"; return 1 ;;
    *" get pod $EXPECTED_POD "*)
      count="$(<"$GET_COUNT")"
      count=$((count + 1))
      printf '%s' "$count" >"$GET_COUNT"
      if [ "$(<"$POD_STATE")" = late ] && [ "$count" -ge 4 ]; then
        printf '%s|%s\\n' "$EXPECTED_UID" "$EXPECTED_OPERATION"
      fi
      return 0
      ;;
    *" wait --for=delete pod/$EXPECTED_POD "*) return 0 ;;
    *) return 64 ;;
  esac
}}
delete_migration_pod_owned_collection() {{
  printf 'operation-delete %s\\n' "$*" >>"$CALL_LOG"
  [ "$1" = "$EXPECTED_POD" ]
  [ "$2" = "$EXPECTED_UID" ]
  [ "$3" = "$EXPECTED_OPERATION" ]
  printf '%s' absent >"$POD_STATE"
}}
delete_migration_pod_uid_precondition() {{
  delete_migration_pod_owned_collection "$@" "$EXPECTED_OPERATION"
}}
{functions}
arm_cleanup_traps
create_migration_pod
printf '%s\\n' 'late-admitted create unexpectedly returned' >&2
exit 99
"""
        result = subprocess.run(
            ["bash", "-c", harness],
            text=True,
            capture_output=True,
            check=False,
            env={
                **os.environ,
                "TEST_ROOT": str(root),
                "CALL_LOG": str(call_log),
                "GET_COUNT": str(get_count),
                "POD_STATE": str(pod_state),
                "POD_MANIFEST": str(pod_manifest),
                "EXPECTED_OPERATION": operation,
                "EXPECTED_POD": pod,
                "EXPECTED_UID": uid,
            },
        )
        if result.returncode == 0:
            fail("late-admitted migration Pod create unexpectedly succeeded")
        if int(get_count.read_text()) < 5:
            fail("create failure did not poll through delayed admission and cleanup")
        calls = call_log.read_text()
        require(calls, f"operation-delete {pod} {uid} {operation}", "owned late-Pod cleanup")
        if pod_state.read_text() != "absent":
            fail("set-e/EXIT cleanup left the late-admitted owned Pod present")


def validate_immediate_absence_does_not_clear_unknown_create_handle() -> None:
    cleanup = shell_function(MIGRATION.read_text(), "cleanup_migration_pod")
    operation = "0123456789abcdef0123456789abcdef"
    pod = f"hermes-agent-migration-{operation}"
    harness = f"""set -uo pipefail
NAMESPACE=default
MIGRATION_POD="$EXPECTED_POD"
MIGRATION_POD_UID=""
MIGRATION_OPERATION_ID="$EXPECTED_OPERATION"
MIGRATION_CREATE_ABSENCE_RECONCILED=0
KUBECTL_REQUEST_TIMEOUT=15s
KUBECTL_OUTER_TIMEOUT=25s
KUBECTL_DELETE_VERIFY_OUTER_TIMEOUT=40s
timeout() {{ if [ "${{1:-}}" = --foreground ]; then shift; fi; shift; "$@"; }}
kubectl() {{ return 0; }}
delete_migration_pod_owned_collection() {{ return 99; }}
{cleanup}
cleanup_migration_pod
status=$?
[ "$status" -ne 0 ]
[ "$MIGRATION_POD" = "$EXPECTED_POD" ]
[ -z "$MIGRATION_POD_UID" ]
[ "$MIGRATION_OPERATION_ID" = "$EXPECTED_OPERATION" ]
"""
    result = subprocess.run(
        ["bash", "-c", harness],
        text=True,
        capture_output=True,
        check=False,
        env={
            **os.environ,
            "EXPECTED_POD": pod,
            "EXPECTED_OPERATION": operation,
        },
    )
    if result.returncode:
        fail(f"immediate-empty cleanup discarded unknown admission ownership:\n{result.stderr}")


def validate_full_create_reconciliation_window_proves_absence() -> None:
    script = MIGRATION.read_text()
    functions = "".join(
        shell_function(script, name)
        for name in ("reconcile_failed_migration_pod_create", "cleanup_migration_pod")
    )
    operation = "0123456789abcdef0123456789abcdef"
    pod = f"hermes-agent-migration-{operation}"
    with tempfile.TemporaryDirectory(prefix="hermes-no-admission-window-") as temporary:
        call_log = Path(temporary) / "calls"
        elapsed_file = Path(temporary) / "elapsed"
        harness = f"""set -uo pipefail
NAMESPACE=default
MIGRATION_POD="$EXPECTED_POD"
MIGRATION_POD_UID=""
MIGRATION_OPERATION_ID="$EXPECTED_OPERATION"
MIGRATION_CREATE_ABSENCE_RECONCILED=0
KUBECTL_REQUEST_TIMEOUT=15s
KUBECTL_OUTER_TIMEOUT=25s
KUBECTL_CREATE_RECONCILE_OUTER_TIMEOUT=25s
MIGRATION_CREATE_RECONCILE_WINDOW_SECONDS=45
sleep() {{ SECONDS=$((SECONDS + 1)); }}
timeout() {{ if [ "${{1:-}}" = --foreground ]; then shift; fi; shift; "$@"; }}
kubectl() {{ printf '%s\\n' "$*" >>"$CALL_LOG"; return 0; }}
delete_migration_pod_owned_collection() {{ return 99; }}
{functions}
start_seconds=$SECONDS
reconcile_failed_migration_pod_create
reconcile_status=$?
printf '%s' "$((SECONDS - start_seconds))" >"$ELAPSED_FILE"
[ "$reconcile_status" -ne 0 ]
[ "$MIGRATION_CREATE_ABSENCE_RECONCILED" -eq 1 ]
cleanup_migration_pod
[ -z "$MIGRATION_POD" ]
[ -z "$MIGRATION_OPERATION_ID" ]
"""
        result = subprocess.run(
            ["bash", "-c", harness],
            text=True,
            capture_output=True,
            check=False,
            env={
                **os.environ,
                "CALL_LOG": str(call_log),
                "ELAPSED_FILE": str(elapsed_file),
                "EXPECTED_POD": pod,
                "EXPECTED_OPERATION": operation,
            },
        )
        if result.returncode:
            fail(f"full no-admission reconciliation control failed:\n{result.stderr}")
        exact_gets = [
            line
            for line in call_log.read_text().splitlines()
            if f"get pod {pod}" in line
        ]
        if int(elapsed_file.read_text()) < 45:
            fail("full-window absence was accepted before the fixed horizon elapsed")
        if len(exact_gets) < 2:
            fail("full-window absence was accepted after only one immediate read")


def validate_create_reconciliation_api_error_retains_unknown_handle() -> None:
    reconcile = shell_function(
        MIGRATION.read_text(), "reconcile_failed_migration_pod_create"
    )
    operation = "0123456789abcdef0123456789abcdef"
    pod = f"hermes-agent-migration-{operation}"
    harness = f"""set -uo pipefail
NAMESPACE=default
MIGRATION_POD="$EXPECTED_POD"
MIGRATION_POD_UID=""
MIGRATION_OPERATION_ID="$EXPECTED_OPERATION"
MIGRATION_CREATE_ABSENCE_RECONCILED=0
KUBECTL_REQUEST_TIMEOUT=15s
KUBECTL_OUTER_TIMEOUT=25s
KUBECTL_CREATE_RECONCILE_OUTER_TIMEOUT=25s
MIGRATION_CREATE_RECONCILE_WINDOW_SECONDS=45
timeout() {{ if [ "${{1:-}}" = --foreground ]; then shift; fi; shift; "$@"; }}
kubectl() {{ return 1; }}
sleep() {{ SECONDS=$((SECONDS + 1)); }}
{reconcile}
reconcile_failed_migration_pod_create
status=$?
[ "$status" -ne 0 ]
[ "$MIGRATION_CREATE_ABSENCE_RECONCILED" -eq 0 ]
[ "$MIGRATION_POD" = "$EXPECTED_POD" ]
[ "$MIGRATION_OPERATION_ID" = "$EXPECTED_OPERATION" ]
"""
    result = subprocess.run(
        ["bash", "-c", harness],
        text=True,
        capture_output=True,
        check=False,
        env={
            **os.environ,
            "EXPECTED_POD": pod,
            "EXPECTED_OPERATION": operation,
        },
    )
    if result.returncode:
        fail(f"create reconciliation API error lost ownership:\n{result.stderr}")


def validate_stale_migration_operation_is_rejected_before_create() -> None:
    script = MIGRATION.read_text()
    functions = "".join(
        shell_function(script, name)
        for name in ("die", "reject_preexisting_migration_pods", "create_migration_pod")
    )
    with tempfile.TemporaryDirectory(prefix="hermes-stale-operation-") as temporary:
        call_log = Path(temporary) / "calls"
        harness = f"""set -euo pipefail
NAMESPACE=default
PVC_NAME=hermes-agent-state
SOURCE_HOME=/home/ben/.hermes
SOURCE_ROOT_DEVICE=1
SOURCE_ROOT_INODE=2
IMAGE=test.invalid/hermes@sha256:{"0" * 64}
MIGRATION_POD=""
MIGRATION_POD_UID=""
MIGRATION_OPERATION_ID=""
MIGRATION_CREATE_ABSENCE_RECONCILED=0
SQLITE_STAGING_DIR=""
KUBECTL_REQUEST_TIMEOUT=15s
KUBECTL_OUTER_TIMEOUT=25s
KUBECTL_WAIT_OUTER_TIMEOUT=140s
KUBECTL_CREATE_RECONCILE_OUTER_TIMEOUT=70s
MIGRATION_CREATE_RECONCILE_WINDOW_SECONDS=45
new_migration_operation_id() {{ printf '%s\\n' 0123456789abcdef0123456789abcdef; }}
timeout() {{ if [ "${{1:-}}" = --foreground ]; then shift; fi; shift; "$@"; }}
kubectl() {{
  printf '%s\\n' "$*" >>"$CALL_LOG"
  case " $* " in
    *" get pods -l app.kubernetes.io/name=hermes-agent-migration -o name "*)
      printf '%s\\n' pod/hermes-agent-migration-stale
      return 0
      ;;
    *" create -f - "*) return 99 ;;
    *) return 64 ;;
  esac
}}
{functions}
create_migration_pod
"""
        result = subprocess.run(
            ["bash", "-c", harness],
            text=True,
            capture_output=True,
            check=False,
            env={**os.environ, "CALL_LOG": str(call_log)},
        )
        if result.returncode == 0:
            fail("pre-existing migration operation was accepted")
        calls = call_log.read_text()
        require(calls, "get pods -l app.kubernetes.io/name=hermes-agent-migration", "stale-Pod scan")
        if " create -f -" in calls:
            fail("new migration operation was created while a stale operation existed")


def validate_staging_cleanup_failure_retains_handle() -> None:
    script = MIGRATION.read_text()
    cleanup = shell_function(script, "cleanup_sqlite_staging")
    with tempfile.TemporaryDirectory(
        prefix="hermes-staging-cleanup-failure-"
    ) as temporary:
        root = Path(temporary)
        staging = root / "hermes-agent-sqlite.cleanup-failure"
        staging.mkdir()
        harness = f"""set -uo pipefail
SQLITE_STAGING_ROOT="$TEST_ROOT"
SQLITE_STAGING_DIR="$TEST_STAGING"
rm() {{ return 1; }}
{cleanup}
cleanup_sqlite_staging
cleanup_status=$?
[ "$cleanup_status" -ne 0 ]
[ "$SQLITE_STAGING_DIR" = "$TEST_STAGING" ]
[ -d "$TEST_STAGING" ]
"""
        result = subprocess.run(
            ["bash", "-c", harness],
            text=True,
            capture_output=True,
            check=False,
            env={
                **os.environ,
                "TEST_ROOT": str(root),
                "TEST_STAGING": str(staging),
            },
        )
        if result.returncode:
            fail(f"staging cleanup failure lost its retained handle:\n{result.stderr}")


def validate_set_e_exit_trap_retries_failed_aggregate_cleanup() -> None:
    script = MIGRATION.read_text()
    functions = "".join(
        shell_function(script, name)
        for name in ("cleanup_migration_resources", "arm_cleanup_traps")
    )
    with tempfile.TemporaryDirectory(prefix="hermes-cleanup-exit-trap-") as temporary:
        call_log = Path(temporary) / "calls"
        harness = f"""set -euo pipefail
: >"$CALL_LOG"
cleanup_migration_pod() {{ printf '%s\\n' pod >>"$CALL_LOG"; return 0; }}
cleanup_sqlite_staging() {{ printf '%s\\n' staging >>"$CALL_LOG"; return 1; }}
{functions}
arm_cleanup_traps
cleanup_migration_resources
trap - EXIT INT TERM
exit 0
"""
        result = subprocess.run(
            ["bash", "-c", harness],
            text=True,
            capture_output=True,
            check=False,
            env={**os.environ, "CALL_LOG": str(call_log)},
        )
        if result.returncode == 0:
            fail("set -e accepted failed aggregate cleanup and disarmed the EXIT trap")
        calls = call_log.read_text().splitlines()
        if calls.count("pod") != 2 or calls.count("staging") != 2:
            fail(f"EXIT trap did not retry every aggregate cleanup member: {calls!r}")


def validate_staging_manifest_contract() -> None:
    with tempfile.TemporaryDirectory(prefix="hermes-staging-manifest-") as temporary:
        root = Path(temporary)
        source = root / "source"
        staging = root / "staging"
        source.mkdir()
        staging.mkdir(mode=0o700)
        secret_marker = "database-content-must-not-enter-manifest"
        create_database(source / "state.db", secret_marker)
        create_database(
            source / "profiles" / "implementer" / "projects.db", secret_marker
        )
        source_identity = manifest_identity(source)
        profiles_identity = manifest_identity(source / "profiles")
        implementer_identity = manifest_identity(source / "profiles" / "implementer")

        staged = run_stage(source, staging)
        if staged.returncode:
            fail(f"host SQLite staging failed:\n{staged.stderr}")
        manifest_path = staging / ".manifest.json"
        if not manifest_path.is_file():
            fail("SQLite staging did not create the exact manifest")
        manifest_text = manifest_path.read_text()
        if secret_marker in manifest_text:
            fail("SQLite staging manifest leaked database contents")
        manifest = json.loads(manifest_text)
        absent_database = {
            "state": "absent",
            "type": None,
            "size": None,
            "sha256": None,
        }
        expected_databases = {name: absent_database for name in DATABASES}
        expected_databases["state.db"] = staged_database_record(staging / "state.db")
        expected_profiles = {
            profile: {
                "state": "absent",
                "type": None,
                "identity": None,
                "databases": {name: absent_database for name in DATABASES},
            }
            for profile in PROFILES
        }
        expected_profiles["implementer"] = {
            "state": "present",
            "type": "directory",
            "identity": implementer_identity,
            "databases": {name: absent_database for name in DATABASES},
        }
        expected_profiles["implementer"]["databases"]["projects.db"] = (
            staged_database_record(staging / "profiles" / "implementer" / "projects.db")
        )
        expected = {
            "version": 2,
            "source_root": source_identity,
            "profiles_parent": {
                "state": "present",
                "type": "directory",
                "identity": profiles_identity,
            },
            "databases": expected_databases,
            "profiles": expected_profiles,
        }
        if manifest != expected or type(manifest.get("version")) is not int:
            fail(f"SQLite staging manifest is not exact: {manifest!r}")


def validate_staged_database_substitution_rejected_before_target_mutation() -> None:
    with tempfile.TemporaryDirectory(prefix="hermes-staged-substitution-") as temporary:
        root = Path(temporary)
        source = root / "source"
        staging = root / "staging"
        target = root / "target"
        create_database(source / "state.db", "original-a")
        staging.mkdir(mode=0o700)
        sentinel = seed_target_sentinel(target)
        staged = run_stage(source, staging)
        if staged.returncode:
            fail(f"host SQLite staging failed:\n{staged.stderr}")

        replacement = root / "replacement.db"
        create_database(replacement, "tampered-b")
        if replacement.stat().st_size != (staging / "state.db").stat().st_size:
            fail("staged substitution fixture must preserve size to exercise SHA-256 binding")
        os.replace(replacement, staging / "state.db")
        synced = run_sync(source, staging, target)
        assert_rejected_before_target_mutation(
            synced, sentinel, "valid staged database content substitution"
        )


def validate_host_stage_rejects_dangling_profiles_parent_symlink() -> None:
    with tempfile.TemporaryDirectory(
        prefix="hermes-dangling-profiles-stage-"
    ) as temporary:
        root = Path(temporary)
        source = root / "source"
        staging = root / "staging"
        source.mkdir()
        (source / "profiles").symlink_to(
            source / "missing-profiles", target_is_directory=True
        )
        staging.mkdir(mode=0o700)
        result = run_stage(source, staging)
        if result.returncode == 0:
            fail("host staging accepted a dangling SOURCE/profiles parent symlink")


def validate_host_stage_rejects_external_profiles_parent_symlink() -> None:
    with tempfile.TemporaryDirectory(
        prefix="hermes-external-profiles-stage-"
    ) as temporary:
        root = Path(temporary)
        source = root / "source"
        external = root / "external-profiles"
        staging = root / "staging"
        source.mkdir()
        create_database(external / "implementer" / "projects.db", "external")
        (source / "profiles").symlink_to(external, target_is_directory=True)
        staging.mkdir(mode=0o700)
        result = run_stage(source, staging)
        if result.returncode == 0:
            fail("host staging followed an external SOURCE/profiles parent symlink")


def validate_pod_preflight_rejects_dangling_profiles_parent_symlink() -> None:
    with tempfile.TemporaryDirectory(
        prefix="hermes-dangling-profiles-sync-"
    ) as temporary:
        root = Path(temporary)
        source = root / "source"
        staging = root / "staging"
        target = root / "target"
        source.mkdir()
        staging.mkdir(mode=0o700)
        sentinel = seed_target_sentinel(target)
        staged = run_stage(source, staging)
        if staged.returncode:
            fail(f"host SQLite staging failed:\n{staged.stderr}")
        (source / "profiles").symlink_to(
            source / "missing-profiles", target_is_directory=True
        )

        synced = run_sync(source, staging, target)
        assert_rejected_before_target_mutation(
            synced, sentinel, "Pod preflight dangling SOURCE/profiles parent symlink"
        )


def validate_pod_preflight_rejects_external_profiles_parent_symlink() -> None:
    with tempfile.TemporaryDirectory(
        prefix="hermes-external-profiles-sync-"
    ) as temporary:
        root = Path(temporary)
        source = root / "source"
        staging = root / "staging"
        target = root / "target"
        profiles = source / "profiles"
        create_database(profiles / "implementer" / "projects.db", "staged")
        staging.mkdir(mode=0o700)
        sentinel = seed_target_sentinel(target)
        staged = run_stage(source, staging)
        if staged.returncode:
            fail(f"host SQLite staging failed:\n{staged.stderr}")
        external = root / "external-profiles"
        profiles.rename(external)
        profiles.symlink_to(external, target_is_directory=True)

        synced = run_sync(source, staging, target)
        assert_rejected_before_target_mutation(
            synced, sentinel, "Pod preflight external SOURCE/profiles parent symlink"
        )


def validate_duplicate_manifest_key_is_rejected() -> None:
    with tempfile.TemporaryDirectory(
        prefix="hermes-duplicate-staging-manifest-"
    ) as temporary:
        root = Path(temporary)
        source = root / "source"
        staging = root / "staging"
        target = root / "target"
        create_database(source / "state.db", "duplicate")
        staging.mkdir(mode=0o700)
        sentinel = seed_target_sentinel(target)
        staged = run_stage(source, staging)
        if staged.returncode:
            fail(f"host SQLite staging failed:\n{staged.stderr}")
        manifest_path = staging / ".manifest.json"
        original_text = manifest_path.read_text()
        manifest_path.write_text('{"version":1,' + original_text[1:])
        synced = run_sync(source, staging, target)
        assert_rejected_before_target_mutation(
            synced, sentinel, "duplicate SQLite manifest root key"
        )


def validate_noncanonical_manifest_values_are_rejected() -> None:
    with tempfile.TemporaryDirectory(
        prefix="hermes-strict-staging-manifest-"
    ) as temporary:
        root = Path(temporary)
        source = root / "source"
        staging = root / "staging"
        create_database(source / "state.db", "strict")
        (source / "profiles" / "implementer").mkdir(parents=True)
        staging.mkdir(mode=0o700)
        staged = run_stage(source, staging)
        if staged.returncode:
            fail(f"host SQLite staging failed:\n{staged.stderr}")
        manifest_path = staging / ".manifest.json"
        original_text = manifest_path.read_text()
        original = json.loads(original_text)
        if original.get("version") != 2 or set(original) != {
            "version",
            "source_root",
            "profiles_parent",
            "databases",
            "profiles",
        }:
            fail("host staging manifest lacks strict source identity fields")
        present_record = original["databases"]["state.db"]
        if set(present_record) != {"state", "type", "size", "sha256"}:
            fail("host staging manifest lacks strict database metadata fields")

        mutations: list[tuple[str, str]] = [
            (
                "non-finite size",
                original_text.replace(
                    f'"size":{original["databases"]["state.db"]["size"]}',
                    '"size":NaN',
                    1,
                ),
            ),
        ]
        structured_mutations: list[tuple[str, object]] = []
        for description, mutate in (
            (
                "missing absent digest field",
                lambda value: value["databases"]["hermes_state.db"].pop("sha256"),
            ),
            (
                "boolean present size",
                lambda value: value["databases"]["state.db"].__setitem__("size", True),
            ),
            (
                "integral-float present size",
                lambda value: value["databases"]["state.db"].__setitem__(
                    "size", float(value["databases"]["state.db"]["size"])
                ),
            ),
            (
                "uppercase digest",
                lambda value: value["databases"]["state.db"].__setitem__(
                    "sha256", "A" * 64
                ),
            ),
            (
                "non-null absent size",
                lambda value: value["databases"]["hermes_state.db"].__setitem__(
                    "size", 0
                ),
            ),
            (
                "non-null absent profile identity",
                lambda value: value["profiles"]["reviewer"].__setitem__(
                    "identity", {"st_dev": 1, "st_ino": 2}
                ),
            ),
            (
                "null present profile identity",
                lambda value: value["profiles"]["implementer"].__setitem__(
                    "identity", None
                ),
            ),
            (
                "zero present profile inode",
                lambda value: value["profiles"]["implementer"]["identity"].__setitem__(
                    "st_ino", 0
                ),
            ),
            (
                "null present profiles-parent identity",
                lambda value: value["profiles_parent"].__setitem__("identity", None),
            ),
            (
                "boolean source device",
                lambda value: value["source_root"].__setitem__("st_dev", True),
            ),
        ):
            value = json.loads(original_text)
            mutate(value)
            structured_mutations.append((description, value))
        mutations.extend(
            (
                description,
                json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
            )
            for description, value in structured_mutations
        )

        for index, (description, mutated_text) in enumerate(mutations):
            manifest_path.write_text(mutated_text)
            target = root / f"target-{index}"
            sentinel = seed_target_sentinel(target)
            synced = run_sync(source, staging, target)
            assert_rejected_before_target_mutation(synced, sentinel, description)
        manifest_path.write_text(original_text)


def validate_host_stage_rejects_dangling_profile_symlink() -> None:
    with tempfile.TemporaryDirectory(prefix="hermes-dangling-profile-stage-") as temporary:
        root = Path(temporary)
        source = root / "source"
        staging = root / "staging"
        (source / "profiles").mkdir(parents=True)
        (source / "profiles" / "implementer").symlink_to(
            source / "missing-profile", target_is_directory=True
        )
        staging.mkdir(mode=0o700)
        result = run_stage(source, staging)
        if result.returncode == 0:
            fail("host staging accepted a dangling allowlisted profile symlink")


def validate_host_stage_rejects_dangling_database_symlink() -> None:
    with tempfile.TemporaryDirectory(prefix="hermes-dangling-database-stage-") as temporary:
        root = Path(temporary)
        source = root / "source"
        staging = root / "staging"
        source.mkdir()
        (source / "state.db").symlink_to(source / "missing-state.db")
        staging.mkdir(mode=0o700)
        result = run_stage(source, staging)
        if result.returncode == 0:
            fail("host staging accepted a dangling allowlisted database symlink")


def validate_profile_disappearance_rejected_before_target_mutation() -> None:
    with tempfile.TemporaryDirectory(prefix="hermes-profile-drift-") as temporary:
        root = Path(temporary)
        source = root / "source"
        staging = root / "staging"
        target = root / "target"
        create_database(source / "profiles" / "implementer" / "projects.db", "staged")
        staging.mkdir(mode=0o700)
        sentinel = seed_target_sentinel(target)
        staged = run_stage(source, staging)
        if staged.returncode:
            fail(f"host SQLite staging failed:\n{staged.stderr}")
        staged_database = staging / "profiles" / "implementer" / "projects.db"
        if not staged_database.is_file():
            fail("profile database was not staged for drift regression")
        shutil.rmtree(source / "profiles" / "implementer")

        synced = run_sync(source, staging, target)
        assert_rejected_before_target_mutation(
            synced, sentinel, "profile disappearance after SQLite staging"
        )
        if not staged_database.is_file():
            fail("profile drift rejection discarded the staged database evidence")


def validate_pod_preflight_rejects_dangling_profile_symlink() -> None:
    with tempfile.TemporaryDirectory(prefix="hermes-dangling-profile-sync-") as temporary:
        root = Path(temporary)
        source = root / "source"
        staging = root / "staging"
        target = root / "target"
        (source / "profiles").mkdir(parents=True)
        staging.mkdir(mode=0o700)
        sentinel = seed_target_sentinel(target)
        staged = run_stage(source, staging)
        if staged.returncode:
            fail(f"host SQLite staging failed:\n{staged.stderr}")
        (source / "profiles" / "implementer").symlink_to(
            source / "missing-profile", target_is_directory=True
        )

        synced = run_sync(source, staging, target)
        assert_rejected_before_target_mutation(
            synced, sentinel, "Pod preflight dangling profile symlink"
        )


def validate_pod_preflight_rejects_dangling_database_symlink() -> None:
    with tempfile.TemporaryDirectory(prefix="hermes-dangling-database-sync-") as temporary:
        root = Path(temporary)
        source = root / "source"
        staging = root / "staging"
        target = root / "target"
        source.mkdir()
        staging.mkdir(mode=0o700)
        sentinel = seed_target_sentinel(target)
        staged = run_stage(source, staging)
        if staged.returncode:
            fail(f"host SQLite staging failed:\n{staged.stderr}")
        (source / "state.db").symlink_to(source / "missing-state.db")

        synced = run_sync(source, staging, target)
        assert_rejected_before_target_mutation(
            synced, sentinel, "Pod preflight dangling database symlink"
        )


def validate_concurrent_wal_writer_is_retained() -> None:
    with tempfile.TemporaryDirectory(prefix="hermes-concurrent-wal-") as temporary:
        root = Path(temporary)
        source = root / "source"
        staging = root / "staging"
        database = source / "state.db"
        source.mkdir()
        staging.mkdir(mode=0o700)
        connection = sqlite3.connect(database)
        try:
            if connection.execute("PRAGMA journal_mode=WAL").fetchone() != ("wal",):
                fail("concurrent-writer fixture did not enter WAL mode")
            connection.execute("PRAGMA wal_autocheckpoint=0")
            connection.execute("CREATE TABLE retained(value TEXT NOT NULL)")
            connection.execute("INSERT INTO retained VALUES ('committed-in-wal')")
            connection.commit()
            wal = Path(f"{database}-wal")
            if not wal.is_file() or wal.stat().st_size <= 32:
                fail("concurrent-writer fixture did not retain committed WAL frames")

            staged = run_stage(source, staging)
            if staged.returncode:
                fail(f"concurrent WAL staging failed:\n{staged.stderr}")
            staged_database = staging / "state.db"
            with sqlite3.connect(
                f"file:{staged_database}?mode=ro", uri=True
            ) as staged_connection:
                if staged_connection.execute("PRAGMA quick_check").fetchone() != ("ok",):
                    fail("concurrent WAL staged backup failed quick_check")
                if staged_connection.execute("PRAGMA journal_mode").fetchone() != (
                    "delete",
                ):
                    fail("concurrent WAL staged backup is not self-contained")
                if staged_connection.execute("SELECT value FROM retained").fetchone() != (
                    "committed-in-wal",
                ):
                    fail("concurrent WAL staged backup lost committed WAL data")
            for suffix in ("-wal", "-shm"):
                if Path(f"{staged_database}{suffix}").exists():
                    fail(f"concurrent WAL staged backup retained {suffix} sidecar")
        finally:
            connection.close()


def validate_staged_sqlite_regression() -> None:
    script = MIGRATION.read_text()
    sync_python = heredoc_body(script, "SYNC_STATE_PY")
    if ".backup(" in sync_python or "immutable=1" in sync_python:
        fail("Pod sync must install staged backups without opening live SQLite databases")
    if "shutil.copy2(staged" in sync_python:
        fail("Pod sync must not reopen a staged database pathname after validation")
    require(
        sync_python,
        "copy_staged_descriptor(staged_fd, temporary_fd)",
        "descriptor-bound staged database copy",
    )

    with tempfile.TemporaryDirectory(prefix="hermes-sqlite-regression-") as temporary:
        root = Path(temporary)
        source = root / "source"
        staging = root / "staging"
        target = root / "target"
        database = source / "profiles" / "implementer" / "projects.db"
        database.parent.mkdir(parents=True)
        top_config = b"top-level-selected-regular-file\n"
        profile_config = b"profile-selected-regular-file\n"
        (source / "config.yaml").write_bytes(top_config)
        (database.parent / "config.yaml").write_bytes(profile_config)
        staging.mkdir(mode=0o700)
        target.mkdir()

        connection = sqlite3.connect(database)
        try:
            if connection.execute("PRAGMA journal_mode=WAL").fetchone() != ("wal",):
                fail("fixture did not enter WAL mode")
            connection.execute("CREATE TABLE retained(value TEXT NOT NULL)")
            connection.execute("INSERT INTO retained VALUES ('staged')")
            connection.commit()
            connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        finally:
            connection.close()
        for suffix in ("-wal", "-shm"):
            if Path(f"{database}{suffix}").exists():
                fail(f"fixture unexpectedly retained {suffix} sidecar")

        staged = run_stage(source, staging)
        if staged.returncode:
            fail(f"host SQLite staging failed:\n{staged.stderr}")

        # Model the Pod's read-only source and staging mounts. The executable
        # sync must consume the staged backup, not reopen or raw-copy the live DB.
        database.chmod(0o444)
        database.parent.chmod(0o555)
        source.joinpath("profiles").chmod(0o555)
        source.chmod(0o555)
        for path in staging.rglob("*"):
            path.chmod(0o555 if path.is_dir() else 0o444)
        staging.chmod(0o555)

        (target / "state.db").write_text("stale")
        (target / "profiles" / "reviewer").mkdir(parents=True)
        (target / "profiles" / "reviewer" / "stale").write_text("stale")
        synced = run_sync(source, staging, target)
        if synced.returncode:
            fail(f"staged initial sync failed:\n{synced.stderr}")

        if (target / "config.yaml").read_bytes() != top_config:
            fail("initial sync did not copy exact top-level selected regular-file bytes")
        if (
            target / "profiles" / "implementer" / "config.yaml"
        ).read_bytes() != profile_config:
            fail("initial sync did not copy exact profile selected regular-file bytes")
        copied = target / "profiles" / "implementer" / "projects.db"
        with sqlite3.connect(f"file:{copied}?mode=ro", uri=True) as connection:
            if connection.execute("PRAGMA quick_check").fetchone() != ("ok",):
                fail("copied staged database failed quick_check")
            if connection.execute("SELECT value FROM retained").fetchone() != ("staged",):
                fail("copied staged database lost retained data")
        if (target / "state.db").exists() or (target / "profiles" / "reviewer").exists():
            fail("absent database/profile did not remove stale target state")


def assert_post_preflight_source_swap_is_safe(
    result: subprocess.CompletedProcess[str],
    target: Path,
    sentinel: Path,
    expected_profile_value: str,
    external_value: str,
    description: str,
) -> None:
    copied_profile = target / "profiles" / "implementer" / "config.yaml"
    if result.returncode:
        fail(f"{description} failed instead of copying retained source data:\n{result.stderr}")
    if not sentinel.is_file() or sentinel.read_text() != "new-top-level":
        fail(f"{description} did not copy the retained source-root file")
    if not copied_profile.is_file() or copied_profile.read_text() != expected_profile_value:
        fail(f"{description} did not stay bound to the retained profile inode")
    for path in target.rglob("*"):
        if path.is_file() and path.read_text(errors="ignore") == external_value:
            fail(f"{description} copied data from a replacement/external source tree")


def validate_post_preflight_profiles_symlink_swap_is_descriptor_bound() -> None:
    with tempfile.TemporaryDirectory(prefix="hermes-profiles-symlink-race-") as temporary:
        root = Path(temporary)
        source = root / "source"
        staging = root / "staging"
        target = root / "target"
        original_profiles = root / "original-profiles"
        external_profiles = root / "external-profiles"
        source.mkdir()
        (source / "config.yaml").write_text("new-top-level")
        create_database(source / "profiles" / "implementer" / "projects.db", "original")
        (source / "profiles" / "implementer" / "config.yaml").write_text(
            "original-profile"
        )
        (external_profiles / "implementer").mkdir(parents=True)
        (external_profiles / "implementer" / "config.yaml").write_text(
            "external-profile"
        )
        staging.mkdir(mode=0o700)
        sentinel = seed_target_sentinel(target)
        staged = run_stage(source, staging)
        if staged.returncode:
            fail(f"host SQLite staging failed:\n{staged.stderr}")
        hook = (
            f"SOURCE.joinpath('profiles').rename(Path({str(original_profiles)!r}))\n"
            f"SOURCE.joinpath('profiles').symlink_to(Path({str(external_profiles)!r}), "
            "target_is_directory=True)"
        )
        synced = run_sync(source, staging, target, before_target_mutation=hook)
        assert_post_preflight_source_swap_is_safe(
            synced,
            target,
            sentinel,
            "original-profile",
            "external-profile",
            "post-preflight SOURCE/profiles external symlink replacement",
        )


def validate_post_preflight_profiles_directory_swap_is_descriptor_bound() -> None:
    with tempfile.TemporaryDirectory(prefix="hermes-profiles-directory-race-") as temporary:
        root = Path(temporary)
        source = root / "source"
        staging = root / "staging"
        target = root / "target"
        original_profiles = root / "original-profiles"
        source.mkdir()
        (source / "config.yaml").write_text("new-top-level")
        create_database(source / "profiles" / "implementer" / "projects.db", "original")
        (source / "profiles" / "implementer" / "config.yaml").write_text(
            "original-profile"
        )
        staging.mkdir(mode=0o700)
        sentinel = seed_target_sentinel(target)
        staged = run_stage(source, staging)
        if staged.returncode:
            fail(f"host SQLite staging failed:\n{staged.stderr}")
        hook = (
            f"SOURCE.joinpath('profiles').rename(Path({str(original_profiles)!r}))\n"
            "SOURCE.joinpath('profiles', 'implementer').mkdir(parents=True)\n"
            "SOURCE.joinpath('profiles', 'implementer', 'config.yaml').write_text("
            "'replacement-profile')"
        )
        synced = run_sync(source, staging, target, before_target_mutation=hook)
        assert_post_preflight_source_swap_is_safe(
            synced,
            target,
            sentinel,
            "original-profile",
            "replacement-profile",
            "post-preflight same-shape profiles directory replacement",
        )


def validate_post_preflight_profile_disappearance_is_descriptor_bound() -> None:
    with tempfile.TemporaryDirectory(prefix="hermes-profile-disappearance-race-") as temporary:
        root = Path(temporary)
        source = root / "source"
        staging = root / "staging"
        target = root / "target"
        retained_profile = root / "retained-implementer"
        source.mkdir()
        (source / "config.yaml").write_text("new-top-level")
        create_database(source / "profiles" / "implementer" / "projects.db", "original")
        (source / "profiles" / "implementer" / "config.yaml").write_text(
            "original-profile"
        )
        staging.mkdir(mode=0o700)
        sentinel = seed_target_sentinel(target)
        staged = run_stage(source, staging)
        if staged.returncode:
            fail(f"host SQLite staging failed:\n{staged.stderr}")
        hook = (
            "SOURCE.joinpath('profiles', 'implementer').rename("
            f"Path({str(retained_profile)!r}))"
        )
        synced = run_sync(source, staging, target, before_target_mutation=hook)
        assert_post_preflight_source_swap_is_safe(
            synced,
            target,
            sentinel,
            "original-profile",
            "never-exists",
            "staged-present profile disappearance after preflight",
        )


def validate_post_preflight_source_root_swap_is_descriptor_bound() -> None:
    with tempfile.TemporaryDirectory(prefix="hermes-source-root-race-") as temporary:
        root = Path(temporary)
        source = root / "source"
        staging = root / "staging"
        target = root / "target"
        retained_source = root / "retained-source"
        external_source = root / "external-source"
        source.mkdir()
        (source / "config.yaml").write_text("new-top-level")
        (source / "profiles" / "implementer").mkdir(parents=True)
        (source / "profiles" / "implementer" / "config.yaml").write_text(
            "original-profile"
        )
        (external_source / "profiles" / "implementer").mkdir(parents=True)
        (external_source / "config.yaml").write_text("external-top-level")
        (external_source / "profiles" / "implementer" / "config.yaml").write_text(
            "external-profile"
        )
        staging.mkdir(mode=0o700)
        sentinel = seed_target_sentinel(target)
        staged = run_stage(source, staging)
        if staged.returncode:
            fail(f"host SQLite staging failed:\n{staged.stderr}")
        hook = (
            f"SOURCE.rename(Path({str(retained_source)!r}))\n"
            f"SOURCE.symlink_to(Path({str(external_source)!r}), target_is_directory=True)"
        )
        synced = run_sync(source, staging, target, before_target_mutation=hook)
        assert_post_preflight_source_swap_is_safe(
            synced,
            target,
            sentinel,
            "original-profile",
            "external-profile",
            "post-preflight source-root external symlink replacement",
        )


def validate_source_mount_identity_mismatch_rejected_before_mutation() -> None:
    with tempfile.TemporaryDirectory(prefix="hermes-source-mount-identity-") as temporary:
        root = Path(temporary)
        source = root / "source"
        staging = root / "staging"
        target = root / "target"
        source.mkdir()
        (source / "config.yaml").write_text("replacement")
        staging.mkdir(mode=0o700)
        sentinel = seed_target_sentinel(target)
        device, inode = directory_identity(source)
        synced = run_sync(
            source,
            staging,
            target,
            phase="final",
            expected_source_identity=(device, inode + 1),
        )
        assert_rejected_before_target_mutation(
            synced, sentinel, "source-root/mount identity mismatch"
        )


def validate_same_shape_source_root_replacement_rejected_before_mutation() -> None:
    with tempfile.TemporaryDirectory(prefix="hermes-source-root-replacement-") as temporary:
        root = Path(temporary)
        source = root / "source"
        staging = root / "staging"
        target = root / "target"
        retained_source = root / "retained-source"
        source.mkdir()
        (source / "config.yaml").write_text("original")
        (source / "profiles" / "implementer").mkdir(parents=True)
        staging.mkdir(mode=0o700)
        sentinel = seed_target_sentinel(target)
        expected_identity = directory_identity(source)
        staged = run_stage(source, staging, expected_identity)
        if staged.returncode:
            fail(f"host SQLite staging failed:\n{staged.stderr}")
        source.rename(retained_source)
        source.mkdir()
        (source / "config.yaml").write_text("replacement")
        (source / "profiles" / "implementer").mkdir(parents=True)
        synced = run_sync(
            source, staging, target, expected_source_identity=expected_identity
        )
        assert_rejected_before_target_mutation(
            synced, sentinel, "same-shape source-root replacement after host staging"
        )


def validate_same_shape_profiles_parent_replacement_rejected_before_mutation() -> None:
    with tempfile.TemporaryDirectory(prefix="hermes-profiles-parent-replacement-") as temporary:
        root = Path(temporary)
        source = root / "source"
        staging = root / "staging"
        target = root / "target"
        retained_profiles = root / "retained-profiles"
        source.mkdir()
        (source / "profiles" / "implementer").mkdir(parents=True)
        (source / "profiles" / "implementer" / "config.yaml").write_text("original")
        staging.mkdir(mode=0o700)
        sentinel = seed_target_sentinel(target)
        expected_identity = directory_identity(source)
        staged = run_stage(source, staging, expected_identity)
        if staged.returncode:
            fail(f"host SQLite staging failed:\n{staged.stderr}")
        (source / "profiles").rename(retained_profiles)
        (source / "profiles" / "implementer").mkdir(parents=True)
        (source / "profiles" / "implementer" / "config.yaml").write_text("replacement")
        synced = run_sync(
            source, staging, target, expected_source_identity=expected_identity
        )
        assert_rejected_before_target_mutation(
            synced, sentinel, "same-shape profiles-parent replacement after host staging"
        )


def validate_host_source_identity_walk_rejects_final_symlink_paths() -> None:
    script = MIGRATION.read_text()
    identity_function = shell_function(script, "read_source_root_identity")
    with tempfile.TemporaryDirectory(prefix="hermes-host-source-identity-") as temporary:
        root = Path(temporary)
        real_parent = root / "real-parent"
        real_source = real_parent / "source"
        real_source.mkdir(parents=True)
        root_symlink = root / "source-link"
        root_symlink.symlink_to(real_source, target_is_directory=True)
        ancestor_symlink = root / "parent-link"
        ancestor_symlink.symlink_to(real_parent, target_is_directory=True)
        harness = f"""set -euo pipefail
{identity_function}
SOURCE_HOME="$REAL_SOURCE"
identity="$(read_source_root_identity)"
[ "$identity" = "$EXPECTED_IDENTITY" ]
SOURCE_HOME="$ROOT_SYMLINK"
if read_source_root_identity >/dev/null 2>&1; then
  printf '%s\\n' 'accepted symlinked SOURCE_HOME root' >&2
  exit 1
fi
SOURCE_HOME="$ANCESTOR_SYMLINK/source"
if read_source_root_identity >/dev/null 2>&1; then
  printf '%s\\n' 'accepted symlinked SOURCE_HOME ancestor' >&2
  exit 1
fi
"""
        result = subprocess.run(
            ["bash", "-c", harness],
            text=True,
            capture_output=True,
            check=False,
            env={
                **os.environ,
                "REAL_SOURCE": str(real_source),
                "ROOT_SYMLINK": str(root_symlink),
                "ANCESTOR_SYMLINK": str(ancestor_symlink),
                "EXPECTED_IDENTITY": "|".join(
                    str(value) for value in directory_identity(real_source)
                ),
            },
        )
        if result.returncode:
            fail(f"host final-sync source identity walk is unsafe:\n{result.stderr}")


def main() -> int:
    checks = (
        validate_manifests,
        validate_migration_script,
        validate_cleanup_failure_is_aggregated,
        validate_cleanup_success_control,
        validate_ambiguous_admitted_create_is_operation_uid_cleaned,
        validate_cleanup_get_is_bounded,
        validate_operation_delete_collection_uses_real_kubectl_transport,
        validate_late_admitted_create_is_found_and_exit_cleaned,
        validate_immediate_absence_does_not_clear_unknown_create_handle,
        validate_full_create_reconciliation_window_proves_absence,
        validate_create_reconciliation_api_error_retains_unknown_handle,
        validate_stale_migration_operation_is_rejected_before_create,
        validate_staging_cleanup_failure_retains_handle,
        validate_set_e_exit_trap_retries_failed_aggregate_cleanup,
        validate_staging_manifest_contract,
        validate_staged_database_substitution_rejected_before_target_mutation,
        validate_host_stage_rejects_dangling_profiles_parent_symlink,
        validate_host_stage_rejects_external_profiles_parent_symlink,
        validate_host_stage_rejects_dangling_profile_symlink,
        validate_host_stage_rejects_dangling_database_symlink,
        validate_profile_disappearance_rejected_before_target_mutation,
        validate_pod_preflight_rejects_dangling_profiles_parent_symlink,
        validate_pod_preflight_rejects_external_profiles_parent_symlink,
        validate_pod_preflight_rejects_dangling_profile_symlink,
        validate_pod_preflight_rejects_dangling_database_symlink,
        validate_duplicate_manifest_key_is_rejected,
        validate_noncanonical_manifest_values_are_rejected,
        validate_concurrent_wal_writer_is_retained,
        validate_staged_sqlite_regression,
        validate_post_preflight_profiles_symlink_swap_is_descriptor_bound,
        validate_post_preflight_profiles_directory_swap_is_descriptor_bound,
        validate_post_preflight_profile_disappearance_is_descriptor_bound,
        validate_post_preflight_source_root_swap_is_descriptor_bound,
        validate_source_mount_identity_mismatch_rejected_before_mutation,
        validate_same_shape_source_root_replacement_rejected_before_mutation,
        validate_same_shape_profiles_parent_replacement_rejected_before_mutation,
        validate_host_source_identity_walk_rejects_final_symlink_paths,
    )
    failures = []
    for check in checks:
        try:
            check()
        except (AssertionError, OSError, ValueError, sqlite3.Error) as exc:
            failures.append(f"{check.__name__}: {exc}")
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        print(f"FAIL: {len(failures)} of {len(checks)} checks failed", file=sys.stderr)
        return 1
    print(f"PASS: all {len(checks)} Hermes Agent manifest and migration checks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
