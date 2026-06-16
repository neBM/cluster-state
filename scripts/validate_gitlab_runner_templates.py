#!/usr/bin/env python3

from __future__ import annotations

import sys
from pathlib import Path

try:
    import tomllib
except ImportError as exc:  # pragma: no cover
    raise SystemExit("python3.11+ is required for tomllib") from exc


def load_template(base_dir: Path, variant_dir: Path) -> str:
    fragments = list((base_dir / "fragments").glob("*.toml"))
    fragments.extend((variant_dir / "fragments").glob("*.toml"))
    ordered = sorted(fragments, key=lambda path: path.name)
    return "".join(path.read_text() for path in ordered)


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    runner_root = repo_root / "infrastructure" / "shared-services" / "gitlab-runner"
    base_dir = runner_root / "runner-base"
    variant_root = runner_root / "runners"

    print("Validating GitLab runner templates")
    for variant_dir in sorted(path for path in variant_root.iterdir() if path.is_dir()):
        template = load_template(base_dir, variant_dir)
        try:
            tomllib.loads(template)
        except tomllib.TOMLDecodeError as exc:
            print(f"{variant_dir.name}: invalid runner template: {exc}", file=sys.stderr)
            return 1
        print(f"  {variant_dir.name}: ok")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
