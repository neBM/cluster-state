#!/usr/bin/env python3

from __future__ import annotations

import re
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
SHARED_POSTGRES_MAX_CONNECTIONS = 100
SUPERUSER_RESERVED_CONNECTIONS = 3
UNBUDGETED_HEADROOM = 25


def read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text()


def expect_int(pattern: str, text: str, description: str) -> int:
    match = re.search(pattern, text, flags=re.MULTILINE)
    if not match:
        raise ValueError(f"could not find {description}")
    return int(match.group(1))


def find_shared_postgres_consumers() -> set[str]:
    candidates: set[str] = set()
    db_markers = (
        "postgresql://",
        "jdbc:postgresql",
        "POSTGRES_HOST",
        "DB_TYPE",
        "DB_MAX_CONNS",
        "KC_DB",
        "database:",
        "adapter: postgresql",
    )

    for path in REPO_ROOT.glob("apps/**/*.yaml"):
        text = path.read_text()
        if "192.168.1.10" in text and any(marker in text for marker in db_markers):
            candidates.add(path.relative_to(REPO_ROOT).as_posix())

    for path in REPO_ROOT.glob("infrastructure/**/*.yaml"):
        text = path.read_text()
        if "192.168.1.10" in text and any(marker in text for marker in db_markers):
            candidates.add(path.relative_to(REPO_ROOT).as_posix())

    return candidates


def main() -> int:
    budgeted_components = {
        "seaweedfs-filer": (
            "infrastructure/storage/seaweedfs/core/configmap-default-seaweedfs-filer-config.yaml",
            expect_int(
                r"connection_max_open\s*=\s*(\d+)",
                read("infrastructure/storage/seaweedfs/core/configmap-default-seaweedfs-filer-config.yaml"),
                "SeaweedFS filer connection_max_open",
            ),
        ),
        "gitlab-rails": (
            "apps/gitlab/configmap-default-gitlab-config-templates.yaml",
            sum(
                int(value)
                for value in re.findall(
                    r"\bpool:\s*(\d+)",
                    read("apps/gitlab/configmap-default-gitlab-config-templates.yaml"),
                )
            ),
        ),
        "matrix-synapse": (
            "apps/matrix/configmap-default-synapse-config.yaml",
            expect_int(
                r"\bcp_max:\s*(\d+)",
                read("apps/matrix/configmap-default-synapse-config.yaml"),
                "Synapse cp_max",
            ),
        ),
        "matrix-mas": (
            "apps/matrix/configmap-default-mas-config-template.yaml",
            expect_int(
                r"\bmax_connections:\s*(\d+)",
                read("apps/matrix/configmap-default-mas-config-template.yaml"),
                "MAS max_connections",
            ),
        ),
        "iris": (
            "apps/iris/deployment-default-iris.yaml",
            expect_int(
                r"- name: DB_MAX_CONNS\s+value:\s+'?(\d+)'?",
                read("apps/iris/deployment-default-iris.yaml"),
                "Iris DB_MAX_CONNS",
            ),
        ),
    }

    expected_shared_db_files = {
        "apps/gitlab/configmap-default-gitlab-config-templates.yaml",
        "apps/keycloak/deployment-default-keycloak.yaml",
        "apps/matrix/configmap-default-mas-config-template.yaml",
        "apps/matrix/configmap-default-synapse-config.yaml",
        "apps/nextcloud/deployment-default-nextcloud.yaml",
        "apps/seerr/deployment-default-seerr.yaml",
    }

    discovered_files = find_shared_postgres_consumers()
    unexpected = sorted(discovered_files - expected_shared_db_files)
    missing = sorted(expected_shared_db_files - discovered_files)

    if unexpected:
        print("Unexpected shared PostgreSQL consumers detected:", file=sys.stderr)
        for path in unexpected:
            print(f"  {path}", file=sys.stderr)
        return 1

    if missing:
        print("Expected shared PostgreSQL consumer files no longer matched the detector:", file=sys.stderr)
        for path in missing:
            print(f"  {path}", file=sys.stderr)
        return 1

    configured_budget = sum(value for _, value in budgeted_components.values())
    safe_budget = (
        SHARED_POSTGRES_MAX_CONNECTIONS
        - SUPERUSER_RESERVED_CONNECTIONS
        - UNBUDGETED_HEADROOM
    )

    print("Validating shared PostgreSQL connection budget")
    print(
        f"  capacity={SHARED_POSTGRES_MAX_CONNECTIONS} "
        f"reserved={SUPERUSER_RESERVED_CONNECTIONS} "
        f"headroom={UNBUDGETED_HEADROOM} "
        f"safe_budget={safe_budget}"
    )
    for component, (path, value) in sorted(budgeted_components.items()):
        print(f"  {component}: {value} ({path})")

    if configured_budget > safe_budget:
        print(
            "Configured shared PostgreSQL pools exceed the safe budget: "
            f"{configured_budget} > {safe_budget}",
            file=sys.stderr,
        )
        return 1

    print(f"  total configured budget: {configured_budget}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
