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
    generic = templates[variants["generic"]]["runners"][0]["kubernetes"]

    node = incident["amd64_node"]
    headroom_m = node["allocatable_cpu_m"] - node["steady_non_ci_cpu_request_m"]
    scheduler_request_m = cpu_millicores(amd64["cpu_request"]) + cpu_millicores(
        amd64["helper_cpu_request"]
    )
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
    if "node_selector" in generic:
        errors.append("generic runner must not require an architecture node selector")

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
    for variant_dir in sorted(path for path in variant_root.iterdir() if path.is_dir()):
        template = load_template(base_dir, variant_dir)
        try:
            templates[variant_dir.name] = tomllib.loads(template)
        except tomllib.TOMLDecodeError as exc:
            print(f"{variant_dir.name}: invalid runner template: {exc}", file=sys.stderr)
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
