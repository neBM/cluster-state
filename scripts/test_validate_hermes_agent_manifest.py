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
import time
import urllib.parse
from pathlib import Path
from typing import NoReturn

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "apps/hermes-agent"
MIGRATION = ROOT / "scripts/hermes-agent-migration.sh"
CUTOVER = ROOT / "scripts/hermes-agent-cutover.sh"
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
    ci = (ROOT / ".gitlab-ci.yml").read_text()
    manifest_rules = re.search(r"^\.validate_manifest_rules:[^\n]*\n(?P<body>.*?)(?=^\S)", ci, re.MULTILINE | re.DOTALL)
    if manifest_rules is None:
        fail(".gitlab-ci.yml lacks .validate_manifest_rules")
    changes_lists = dict(re.findall(r"^  - if: (?P<condition>[^\n]+)\n    changes:\n(?P<changes>(?:      - [^\n]+\n)+)", manifest_rules.group("body"), re.MULTILINE))
    for condition in ('$CI_PIPELINE_SOURCE == "merge_request_event"', '$CI_COMMIT_BRANCH == "main"'):
        if "      - scripts/hermes-agent-cutover.sh\n" not in changes_lists.get(condition, ""):
            fail(f".validate_manifest_rules lacks cutover validation trigger for {condition}")

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
    expected_ports = {("api", "8642", "8642"), ("webhook", "8644", "8644")}
    actual_ports = set(re.findall(r"- name: (\w+)\n\s+port: (\d+)\n\s+protocol: TCP\n\s+targetPort: (\d+)", service))
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
    if re.findall(r'^\s*(timeout\s+\S+\s+systemctl --user stop "\$SOURCE_UNIT")$', final_sync, re.MULTILINE) != ['timeout 120s systemctl --user stop "$SOURCE_UNIT"']:
        fail("final-sync source stop must use the exact 120-second outer timeout")
    ordered(
        final_sync,
        ['timeout 120s systemctl --user stop "$SOURCE_UNIT"', "wait_for_source_inactive", "require_candidate_target", "run_sync final"],
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
    if script.count("mountPath: /source") != 1 or not re.search(r"- name: source\n\s+mountPath: /source\n\s+readOnly: true", script):
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
    require(
        operation_delete,
        'delete --raw="/api/v1/namespaces/${NAMESPACE}/pods/${pod}" -f -',
        "exact-name raw Pod DELETE transport",
    )
    require(
        operation_delete,
        '"preconditions":{"uid":"%s","resourceVersion":"%s"}',
        "UID/resourceVersion DeleteOptions preconditions",
    )
    if "labelSelector=" in operation_delete or "fieldSelector=" in operation_delete:
        fail("migration cleanup must not use selector-scoped DeleteCollection")
    require(
        operation_delete,
        'kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT"',
        "bounded singular DELETE request",
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
            'timeout 120s systemctl --user stop "$SOURCE_UNIT"',
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
      printf '%s|%s|%s|1\\n' "$MIGRATION_POD" "$MIGRATION_POD_UID" "$MIGRATION_OPERATION_ID"
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
        printf '%s|%s|%s|1\\n' "$MIGRATION_POD" "$MIGRATION_POD_UID" "$MIGRATION_OPERATION_ID"
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
        case " $* " in
          *resourceVersion*) printf '%s|%s|%s|1\\n' "$EXPECTED_POD" "$EXPECTED_UID" "$EXPECTED_OPERATION" ;;
          *) printf '%s|%s\\n' "$EXPECTED_UID" "$EXPECTED_OPERATION" ;;
        esac
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


def validate_preconditioned_delete_converges_with_real_kubectl_transport() -> None:
    script = MIGRATION.read_text()
    functions = "".join(
        shell_function(script, name)
        for name in ("delete_migration_pod_owned_collection", "cleanup_migration_pod")
    )
    operation = "0123456789abcdef0123456789abcdef"
    pod = f"hermes-agent-migration-{operation}"
    uid = "11111111-2222-3333-4444-555555555555"

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

        def read_request_body(self) -> bytes:
            if self.headers.get("Transfer-Encoding", "").lower() != "chunked":
                length = int(self.headers.get("Content-Length", "0"))
                return self.rfile.read(length)
            chunks = []
            while True:
                size_line = self.rfile.readline().strip()
                size = int(size_line.split(b";", 1)[0], 16)
                if size == 0:
                    while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                        pass
                    return b"".join(chunks)
                chunks.append(self.rfile.read(size))
                if self.rfile.read(2) != b"\r\n":
                    raise RuntimeError("malformed chunked kubectl request")

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
                if getattr(self.server, "fail_get_after_delete") and getattr(
                    self.server, "delete_accepted"
                ):
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
                if current is not None and getattr(self.server, "delete_accepted"):
                    post_delete_gets = getattr(self.server, "post_delete_gets") + 1
                    setattr(self.server, "post_delete_gets", post_delete_gets)
                    replacement = getattr(self.server, "replace_after_delete")
                    if post_delete_gets == 1 and replacement is not None:
                        current = replacement
                        setattr(self.server, "pod", current)
                    elif post_delete_gets > 2:
                        current = None
                        setattr(self.server, "pod", None)
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
            body = self.read_request_body()
            getattr(self.server, "delete_requests").append((parsed, body))
            replacement = getattr(self.server, "replace_before_delete")
            if replacement is not None:
                setattr(self.server, "pod", replacement)
            current = getattr(self.server, "pod")
            try:
                delete_options = json.loads(body)
            except (json.JSONDecodeError, UnicodeDecodeError):
                delete_options = None
            expected_preconditions = None
            if current is not None:
                expected_preconditions = {
                    "uid": current["metadata"].get("uid"),
                    "resourceVersion": current["metadata"].get("resourceVersion"),
                }
            if (
                parsed.path != f"/api/v1/namespaces/default/pods/{pod}"
                or urllib.parse.parse_qs(parsed.query) != {"timeout": ["3s"]}
                or not isinstance(current, dict)
                or not isinstance(delete_options, dict)
                or delete_options.get("apiVersion") != "v1"
                or delete_options.get("kind") != "DeleteOptions"
                or delete_options.get("preconditions") != expected_preconditions
            ):
                self.send_object(
                    409,
                    {
                        "apiVersion": "v1",
                        "kind": "Status",
                        "status": "Failure",
                        "reason": "Conflict",
                        "code": 409,
                    },
                )
                return
            current["metadata"]["deletionTimestamp"] = "2026-09-02T20:00:00Z"
            current["metadata"]["resourceVersion"] = "2"
            setattr(self.server, "delete_accepted", True)
            self.send_object(
                200,
                {
                    "apiVersion": "v1",
                    "kind": "Status",
                    "status": "Success",
                    "code": 200,
                },
            )

    def pod_object(
        current_name: str = pod,
        current_uid: str = uid,
        current_operation: str = operation,
        resource_version: str | None = "1",
    ) -> dict[str, object]:
        metadata: dict[str, object] = {
            "name": current_name,
            "namespace": "default",
            "uid": current_uid,
            "labels": {
                "app.kubernetes.io/name": "hermes-agent-migration",
                "hermes-agent-migration-operation": current_operation,
            },
        }
        if resource_version is not None:
            metadata["resourceVersion"] = resource_version
        return {"apiVersion": "v1", "kind": "Pod", "metadata": metadata}

    with tempfile.TemporaryDirectory(prefix="hermes-preconditioned-delete-") as temporary:
        root = Path(temporary)

        def run_cleanup(
            initial_pod: dict[str, object],
            *,
            expect_success: bool,
            fail_get_after_delete: bool = False,
            replace_before_delete: dict[str, object] | None = None,
            replace_after_delete: dict[str, object] | None = None,
        ) -> tuple[
            subprocess.CompletedProcess[str],
            list[tuple[urllib.parse.SplitResult, bytes]],
            int,
            dict[str, object] | None,
        ]:
            server = http.server.ThreadingHTTPServer(
                ("127.0.0.1", 0), FakeKubernetesAPI
            )
            setattr(server, "pod", initial_pod)
            setattr(server, "delete_requests", [])
            setattr(server, "get_requests", [])
            setattr(server, "delete_accepted", False)
            setattr(server, "post_delete_gets", 0)
            setattr(server, "fail_get_after_delete", fail_get_after_delete)
            setattr(server, "replace_before_delete", replace_before_delete)
            setattr(server, "replace_after_delete", replace_after_delete)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            kubeconfig = root / f"kubeconfig-{server.server_port}"
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
            harness = f"""set -euo pipefail
NAMESPACE=default
MIGRATION_POD="$EXPECTED_POD"
MIGRATION_POD_UID="$EXPECTED_UID"
MIGRATION_OPERATION_ID="$EXPECTED_OPERATION"
MIGRATION_CREATE_ABSENCE_RECONCILED=0
KUBECTL_REQUEST_TIMEOUT=3s
KUBECTL_OUTER_TIMEOUT=5s
KUBECTL_DELETE_OUTER_TIMEOUT=5s
KUBECTL_DELETE_VERIFY_OUTER_TIMEOUT=5s
sleep() {{ :; }}
{functions}
if cleanup_migration_pod; then
  cleanup_status=0
else
  cleanup_status=$?
fi
if [ "$EXPECT_SUCCESS" -eq 1 ]; then
  [ "$cleanup_status" -eq 0 ]
  [ -z "$MIGRATION_POD" ]
  [ -z "$MIGRATION_POD_UID" ]
  [ -z "$MIGRATION_OPERATION_ID" ]
else
  [ "$cleanup_status" -ne 0 ]
  [ "$MIGRATION_POD" = "$EXPECTED_POD" ]
  [ "$MIGRATION_POD_UID" = "$EXPECTED_UID" ]
  [ "$MIGRATION_OPERATION_ID" = "$EXPECTED_OPERATION" ]
fi
"""
            try:
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
                        "EXPECT_SUCCESS": "1" if expect_success else "0",
                    },
                    timeout=20,
                )
                requests = list(getattr(server, "delete_requests"))
                post_delete_gets = getattr(server, "post_delete_gets")
                remaining_pod = getattr(server, "pod")
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=5)
            return result, requests, post_delete_gets, remaining_pod

        result, requests, post_delete_gets, _ = run_cleanup(
            pod_object(), expect_success=True
        )
        if result.returncode:
            fail(
                "preconditioned cleanup did not converge:\n"
                f"{result.stderr} requests={requests!r}"
            )
        if len(requests) != 1:
            fail(
                f"expected one real kubectl DELETE, observed {len(requests)}; "
                f"stdout={result.stdout!r} stderr={result.stderr!r}"
            )
        parsed, body = requests[0]
        if parsed.path != f"/api/v1/namespaces/default/pods/{pod}" or (
            urllib.parse.parse_qs(parsed.query) != {"timeout": ["3s"]}
        ):
            fail(f"cleanup did not use exact-name singular DELETE: {parsed!r}")
        delete_options = json.loads(body)
        if delete_options.get("preconditions") != {
            "uid": uid,
            "resourceVersion": "1",
        }:
            fail(f"raw delete lacks exact object preconditions: {delete_options!r}")
        if post_delete_gets < 3:
            fail("cleanup did not poll through temporary post-delete visibility")

        for description, initial_pod in (
            ("replacement UID", pod_object(current_uid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")),
            (
                "wrong operation label",
                pod_object(current_operation="fedcba9876543210fedcba9876543210"),
            ),
            ("wrong response name", pod_object(current_name=f"{pod}-replacement")),
            ("malformed identity", pod_object(resource_version=None)),
        ):
            result, requests, _, _ = run_cleanup(initial_pod, expect_success=False)
            if result.returncode:
                fail(f"{description} cleanup control failed:\n{result.stderr}")
            if requests:
                fail(f"cleanup issued DELETE for {description}")

        for description, replacement in (
            (
                "same-name replacement UID race",
                pod_object(
                    current_uid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                    resource_version="2",
                ),
            ),
            (
                "operation-label drift race",
                pod_object(
                    current_operation="fedcba9876543210fedcba9876543210",
                    resource_version="2",
                ),
            ),
        ):
            result, requests, _, remaining_pod = run_cleanup(
                pod_object(),
                expect_success=False,
                replace_before_delete=replacement,
            )
            if result.returncode:
                fail(f"{description} cleanup control failed:\n{result.stderr}")
            if len(requests) != 1 or remaining_pod != replacement:
                fail(f"preconditioned DELETE did not preserve {description}")

        replacement = pod_object(
            current_uid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            current_operation="fedcba9876543210fedcba9876543210",
            resource_version="3",
        )
        result, requests, _, remaining_pod = run_cleanup(
            pod_object(),
            expect_success=False,
            replace_after_delete=replacement,
        )
        if result.returncode:
            fail(f"post-delete replacement cleanup control failed:\n{result.stderr}")
        if len(requests) != 1 or remaining_pod != replacement:
            fail("cleanup retried DELETE or removed a post-delete replacement")

        result, requests, _, _ = run_cleanup(
            pod_object(), expect_success=False, fail_get_after_delete=True
        )
        if result.returncode:
            fail(f"post-delete GET error control failed:\n{result.stderr}")
        if len(requests) != 1:
            fail("post-delete GET error path did not issue exactly one guarded DELETE")


def validate_cleanup_deadline_retains_owned_handle() -> None:
    cleanup = shell_function(MIGRATION.read_text(), "cleanup_migration_pod")
    operation = "0123456789abcdef0123456789abcdef"
    pod = f"hermes-agent-migration-{operation}"
    uid = "11111111-2222-3333-4444-555555555555"
    harness = f"""set -euo pipefail
NAMESPACE=default
MIGRATION_POD="$EXPECTED_POD"
MIGRATION_POD_UID="$EXPECTED_UID"
MIGRATION_OPERATION_ID="$EXPECTED_OPERATION"
MIGRATION_CREATE_ABSENCE_RECONCILED=0
KUBECTL_REQUEST_TIMEOUT=1s
KUBECTL_OUTER_TIMEOUT=2s
KUBECTL_DELETE_VERIFY_OUTER_TIMEOUT=3s
timeout() {{ if [ "${{1:-}}" = --foreground ]; then shift; fi; shift; "$@"; }}
sleep() {{ SECONDS=$((SECONDS + 1)); }}
kubectl() {{
  case " $* " in
    *" get pod $EXPECTED_POD "*)
      printf '%s|%s|%s|1\\n' "$EXPECTED_POD" "$EXPECTED_UID" "$EXPECTED_OPERATION"
      return 0
      ;;
    *" wait --for=delete pod/$EXPECTED_POD "*) return 1 ;;
    *) return 64 ;;
  esac
}}
delete_migration_pod_owned_collection() {{ return 0; }}
{cleanup}
start_seconds=$SECONDS
if cleanup_migration_pod; then
  printf '%s\\n' 'cleanup unexpectedly accepted a surviving owned Pod' >&2
  exit 1
fi
elapsed=$((SECONDS - start_seconds))
[ "$elapsed" -ge 3 ]
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
            "EXPECTED_POD": pod,
            "EXPECTED_UID": uid,
            "EXPECTED_OPERATION": operation,
        },
    )
    if result.returncode:
        fail(f"cleanup deadline control failed:\n{result.stderr}")


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
        case " $* " in
          *resourceVersion*) printf '%s|%s|%s|1\\n' "$EXPECTED_POD" "$EXPECTED_UID" "$EXPECTED_OPERATION" ;;
          *) printf '%s|%s\\n' "$EXPECTED_UID" "$EXPECTED_OPERATION" ;;
        esac
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


def validate_final_sync_replaces_then_recovers_selected_state() -> None:
    with tempfile.TemporaryDirectory(prefix="hermes-final-sync-") as temporary:
        root = Path(temporary)
        source, target, staging = root / "source", root / "target", root / "staging"
        nested = source / "sessions" / "nested"
        nested.mkdir(parents=True)
        (source / "profiles" / "implementer").mkdir(parents=True)
        (source / "config.yaml").write_text("current")
        (source / "profiles" / "implementer" / "config.yaml").write_text("profile")
        create_database(source / "state.db", "state")
        create_database(source / "hermes_state.db", "hermes")
        suffix_database = nested / "archive-journal"
        create_database(suffix_database, "suffix-database")
        (nested / "notes-wal").write_bytes(b"unrelated suffix data")
        wal_database = nested / "events.sqlite"
        connection = sqlite3.connect(wal_database)
        try:
            connection.execute("PRAGMA journal_mode=WAL")
            connection.execute("PRAGMA wal_autocheckpoint=0")
            connection.execute("CREATE TABLE retained(value TEXT NOT NULL)")
            connection.execute("INSERT INTO retained VALUES ('committed-wal')")
            connection.commit()
            wal_database.chmod(0o700)
            source_snapshot = {
                str(path.relative_to(source)): (path.read_bytes(), path.stat().st_mode & 0o777)
                for path in source.rglob("*") if path.is_file()
            }
            target.mkdir()
            (target / "state.db").write_bytes(b"SQLite format 3\x00corrupt")
            (target / "hermes_state.db").mkdir()
            (target / "config.yaml").mkdir()
            (target / "profiles").write_text("wrong type")
            (target / "stale").write_text("remove")
            synced = run_sync(source, staging, target, phase="final")
            if synced.returncode:
                fail(f"stopped-source final sync failed:\n{synced.stderr}")
            if source_snapshot != {
                str(path.relative_to(source)): (path.read_bytes(), path.stat().st_mode & 0o777)
                for path in source.rglob("*") if path.is_file()
            }:
                fail("final sync mutated the stopped source fixture")
        finally:
            connection.close()
        for actual, value in ((target / "state.db", "state"), (target / "hermes_state.db", "hermes"),
                              (target / "sessions" / "nested" / "archive-journal", "suffix-database"),
                              (target / "sessions" / "nested" / "events.sqlite", "committed-wal")):
            with sqlite3.connect(f"file:{actual}?mode=ro", uri=True) as database:
                if database.execute("SELECT value FROM retained").fetchone() != (value,):
                    fail(f"final sync lost database content: {actual}")
                if database.execute("PRAGMA journal_mode").fetchone() != ("delete",):
                    fail(f"final sync did not select DELETE mode: {actual}")
        copied_wal = target / "sessions" / "nested" / "events.sqlite"
        if copied_wal.stat().st_mode & 0o777 != 0o700:
            fail("final sync did not preserve database mode")
        if (target / "sessions" / "nested" / "notes-wal").read_bytes() != b"unrelated suffix data":
            fail("final sync removed unrelated suffix-named selected data")
        if not (target / "sessions" / "nested" / "archive-journal").is_file():
            fail("final sync removed a SQLite database ending in -journal")
        databases = (target / "state.db", target / "hermes_state.db", copied_wal,
                     target / "sessions" / "nested" / "archive-journal")
        if any(Path(f"{database}{suffix}").exists() for database in databases for suffix in ("-wal", "-shm", "-journal")):
            fail("final sync retained an associated SQLite sidecar")
        if not (target / "config.yaml").is_file() or not (target / "profiles" / "implementer").is_dir():
            fail("final sync did not replace destination type conflicts")
        if (target / "stale").exists():
            fail("final sync retained stale unapproved target state")
        collision_source, collision_target = root / "collision-source", root / "collision-target"
        (collision_source / "sessions").mkdir(parents=True); collision_target.mkdir()
        create_database(collision_source / "sessions" / "ledger", "main")
        create_database(collision_source / "sessions" / "ledger-journal", "collision")
        collided = run_sync(collision_source, staging, collision_target, phase="final")
        if collided.returncode == 0 or "database/companion path collision" not in collided.stderr:
            fail(f"final sync did not explicitly reject an ambiguous SQLite collision: {collided.stderr}")
        accepted = []
        for index, relative in enumerate((Path("state.db"), Path("profiles/implementer/state.db"))):
            corrupt_source, corrupt_target = root / f"corrupt-source-{index}", root / f"corrupt-target-{index}"
            corrupt_source.mkdir(); corrupt_target.mkdir(); path = corrupt_source / relative
            path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b"not a SQLite database")
            rejected = run_sync(corrupt_source, staging, corrupt_target, phase="final")
            if rejected.returncode == 0: accepted.append(str(relative))
            if path.read_bytes() != b"not a SQLite database": fail("final sync mutated a corrupt source database")
        if accepted: fail(f"final sync accepted corrupt present allowlisted databases: {accepted!r}")
        for index, (parent, suffix) in enumerate((parent, suffix) for parent in (Path("."), Path("profiles/implementer")) for suffix in ("-wal", "-shm", "-journal")):
            orphan_source, orphan_target = root / f"orphan-source-{index}", root / f"orphan-target-{index}"
            (orphan_source / parent).mkdir(parents=True); sentinel = seed_target_sentinel(orphan_target)
            sidecar = orphan_source / parent / f"state.db{suffix}"; sidecar.write_bytes(b"orphan companion")
            rejected = run_sync(orphan_source, staging, orphan_target, phase="final")
            assert_rejected_before_target_mutation(rejected, sentinel, f"orphan allowlisted companion {parent}/state.db{suffix}")
            if sidecar.read_bytes() != b"orphan companion" or "selected final state sync completed" in rejected.stdout:
                fail(f"orphan allowlisted companion was mutated or reported normalized: {parent}/state.db{suffix}")
        script = function_body(MIGRATION.read_text(), "run_sync")
        if 'timeout --foreground 3300s' not in script or "1200s" in script:
            fail("final sync must retain the original 3300-second outer timeout")


def validate_cutover_launcher_control_flow() -> None:
    """Command-double control-flow qualification; not a production cutover rehearsal."""
    original = CUTOVER.read_text()
    revision = "main@sha1:" + "a" * 40

    def run_case(case: str, prior: str | None = None) -> dict[str, object]:
        with tempfile.TemporaryDirectory(prefix=f"hermes-cutover-{case}-") as temporary:
            root, fakebin = Path(temporary), Path(temporary) / "bin"
            source, kubeconfig, dropin = root / "home", root / "kubeconfig", root / "fence.conf"
            source.mkdir(); fakebin.mkdir(); kubeconfig.write_text("fake")
            token, result = source / "gateway-authority.enabled", source / "k8s-cutover-result.json"
            token.touch(mode=0o600)
            dropin.write_bytes(b"[Unit]\nConditionPathExists=/home/ben/.hermes/gateway-authority.enabled\n[Service]\nKillMode=control-group\nTimeoutStopSec=90s\nSendSIGKILL=yes\n")
            dropin.chmod(0o600)
            if prior:
                result.write_text(json.dumps({"state": prior, "lastPhase": prior, "revision": revision,
                                              "fence": "verified-fenced"}) + "\n")
                result.chmod(0o600)
            state, pid, events, activation = root / "state", root / "pid", root / "events", root / "activation"
            barrier, release = root / "barrier", root / "release"
            state.write_text("active"); pid.write_text("4242"); events.write_text("")
            proc_cgroup = root / "proc-cgroup"; proc_cgroup.write_text("0::/control/cutover\n")
            launcher = root / "hermes-agent-cutover.sh"
            transformed = original
            for old, new in {
                'SOURCE_HOME="/home/ben/.hermes"': f'SOURCE_HOME="{source}"',
                'SOURCE_UNIT="hermes-gateway.service"': 'SOURCE_UNIT="fake-source.service"',
                'KUBECONFIG="/home/ben/.kube/config"': f'KUBECONFIG="{kubeconfig}"',
                'DROPIN="/home/ben/.config/systemd/user/hermes-gateway.service.d/20-authority-fence.conf"': f'DROPIN="{dropin}"',
                'PROC_CGROUP="/proc/$$/cgroup"': f'PROC_CGROUP="{proc_cgroup}"',
            }.items():
                transformed = transformed.replace(old, new)
            launcher.write_text(transformed); launcher.chmod(0o755)
            helper = root / "hermes-agent-migration.sh"
            helper.write_text("#!/usr/bin/env bash\nprintf 'helper:%s\\n' \"$1\" >>\"$EVENTS\"\nif [ \"$1\" = final-sync ]; then\n [ ! -e \"$TOKEN\" ] || { printf 'helper-token-present\\n' >>\"$EVENTS\"; exit 8; }\n [ \"$CASE\" != lock-race ] || { : >\"$BARRIER\"; while [ ! -e \"$RELEASE\" ]; do sleep .02; done; }\n case \"$CASE\" in helper-failure|fence-failure) exit 9;; helper-signal) kill -TERM \"$PPID\"; exit 9;; esac\n printf inactive >\"$STATE\"; printf 0 >\"$PID\"\nfi\n")
            helper.chmod(0o755)
            doubles = {
                "timeout": "#!/usr/bin/env bash\n[ \"${1:-}\" = --foreground ] && shift\nshift\nexec \"$@\"\n",
                "python3": "#!/usr/bin/env bash\nif [ \"$CASE\" = result-failure ] && [ \"${3:-}\" = write ] && [ \"${4:-}\" = started ]; then exit 9; fi\nexec /usr/bin/python3 \"$@\"\n",
                "systemctl": """#!/usr/bin/python3
import os,sys
from pathlib import Path
a=sys.argv[1:]; e=Path(os.environ['EVENTS']); e.open('a').write('systemctl:'+ ' '.join(a)+'\\n')
if 'stop' in a:
 if os.environ['CASE']=='fence-failure': raise SystemExit(9)
 Path(os.environ['STATE']).write_text('inactive'); Path(os.environ['PID']).write_text('0'); raise SystemExit(0)
p=a[a.index('-p')+1]; kill='mixed' if os.environ['CASE']=='killmode-override' else 'control-group'
values={'ActiveState':Path(os.environ['STATE']).read_text(),'MainPID':Path(os.environ['PID']).read_text(),'ControlGroup':'/control/source','DropInPaths':os.environ['DROPIN'],'NeedDaemonReload':'no','KillMode':kill,'SendSIGKILL':'yes','TimeoutStopUSec':'1min 30s'}
print(values.get(p,''))
""",
                "systemd-analyze": "#!/usr/bin/env bash\n[ \"$#\" -eq 2 ] && [ \"$1\" = timespan ] && [ \"$2\" = '1min 30s' ] || exit 2\nprintf 'Original: 1min 30s\\n      μs: 90000000\\n   Human: 1min 30s\\n'\n",
                "kubectl": """#!/usr/bin/python3
import json,os,sys
from pathlib import Path
a=sys.argv[1:]; e=Path(os.environ['EVENTS']); e.open('a').write('kubectl:'+ ' '.join(a)+'\\n'); case=os.environ['CASE']; rev=os.environ['REV']
if 'patch' in a:
 r=json.loads(Path(os.environ['RESULT']).read_text()); e.open('a').write('patch-result:'+r['state']+'\\n'); payload=json.loads(a[a.index('-p')+1]); Path(os.environ['ACTIVATION']).write_text(payload['metadata']['annotations']['reconcile.fluxcd.io/requestedAt']); raise SystemExit(0)
if 'pods' in a:
 items=[]
 if case=='target-pod': items=[{'apiVersion':'v1','kind':'Pod','metadata':{'name':'hermes-agent-x','namespace':'default','labels':{}},'spec':{}}]
 if case=='pvc-pod': items=[{'apiVersion':'v1','kind':'Pod','metadata':{'name':'consumer','namespace':'default'},'spec':{'volumes':[{'persistentVolumeClaim':{'claimName':'hermes-agent-state'}}]}}]
 print(json.dumps({'apiVersion':'v1','kind':'List','metadata':{'continue':None},'items':items})); raise SystemExit(0)
if 'namespace' in a: print('16710d5a-45ec-4b64-a101-b1a4db28a6e7'); raise SystemExit(0)
i=a.index('get'); kind,name=a[i+1:i+3]
if kind=='gitrepository': print('true|'+rev); raise SystemExit(0)
if name=='cluster-state': print('true'); raise SystemExit(0)
if not Path(os.environ['ACTIVATION']).exists(): print('true'); raise SystemExit(0)
t=Path(os.environ['ACTIVATION']).read_text(); print(json.dumps({'apiVersion':'kustomize.toolkit.fluxcd.io/v1','kind':'Kustomization','metadata':{'name':'apps','namespace':'flux-system','generation':8,'annotations':{'reconcile.fluxcd.io/requestedAt':t}},'spec':{'suspend':False},'status':{'lastHandledReconcileAt':t,'lastAppliedRevision':rev,'observedGeneration':8,'conditions':[{'type':'Ready','status':'True','reason':'AnyReason'}]}}))
""",
            }
            for name, body in doubles.items():
                path = fakebin / name; path.write_text(body); path.chmod(0o755)
            env = {**os.environ, "PATH": f"{fakebin}:{os.environ['PATH']}", "CASE": case,
                   "STATE": str(state), "PID": str(pid), "EVENTS": str(events), "DROPIN": str(dropin),
                   "RESULT": str(result), "ACTIVATION": str(activation), "REV": revision,
                   "BARRIER": str(barrier), "RELEASE": str(release), "TOKEN": str(token)}
            if case == "lock-race":
                first = subprocess.Popen([launcher, revision], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env, start_new_session=True)
                deadline = time.monotonic() + 5
                while not barrier.exists() and first.poll() is None and time.monotonic() < deadline: time.sleep(.01)
                before = (result.read_bytes(), events.read_text(), token.exists(), state.read_text())
                second = subprocess.Popen([launcher, revision], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env, start_new_session=True)
                while second.poll() is None and events.read_text().count("helper:final-sync\n") < 2 and time.monotonic() < deadline: time.sleep(.01)
                unchanged = before == (result.read_bytes(), events.read_text(), token.exists(), state.read_text())
                if second.poll() is None: os.killpg(second.pid, 9)
                second.communicate(timeout=20); release.touch(); first.communicate(timeout=20)
                return {"code": first.returncode, "contender": second.returncode, "unchanged": unchanged, "events": events.read_text(), "barrier": barrier.exists()}
            completed = subprocess.run([launcher, revision], capture_output=True, text=True, env=env, timeout=20)
            invalid_codes = [subprocess.run([launcher, *arguments], capture_output=True, env=env).returncode
                             for arguments in ([], ["MAIN@sha1:" + "a" * 40])]
            value = json.loads(result.read_text()) if result.is_file() else None
            return {"code": completed.returncode, "events": events.read_text(), "token": token.exists(),
                    "state": state.read_text(), "result": value,
                    "mode": result.stat().st_mode & 0o777 if result.is_file() else None,
                    "stderr": completed.stderr, "invalid_codes": invalid_codes}

    override, success, defects = run_case("killmode-override"), run_case("success"), []
    if (override["code"] == 0 or not override["token"] or override["result"] is not None or override["state"] != "active" or "helper:" in str(override["events"]) or " stop " in str(override["events"])):
        defects.append(f"effective KillMode override crossed the preflight boundary: {override!r}")
    if success["code"] or success["result"]["state"] != "success" or success["mode"] != 0o600:
        defects.append(f"valid generic-List cutover control flow failed: {success!r}")
    if defects: fail("; ".join(defects))
    ordered(str(success["events"]), ["helper:final-sync", "get pods --chunk-size=0 -o json",
                                    "patch-result:activation-attempted", "helper:verify-target"], "cutover")
    initial = run_case("result-failure")
    if initial["code"] == 0 or not initial["token"] or initial["state"] != "active" or " stop " in initial["events"] or "helper:" in initial["events"]:
        fail(f"initial result failure crossed the destructive boundary: {initial!r}")
    helper = run_case("helper-failure")
    if helper["code"] == 0 or helper["result"]["fence"] != "verified-fenced" or helper["token"] or helper["state"] != "inactive" or " start " in helper["events"]:
        fail(f"helper failure was not honestly fail-fenced: {helper!r}")
    signal = run_case("helper-signal")
    if signal["code"] == 0 or not isinstance(signal["result"], dict) or signal["result"].get("fence") != "verified-fenced" or signal["token"] or signal["state"] != "inactive" or " start " in str(signal["events"]):
        fail(f"helper signal was not honestly fail-fenced: {signal!r}")
    unknown = run_case("fence-failure")
    if unknown["code"] == 0 or unknown["result"]["fence"] != "fence-unknown" or " start " in unknown["events"]:
        fail(f"failed fence operation was misreported: {unknown!r}")
    for prior in ("activation-attempted", "success"):
        blocked = run_case(f"prior-{prior}", prior)
        if blocked["code"] == 0 or not blocked["token"] or blocked["state"] != "active" or "helper:" in blocked["events"]:
            fail(f"prior {prior} result did not block rerun: {blocked!r}")
    for case in ("target-pod", "pvc-pod"):
        blocked = run_case(case)
        if (blocked["code"] == 0 or " patch " in blocked["events"]
                or blocked["result"]["fence"] != "verified-fenced" or blocked["result"]["lastPhase"] != "synced"):
            fail(f"{case} did not block activation: {blocked!r}")
    race = run_case("lock-race")
    if race["code"] or race["contender"] == 0 or not race["unchanged"] or not race["barrier"] or str(race["events"]).count("helper:final-sync\n") != 1: fail(f"concurrent launchers crossed the process lock boundary: {race!r}")
    if success["invalid_codes"] != [64, 64]:
        fail(f"launcher accepted invalid arguments: {success['invalid_codes']!r}")
    if sum(bool(line.strip()) for line in original.splitlines()) > 116:
        fail("cutover launcher exceeds 116 nonblank lines")


def main() -> int:
    checks = (
        validate_manifests,
        validate_migration_script,
        validate_cleanup_failure_is_aggregated,
        validate_cleanup_success_control,
        validate_ambiguous_admitted_create_is_operation_uid_cleaned,
        validate_cleanup_get_is_bounded,
        validate_preconditioned_delete_converges_with_real_kubectl_transport,
        validate_cleanup_deadline_retains_owned_handle,
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
        validate_final_sync_replaces_then_recovers_selected_state,
        validate_cutover_launcher_control_flow,
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
