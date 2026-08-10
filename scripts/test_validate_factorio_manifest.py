#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Callable
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
VALIDATOR = ROOT / "scripts/validate_factorio_manifest.py"


def run(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "uv",
            "--no-config",
            "run",
            "--locked",
            "--script",
            str(VALIDATOR),
            "--repo-root",
            str(root),
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    if text.count(old) != 1:
        raise AssertionError(f"{path}: expected exactly one mutation target {old!r}")
    path.write_text(text.replace(old, new, 1))


def replace_yaml_list_item_once(path: Path, old: str, new: str) -> None:
    pattern = re.compile(
        rf"^(?P<indent>[ \t]*)-[ \t]+{re.escape(old)}(?P<trailing>[ \t]*)$",
        re.MULTILINE,
    )
    text = path.read_text()
    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        raise AssertionError(
            f"{path}: expected exactly one complete YAML list item {old!r}"
        )
    match = matches[0]
    replacement = f"{match.group('indent')}- {new}{match.group('trailing')}"
    path.write_text(text[: match.start()] + replacement + text[match.end() :])


def yaml_scalar_line(path: Path, key: str) -> tuple[str, str]:
    pattern = re.compile(
        rf"^(?P<line>[ \t]*{re.escape(key)}:[ \t]*(?P<quote>['\"]?)(?P<value>[^'\"\s#]+)(?P=quote)[ \t]*)$",
        re.MULTILINE,
    )
    matches = list(pattern.finditer(path.read_text()))
    if len(matches) != 1:
        raise AssertionError(f"{path}: expected exactly one YAML scalar {key!r}")
    return matches[0].group("line"), matches[0].group("value")


def fixture(parent: Path, name: str) -> Path:
    root = parent / name
    shutil.copytree(ROOT / "apps", root / "apps")
    shutil.copytree(
        ROOT / "infrastructure/storage/restic-backup",
        root / "infrastructure/storage/restic-backup",
    )
    shutil.copytree(
        ROOT / "infrastructure/storage/storage-classes",
        root / "infrastructure/storage/storage-classes",
    )
    (root / "scripts").mkdir(parents=True)
    shutil.copy2(ROOT / "scripts/hestia-firewalld-setup.sh", root / "scripts")
    shutil.copy2(ROOT / "renovate.json", root / "renovate.json")
    return root


def mutation(
    parent: Path,
    name: str,
    relative: str,
    old: str,
    new: str,
    expected: str,
    *,
    replacer: Callable[[Path, str, str], None] = replace_once,
) -> None:
    root = fixture(parent, name)
    replacer(root / relative, old, new)
    result = run(root)
    combined = result.stdout + result.stderr
    if result.returncode == 0:
        raise AssertionError(f"{name}: mutation was accepted")
    if expected not in combined:
        raise AssertionError(f"{name}: expected {expected!r}, got:\n{combined}")
    print(f"PASS mutation {name}")


def node_selector_mutation(
    parent: Path,
    name: str,
    hostname_line: str,
    expected: str,
) -> None:
    root = fixture(parent, name)
    path = root / "apps/factorio/deployment-default-factorio.yaml"
    current = (
        "      nodeSelector:\n"
        "        kubernetes.io/arch: amd64\n"
    )
    required = current + "        kubernetes.io/hostname: hestia\n"
    text = path.read_text()
    if text.count(required) == 1:
        pass
    elif text.count(current) == 1:
        path.write_text(text.replace(current, required, 1))
    else:
        raise AssertionError(
            f"{name}: expected exactly one canonical or pre-Hestia nodeSelector"
        )
    replace_once(
        path,
        "        kubernetes.io/hostname: hestia\n",
        hostname_line,
    )
    result = run(root)
    combined = result.stdout + result.stderr
    if result.returncode == 0:
        raise AssertionError(f"{name}: mutation was accepted")
    if expected not in combined:
        raise AssertionError(f"{name}: expected {expected!r}, got:\n{combined}")
    print(f"PASS mutation {name}")


def accepted_mutation(
    parent: Path,
    name: str,
    relative: str,
    old: str,
    new: str,
) -> None:
    root = fixture(parent, name)
    replace_once(root / relative, old, new)
    result = run(root)
    combined = result.stdout + result.stderr
    if result.returncode:
        raise AssertionError(f"{name}: valid mutation was rejected:\n{combined}")
    print(f"PASS accepted mutation {name}")


def exact_unordered_strings(value: Any, expected: set[str]) -> bool:
    return (
        isinstance(value, list)
        and len(value) == len(expected)
        and all(isinstance(item, str) for item in value)
        and set(value) == expected
    )


def factorio_renovate_rules(renovate: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        rule
        for rule in renovate.get("packageRules", [])
        if isinstance(rule, dict)
        and rule.get("matchManagers") == ["kustomize"]
        and rule.get("matchDatasources") == ["docker"]
        and rule.get("matchFileNames") == ["apps/factorio/kustomization.yaml"]
        and exact_unordered_strings(
            rule.get("matchPackageNames"),
            {"factoriotools/factorio", "docker.io/factoriotools/factorio"},
        )
    ]


def renovate_mutation(
    parent: Path,
    name: str,
    field: str,
    new_value: Any,
    expected: str,
    *,
    selector_field: str | None = None,
) -> None:
    root = fixture(parent, name)
    path = root / "renovate.json"
    renovate = json.loads(path.read_text())
    matching_rules = [
        rule
        for rule in factorio_renovate_rules(renovate)
        if (selector_field or field) in rule
    ]
    if len(matching_rules) != 1:
        raise AssertionError(f"{name}: expected exactly one Factorio Renovate rule with {field!r}")
    matching_rules[0][field] = new_value
    path.write_text(json.dumps(renovate, indent=2) + "\n")
    result = run(root)
    combined = result.stdout + result.stderr
    if result.returncode == 0:
        raise AssertionError(f"{name}: mutation was accepted")
    if expected not in combined:
        raise AssertionError(f"{name}: expected {expected!r}, got:\n{combined}")
    print(f"PASS mutation {name}")


def accepted_renovate_package_order_mutation(parent: Path) -> None:
    name = "renovate-package-name-order"
    root = fixture(parent, name)
    path = root / "renovate.json"
    renovate = json.loads(path.read_text())
    matching_rules = factorio_renovate_rules(renovate)
    if len(matching_rules) != 2:
        raise AssertionError(f"{name}: expected exactly two Factorio Renovate rules")
    for rule in matching_rules:
        rule["matchPackageNames"] = list(reversed(rule["matchPackageNames"]))
    path.write_text(json.dumps(renovate, indent=2) + "\n")
    result = run(root)
    combined = result.stdout + result.stderr
    if result.returncode:
        raise AssertionError(f"{name}: order-only valid mutation was rejected:\n{combined}")
    print(f"PASS accepted mutation {name}")


def renovate_rule_order_mutation(parent: Path) -> None:
    name = "renovate-factorio-rules-before-broad-group"
    root = fixture(parent, name)
    path = root / "renovate.json"
    renovate = json.loads(path.read_text())
    package_rules = renovate.get("packageRules", [])
    factorio_rules = factorio_renovate_rules(renovate)
    broad_rules = [
        rule
        for rule in package_rules
        if isinstance(rule, dict)
        and rule.get("groupName") == "k8s-images"
        and "apps/**/kustomization.yaml" in rule.get("matchFileNames", [])
    ]
    if len(factorio_rules) != 2 or len(broad_rules) != 1:
        raise AssertionError(f"{name}: expected two Factorio rules and one broad k8s-images rule")
    factorio_rule_ids = {id(rule) for rule in factorio_rules}
    renovate["packageRules"] = factorio_rules + [
        rule for rule in package_rules if id(rule) not in factorio_rule_ids
    ]
    path.write_text(json.dumps(renovate, indent=2) + "\n")
    result = run(root)
    combined = result.stdout + result.stderr
    if result.returncode == 0:
        raise AssertionError(f"{name}: mutation was accepted")
    expected = "Factorio Renovate rules must override the broad k8s-images group"
    if expected not in combined:
        raise AssertionError(f"{name}: expected {expected!r}, got:\n{combined}")
    print(f"PASS mutation {name}")


def renovate_later_override_mutation(parent: Path) -> None:
    name = "renovate-later-broad-factorio-override"
    root = fixture(parent, name)
    path = root / "renovate.json"
    renovate = json.loads(path.read_text())
    package_rules = renovate.get("packageRules", [])
    if not isinstance(package_rules, list):
        raise AssertionError(f"{name}: expected packageRules list")
    package_rules.append(
        {
            "description": "Unsafe later override matching Factorio",
            "matchManagers": ["kustomize"],
            "matchDatasources": ["docker"],
            "matchFileNames": ["apps/**/kustomization.yaml"],
            "versioning": "docker",
            "allowedVersions": "*",
            "ignoreTests": True,
            "platformAutomerge": True,
            "groupName": "late-factorio-override",
            "groupSlug": "late-factorio-override",
        }
    )
    path.write_text(json.dumps(renovate, indent=2) + "\n")
    result = run(root)
    combined = result.stdout + result.stderr
    if result.returncode == 0:
        raise AssertionError(f"{name}: mutation was accepted")
    expected = (
        "Factorio Renovate restriction and automerge rules must be the ordered "
        "final two packageRules"
    )
    if expected not in combined:
        raise AssertionError(f"{name}: expected {expected!r}, got:\n{combined}")
    print(f"PASS mutation {name}")


def renovate_factorio_rule_sequence_mutation(parent: Path) -> None:
    name = "renovate-factorio-final-rules-reversed"
    root = fixture(parent, name)
    path = root / "renovate.json"
    renovate = json.loads(path.read_text())
    package_rules = renovate.get("packageRules", [])
    factorio_rules = factorio_renovate_rules(renovate)
    if not isinstance(package_rules, list) or package_rules[-2:] != factorio_rules:
        raise AssertionError(f"{name}: expected Factorio rules to be the final two rules")
    package_rules[-2:] = reversed(package_rules[-2:])
    path.write_text(json.dumps(renovate, indent=2) + "\n")
    result = run(root)
    combined = result.stdout + result.stderr
    if result.returncode == 0:
        raise AssertionError(f"{name}: mutation was accepted")
    expected = (
        "Factorio Renovate restriction and automerge rules must be the ordered "
        "final two packageRules"
    )
    if expected not in combined:
        raise AssertionError(f"{name}: expected {expected!r}, got:\n{combined}")
    print(f"PASS mutation {name}")


def main() -> int:
    baseline = run(ROOT)
    combined = baseline.stdout + baseline.stderr
    if not (ROOT / "apps/factorio").exists():
        if baseline.returncode == 0 or "apps/factorio desired state is missing" not in combined:
            print(combined, file=sys.stderr)
            return 2
        print("AUTHENTIC RED: Factorio desired state is missing", file=sys.stderr)
        return 1
    if baseline.returncode:
        print(combined, file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="factorio-mutations-") as temp:
        parent = Path(temp)
        node_selector_mutation(
            parent,
            "node-selector-hostname-removed",
            "",
            "ERROR: Factorio architecture/scheduling: expected "
            "{'kubernetes.io/arch': 'amd64', 'kubernetes.io/hostname': 'hestia'}, "
            "got {'kubernetes.io/arch': 'amd64'}",
        )
        node_selector_mutation(
            parent,
            "node-selector-hostname-substituted",
            "        kubernetes.io/hostname: nyx\n",
            "ERROR: Factorio architecture/scheduling: expected "
            "{'kubernetes.io/arch': 'amd64', 'kubernetes.io/hostname': 'hestia'}, "
            "got {'kubernetes.io/arch': 'amd64', 'kubernetes.io/hostname': 'nyx'}",
        )
        image_path = ROOT / "apps/factorio/kustomization.yaml"
        current_combined_line, current_combined = yaml_scalar_line(image_path, "newTag")
        if current_combined.count("@") != 1:
            raise AssertionError(
                f"baseline Factorio newTag is not combined tag@digest: {current_combined!r}"
            )
        current_tag, current_digest = current_combined.split("@")
        tag_match = re.fullmatch(r"stable-2\.0\.(\d+)", current_tag)
        if tag_match is None:
            raise AssertionError(f"baseline Factorio tag is not stable-2.0 patch-only: {current_tag!r}")
        if re.fullmatch(r"sha256:[0-9a-f]{64}", current_digest) is None:
            raise AssertionError(f"baseline Factorio digest is malformed: {current_digest!r}")
        updated_tag = f"stable-2.0.{int(tag_match.group(1)) + 1}"
        updated_digest = current_digest[:-1] + ("0" if current_digest[-1] != "0" else "1")
        updated_combined = f"{updated_tag}@{updated_digest}"
        accepted_mutation(
            parent,
            "image-renovate-stable-patch-and-digest-update",
            "apps/factorio/kustomization.yaml",
            current_combined_line,
            current_combined_line.replace(current_combined, updated_combined, 1),
        )
        mutation(
            parent,
            "app-inclusion-removed",
            "apps/kustomization.yaml",
            "- factorio\n",
            "",
            "apps entrypoint does not include Factorio",
        )
        mutation(
            parent,
            "image-numeric-experimental-tag",
            "apps/factorio/kustomization.yaml",
            current_combined_line,
            current_combined_line.replace(
                current_combined,
                f"{current_tag.removeprefix('stable-')}@{current_digest}",
                1,
            ),
            "newTag tag must match",
        )
        mutation(
            parent,
            "image-stable-2.1-drift",
            "apps/factorio/kustomization.yaml",
            current_combined_line,
            current_combined_line.replace(
                current_combined,
                f"stable-2.1.0@{current_digest}",
                1,
            ),
            "newTag tag must match",
        )
        mutation(
            parent,
            "image-digest-removed",
            "apps/factorio/kustomization.yaml",
            current_combined_line,
            current_combined_line.replace(current_combined, current_tag, 1),
            "newTag must contain exactly one '@'",
        )
        mutation(
            parent,
            "image-digest-malformed",
            "apps/factorio/kustomization.yaml",
            current_combined_line,
            current_combined_line.replace(
                current_combined,
                f"{current_tag}@{current_digest[:-1]}",
                1,
            ),
            "newTag digest must match",
        )
        image_indent = current_combined_line[: len(current_combined_line) - len(current_combined_line.lstrip())]
        mutation(
            parent,
            "image-separate-digest-field",
            "apps/factorio/kustomization.yaml",
            current_combined_line,
            current_combined_line.replace(current_combined, current_tag, 1)
            + f"\n{image_indent}digest: {current_digest}",
            "must contain exactly name and combined newTag",
        )
        accepted_renovate_package_order_mutation(parent)
        renovate_later_override_mutation(parent)
        renovate_factorio_rule_sequence_mutation(parent)
        renovate_rule_order_mutation(parent)
        renovate_mutation(
            parent,
            "renovate-2.1-allowed",
            "allowedVersions",
            r"/^stable-2\.[0-9]+\.[0-9]+$/",
            "versioning and allowedVersions must be exactly",
        )
        renovate_mutation(
            parent,
            "renovate-numeric-tags-versioning",
            "versioning",
            r"regex:^stable-(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$",
            "restriction versioning and allowedVersions must be exactly",
        )
        renovate_mutation(
            parent,
            "renovate-minor-automerge",
            "matchUpdateTypes",
            ["patch", "digest", "pinDigest", "minor"],
            "matchUpdateTypes must be exactly patch, digest, and pinDigest",
        )
        renovate_mutation(
            parent,
            "renovate-pin-digests-disabled",
            "pinDigests",
            False,
            "restriction must set pinDigests true",
        )
        renovate_mutation(
            parent,
            "renovate-update-types-added-to-restriction",
            "matchUpdateTypes",
            ["patch", "digest", "pinDigest"],
            "without matchUpdateTypes",
            selector_field="allowedVersions",
        )
        renovate_mutation(
            parent,
            "renovate-factorio-group-slug-weakened",
            "groupSlug",
            "k8s-images",
            "groupName/groupSlug factorio",
            selector_field="allowedVersions",
        )
        renovate_mutation(
            parent,
            "renovate-canonical-package-name-only",
            "matchPackageNames",
            ["factoriotools/factorio"],
            "exactly two explicit Factorio",
            selector_field="allowedVersions",
        )
        renovate_mutation(
            parent,
            "renovate-automerge-disabled",
            "automerge",
            False,
            "automerge must fail closed",
        )
        renovate_mutation(
            parent,
            "renovate-automerge-not-pr",
            "automergeType",
            "branch",
            "automerge must fail closed",
        )
        renovate_mutation(
            parent,
            "renovate-tests-ignored",
            "ignoreTests",
            True,
            "automerge must fail closed",
        )
        renovate_mutation(
            parent,
            "renovate-platform-automerge-enabled",
            "platformAutomerge",
            True,
            "automerge must fail closed",
        )
        mutation(
            parent,
            "root-user",
            "apps/factorio/deployment-default-factorio.yaml",
            "    runAsUser: 845",
            "    runAsUser: 0",
            "Factorio pod securityContext",
        )
        mutation(
            parent,
            "pod-run-as-non-root-bool-to-int",
            "apps/factorio/deployment-default-factorio.yaml",
            "        runAsNonRoot: true",
            "        runAsNonRoot: 1",
            "Factorio pod securityContext",
        )
        mutation(
            parent,
            "pod-run-as-user-int-to-float",
            "apps/factorio/deployment-default-factorio.yaml",
            "        runAsUser: 845",
            "        runAsUser: 845.0",
            "Factorio pod securityContext",
        )
        mutation(
            parent,
            "rolling-update-writers",
            "apps/factorio/deployment-default-factorio.yaml",
            "    type: Recreate",
            "    type: RollingUpdate",
            "Deployment/factorio.spec.strategy",
        )
        mutation(
            parent,
            "container-args-removed",
            "apps/factorio/deployment-default-factorio.yaml",
            "        args: []\n",
            "",
            "Factorio container args must be explicitly present",
        )
        mutation(
            parent,
            "container-args-drift",
            "apps/factorio/deployment-default-factorio.yaml",
            "        args: []",
            "        args:\n        - --unexpected-image-cmd",
            "Factorio container args",
        )
        mutation(
            parent,
            "service-links-enabled",
            "apps/factorio/deployment-default-factorio.yaml",
            "      enableServiceLinks: false",
            "      enableServiceLinks: true",
            "Factorio service links",
        )
        mutation(
            parent,
            "configmap-mode-executable",
            "apps/factorio/deployment-default-factorio.yaml",
            "          defaultMode: 0444",
            "          defaultMode: 0555",
            "Factorio generated configuration volume",
        )
        mutation(
            parent,
            "rcon-added",
            "apps/factorio/files/start-factorio.sh",
            '  --server-id "${STATE_DIR}/server-id.json" \\\n',
            '  --rcon-port 27015 \\\n  --server-id "${STATE_DIR}/server-id.json" \\\n',
            "must not configure or expose RCON",
        )
        mutation(
            parent,
            "tcp-service",
            "apps/factorio/service-default-factorio.yaml",
            "    protocol: UDP",
            "    protocol: TCP",
            "Factorio external endpoint",
        )
        mutation(
            parent,
            "public-listing",
            "apps/factorio/files/server-settings.json",
            '    "public": false,',
            '    "public": true,',
            "server-settings.json.visibility",
        )
        mutation(
            parent,
            "server-visibility-bool-to-int",
            "apps/factorio/files/server-settings.json",
            '    "public": false,',
            '    "public": 0,',
            "server-settings.json.visibility",
        )
        mutation(
            parent,
            "map-settings-file-removed",
            "apps/factorio/kustomization.yaml",
            "  - files/map-settings.json\n",
            "",
            "Factorio generated config files",
        )
        mutation(
            parent,
            "peaceful-mode-enabled",
            "apps/factorio/files/map-gen-settings.json",
            '  "peaceful_mode": false,',
            '  "peaceful_mode": true,',
            "map-gen-settings.json.peaceful_mode",
        )
        mutation(
            parent,
            "enemy-expansion-disabled",
            "apps/factorio/files/map-settings.json",
            '  "enemy_expansion":\n  {\n    "enabled": true,',
            '  "enemy_expansion":\n  {\n    "enabled": false,',
            "map-settings.json.enemy_expansion.enabled",
        )
        mutation(
            parent,
            "whitelist-broadened",
            "apps/factorio/files/server-whitelist.json",
            '["neBM"]',
            '["neBM", "guest"]',
            "Factorio whitelist",
        )
        mutation(
            parent,
            "space-age-enabled",
            "apps/factorio/files/mod-list.json",
            '{"name": "space-age", "enabled": false}',
            '{"name": "space-age", "enabled": true}',
            "Factorio vanilla mod list",
        )
        mutation(
            parent,
            "mod-policy-bool-to-int",
            "apps/factorio/files/mod-list.json",
            '{"name": "base", "enabled": true}',
            '{"name": "base", "enabled": 1}',
            "Factorio vanilla mod list",
        )
        mutation(
            parent,
            "pvc-not-seaweedfs",
            "apps/factorio/persistentvolumeclaim-default-factorio-data-sw.yaml",
            "  storageClassName: seaweedfs",
            "  storageClassName: local-path-retain",
            "Factorio retained SeaweedFS PVC",
        )
        mutation(
            parent,
            "pvc-not-rwx",
            "apps/factorio/persistentvolumeclaim-default-factorio-data-sw.yaml",
            "ReadWriteMany",
            "ReadWriteOnce",
            "Factorio retained SeaweedFS PVC",
            replacer=replace_yaml_list_item_once,
        )
        mutation(
            parent,
            "restic-path-removed",
            "infrastructure/storage/restic-backup/files/critical-pvc-paths.txt",
            "/data/factorio-data-sw\n",
            "",
            "Restic critical paths must include",
        )
        mutation(
            parent,
            "firewall-tcp",
            "scripts/hestia-firewalld-setup.sh",
            "--permanent --zone=FedoraServer --add-port=34197/udp",
            "--permanent --zone=FedoraServer --add-port=34197/tcp",
            "durably open 34197/udp",
        )
        mutation(
            parent,
            "network-policy-broadened",
            "apps/factorio/networkpolicy-default-factorio-lan.yaml",
            "        cidr: 192.168.1.0/24",
            "        cidr: 0.0.0.0/0",
            "Factorio LAN-only ingress policy",
        )

    print("Factorio manifest semantic and mutation tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
