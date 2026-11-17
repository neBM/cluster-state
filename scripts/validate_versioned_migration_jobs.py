#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML==6.0.3"]
# ///

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml
from yaml.constructor import ConstructorError
from yaml.nodes import MappingNode


REPO_ROOT = Path(__file__).resolve().parent.parent
GITLAB_KUSTOMIZATION = REPO_ROOT / "apps/gitlab/kustomization.yaml"
GITLAB_VERSION_RE = re.compile(
    r"^v(?P<major>[1-9]\d*)\.(?P<minor>[0-9]|1[01])\.(?P<patch>0|[1-9]\d*)$"
)
TARGETS = (
    "apps/gitlab",
    "apps/feedback",
)


class UniqueKeySafeLoader(yaml.SafeLoader):
    pass


def construct_unique_mapping(
    loader: UniqueKeySafeLoader, node: MappingNode, deep: bool = False
) -> dict[Any, Any]:
    loader.flatten_mapping(node)
    mapping: dict[Any, Any] = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        try:
            duplicate = key in mapping
        except TypeError as exc:
            raise ConstructorError(
                "while constructing a mapping",
                node.start_mark,
                "found unhashable key",
                key_node.start_mark,
            ) from exc
        if duplicate:
            raise ConstructorError(
                "while constructing a mapping",
                node.start_mark,
                f"duplicate mapping key {key!r}",
                key_node.start_mark,
            )
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


UniqueKeySafeLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    construct_unique_mapping,
)


def parse_gitlab_release_versions(kustomization: str) -> tuple[str, str]:
    try:
        document = yaml.load(kustomization, Loader=UniqueKeySafeLoader)
    except yaml.YAMLError as exc:
        raise ValueError(f"invalid Kustomization YAML: {exc}") from exc

    if type(document) is not dict:
        raise ValueError("expected Kustomization to be a mapping")

    generators = document.get("configMapGenerator")
    if type(generators) is not list:
        raise ValueError("expected configMapGenerator to be a list")

    release_generators: list[dict[str, Any]] = []
    for index, generator in enumerate(generators):
        if type(generator) is not dict:
            raise ValueError(f"configMapGenerator[{index}] must be a mapping")
        name = generator.get("name")
        if type(name) is not str:
            raise ValueError(f"configMapGenerator[{index}].name must be a string")
        if name == "gitlab-release":
            release_generators.append(generator)

    if len(release_generators) != 1:
        raise ValueError(
            "expected exactly one configMapGenerator named 'gitlab-release', "
            f"found {len(release_generators)}"
        )

    literals = release_generators[0].get("literals")
    if type(literals) is not list:
        raise ValueError("gitlab-release literals must be a list")

    versions: dict[str, list[str]] = {"appVersion": [], "migrationVersion": []}
    for index, literal in enumerate(literals):
        if type(literal) is not str:
            raise ValueError(f"gitlab-release literals[{index}] must be a string")
        key, separator, value = literal.partition("=")
        if separator and key in versions:
            versions[key].append(value)

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
    app = parse_gitlab_version(app_version)
    migration = parse_gitlab_version(migration_version)
    if migration < app:
        raise ValueError(
            f"migrationVersion {migration_version!r} is behind appVersion {app_version!r}"
        )

    app_release = app[:2]
    migration_release = migration[:2]
    one_minor_ahead = (
        migration_release == (app_release[0], app_release[1] + 1)
        or (
            app_release[1] == 11
            and migration_release == (app_release[0] + 1, 0)
        )
    )

    if migration_release == app_release or one_minor_ahead:
        return
    raise ValueError(
        f"migrationVersion {migration_version!r} is more than one minor release ahead "
        f"of appVersion {app_version!r}"
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


def parse_migration_image(image: str) -> tuple[str, str]:
    # Split the digest before the tag: registry ports and sha256 colons are not tags.
    reference, separator, digest = image.partition("@")
    if separator and re.fullmatch(r"sha256:[0-9a-f]{64}", digest) is None:
        raise ValueError(f"invalid sha256 digest in image {image!r}")
    repository, separator, tag = reference.rpartition(":")
    component = r"[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*"
    registry_label = r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?"
    registry_host = rf"{registry_label}(?:\.{registry_label})*"
    repository_pattern = rf"(?:{registry_host}(?::[0-9]+)?/)?{component}(?:/{component})*"
    if (
        not separator
        or re.fullmatch(repository_pattern, repository) is None
        or re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}", tag) is None
    ):
        raise ValueError(f"image {image!r} requires a repository and valid tag")
    return repository, tag


def validate_job_name_matches_image(name: str, image: str) -> None:
    try:
        _, image_tag = parse_migration_image(image)
    except ValueError as exc:
        raise SystemExit(f"{name}: {exc}") from exc
    if f"-{image_tag}-" in name or name.endswith(f"-{image_tag}"):
        return

    raise SystemExit(
        f"{name}: rendered job name does not contain image tag {image_tag!r} from {image!r}"
    )


def validate_feedback_migration_release(
    kustomization: str,
    rendered: str,
    latest_migration: int,
    producer_repository: str,
) -> None:
    documents = list(yaml.load_all(rendered, Loader=UniqueKeySafeLoader))
    releases = [
        doc for doc in documents if isinstance(doc, dict)
        and doc.get("kind") == "ConfigMap"
        and doc.get("metadata", {}).get("name") == "feedback-release"
    ]
    jobs = [doc for doc in documents if isinstance(doc, dict) and doc.get("kind") == "Job"]
    if len(releases) != 1 or len(jobs) != 1:
        raise ValueError("expected exactly one feedback-release ConfigMap and migration Job")
    release = releases[0].get("data", {})
    version = release.get("migrationVersion")
    expected_version = f"v{latest_migration}"
    if version != expected_version:
        raise ValueError(f"migrationVersion must match highest SQL migration {expected_version}")
    # The native package job extracts this exact unquoted literal with sed.
    producer_versions = re.findall(r"^  - migrationVersion=(.*)$", kustomization, re.MULTILINE)
    if producer_versions != [version]:
        raise ValueError("migrationVersion literal must be readable by the native image producer")
    suffix = release.get("migrationRunSuffix")
    if not isinstance(suffix, str) or re.fullmatch(r"r[1-9]\d*", suffix) is None:
        raise ValueError("invalid migrationRunSuffix")
    image = release.get("migrationImage")
    if not isinstance(image, str):
        raise ValueError("feedback-release requires migrationImage")
    repository, tag = parse_migration_image(image)
    if repository != producer_repository or tag != version:
        raise ValueError("migrationImage must match the native producer repository and migrationVersion")
    job = jobs[0]
    if job["metadata"]["name"] != f"feedback-migrations-{version}-{suffix}":
        raise ValueError("feedback migration Job identity must match version and run suffix")
    containers = job.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
    if len(containers) != 1 or containers[0].get("image") != image:
        raise ValueError("feedback migration Job must use the whole migrationImage reference")


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
        if path == "apps/feedback":
            try:
                ci = yaml.safe_load((REPO_ROOT / ".gitlab-ci.yml").read_text())
                # Native GitLab project registry prefix (including its explicit port).
                producer_repository = ci["variables"]["FEEDBACK_MIGRATIONS_IMAGE"].replace(
                    "${CI_REGISTRY_IMAGE}", "registry.brmartin.co.uk:443/ben/cluster-state"
                )
                latest_migration = max(
                    int(sql.name.split("_", 1)[0])
                    for sql in (REPO_ROOT / path / "migrations").glob("[0-9]*_*.sql")
                )
                validate_feedback_migration_release(
                    (REPO_ROOT / path / "kustomization.yaml").read_text(),
                    rendered,
                    latest_migration,
                    producer_repository,
                )
            except (OSError, ValueError, KeyError, yaml.YAMLError) as exc:
                raise SystemExit(f"{path}: {exc}") from exc
        jobs = parse_job_documents(rendered)
        if not jobs:
            raise SystemExit(f"{path}: no rendered Job found")

        for name, image in jobs:
            validate_job_name_matches_image(name, image)
            print(f"  {path}: {name} -> {image}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
