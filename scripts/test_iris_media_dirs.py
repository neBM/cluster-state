#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML==6.0.3"]
# ///

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parent.parent
EXPECTED_MEDIA_DIRS = (
    "Movies:/media/downloads/media/Movies,TV:/media/downloads/media/TV"
)


def render_apps() -> list[dict[str, Any]]:
    if executable := shutil.which("kustomize"):
        command = [executable, "build", "apps"]
    else:
        command = ["kubectl", "kustomize", "apps"]
    result = subprocess.run(
        command,
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        raise AssertionError(
            f"{' '.join(command)} failed with exit {result.returncode}:\n"
            f"{result.stderr.strip()}"
        )
    resources = [item for item in yaml.safe_load_all(result.stdout) if item]
    if not all(isinstance(item, dict) for item in resources):
        raise AssertionError("apps render contains a non-object YAML document")
    return resources


def one(
    resources: list[dict[str, Any]],
    kind: str,
    name: str,
    namespace: str | None,
) -> dict[str, Any]:
    matches = [
        item
        for item in resources
        if item.get("kind") == kind
        and item.get("metadata", {}).get("name") == name
        and item.get("metadata", {}).get("namespace") == namespace
    ]
    if len(matches) != 1:
        raise AssertionError(
            f"expected exactly one rendered {kind}/{name} in {namespace!r}, "
            f"got {len(matches)}"
        )
    return matches[0]


def named(items: Any, label: str) -> dict[str, dict[str, Any]]:
    if not isinstance(items, list) or not all(isinstance(item, dict) for item in items):
        raise AssertionError(f"{label} must be a list of objects")
    indexed = {
        item.get("name"): item for item in items if isinstance(item.get("name"), str)
    }
    if len(indexed) != len(items):
        raise AssertionError(f"{label} must have unique string names")
    return indexed


def strict_equal(actual: Any, expected: Any, label: str) -> None:
    remaining_nodes = 10_000
    none_type = type(None)

    def is_yaml_safe_type(value_type: type[Any]) -> bool:
        return (
            value_type is dict
            or value_type is list
            or value_type is str
            or value_type is bool
            or value_type is int
            or value_type is float
            or value_type is none_type
        )

    def compare(actual_item: Any, expected_item: Any, path: str, depth: int) -> None:
        nonlocal remaining_nodes
        remaining_nodes -= 1
        if remaining_nodes < 0 or depth > 100:
            raise AssertionError(f"{path}: comparison exceeded the safety bound")

        actual_type = type(actual_item)
        expected_type = type(expected_item)
        if not is_yaml_safe_type(actual_type) or not is_yaml_safe_type(expected_type):
            raise AssertionError(f"{path}: unsupported YAML value")

        if actual_type is not expected_type:
            raise AssertionError(
                f"{path}: expected {expected_type.__name__}, got {actual_type.__name__}"
            )

        if expected_type is dict:
            for key in actual_item:
                if type(key) is not str:
                    raise AssertionError(f"{path}: unsupported YAML object key")
            for key in expected_item:
                if type(key) is not str:
                    raise AssertionError(f"{path}: unsupported YAML object key")
            if len(actual_item) != len(expected_item):
                raise AssertionError(
                    f"{path}: expected keys {list(expected_item)!r}, "
                    f"got {list(actual_item)!r}"
                )
            for key, expected_value in expected_item.items():
                if key not in actual_item:
                    raise AssertionError(
                        f"{path}: expected key {key!r}, got keys {list(actual_item)!r}"
                    )
                compare(
                    actual_item[key],
                    expected_value,
                    f"{path}[{key!r}]",
                    depth + 1,
                )
            return

        if expected_type is list:
            if len(actual_item) != len(expected_item):
                raise AssertionError(
                    f"{path}: expected sequence length {len(expected_item)}, "
                    f"got {len(actual_item)}"
                )
            for index, (actual_value, expected_value) in enumerate(
                zip(actual_item, expected_item, strict=True)
            ):
                compare(
                    actual_value,
                    expected_value,
                    f"{path}[{index}]",
                    depth + 1,
                )
            return

        if actual_item != expected_item:
            raise AssertionError(
                f"{path}: expected {expected_item!r}, got {actual_item!r}"
            )

    compare(actual, expected, label, 0)


def verify_strict_equal_alias_rejection() -> None:
    alias_cases = [
        (
            {"nested": [{"readOnly": 1}]},
            {"nested": [{"readOnly": True}]},
            "['nested'][0]['readOnly']",
        ),
        (
            {"nested": [{"count": 1.0}]},
            {"nested": [{"count": 1}]},
            "['nested'][0]['count']",
        ),
    ]
    for actual, expected, expected_path in alias_cases:
        try:
            strict_equal(actual, expected, "strict_equal self-check")
        except AssertionError as error:
            if expected_path not in str(error):
                raise AssertionError(
                    f"strict_equal self-check did not report {expected_path}"
                ) from error
        else:
            raise AssertionError(
                "strict_equal self-check accepted a nested scalar type alias"
            )

    class Hostile:
        callbacks = {"hash": 0, "eq": 0, "repr": 0}

        @classmethod
        def reset(cls) -> None:
            cls.callbacks = {"hash": 0, "eq": 0, "repr": 0}

        def __hash__(self) -> int:
            type(self).callbacks["hash"] += 1
            return 1

        def __eq__(self, other: object) -> bool:
            type(self).callbacks["eq"] += 1
            raise RuntimeError("hostile equality executed")

        def __repr__(self) -> str:
            type(self).callbacks["repr"] += 1
            raise RuntimeError("hostile repr executed")

    hostile_cases = [
        (Hostile(), Hostile(), "hostile scalar"),
        ({Hostile(): "actual"}, {Hostile(): "expected"}, "hostile object key"),
    ]
    for actual, expected, case_label in hostile_cases:
        Hostile.reset()
        try:
            strict_equal(actual, expected, f"strict_equal self-check {case_label}")
        except AssertionError as error:
            if "unsupported YAML" not in str(error):
                raise AssertionError(
                    f"strict_equal self-check did not reject {case_label} safely"
                ) from error
        else:
            raise AssertionError(f"strict_equal self-check accepted {case_label}")
        if any(Hostile.callbacks.values()):
            raise AssertionError(
                f"strict_equal self-check invoked {case_label} callbacks: "
                f"{Hostile.callbacks}"
            )


def main() -> int:
    verify_strict_equal_alias_rejection()
    resources = render_apps()
    deployment = one(resources, "Deployment", "iris", "default")
    pod = deployment.get("spec", {}).get("template", {}).get("spec", {})
    containers = named(pod.get("containers"), "Deployment/iris containers")
    container = containers.get("iris", {})

    env = named(container.get("env"), "Deployment/iris container env")
    strict_equal(
        env.get("MEDIA_DIRS", {}).get("value"),
        EXPECTED_MEDIA_DIRS,
        "Deployment/iris MEDIA_DIRS",
    )

    mounts = named(
        container.get("volumeMounts"),
        "Deployment/iris container volumeMounts",
    )
    strict_equal(
        mounts.get("media"),
        {
            "mountPath": "/media",
            "mountPropagation": "None",
            "name": "media",
            "readOnly": True,
        },
        "Deployment/iris parent MartiniBar media mount",
    )
    strict_equal(
        mounts.get("media-tv"),
        {
            "mountPath": "/media/downloads/media/TV",
            "mountPropagation": "None",
            "name": "media-tv",
            "readOnly": True,
        },
        "Deployment/iris nested Windsor TV mount",
    )

    volumes = named(pod.get("volumes"), "Deployment/iris volumes")
    strict_equal(
        volumes.get("media"),
        {
            "name": "media",
            "persistentVolumeClaim": {
                "claimName": "iris-synology-media",
                "readOnly": True,
            },
        },
        "Deployment/iris parent MartiniBar media PVC",
    )
    strict_equal(
        volumes.get("media-tv"),
        {
            "name": "media-tv",
            "persistentVolumeClaim": {
                "claimName": "media-windsor-tv",
                "readOnly": True,
            },
        },
        "Deployment/iris nested Windsor TV PVC",
    )

    parent_pvc = one(
        resources,
        "PersistentVolumeClaim",
        "iris-synology-media",
        "default",
    )
    strict_equal(
        parent_pvc.get("spec", {}).get("accessModes"),
        ["ReadOnlyMany"],
        "PersistentVolumeClaim/iris-synology-media accessModes",
    )
    strict_equal(
        parent_pvc.get("spec", {}).get("storageClassName"),
        "synology-nfs-static",
        "PersistentVolumeClaim/iris-synology-media storageClassName",
    )
    strict_equal(
        parent_pvc.get("spec", {}).get("volumeMode"),
        "Filesystem",
        "PersistentVolumeClaim/iris-synology-media volumeMode",
    )
    strict_equal(
        parent_pvc.get("spec", {}).get("volumeName"),
        None,
        "PersistentVolumeClaim/iris-synology-media volumeName",
    )

    parent_pv = one(resources, "PersistentVolume", "iris-synology-media", None)
    strict_equal(
        parent_pv.get("spec", {}).get("accessModes"),
        ["ReadOnlyMany"],
        "PersistentVolume/iris-synology-media accessModes",
    )
    strict_equal(
        parent_pv.get("spec", {}).get("storageClassName"),
        "synology-nfs-static",
        "PersistentVolume/iris-synology-media storageClassName",
    )
    strict_equal(
        parent_pv.get("spec", {}).get("volumeMode"),
        "Filesystem",
        "PersistentVolume/iris-synology-media volumeMode",
    )
    strict_equal(
        parent_pv.get("spec", {}).get("mountOptions"),
        ["soft", "ro", "timeo=150", "retrans=3"],
        "PersistentVolume/iris-synology-media mountOptions",
    )
    strict_equal(
        parent_pv.get("spec", {}).get("nfs"),
        {
            "path": "/volume1/docker",
            "readOnly": True,
            "server": "192.168.1.10",
        },
        "PersistentVolume/iris-synology-media MartiniBar source",
    )

    tv_pvc = one(
        resources,
        "PersistentVolumeClaim",
        "media-windsor-tv",
        "default",
    )
    strict_equal(
        tv_pvc.get("spec", {}).get("accessModes"),
        ["ReadOnlyMany"],
        "PersistentVolumeClaim/media-windsor-tv accessModes",
    )
    strict_equal(
        tv_pvc.get("spec", {}).get("storageClassName"),
        "synology-nfs-static",
        "PersistentVolumeClaim/media-windsor-tv storageClassName",
    )
    strict_equal(
        tv_pvc.get("spec", {}).get("volumeMode"),
        "Filesystem",
        "PersistentVolumeClaim/media-windsor-tv volumeMode",
    )
    strict_equal(
        tv_pvc.get("spec", {}).get("volumeName"),
        "media-windsor-tv",
        "PersistentVolumeClaim/media-windsor-tv volumeName",
    )

    tv_pv = one(resources, "PersistentVolume", "media-windsor-tv", None)
    strict_equal(
        tv_pv.get("spec", {}).get("accessModes"),
        ["ReadOnlyMany"],
        "PersistentVolume/media-windsor-tv accessModes",
    )
    strict_equal(
        tv_pv.get("spec", {}).get("storageClassName"),
        "synology-nfs-static",
        "PersistentVolume/media-windsor-tv storageClassName",
    )
    strict_equal(
        tv_pv.get("spec", {}).get("volumeMode"),
        "Filesystem",
        "PersistentVolume/media-windsor-tv volumeMode",
    )
    strict_equal(
        tv_pv.get("spec", {}).get("mountOptions"),
        ["nfsvers=3", "hard", "ro", "timeo=600"],
        "PersistentVolume/media-windsor-tv mountOptions",
    )
    strict_equal(
        tv_pv.get("spec", {}).get("nfs"),
        {
            "path": "/volume1/media-tv",
            "readOnly": True,
            "server": "192.168.1.11",
        },
        "PersistentVolume/media-windsor-tv Windsor source",
    )

    print("Iris MEDIA_DIRS and nested read-only Windsor TV mount validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
