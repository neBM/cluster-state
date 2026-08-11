#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML==6.0.3"]
# ///

from __future__ import annotations

import argparse
import configparser
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parent.parent
IMAGE_NAME = "factoriotools/factorio"
IMAGE_TAG_PATTERN = re.compile(r"^stable-2\.0\.\d+$")
IMAGE_DIGEST_PATTERN = re.compile(r"^sha256:[0-9a-f]{64}$")
RENOVATE_PACKAGE_NAMES = frozenset({IMAGE_NAME, f"docker.io/{IMAGE_NAME}"})
RENOVATE_VERSIONING = r"regex:^stable-(?<major>2)\.(?<minor>0)\.(?<patch>\d+)$"
RENOVATE_ALLOWED_VERSIONS = r"/^stable-2\.0\.[0-9]+$/"
RENOVATE_AUTOMERGE_UPDATE_TYPES = frozenset({"patch", "digest", "pinDigest"})
FACTORIO_PORT = 34197


def _type_strict_equal(actual: Any, expected: Any) -> bool:
    if type(actual) is not type(expected):
        return False
    if isinstance(expected, dict):
        return actual.keys() == expected.keys() and all(
            _type_strict_equal(actual[key], value)
            for key, value in expected.items()
        )
    if isinstance(expected, (list, tuple)):
        return len(actual) == len(expected) and all(
            _type_strict_equal(actual_item, expected_item)
            for actual_item, expected_item in zip(actual, expected, strict=True)
        )
    return actual == expected


class Checks:
    def __init__(self) -> None:
        self.errors: list[str] = []

    def equal(self, actual: Any, expected: Any, path: str) -> None:
        if not _type_strict_equal(actual, expected):
            self.errors.append(f"{path}: expected {expected!r}, got {actual!r}")

    def true(self, condition: bool, message: str) -> None:
        if not condition:
            self.errors.append(message)

    def one(self, resources: list[dict[str, Any]], kind: str, name: str) -> dict[str, Any]:
        matches = [
            item
            for item in resources
            if item.get("kind") == kind
            and item.get("metadata", {}).get("name") == name
        ]
        if len(matches) != 1:
            self.errors.append(f"expected exactly one {kind}/{name}, got {len(matches)}")
            return {}
        return matches[0]


def render(root: Path, relative: str) -> list[dict[str, Any]]:
    path = root / relative
    if not (path / "kustomization.yaml").is_file():
        raise ValueError(f"{relative} is not a Kustomize entrypoint")
    executable = shutil.which("kustomize")
    command = [executable, "build", relative] if executable else ["kubectl", "kustomize", relative]
    result = subprocess.run(command, cwd=root, capture_output=True, text=True, check=False)
    if result.returncode:
        raise ValueError(f"render {relative}: {result.stderr.strip()}")
    return [doc for doc in yaml.safe_load_all(result.stdout) if isinstance(doc, dict)]


def parse_json(data: dict[str, str], name: str, checks: Checks) -> Any:
    try:
        return json.loads(data.get(name, ""))
    except json.JSONDecodeError as exc:
        checks.errors.append(f"ConfigMap factorio-config/{name}: invalid JSON: {exc}")
        return None


def exact_unordered_strings(value: Any, expected: frozenset[str]) -> bool:
    return (
        isinstance(value, list)
        and len(value) == len(expected)
        and all(isinstance(item, str) for item in value)
        and set(value) == expected
    )


def validate_renovate(root: Path, checks: Checks) -> None:
    try:
        renovate = json.loads((root / "renovate.json").read_text())
    except (OSError, json.JSONDecodeError) as exc:
        checks.errors.append(f"renovate.json: {exc}")
        return

    package_rules = renovate.get("packageRules", [])
    if not isinstance(package_rules, list):
        checks.errors.append("renovate.json.packageRules must be a list")
        return
    factorio_rules: list[tuple[int, dict[str, Any]]] = []
    for index, rule in enumerate(package_rules):
        if not isinstance(rule, dict):
            continue
        if (
            rule.get("matchManagers") == ["kustomize"]
            and rule.get("matchDatasources") == ["docker"]
            and rule.get("matchFileNames") == ["apps/factorio/kustomization.yaml"]
            and exact_unordered_strings(rule.get("matchPackageNames"), RENOVATE_PACKAGE_NAMES)
        ):
            factorio_rules.append((index, rule))

    checks.true(
        len(factorio_rules) == 2,
        "Renovate must have exactly two explicit Factorio kustomize/docker rules matching both canonical package names",
    )
    restriction = [
        (index, rule)
        for index, rule in factorio_rules
        if "allowedVersions" in rule or "versioning" in rule or "pinDigests" in rule
    ]
    automerge = [
        (index, rule)
        for index, rule in factorio_rules
        if any(
            field in rule
            for field in (
                "matchUpdateTypes",
                "automerge",
                "automergeType",
                "ignoreTests",
                "platformAutomerge",
            )
        )
    ]
    checks.true(
        len(restriction) == 1
        and restriction[0][1].get("versioning") == RENOVATE_VERSIONING
        and restriction[0][1].get("allowedVersions") == RENOVATE_ALLOWED_VERSIONS
        and "matchUpdateTypes" not in restriction[0][1],
        "Factorio Renovate restriction versioning and allowedVersions must be exactly stable-2.0 patch-only without matchUpdateTypes",
    )
    checks.true(
        len(restriction) == 1
        and restriction[0][1].get("pinDigests") is True
        and restriction[0][1].get("groupName") == "factorio"
        and restriction[0][1].get("groupSlug") == "factorio",
        "Factorio Renovate restriction must set pinDigests true and groupName/groupSlug factorio",
    )
    checks.true(
        len(automerge) == 1
        and exact_unordered_strings(
            automerge[0][1].get("matchUpdateTypes"),
            RENOVATE_AUTOMERGE_UPDATE_TYPES,
        )
        and "allowedVersions" not in automerge[0][1]
        and "versioning" not in automerge[0][1],
        "Factorio Renovate automerge matchUpdateTypes must be exactly patch, digest, and pinDigest in a separate rule",
    )
    checks.true(
        len(automerge) == 1
        and automerge[0][1].get("automerge") is True
        and automerge[0][1].get("automergeType") == "pr"
        and automerge[0][1].get("ignoreTests") is False
        and automerge[0][1].get("platformAutomerge") is False,
        "Factorio Renovate automerge must fail closed with automerge pr, tests required, and platform automerge disabled",
    )
    checks.true(
        len(restriction) == 1
        and len(automerge) == 1
        and [restriction[0][0], automerge[0][0]]
        == [len(package_rules) - 2, len(package_rules) - 1],
        "Factorio Renovate restriction and automerge rules must be the ordered final two packageRules",
    )
    if len(restriction) == 1 and len(automerge) == 1:
        restriction_index, _ = restriction[0]
        automerge_index, automerge_rule = automerge[0]
        explicit_automerge_group = (
            automerge_rule.get("groupName") == "factorio"
            and automerge_rule.get("groupSlug") == "factorio"
        )
        inherited_automerge_group = (
            "groupName" not in automerge_rule
            and "groupSlug" not in automerge_rule
            and automerge_index < restriction_index
        )
        checks.true(
            explicit_automerge_group or inherited_automerge_group,
            "Factorio Renovate rules must produce an unambiguous final factorio groupName/groupSlug",
        )
    broad_group_indexes = [
        index
        for index, rule in enumerate(package_rules)
        if isinstance(rule, dict)
        and rule.get("groupName") == "k8s-images"
        and isinstance(rule.get("matchFileNames"), list)
        and "apps/**/kustomization.yaml" in rule["matchFileNames"]
    ]
    checks.true(
        not broad_group_indexes
        or all(index > max(broad_group_indexes) for index, _ in factorio_rules),
        "Factorio Renovate rules must override the broad k8s-images group",
    )


def validate_factorio(root: Path) -> list[str]:
    checks = Checks()
    factorio_root = root / "apps/factorio"
    if not (factorio_root / "kustomization.yaml").is_file():
        return ["apps/factorio desired state is missing"]

    rendered: dict[str, list[dict[str, Any]]] = {}
    for name, entrypoint in (
        ("apps", "apps"),
        ("restic", "infrastructure/storage/restic-backup"),
        ("storage", "infrastructure/storage/storage-classes"),
    ):
        try:
            rendered[name] = render(root, entrypoint)
        except (ValueError, yaml.YAMLError) as exc:
            checks.errors.append(str(exc))
    if checks.errors:
        return checks.errors

    app_resources = [
        item
        for item in rendered["apps"]
        if item.get("metadata", {}).get("labels", {}).get("app") == "factorio"
    ]
    checks.true(bool(app_resources), "apps entrypoint does not include Factorio")
    for resource in app_resources:
        checks.equal(
            resource.get("metadata", {}).get("namespace"),
            "default",
            f"{resource.get('kind')}/{resource.get('metadata', {}).get('name')}.metadata.namespace",
        )
    checks.true(
        not any(item.get("kind") == "Secret" for item in app_resources),
        "Factorio desired state must not contain Secret resources",
    )
    rendered_text = yaml.safe_dump_all(app_resources, sort_keys=True).lower()
    checks.true("rcon" not in rendered_text, "Factorio desired state must not configure or expose RCON")

    deployment = checks.one(app_resources, "Deployment", "factorio")
    service = checks.one(app_resources, "Service", "factorio")
    pvc = checks.one(app_resources, "PersistentVolumeClaim", "factorio-data-sw")
    policy = checks.one(app_resources, "NetworkPolicy", "factorio-lan")
    configmaps = [
        item
        for item in app_resources
        if item.get("kind") == "ConfigMap"
        and item.get("metadata", {}).get("name", "").startswith("factorio-config-")
    ]
    if len(configmaps) != 1:
        checks.errors.append(f"expected one hashed Factorio ConfigMap, got {len(configmaps)}")
        configmap: dict[str, Any] = {}
    else:
        configmap = configmaps[0]

    try:
        kustomization = yaml.safe_load((factorio_root / "kustomization.yaml").read_text())
    except (OSError, yaml.YAMLError) as exc:
        checks.errors.append(f"apps/factorio/kustomization.yaml: {exc}")
        kustomization = {}
    images = kustomization.get("images") if isinstance(kustomization, dict) else None
    checks.true(
        isinstance(images, list)
        and len(images) == 1
        and isinstance(images[0], dict),
        "apps/factorio/kustomization.yaml.images must contain exactly one image entry",
    )
    image = images[0] if isinstance(images, list) and len(images) == 1 and isinstance(images[0], dict) else {}
    image_name = image.get("name")
    combined_new_tag = image.get("newTag")
    checks.equal(image_name, IMAGE_NAME, "apps/factorio/kustomization.yaml.images[0].name")
    checks.true(
        set(image) == {"name", "newTag"},
        "apps/factorio/kustomization.yaml.images[0] must contain exactly name and combined newTag; a separate digest key is forbidden",
    )
    image_tag: str | None = None
    image_digest: str | None = None
    if isinstance(combined_new_tag, str) and combined_new_tag.count("@") == 1:
        image_tag, image_digest = combined_new_tag.split("@")
    checks.true(
        image_tag is not None and image_digest is not None,
        "apps/factorio/kustomization.yaml.images[0].newTag must contain exactly one '@' separating tag and digest",
    )
    checks.true(
        image_tag is not None and IMAGE_TAG_PATTERN.fullmatch(image_tag) is not None,
        r"apps/factorio/kustomization.yaml.images[0].newTag tag must match ^stable-2\.0\.\d+$",
    )
    checks.true(
        isinstance(image_digest, str) and IMAGE_DIGEST_PATTERN.fullmatch(image_digest) is not None,
        r"apps/factorio/kustomization.yaml.images[0].newTag digest must match ^sha256:[0-9a-f]{64}$",
    )
    rendered_image = (
        f"{IMAGE_NAME}:{combined_new_tag}"
        if isinstance(combined_new_tag, str)
        else None
    )
    generators = kustomization.get("configMapGenerator", []) if isinstance(kustomization, dict) else []
    checks.true(
        len(generators) == 1
        and generators[0].get("name") == "factorio-config"
        and "disableNameSuffixHash" not in generators[0].get("options", {}),
        "Factorio configuration must use a hash-suffixed configMapGenerator",
    )

    if deployment:
        spec = deployment.get("spec", {})
        checks.equal(spec.get("replicas"), 1, "Deployment/factorio.spec.replicas")
        checks.equal(spec.get("strategy"), {"type": "Recreate"}, "Deployment/factorio.spec.strategy")
        pod = spec.get("template", {}).get("spec", {})
        checks.equal(pod.get("automountServiceAccountToken"), False, "Factorio service-account token")
        checks.equal(pod.get("enableServiceLinks"), False, "Factorio service links")
        checks.equal(
            pod.get("nodeSelector"),
            {
                "kubernetes.io/arch": "amd64",
                "kubernetes.io/hostname": "hestia",
            },
            "Factorio architecture/scheduling",
        )
        checks.equal(pod.get("terminationGracePeriodSeconds"), 300, "Factorio termination grace")
        checks.equal(
            pod.get("securityContext"),
            {
                "runAsNonRoot": True,
                "runAsUser": 845,
                "runAsGroup": 845,
                "fsGroup": 845,
                "fsGroupChangePolicy": "OnRootMismatch",
                "seccompProfile": {"type": "RuntimeDefault"},
            },
            "Factorio pod securityContext",
        )
        try:
            source_deployment = yaml.safe_load(
                (factorio_root / "deployment-default-factorio.yaml").read_text()
            )
        except (OSError, yaml.YAMLError) as exc:
            checks.errors.append(
                f"apps/factorio/deployment-default-factorio.yaml: {exc}"
            )
        else:
            source_pod = (
                source_deployment.get("spec", {})
                .get("template", {})
                .get("spec", {})
                if isinstance(source_deployment, dict)
                else {}
            )
            checks.equal(
                source_pod.get("securityContext"),
                pod.get("securityContext"),
                "Factorio pod securityContext source/rendered type parity",
            )
        containers = pod.get("containers", [])
        if len(containers) != 1:
            checks.errors.append(f"Deployment/factorio: expected one container, got {len(containers)}")
        else:
            container = containers[0]
            checks.equal(container.get("name"), "factorio", "Factorio container name")
            checks.equal(
                container.get("image"),
                rendered_image,
                "Deployment/factorio image must equal factoriotools/factorio:<combined-newTag>",
            )
            checks.equal(
                container.get("command"),
                ["/bin/bash", "/config/start-factorio.sh"],
                "Factorio entrypoint bypass command",
            )
            checks.true(
                "args" in container,
                "Factorio container args must be explicitly present",
            )
            checks.equal(container.get("args"), [], "Factorio container args")
            checks.equal(
                container.get("env"),
                [{"name": "DLC_SPACE_AGE", "value": "false"}],
                "Factorio Space Age environment",
            )
            checks.equal(
                container.get("ports"),
                [{"containerPort": FACTORIO_PORT, "name": "game", "protocol": "UDP"}],
                "Factorio container ports",
            )
            checks.equal(
                container.get("resources"),
                {
                    "requests": {"cpu": "100m", "memory": "512Mi"},
                    "limits": {"cpu": "2", "memory": "4Gi"},
                },
                "Factorio resources",
            )
            checks.equal(
                container.get("securityContext"),
                {
                    "allowPrivilegeEscalation": False,
                    "readOnlyRootFilesystem": True,
                    "capabilities": {"drop": ["ALL"]},
                },
                "Factorio container securityContext",
            )
            mounts = {item.get("name"): item for item in container.get("volumeMounts", [])}
            checks.equal(
                mounts,
                {
                    "factorio-data": {"name": "factorio-data", "mountPath": "/factorio"},
                    "factorio-config": {"name": "factorio-config", "mountPath": "/config", "readOnly": True},
                    "runtime": {"name": "runtime", "mountPath": "/runtime"},
                    "tmp": {"name": "tmp", "mountPath": "/tmp"},
                },
                "Factorio volume mounts",
            )
        volumes = {item.get("name"): item for item in pod.get("volumes", [])}
        checks.equal(
            volumes.get("factorio-data"),
            {"name": "factorio-data", "persistentVolumeClaim": {"claimName": "factorio-data-sw"}},
            "Factorio persistent volume",
        )
        checks.equal(volumes.get("runtime"), {"name": "runtime", "emptyDir": {}}, "Factorio runtime volume")
        checks.equal(volumes.get("tmp"), {"name": "tmp", "emptyDir": {}}, "Factorio tmp volume")
        expected_config_name = configmap.get("metadata", {}).get("name") if configmap else None
        checks.equal(
            volumes.get("factorio-config"),
            {"name": "factorio-config", "configMap": {"name": expected_config_name, "defaultMode": 292}},
            "Factorio generated configuration volume",
        )

    if service:
        service_spec = service.get("spec", {})
        checks.equal(service_spec.get("type", "ClusterIP"), "ClusterIP", "Service/factorio.spec.type")
        checks.equal(service_spec.get("externalIPs"), ["192.168.1.5"], "Factorio LAN external IP")
        checks.equal(service_spec.get("externalTrafficPolicy"), "Local", "Factorio source-IP preservation")
        checks.equal(
            service_spec.get("ports"),
            [{"name": "game", "port": FACTORIO_PORT, "protocol": "UDP", "targetPort": FACTORIO_PORT}],
            "Factorio external endpoint",
        )

    if policy:
        checks.equal(
            policy.get("spec"),
            {
                "podSelector": {"matchLabels": {"app": "factorio"}},
                "policyTypes": ["Ingress"],
                "ingress": [
                    {
                        "from": [{"ipBlock": {"cidr": "192.168.1.0/24"}}],
                        "ports": [{"port": FACTORIO_PORT, "protocol": "UDP"}],
                    }
                ],
            },
            "Factorio LAN-only ingress policy",
        )

    if pvc:
        checks.equal(
            pvc.get("spec"),
            {
                "storageClassName": "seaweedfs",
                "accessModes": ["ReadWriteMany"],
                "resources": {"requests": {"storage": "10Gi"}},
            },
            "Factorio retained SeaweedFS PVC",
        )
    seaweedfs = checks.one(rendered["storage"], "StorageClass", "seaweedfs")
    if seaweedfs:
        checks.equal(seaweedfs.get("reclaimPolicy"), "Retain", "StorageClass/seaweedfs.reclaimPolicy")

    if configmap:
        data = configmap.get("data", {})
        checks.equal(
            set(data),
            {
                "config.ini",
                "map-gen-settings.json",
                "map-settings.json",
                "mod-list.json",
                "server-adminlist.json",
                "server-settings.json",
                "server-whitelist.json",
                "start-factorio.sh",
            },
            "Factorio generated config files",
        )
        map_gen_settings = parse_json(data, "map-gen-settings.json", checks)
        if isinstance(map_gen_settings, dict):
            for name, expected in {
                "width": 0,
                "height": 0,
                "starting_area": 1,
                "peaceful_mode": False,
                "seed": None,
            }.items():
                checks.equal(
                    map_gen_settings.get(name),
                    expected,
                    f"map-gen-settings.json.{name}",
                )
            checks.equal(
                map_gen_settings.get("autoplace_controls"),
                {
                    "coal": {"frequency": 1, "size": 1, "richness": 1},
                    "stone": {"frequency": 1, "size": 1, "richness": 1},
                    "copper-ore": {"frequency": 1, "size": 1, "richness": 1},
                    "iron-ore": {"frequency": 1, "size": 1, "richness": 1},
                    "uranium-ore": {"frequency": 1, "size": 1, "richness": 1},
                    "crude-oil": {"frequency": 1, "size": 1, "richness": 1},
                    "water": {"frequency": 1, "size": 1},
                    "trees": {"frequency": 1, "size": 1},
                    "enemy-base": {"frequency": 1, "size": 1},
                },
                "map-gen-settings.json.autoplace_controls",
            )
            cliff_settings = map_gen_settings.get("cliff_settings", {})
            for name, expected in {
                "name": "cliff",
                "cliff_elevation_0": 10,
                "cliff_elevation_interval": 40,
                "richness": 1,
            }.items():
                checks.equal(
                    cliff_settings.get(name) if isinstance(cliff_settings, dict) else None,
                    expected,
                    f"map-gen-settings.json.cliff_settings.{name}",
                )
        map_settings = parse_json(data, "map-settings.json", checks)
        if isinstance(map_settings, dict):
            expected_map_settings = {
                "difficulty_settings": {
                    "technology_price_multiplier": 1,
                    "spoil_time_modifier": 1,
                },
                "pollution": {
                    "enabled": True,
                    "diffusion_ratio": 0.02,
                    "min_to_diffuse": 15,
                    "ageing": 1,
                    "expected_max_per_chunk": 150,
                    "min_to_show_per_chunk": 50,
                    "min_pollution_to_damage_trees": 60,
                    "pollution_with_max_forest_damage": 150,
                    "pollution_per_tree_damage": 50,
                    "pollution_restored_per_tree_damage": 10,
                    "max_pollution_to_restore_trees": 20,
                    "enemy_attack_pollution_consumption_modifier": 1,
                },
                "enemy_evolution": {
                    "enabled": True,
                    "time_factor": 0.000004,
                    "destroy_factor": 0.002,
                    "pollution_factor": 0.0000009,
                },
                "enemy_expansion": {
                    "enabled": True,
                    "max_expansion_distance": 7,
                    "friendly_base_influence_radius": 2,
                    "enemy_building_influence_radius": 2,
                    "building_coefficient": 0.1,
                    "other_base_coefficient": 2.0,
                    "neighbouring_chunk_coefficient": 0.5,
                    "neighbouring_base_chunk_coefficient": 0.4,
                    "max_colliding_tiles_coefficient": 0.9,
                    "settler_group_min_size": 5,
                    "settler_group_max_size": 20,
                    "min_expansion_cooldown": 14400,
                    "max_expansion_cooldown": 216000,
                },
            }
            for section, expected_values in expected_map_settings.items():
                actual_values = map_settings.get(section, {})
                for name, expected in expected_values.items():
                    checks.equal(
                        actual_values.get(name) if isinstance(actual_values, dict) else None,
                        expected,
                        f"map-settings.json.{section}.{name}",
                    )
            checks.equal(
                map_settings.get("max_failed_behavior_count"),
                3,
                "map-settings.json.max_failed_behavior_count",
            )
        settings = parse_json(data, "server-settings.json", checks)
        if isinstance(settings, dict):
            expected_settings = {
                "name": "Martins Server",
                "description": "Default Freeplay",
                "max_players": 4,
                "visibility": {"public": False, "lan": True},
                "username": "",
                "password": "",
                "token": "",
                "game_password": "",
                "require_user_verification": True,
                "allow_commands": "admins-only",
                "autosave_interval": 10,
                "autosave_slots": 12,
                "auto_pause": True,
                "auto_pause_when_players_connect": False,
                "only_admins_can_pause_the_game": True,
                "autosave_only_on_server": True,
                "non_blocking_saving": False,
            }
            for name, expected in expected_settings.items():
                checks.equal(settings.get(name), expected, f"server-settings.json.{name}")
        checks.equal(parse_json(data, "server-whitelist.json", checks), ["neBM"], "Factorio whitelist")
        checks.equal(parse_json(data, "server-adminlist.json", checks), ["neBM"], "Factorio admin list")
        mod_list = parse_json(data, "mod-list.json", checks)
        expected_mods = {
            "base": True,
            "elevated-rails": False,
            "quality": False,
            "space-age": False,
        }
        if isinstance(mod_list, dict):
            actual_mods = {
                item.get("name"): item.get("enabled")
                for item in mod_list.get("mods", [])
                if isinstance(item, dict)
            }
            checks.equal(actual_mods, expected_mods, "Factorio vanilla mod list")
        parser = configparser.ConfigParser()
        try:
            parser.read_string(data.get("config.ini", ""))
            checks.equal(parser.get("path", "read-data"), "/opt/factorio/data", "config.ini read-data")
            checks.equal(parser.get("path", "write-data"), "/factorio", "config.ini write-data")
            checks.equal(parser.getint("other", "autosave-interval"), 10, "config.ini autosave interval")
            checks.equal(parser.getint("other", "autosave-slots"), 12, "config.ini autosave slots")
            checks.equal(parser.getboolean("other", "check-updates"), False, "config.ini update checks")
            checks.equal(parser.getboolean("other", "enable-experimental-updates"), False, "config.ini experimental updates")
            checks.equal(parser.getboolean("other", "enable-new-mods"), False, "config.ini new mods")
        except (configparser.Error, KeyError, ValueError) as exc:
            checks.errors.append(f"ConfigMap factorio-config/config.ini: {exc}")
        wrapper = data.get("start-factorio.sh", "")
        checks.true("set -euo pipefail" in wrapper and "set -x" not in wrapper, "Factorio wrapper must fail closed without shell tracing")
        checks.true("rcon" not in wrapper.lower(), "Factorio wrapper must never configure RCON")
        for required in (
            "/opt/factorio/bin/x64/factorio",
            "--create",
            "--config",
            "--map-gen-settings",
            "--map-settings",
            "--server-settings",
            "--server-whitelist",
            "--use-server-whitelist",
            "--server-adminlist",
            "--server-id",
            "--mod-directory",
            "--start-server-load-latest",
            ".last-started-version",
            "pre-upgrade",
        ):
            checks.true(required in wrapper, f"Factorio wrapper missing required contract: {required}")

    restic_job = checks.one(rendered["restic"], "CronJob", "restic-critical-pvc-backup")
    restic_config = checks.one(rendered["restic"], "ConfigMap", "restic-backup-scripts")
    if restic_job:
        pod = restic_job.get("spec", {}).get("jobTemplate", {}).get("spec", {}).get("template", {}).get("spec", {})
        containers = pod.get("containers", [])
        restic = next((item for item in containers if item.get("name") == "restic"), {})
        mounts = {item.get("name"): item for item in restic.get("volumeMounts", [])}
        volumes = {item.get("name"): item for item in pod.get("volumes", [])}
        checks.equal(
            mounts.get("factorio-data-sw"),
            {"name": "factorio-data-sw", "mountPath": "/data/factorio-data-sw", "readOnly": True},
            "Restic Factorio mount",
        )
        checks.equal(
            volumes.get("factorio-data-sw"),
            {
                "name": "factorio-data-sw",
                "persistentVolumeClaim": {"claimName": "factorio-data-sw", "readOnly": True},
            },
            "Restic Factorio PVC",
        )
    if restic_config:
        restic_data = restic_config.get("data", {})
        configured_paths = {
            line.strip()
            for line in restic_data.get("critical-pvc-paths.txt", "").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        }
        checks.true(
            "/data/factorio-data-sw" in configured_paths,
            "Restic critical paths must include /data/factorio-data-sw",
        )
        try:
            backup_policy = yaml.safe_load(restic_data.get("backup-policy.yaml", ""))
            includes = backup_policy.get("jobs", [])[0].get("includes", [])
        except (AttributeError, IndexError, yaml.YAMLError) as exc:
            checks.errors.append(f"Restic backup policy is invalid: {exc}")
        else:
            factorio_includes = [item for item in includes if item.get("pvc") == "factorio-data-sw"]
            checks.equal(
                factorio_includes,
                [
                    {
                        "pvc": "factorio-data-sw",
                        "path": "/data/factorio-data-sw",
                        "reason": "Factorio saves and server identity",
                    }
                ],
                "Restic Factorio backup policy",
            )

    firewall_path = root / "scripts/hestia-firewalld-setup.sh"
    try:
        firewall = firewall_path.read_text()
    except OSError as exc:
        checks.errors.append(f"{firewall_path}: {exc}")
    else:
        checks.true(
            "--permanent --zone=FedoraServer --add-port=34197/udp" in firewall,
            "Hestia firewalld setup must durably open 34197/udp in FedoraServer",
        )
        checks.true("34197/tcp" not in firewall, "Hestia firewalld setup must not open Factorio TCP/RCON")

    validate_renovate(root, checks)
    return checks.errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate the Factorio GitOps policy contract")
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    args = parser.parse_args()
    errors = validate_factorio(args.repo_root.resolve())
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("Factorio manifest validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
