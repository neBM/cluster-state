#!/usr/bin/env python3

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
TARGETS = (
    "apps/gitlab",
    "apps/feedback",
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
