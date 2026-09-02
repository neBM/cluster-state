#!/usr/bin/env python3

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
GITLAB_KUSTOMIZATION = REPO_ROOT / "apps/gitlab/kustomization.yaml"
GITLAB_RELEASE_LITERAL_RE = re.compile(
    r"^\s*-\s*(?P<key>appVersion|migrationVersion)=(?P<version>\S+)\s*$",
    re.MULTILINE,
)
GITLAB_VERSION_RE = re.compile(
    r"^v(?P<major>[1-9]\d*)\.(?P<minor>[0-9]|1[01])\.(?P<patch>0|[1-9]\d*)$"
)
TARGETS = (
    "apps/gitlab",
    "apps/feedback",
)


def parse_gitlab_release_versions(kustomization: str) -> tuple[str, str]:
    versions: dict[str, list[str]] = {"appVersion": [], "migrationVersion": []}
    for match in GITLAB_RELEASE_LITERAL_RE.finditer(kustomization):
        versions[match.group("key")].append(match.group("version"))

    for key, values in versions.items():
        if len(values) != 1:
            raise ValueError(f"expected exactly one {key} literal, found {len(values)}")

    return versions["appVersion"][0], versions["migrationVersion"][0]


def parse_gitlab_version(version: str) -> tuple[int, int, int]:
    match = GITLAB_VERSION_RE.fullmatch(version)
    if match is None:
        raise ValueError(
            f"invalid GitLab version {version!r}; expected v<major>.<minor>.<patch>"
        )
    return (
        int(match.group("major")),
        int(match.group("minor")),
        int(match.group("patch")),
    )


def validate_gitlab_version_drift(app_version: str, migration_version: str) -> None:
    app_release = parse_gitlab_version(app_version)[:2]
    migration_release = parse_gitlab_version(migration_version)[:2]
    one_minor_ahead = (
        migration_release == (app_release[0], app_release[1] + 1)
        or (
            app_release[1] == 11
            and migration_release == (app_release[0] + 1, 0)
        )
    )

    if migration_release == app_release or one_minor_ahead:
        return
    if migration_release > app_release:
        raise ValueError(
            f"migrationVersion {migration_version!r} is more than one minor release ahead "
            f"of appVersion {app_version!r}"
        )
    raise ValueError(
        f"migrationVersion {migration_version!r} is behind appVersion {app_version!r}"
    )


def render(path: str) -> str:
    for command in (["kustomize", "build", path], ["kubectl", "kustomize", path]):
        try:
            completed = subprocess.run(
                command,
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
        except FileNotFoundError:
            continue
        except subprocess.CalledProcessError as exc:
            raise SystemExit(exc.stderr or exc.stdout or str(exc)) from exc
        return completed.stdout
    raise SystemExit("kustomize or kubectl is required")


def parse_job_documents(rendered: str) -> list[tuple[str, str]]:
    jobs: list[tuple[str, str]] = []

    for document in rendered.split("---"):
        kind = ""
        name = ""
        image = ""
        in_metadata = False

        for line in document.splitlines():
            if not line.strip():
                continue

            if not line.startswith(" "):
                in_metadata = False

            if line.startswith("kind:"):
                kind = line.split(":", 1)[1].strip()
                continue

            if line == "metadata:":
                in_metadata = True
                continue

            if in_metadata and line.startswith("  name:") and not name:
                name = line.split(":", 1)[1].strip()
                continue

            if re.match(r"^\s*image:\s*", line) and not image:
                image = line.split(":", 1)[1].strip()

        if kind == "Job" and name and image:
            jobs.append((name, image))

    return jobs


def validate_job_name_matches_image(name: str, image: str) -> None:
    if ":" not in image:
        raise SystemExit(f"{name}: image {image!r} is missing a tag")

    image_tag = image.rsplit(":", 1)[1]
    if f"-{image_tag}-" in name or name.endswith(f"-{image_tag}"):
        return

    raise SystemExit(
        f"{name}: rendered job name does not contain image tag {image_tag!r} from {image!r}"
    )


def main() -> int:
    print("Validating versioned migration jobs")
    try:
        app_version, migration_version = parse_gitlab_release_versions(
            GITLAB_KUSTOMIZATION.read_text()
        )
        validate_gitlab_version_drift(app_version, migration_version)
    except (OSError, ValueError) as exc:
        relative_path = GITLAB_KUSTOMIZATION.relative_to(REPO_ROOT)
        raise SystemExit(f"{relative_path}: {exc}") from exc
    print(
        f"  apps/gitlab: appVersion={app_version}, "
        f"migrationVersion={migration_version}"
    )

    for path in TARGETS:
        rendered = render(path)
        jobs = parse_job_documents(rendered)
        if not jobs:
            raise SystemExit(f"{path}: no rendered Job found")

        for name, image in jobs:
            validate_job_name_matches_image(name, image)
            print(f"  {path}: {name} -> {image}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
