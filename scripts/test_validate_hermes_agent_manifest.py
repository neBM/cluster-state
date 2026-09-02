#!/usr/bin/env python3
"""Focused migration-critical checks for the Hermes Agent Kubernetes slice."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "apps/hermes-agent"
MIGRATION = ROOT / "scripts/hermes-agent-migration.sh"
IMAGE = (
    "nousresearch/hermes-agent:v2026.8.16.2@"
    "sha256:a39fc11620213e3669a327aff5c6cb1eb2b8a238c6044e33e7ef8885833d89a7"
)


def fail(message: str) -> None:
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
    require(script, "readOnly: true", "read-only source mount")
    require(script, "activeDeadlineSeconds:", "bounded migration pod")
    require(script, "trap cleanup_migration_pod", "migration pod cleanup")
    require(script, '"api_server", "feishu", "matrix", "webhook"', "connected platform verification")
    require(script, "wait_for_source_healthy", "rollback source health verification")
    require(script, "symlinks=True", "nested symlinks preserved without following")
    if "def reject_symlinks" in script:
        fail("selected trees must not reject preserved nested symlinks")


def main() -> int:
    try:
        validate_manifests()
        validate_migration_script()
    except (AssertionError, OSError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    print("PASS: Hermes Agent manifest and migration invariants")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
