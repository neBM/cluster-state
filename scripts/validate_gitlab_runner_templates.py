#!/usr/bin/env python3

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

try:
    import tomllib
except ImportError as exc:  # pragma: no cover
    raise SystemExit("python3.11+ is required for tomllib") from exc


def load_template(base_dir: Path, variant_dir: Path) -> str:
    fragments = list((base_dir / "fragments").glob("*.toml"))
    fragments.extend((variant_dir / "fragments").glob("*.toml"))
    ordered = sorted(fragments, key=lambda path: path.name)
    return "".join(path.read_text() for path in ordered)


def validate_storage_contract(runner: dict[str, Any]) -> list[str]:
    """Make graphroot Pod-owned while preserving workspace/cache hostPaths.

    Exact volume lists also reject duplicate repo names/mounts and alternative
    backends. /builds must match builds_dir so Runner suppresses its default repo.
    """
    expected_volumes = {
        "empty_dir": [
            {"name": "containers-storage", "mount_path": "/var/lib/containers", "medium": ""},
        ],
        "host_path": [
            {"name": "repo", "mount_path": "/builds",
             "host_path": "/var/lib/ci-builds-nocow", "read_only": False},
            {"name": "ci-cache", "mount_path": "/ci-cache",
             "host_path": "/var/lib/ci-cache-nocow", "read_only": False},
        ],
        "config_map": [
            {"name": "gitlab-runner-registries-conf", "mount_path": "/etc/containers/registries.conf",
             "sub_path": "registries.conf", "read_only": True},
            {"name": "gitlab-runner-docker-daemon", "mount_path": "/etc/docker/daemon.json",
             "sub_path": "daemon.json", "read_only": True},
        ],
    }
    errors = []
    if runner.get("builds_dir") != "/builds":
        errors.append("builds_dir must match the explicit repo mount at /builds")
    if runner.get("kubernetes", {}).get("volumes") != expected_volumes:
        errors.append("volumes must use disk-backed emptyDir graphroot, unchanged repo/ci-cache hostPaths and read-only registry config")
    return errors


def cpu_millicores(value: str) -> int:
    if value.endswith("m"):
        return int(value[:-1])
    return int(value) * 1000


def validate_capacity_contract(
    templates: dict[str, dict[str, Any]], incident: dict[str, Any]
) -> list[str]:
    errors: list[str] = []
    variants = incident["runner_variants"]
    amd64 = templates[variants["architecture_bound"]]["runners"][0]["kubernetes"]


    node = incident["amd64_node"]
    headroom_m = node["allocatable_cpu_m"] - node["steady_non_ci_cpu_request_m"]
    scheduler_request_m = cpu_millicores(amd64["cpu_request"]) + cpu_millicores(
        amd64["helper_cpu_request"]
    ) + len(amd64.get("services", [])) * cpu_millicores(amd64["service_cpu_request"])
    if scheduler_request_m > headroom_m:
        errors.append(
            "amd64 scheduler CPU request "
            f"{scheduler_request_m}m exceeds recorded no-other-CI headroom {headroom_m}m"
        )

    wait = incident["capacity_wait"]
    required_poll_timeout = (
        wait["competing_job_active_deadline_seconds"] + wait["scheduling_margin_seconds"]
    )
    if amd64["poll_timeout"] < required_poll_timeout:
        errors.append(
            f"amd64 poll_timeout {amd64['poll_timeout']}s is shorter than bounded "
            f"one-slot capacity-wait horizon {required_poll_timeout}s"
        )

    for variant, template in templates.items():
        kubernetes = template["runners"][0]["kubernetes"]
        required_anti_affinity = (
            kubernetes.get("affinity", {})
            .get("pod_anti_affinity", {})
            .get("required_during_scheduling_ignored_during_execution", [])
        )
        if not any(
            term.get("topology_key") == "kubernetes.io/hostname"
            and term.get("namespaces") == ["ci", "ci-maintenance-worker"]
            and term.get("label_selector", {}).get("match_labels", {}).get(
                "ci.brmartin.co.uk/job"
            )
            == "true"
            for term in required_anti_affinity
        ):
            errors.append(
                f"{variant} runner requires hard one-CI-job-per-node anti-affinity"
            )

    if amd64.get("node_selector") != {"kubernetes.io/arch": "amd64"}:
        errors.append("amd64 runner must be narrowly selected to kubernetes.io/arch=amd64")
    # Historical generic jobs now consume native architecture registrations.
    if templates["arm64"]["runners"][0]["kubernetes"].get("node_selector") != {"kubernetes.io/arch": "arm64"}:
        errors.append("arm64 runner must be narrowly selected to kubernetes.io/arch=arm64")

    return errors


def memory_mebibytes(value):
    for suffix, multiplier in (("Gi", 1024), ("Mi", 1), ("Ki", 1 / 1024)):
        if value.endswith(suffix):
            return int(value[:-len(suffix)]) * multiplier
    return int(value) / (1024 * 1024)


def validate_pool_contract(configs, manager_requests, fixture):
    """Validate actual generated production maps, not an independent lane model.

    Requests are sharing weights, not useful-CPU targets. The synthetic healthy
    envelope includes injected and declared services and conservatively reserves
    the movable manager on each candidate node. Helper/init uses max, not two helpers.
    Count only nodes fitting CPU AND memory on that same node. These fixtures
    exercise resource accounting, not live admission or future outage guarantees.
    Kubedock child Pods are outside Runner's Pod envelope and remain a live gate.
    """
    errors = []
    if set(configs) != {"architecture"} or set(manager_requests) != {"architecture"}:
        return ["exactly one architecture-aware manager is required"]
    config = configs["architecture"]
    if config["concurrent"] != 3:
        errors.append("global acquisition bound must equal 3")
    if [r["name"] for r in config["runners"]] != ["k8s-amd64", "k8s-arm64"]:
        return errors + ["exactly two native architecture registrations are required"]
    overhead = sum(cpu_millicores(r["cpu"]) for r in manager_requests.values())
    memory_overhead = sum(memory_mebibytes(r["memory"]) for r in manager_requests.values())
    for runner in config["runners"]:
        arch = runner["name"].removeprefix("k8s-")
        required_cpu = overhead + fixture["margin_cpu_m"]
        required_memory = memory_overhead + fixture["margin_memory_mi"]
        k = runner["kubernetes"]
        if k.get("node_selector") != {"kubernetes.io/arch": arch}:
            errors.append(f"{arch}: execution architecture escapes its acquisition group")
        if any(k.get(key) for key in ("cpu_limit", "helper_cpu_limit", "service_cpu_limit")):
            errors.append(f"{arch}: CPU quota prevents idle-core sharing")
        terms = k.get("affinity", {}).get("pod_anti_affinity", {}).get(
            "required_during_scheduling_ignored_during_execution", [])
        if k.get("pod_labels", {}).get("ci.brmartin.co.uk/job") != "true" or not any(
            t.get("topology_key") == "kubernetes.io/hostname" and
            t.get("namespaces") == ["ci", "ci-maintenance-worker"] and
            t.get("label_selector", {}).get("match_labels") == {"ci.brmartin.co.uk/job": "true"}
            for t in terms
        ):
            errors.append(f"{arch}: hard one-job-per-node isolation changed")
        if {key: k.get(key) for key in ("memory_request", "memory_limit", "helper_memory_request", "helper_memory_limit")} != {
            "memory_request": "512Mi", "memory_limit": "6Gi", "helper_memory_request": "128Mi", "helper_memory_limit": "256Mi"
        }:
            errors.append(f"{arch}: build/helper memory envelope changed")
        if k.get("service_memory_request") != "64Mi" or cpu_millicores(k.get("service_cpu_request", "0")) <= 0:
            errors.append(f"{arch}: injected/declared services are unaccounted")
        services = len(k.get("services", [])) + fixture["max_declared_services"][arch]
        request = cpu_millicores(k["cpu_request"]) + cpu_millicores(k["helper_cpu_request"]) + services * cpu_millicores(k.get("service_cpu_request", "0"))
        memory_request = memory_mebibytes(k["memory_request"]) + memory_mebibytes(k["helper_memory_request"]) + services * memory_mebibytes(k["service_memory_request"])
        required_cpu = max(required_cpu, request + overhead + fixture["margin_cpu_m"])
        required_memory = max(required_memory, memory_request + memory_overhead + fixture["margin_memory_mi"])
        pool = fixture["pools"][arch]
        slots = sum(cpu >= required_cpu and memory >= required_memory
                    for _, cpu, memory in zip(pool["nodes"], pool["headroom_cpu_m"],
                                              pool["headroom_memory_mi"], strict=True))
        expected_slots = {"amd64": 1, "arm64": 2}[arch]
        if pool["slots"] != expected_slots:
            errors.append(f"{arch}: fixture topology must match configured slots")
        if runner["limit"] != expected_slots:
            errors.append(f"{arch}: incorrect per-registration limit")
        if slots < expected_slots:
            errors.append(f"{arch}: fixture fits only {slots} of {expected_slots} configured slots")
    return errors


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    runner_root = repo_root / "infrastructure" / "shared-services" / "gitlab-runner"
    base_dir = runner_root / "runner-base"
    variant_root = runner_root / "runners"
    incident_paths = sorted(
        (repo_root / "scripts" / "fixtures").glob(
            "gitlab-runner-capacity-incident-*.json"
        )
    )

    print("Validating GitLab runner templates")
    templates: dict[str, dict[str, Any]] = {}
    for variant_dir in sorted(path for path in variant_root.iterdir() if (path / "fragments").is_dir()):
        template = load_template(base_dir, variant_dir)
        try:
            templates[variant_dir.name] = tomllib.loads(template)
        except tomllib.TOMLDecodeError as exc:
            print(f"{variant_dir.name}: invalid runner template: {exc}", file=sys.stderr)
            return 1
        for error in validate_storage_contract(templates[variant_dir.name]["runners"][0]):
            print(f"{variant_dir.name}: storage contract: {error}", file=sys.stderr)
            return 1
        print(f"  {variant_dir.name}: ok")

    if not incident_paths:
        print("capacity contract: no incident fixtures found", file=sys.stderr)
        return 1

    capacity_errors = False
    for incident_path in incident_paths:
        print(f"  validating capacity fixture: {incident_path.name}")
        incident = json.loads(incident_path.read_text())
        errors = validate_capacity_contract(templates, incident)
        if errors:
            capacity_errors = True
            for error in errors:
                print(f"capacity contract: {error}", file=sys.stderr)
        else:
            print("    scheduling capacity contract: ok")

    if capacity_errors:
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
