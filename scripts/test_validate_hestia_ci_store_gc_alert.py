#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "PyYAML==6.0.3",
# ]
# ///

from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from types import ModuleType

ROOT = Path(__file__).resolve().parent.parent
VALIDATOR = ROOT / "scripts/validate_hestia_ci_store_gc_alert.py"


def load_validator() -> ModuleType:
    spec = importlib.util.spec_from_file_location("hestia_validator", VALIDATOR)
    if spec is None or spec.loader is None:
        raise AssertionError("validator module cannot be loaded")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["uv", "--no-config", "run", "--locked", "--script", str(VALIDATOR), "--repo-root", str(root)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )


def fixture(parent: Path, name: str) -> Path:
    root = parent / name
    shutil.copytree(ROOT / "infrastructure", root / "infrastructure")
    (root / "scripts").mkdir(parents=True)
    for relative in (
        "scripts/validate_kustomize.sh",
        "scripts/validate_hestia_ci_store_gc_alert.py",
        "scripts/test_validate_hestia_ci_store_gc_alert.py",
        ".gitlab-ci.yml",
    ):
        source = ROOT / relative
        destination = root / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
    return root


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    if text.count(old) != 1:
        raise AssertionError(f"{path}: expected exactly one mutation target {old!r}, got {text.count(old)}")
    path.write_text(text.replace(old, new, 1))


def mutation(
    parent: Path,
    name: str,
    relative: str,
    old: str,
    new: str,
    expected: str,
) -> None:
    root = fixture(parent, name)
    path = root / relative
    if name == "alert-wrong-threshold":
        text = path.read_text()
        marker = "        - uid: hestia-noisy-disk-space-low-api"
        before, separator, after = text.partition(marker)
        if not separator or after.count(old) != 1:
            raise AssertionError(f"{path}: expected one post-alert mutation target {old!r}, got {after.count(old)}")
        path.write_text(before + separator + after.replace(old, new, 1))
    else:
        replace_once(path, old, new)
    result = run(root)
    combined = result.stdout + result.stderr
    if result.returncode == 0:
        raise AssertionError(f"{name}: mutation was accepted")
    if expected not in combined:
        raise AssertionError(f"{name}: expected {expected!r}, got:\n{combined}")
    print(f"PASS mutation {name}")


def test_podman_runtime_paths(module: ModuleType) -> None:
    resources = module.render(ROOT, "infrastructure/shared-services")
    cronjobs = [
        resource
        for resource in resources
        if resource.get("kind") == "CronJob"
        and resource.get("metadata", {}).get("name") == "hestia-ci-store-gc"
    ]
    if len(cronjobs) != 1:
        raise AssertionError(f"expected one production GC CronJob, got {len(cronjobs)}")
    pod_spec = module.pod_spec(cronjobs[0])
    containers = pod_spec.get("containers")
    if type(containers) is not list or len(containers) != 1 or type(containers[0]) is not dict:
        raise AssertionError("production GC must contain exactly one container")
    container = containers[0]
    arguments = container.get("args")
    script = arguments[0] if type(arguments) is list and len(arguments) == 1 and type(arguments[0]) is str else ""

    failures = []
    tmpdir_options = [line.strip() for line in script.splitlines() if line.strip().startswith("--tmpdir=")]
    if tmpdir_options != ["--tmpdir=/tmp/libpod"]:
        failures.append(f"global Podman tmpdir expected ['--tmpdir=/tmp/libpod'], got {tmpdir_options!r}")

    environment = container.get("env")
    tmpdir_environment = (
        [entry for entry in environment if type(entry) is dict and entry.get("name") == "TMPDIR"]
        if type(environment) is list
        else []
    )
    expected_tmpdir_environment = [{"name": "TMPDIR", "value": "/tmp"}]
    if not module.strict_equal(tmpdir_environment, expected_tmpdir_environment):
        failures.append(f"TMPDIR environment expected {expected_tmpdir_environment!r}, got {tmpdir_environment!r}")

    volume_mounts = container.get("volumeMounts")
    runtime_mounts = (
        [
            mount
            for mount in volume_mounts
            if type(mount) is dict and mount.get("name") in {"run-lock", "dev-shm"}
        ]
        if type(volume_mounts) is list
        else []
    )
    expected_runtime_mounts = [
        {"mountPath": "/run/lock", "name": "run-lock"},
        {"mountPath": "/dev/shm", "name": "dev-shm"},
    ]
    if not module.strict_equal(runtime_mounts, expected_runtime_mounts):
        failures.append(f"runtime mounts expected {expected_runtime_mounts!r}, got {runtime_mounts!r}")

    volumes = pod_spec.get("volumes")
    runtime_volumes = (
        [
            volume
            for volume in volumes
            if type(volume) is dict and volume.get("name") in {"run-lock", "dev-shm"}
        ]
        if type(volumes) is list
        else []
    )
    expected_runtime_volumes = [
        {"emptyDir": {"medium": "Memory"}, "name": "run-lock"},
        {"emptyDir": {"medium": "Memory", "sizeLimit": "64Mi"}, "name": "dev-shm"},
    ]
    if not module.strict_equal(runtime_volumes, expected_runtime_volumes):
        failures.append(f"runtime volumes expected {expected_runtime_volumes!r}, got {runtime_volumes!r}")

    if failures:
        raise AssertionError("production Podman runtime-path contract is incomplete:\n- " + "\n- ".join(failures))
    print("PASS production Podman runtime-path contract")


def pod(uid: str, name: str, phase: str, node: str, labels: dict[str, str]) -> dict[str, object]:
    return {
        "metadata": {"uid": uid, "name": name, "namespace": "ci", "labels": labels},
        "spec": {"nodeName": node},
        "status": {"phase": phase},
    }


def test_runtime_gate(module: ModuleType) -> None:
    self_labels = {module.JOB_LABEL: "true", module.MAINTENANCE_LABEL: "true"}
    self_pod = pod("maintenance-uid", "hestia-ci-store-gc-test", "Running", "hestia", self_labels)
    stale_id = "a" * 64
    stale_external = [{"Id": stale_id, "Created": int(time.time()) - 8 * 24 * 60 * 60}]
    recent_external = [{"Id": "b" * 64, "Created": int(time.time())}]

    with tempfile.TemporaryDirectory(prefix="hestia-gc-runtime-") as temporary:
        root = Path(temporary)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        calls = root / "podman.calls"
        token = root / "token"
        ca = root / "ca.crt"
        token.write_text("fixture-token")
        ca.write_text("fixture-ca")
        (bin_dir / "curl").write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "output=\n"
            "while [ \"$#\" -gt 0 ]; do\n"
            "  if [ \"$1\" = --output ]; then output=$2; shift 2; else shift; fi\n"
            "done\n"
            "cp \"$PODS_FIXTURE\" \"$output\"\n"
        )
        (bin_dir / "podman").write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "if [[ \" $* \" == *\" ps -a --external \"* ]]; then\n"
            "  printf 'READ %s\\n' \"$*\" >>\"$PODMAN_CALLS\"\n"
            "  cat \"$EXTERNAL_FIXTURE\"\n"
            "else\n"
            "  printf 'MUTATE %s\\n' \"$*\" >>\"$PODMAN_CALLS\"\n"
            "fi\n"
        )
        for executable in bin_dir.iterdir():
            executable.chmod(0o755)

        script = module.GC_SCRIPT.replace(module.SA_TOKEN_PATH, str(token)).replace(module.SA_CA_PATH, str(ca))
        base_env = {
            "PATH": f"{bin_dir}:/usr/bin:/bin",
            "KUBERNETES_SERVICE_HOST": "127.0.0.1",
            "KUBERNETES_SERVICE_PORT_HTTPS": "443",
            "NODE_NAME": "hestia",
            "POD_UID": "maintenance-uid",
            "PODMAN_CALLS": str(calls),
        }
        cases = (
            (
                "active-running",
                {"metadata": {"continue": ""}, "items": [self_pod, pod("job-1", "runner-a-project-1-concurrent-0-x", "Running", "hestia", {module.JOB_LABEL: "true"})]},
                [],
                False,
                "active GitLab job pod(s) block cleanup",
                0,
            ),
            (
                "active-pending-unscheduled",
                {"metadata": {"continue": ""}, "items": [self_pod, pod("job-2", "runner-b-project-2-concurrent-0-x", "Pending", "", {module.JOB_LABEL: "true"})]},
                [],
                False,
                "active GitLab job pod(s) block cleanup",
                0,
            ),
            (
                "incomplete-list",
                {"metadata": {"continue": "next"}, "items": [self_pod]},
                [],
                False,
                "pod list is incomplete",
                0,
            ),
            (
                "self-absent",
                {"metadata": {"continue": ""}, "items": []},
                [],
                False,
                "maintenance Pod is absent",
                0,
            ),
            (
                "self-wrong-node",
                {"metadata": {"continue": ""}, "items": [pod("maintenance-uid", "hestia-ci-store-gc-test", "Running", "nyx", self_labels)]},
                [],
                False,
                "maintenance Pod identity is inconsistent",
                0,
            ),
            (
                "no-active-job",
                {"metadata": {"continue": ""}, "items": [self_pod, pod("old", "runner-old-project-1-concurrent-0-x", "Succeeded", "hestia", {module.JOB_LABEL: "true"})]},
                [],
                True,
                "Kubernetes API gate passed",
                2,
            ),
            (
                "stale-external",
                {"metadata": {"continue": ""}, "items": [self_pod]},
                stale_external,
                True,
                "Kubernetes API gate passed",
                3,
            ),
            (
                "recent-external-rejected",
                {"metadata": {"continue": ""}, "items": [self_pod]},
                recent_external,
                False,
                "recent external container",
                1,
            ),
        )
        for name, pods, external, should_succeed, expected, expected_mutations in cases:
            pods_fixture = root / f"{name}-pods.json"
            external_fixture = root / f"{name}-external.json"
            pods_fixture.write_text(json.dumps(pods))
            external_fixture.write_text(json.dumps(external))
            calls.unlink(missing_ok=True)
            env = base_env | {"PODS_FIXTURE": str(pods_fixture), "EXTERNAL_FIXTURE": str(external_fixture)}
            result = subprocess.run(
                ["/bin/bash", "-ceu", "--", script],
                capture_output=True,
                text=True,
                env=env,
                check=False,
            )
            combined = result.stdout + result.stderr
            call_lines = calls.read_text().splitlines() if calls.is_file() else []
            mutations = [line for line in call_lines if line.startswith("MUTATE ")]
            if should_succeed != (result.returncode == 0):
                raise AssertionError(f"{name}: unexpected exit {result.returncode}:\n{combined}")
            if len(mutations) != expected_mutations:
                raise AssertionError(f"{name}: expected {expected_mutations} mutations, got {call_lines}")
            if expected not in combined:
                raise AssertionError(f"{name}: expected {expected!r}, got:\n{combined}")
            if name == "stale-external":
                if not any(f"rm --force {stale_id}" in line for line in mutations):
                    raise AssertionError(f"{name}: supported stale-container removal missing: {mutations}")
                if not any("image prune --all --force --filter until=168h" in line for line in mutations):
                    raise AssertionError(f"{name}: age-bounded image prune missing: {mutations}")
            print(f"PASS runtime gate {name}")


def main() -> int:
    module = load_validator()
    test_podman_runtime_paths(module)
    clean = run(ROOT)
    if clean.returncode:
        raise AssertionError(f"canonical desired state rejected:\n{clean.stdout}{clean.stderr}")
    print("PASS canonical desired state")

    with tempfile.TemporaryDirectory(prefix="hestia-validator-") as temporary:
        parent = Path(temporary)
        gc = "infrastructure/shared-services/gitlab-runner/ci/cronjob-ci-hestia-ci-store-gc.yaml"
        role = "infrastructure/shared-services/gitlab-runner/ci/role-ci-hestia-ci-store-gc.yaml"
        alert = "infrastructure/observability-ui/grafana/_grafana_alert_rules.yaml"
        wrapper = "scripts/validate_kustomize.sh"
        mutations = (
            ("gc-wrong-target", gc, module.GC_HOST_PATH, "/var/lib/ci-containers-nocow", "GC volumes"),
            ("gc-cache-scope", gc, module.GC_HOST_PATH, "/var/lib/ci-cache-nocow", "GC volumes"),
            ("gc-missing-podman-tmpdir", gc, "                --tmpdir=/tmp/libpod\n", "", "GC script"),
            ("gc-wrong-podman-tmpdir", gc, "                --tmpdir=/tmp/libpod\n", "                --tmpdir=/run/libpod\n", "GC script"),
            ("gc-duplicate-podman-tmpdir", gc, "                --tmpdir=/tmp/libpod\n", "                --tmpdir=/tmp/libpod\n                --tmpdir=/tmp/libpod\n", "GC script"),
            ("gc-missing-tmpdir-environment", gc, "            - name: TMPDIR\n              value: /tmp\n", "", "GC container environment"),
            ("gc-wrong-tmpdir-environment", gc, "            - name: TMPDIR\n              value: /tmp\n", "            - name: TMPDIR\n              value: /var/tmp\n", "GC container environment"),
            ("gc-duplicate-tmpdir-environment", gc, "            - name: TMPDIR\n              value: /tmp\n", "            - name: TMPDIR\n              value: /tmp\n            - name: TMPDIR\n              value: /tmp\n", "GC container environment"),
            ("gc-missing-run-lock-mount", gc, "            - mountPath: /run/lock\n              name: run-lock\n", "", "GC volumeMounts"),
            ("gc-broad-run-lock-mount", gc, "            - mountPath: /run/lock\n              name: run-lock\n", "            - mountPath: /run\n              name: run-lock\n", "GC volumeMounts"),
            ("gc-duplicate-run-lock-mount", gc, "            - mountPath: /run/lock\n              name: run-lock\n", "            - mountPath: /run/lock\n              name: run-lock\n            - mountPath: /run/lock\n              name: run-lock\n", "GC volumeMounts"),
            ("gc-missing-run-lock-volume", gc, "          - emptyDir: {medium: Memory}\n            name: run-lock\n", "", "GC volumes"),
            ("gc-wrong-run-lock-volume", gc, "          - emptyDir: {medium: Memory}\n            name: run-lock\n", "          - emptyDir: {}\n            name: run-lock\n", "GC volumes"),
            ("gc-duplicate-run-lock-volume", gc, "          - emptyDir: {medium: Memory}\n            name: run-lock\n", "          - emptyDir: {medium: Memory}\n            name: run-lock\n          - emptyDir: {medium: Memory}\n            name: run-lock\n", "GC volumes"),
            ("gc-missing-dev-shm-mount", gc, "            - mountPath: /dev/shm\n              name: dev-shm\n", "", "GC volumeMounts"),
            ("gc-wrong-dev-shm-mount", gc, "            - mountPath: /dev/shm\n              name: dev-shm\n", "            - mountPath: /dev/shm-wrong\n              name: dev-shm\n", "GC volumeMounts"),
            ("gc-duplicate-dev-shm-mount", gc, "            - mountPath: /dev/shm\n              name: dev-shm\n", "            - mountPath: /dev/shm\n              name: dev-shm\n            - mountPath: /dev/shm\n              name: dev-shm\n", "GC volumeMounts"),
            ("gc-missing-dev-shm-volume", gc, "          - emptyDir: {medium: Memory, sizeLimit: 64Mi}\n            name: dev-shm\n", "", "GC volumes"),
            ("gc-wrong-dev-shm-medium", gc, "          - emptyDir: {medium: Memory, sizeLimit: 64Mi}\n            name: dev-shm\n", "          - emptyDir: {sizeLimit: 64Mi}\n            name: dev-shm\n", "GC volumes"),
            ("gc-wrong-dev-shm-size", gc, "          - emptyDir: {medium: Memory, sizeLimit: 64Mi}\n            name: dev-shm\n", "          - emptyDir: {medium: Memory, sizeLimit: 128Mi}\n            name: dev-shm\n", "GC volumes"),
            ("gc-duplicate-dev-shm-volume", gc, "          - emptyDir: {medium: Memory, sizeLimit: 64Mi}\n            name: dev-shm\n", "          - emptyDir: {medium: Memory, sizeLimit: 64Mi}\n            name: dev-shm\n          - emptyDir: {medium: Memory, sizeLimit: 64Mi}\n            name: dev-shm\n", "GC volumes"),
            ("gc-not-age-bounded", gc, "--filter until=168h --format json", "--filter until=24h --format json", "GC script"),
            ("gc-overlap", gc, "concurrencyPolicy: Forbid", "concurrencyPolicy: Allow", "CronJob concurrencyPolicy"),
            ("gc-no-scheduler-lock", gc, 'matchLabels:\n                    ci.brmartin.co.uk/job: "true"\n                topologyKey:', 'matchLabels:\n                    ci.brmartin.co.uk/job: "false"\n                topologyKey:', "GC scheduler exclusion"),
            ("gc-mutable-image", gc, module.GC_IMAGE, "quay.io/podman/stable:v5.8.2", "GC image"),
            ("gc-raw-delete", gc, "              podman_store=(", "              rm -rf /var/lib/containers/storage\n              podman_store=(", "GC must not raw-delete storage"),
            ("gc-no-active-gate", gc, "/api/v1/namespaces/ci/pods?limit=500", "/api/v1/namespaces/ci/pods/does-not-exist", "GC script"),
            ("gc-no-external-cleanup", gc, "ps -a --external", "ps -a", "GC script"),
            ("gc-broad-rbac", role, "verbs:\n  - list", "verbs:\n  - list\n  - get", "GC Role rules"),
            ("gc-unprivileged", gc, "privileged: true", "privileged: false", "GC securityContext"),
            ("gc-test-unlocked", wrapper, 'uv --no-config run --locked --script "${repo_root}/scripts/test_validate_hestia_ci_store_gc_alert.py"', 'python3 "${repo_root}/scripts/test_validate_hestia_ci_store_gc_alert.py"', "validate_kustomize GC/alert test call count"),
            ("alert-wrong-mount", alert, 'expr: |-\n                    (\n                      label_replace(\n                        min by(instance) (\n                          (\n                            node_filesystem_avail_bytes{job="kubernetes-service-endpoints",app_kubernetes_io_name="node-exporter",mountpoint="/srv/noisy",fstype="xfs"}', 'expr: |-\n                    (\n                      label_replace(\n                        min by(instance) (\n                          (\n                            node_filesystem_avail_bytes{job="kubernetes-service-endpoints",app_kubernetes_io_name="node-exporter",mountpoint="/srv/noisy-bind",fstype="xfs"}', "alert PromQL"),
            ("alert-wrong-job", alert, 'expr: |-\n                    (\n                      label_replace(\n                        min by(instance) (\n                          (\n                            node_filesystem_avail_bytes{job="kubernetes-service-endpoints"', 'expr: |-\n                    (\n                      label_replace(\n                        min by(instance) (\n                          (\n                            node_filesystem_avail_bytes{job="kubernetes-pods"', "alert PromQL"),
            ("alert-wrong-node", alert, 'max by(internal_ip, node) (kube_node_info{node="hestia"})\n                    )\n                    or', 'max by(internal_ip, node) (kube_node_info{node="nyx"})\n                    )\n                    or', "alert PromQL"),
            ("alert-wrong-threshold", alert, "- 15", "- 10", "alert threshold conditions"),
            ("alert-not-fail-closed", alert, "          noDataState: Alerting\n          execErrState: OK\n          for: 5m\n          annotations:\n            description: The canonical node-exporter", "          noDataState: OK\n          execErrState: OK\n          for: 5m\n          annotations:\n            description: The canonical node-exporter", "alert noDataState"),
            ("alert-wrong-duration", alert, "          noDataState: Alerting\n          execErrState: OK\n          for: 5m\n          annotations:\n            description: The canonical node-exporter", "          noDataState: Alerting\n          execErrState: OK\n          for: 10m\n          annotations:\n            description: The canonical node-exporter", "alert for"),
        )
        for case in mutations:
            mutation(parent, *case)

    test_runtime_gate(module)
    print("Hestia CI store GC and /srv/noisy mutation tests passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
