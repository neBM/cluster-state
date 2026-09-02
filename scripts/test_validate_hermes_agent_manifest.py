#!/usr/bin/env python3
"""Focused migration-critical checks for the Hermes Agent Kubernetes slice."""

from __future__ import annotations

import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
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


def run_stage(source: Path, staging: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, "-", str(source), str(staging)],
        input=heredoc_body(MIGRATION.read_text(), "STAGE_SQLITE_PY"),
        text=True,
        capture_output=True,
        check=False,
    )


def run_sync(
    source: Path,
    staging: Path,
    target: Path,
    phase: str = "initial",
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
    return subprocess.run(
        [sys.executable, "-", phase],
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
        'timeout --foreground 3300s python3 - "$SOURCE_HOME" "$SQLITE_STAGING_DIR"',
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
            "create_sqlite_staging",
            "require_candidate_target",
            "create_migration_pod",
            "run_sync initial",
            "cleanup_migration_resources",
        ],
        "initial-sync staging/guard/copy/cleanup",
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
SQLITE_STAGING_ROOT="$TEST_ROOT"
SQLITE_STAGING_DIR="$TEST_STAGING"
: >"$CALL_LOG"
kubectl() {{
  printf '%s\\n' "$*" >>"$CALL_LOG"
  case " $* " in
    *" delete pod migration-pod "*) return 1 ;;
    *" get pod migration-pod "*) printf '%s\\n' pod/migration-pod; return 0 ;;
    *) return 64 ;;
  esac
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
  *"delete pod migration-pod"*) ;;
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
SQLITE_STAGING_ROOT="$TEST_ROOT"
SQLITE_STAGING_DIR="$TEST_STAGING"
: >"$CALL_LOG"
kubectl() {{
  printf '%s\\n' "$*" >>"$CALL_LOG"
  case " $* " in
    *" delete pod migration-pod "*) return 0 ;;
    *" get pod migration-pod "*) return 0 ;;
    *) return 64 ;;
  esac
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
  *"delete pod migration-pod"*) ;;
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
        absent_database = {"state": "absent", "type": None}
        present_database = {"state": "present", "type": "regular_file"}
        expected_databases = {name: absent_database for name in DATABASES}
        expected_databases["state.db"] = present_database
        expected_profiles = {
            profile: {
                "state": "absent",
                "type": None,
                "databases": {name: absent_database for name in DATABASES},
            }
            for profile in PROFILES
        }
        expected_profiles["implementer"] = {
            "state": "present",
            "type": "directory",
            "databases": {name: absent_database for name in DATABASES},
        }
        expected_profiles["implementer"]["databases"]["projects.db"] = (
            present_database
        )
        expected = {
            "version": 1,
            "databases": expected_databases,
            "profiles": expected_profiles,
        }
        if manifest != expected or type(manifest.get("version")) is not int:
            fail(f"SQLite staging manifest is not exact: {manifest!r}")


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
    require(sync_python, "shutil.copy2(staged, temporary)", "staged database copy")

    with tempfile.TemporaryDirectory(prefix="hermes-sqlite-regression-") as temporary:
        root = Path(temporary)
        source = root / "source"
        staging = root / "staging"
        target = root / "target"
        database = source / "profiles" / "implementer" / "projects.db"
        database.parent.mkdir(parents=True)
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

        copied = target / "profiles" / "implementer" / "projects.db"
        with sqlite3.connect(f"file:{copied}?mode=ro", uri=True) as connection:
            if connection.execute("PRAGMA quick_check").fetchone() != ("ok",):
                fail("copied staged database failed quick_check")
            if connection.execute("SELECT value FROM retained").fetchone() != ("staged",):
                fail("copied staged database lost retained data")
        if (target / "state.db").exists() or (target / "profiles" / "reviewer").exists():
            fail("absent database/profile did not remove stale target state")


def main() -> int:
    checks = (
        validate_manifests,
        validate_migration_script,
        validate_cleanup_failure_is_aggregated,
        validate_cleanup_success_control,
        validate_staging_manifest_contract,
        validate_host_stage_rejects_dangling_profile_symlink,
        validate_host_stage_rejects_dangling_database_symlink,
        validate_profile_disappearance_rejected_before_target_mutation,
        validate_pod_preflight_rejects_dangling_profile_symlink,
        validate_pod_preflight_rejects_dangling_database_symlink,
        validate_concurrent_wal_writer_is_retained,
        validate_staged_sqlite_regression,
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
