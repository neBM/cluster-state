#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML==6.0.3"]
# ///
"""Validate the policy-only Hermes SSH workspace foundation."""

from __future__ import annotations

import argparse
import copy
import os
import shutil
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path, PurePosixPath
from typing import Any, NoReturn

import yaml
from yaml.constructor import ConstructorError
from yaml.nodes import MappingNode

ROOT = Path(__file__).resolve().parent.parent
FLUX_APPS = Path("clusters/k3s-homelab/flux-system/kustomization-apps.yaml")
WORKSPACE = "hermes-workspace"
PVC = "hermes-workspace-windsor"
POLICY_FILE = "ciliumnetworkpolicy-default-hermes-workspace.yaml"
DEPLOYMENT_FILES = [
    POLICY_FILE,
    "deployment-default-hermes-workspace.yaml",
    "persistentvolumeclaim-default-hermes-workspace-windsor.yaml",
    "service-default-hermes-workspace.yaml",
]
FOUNDATION_SOURCE_NAMES = {"kustomization.yaml", POLICY_FILE}
DEPLOYED_SOURCE_NAMES = {"kustomization.yaml", *DEPLOYMENT_FILES}
APP_LABEL = "app.kubernetes.io/name"
PRIVATE_EXCEPTIONS = [
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16",
    "100.64.0.0/10", "127.0.0.0/8", "224.0.0.0/4", "240.0.0.0/4",
]
EXPECTED_KUSTOMIZATION = {
    "apiVersion": "kustomize.config.k8s.io/v1beta1",
    "kind": "Kustomization",
    "resources": [POLICY_FILE],
}
EXPECTED_DEPLOYED_KUSTOMIZATION = {
    **EXPECTED_KUSTOMIZATION,
    "resources": DEPLOYMENT_FILES,
}
EXPECTED_POLICY = {
    "apiVersion": "cilium.io/v2",
    "kind": "CiliumNetworkPolicy",
    "metadata": {"name": WORKSPACE, "namespace": "default"},
    "spec": {
        "endpointSelector": {"matchLabels": {APP_LABEL: WORKSPACE}},
        "ingress": [
            {
                "fromEndpoints": [
                    {"matchLabels": {APP_LABEL: "hermes-agent"}},
                ],
                "toPorts": [
                    {"ports": [{"port": "2222", "protocol": "TCP"}]},
                ],
            },
        ],
        "egress": [
            {
                "toEndpoints": [
                    {
                        "matchLabels": {
                            "k8s:io.kubernetes.pod.namespace": "kube-system",
                            "k8s:k8s-app": "kube-dns",
                        },
                    },
                ],
                "toPorts": [
                    {
                        "ports": [
                            {"port": "53", "protocol": "UDP"},
                            {"port": "53", "protocol": "TCP"},
                        ],
                        "rules": {"dns": [{"matchPattern": "*"}]},
                    },
                ],
            },
            {
                "toCIDRSet": [
                    {"cidr": "0.0.0.0/0", "except": PRIVATE_EXCEPTIONS},
                ],
                "toPorts": [
                    {
                        "ports": [
                            {"port": "80", "protocol": "TCP"},
                            {"port": "443", "protocol": "TCP"},
                        ],
                    },
                ],
            },
        ],
    },
}


class UniqueKeyLoader(yaml.SafeLoader):
    """Safe YAML loader that also rejects duplicate mapping keys."""


def construct_unique_mapping(
    loader: UniqueKeyLoader, node: MappingNode, deep: bool = False
) -> dict[Any, Any]:
    mapping: dict[Any, Any] = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise ConstructorError(
                "while constructing a mapping",
                node.start_mark,
                f"found duplicate key {key!r}",
                key_node.start_mark,
            )
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, construct_unique_mapping
)


def fail(message: str) -> NoReturn:
    raise AssertionError(message)


def load_documents(text: str, label: str) -> list[dict[str, Any]]:
    documents = list(yaml.load_all(text, Loader=UniqueKeyLoader))
    if any(not isinstance(document, dict) for document in documents):
        fail(f"{label}: every YAML document must be an object")
    return documents


def load_object(path: Path) -> dict[str, Any]:
    documents = load_documents(path.read_text(), str(path))
    if len(documents) != 1:
        fail(f"{path}: expected one YAML object, found {len(documents)}")
    return documents[0]


def render(path: Path) -> list[dict[str, Any]]:
    executable = shutil.which("kustomize")
    command = [executable, "build", str(path)] if executable else ["kubectl", "kustomize", str(path)]
    env = os.environ.copy()
    env["KUBECONFIG"] = "/dev/null"
    result = subprocess.run(command, capture_output=True, text=True, env=env, check=False)
    if result.returncode:
        fail(f"render {path}: {result.stderr.strip()}")
    return load_documents(result.stdout, f"render {path}")


def authoritative_apps(root: Path) -> Path:
    flux = load_object(root / FLUX_APPS)
    identity = (
        flux.get("apiVersion"),
        flux.get("kind"),
        (flux.get("metadata") or {}).get("namespace"),
        (flux.get("metadata") or {}).get("name"),
    )
    expected = (
        "kustomize.toolkit.fluxcd.io/v1",
        "Kustomization",
        "flux-system",
        "apps",
    )
    if identity != expected:
        fail(f"Flux apps Kustomization identity: expected {expected!r}, got {identity!r}")
    spec = flux.get("spec") or {}
    if spec.get("prune") is not True or spec.get("wait") is not True:
        fail("Flux apps Kustomization must keep prune: true and wait: true")
    raw = spec.get("path")
    if not isinstance(raw, str) or not raw.startswith("./"):
        fail("Flux apps spec.path must be a normalized repository-relative path")
    relative = PurePosixPath(raw[2:])
    if not relative.parts or ".." in relative.parts or relative.is_absolute():
        fail("Flux apps spec.path must be a normalized repository-relative path")
    candidate = (root / Path(*relative.parts)).resolve()
    try:
        candidate.relative_to(root.resolve())
    except ValueError:
        fail("Flux apps spec.path escapes the repository")
    if not candidate.is_dir():
        fail(f"Flux apps spec.path is not a directory: {raw}")
    return candidate


def validate_workspace_objects(objects: list[dict[str, Any]], label: str) -> None:
    if len(objects) != 1:
        kinds = [item.get("kind") for item in objects]
        fail(f"{label}: expected only CiliumNetworkPolicy/hermes-workspace, got {kinds!r}")
    if objects[0] != EXPECTED_POLICY:
        fail(f"{label}: CiliumNetworkPolicy/hermes-workspace semantics differ from the exact contract")


def validate_repository(root: Path) -> None:
    apps = authoritative_apps(root)
    apps_kustomization = load_object(apps / "kustomization.yaml")
    resources = apps_kustomization.get("resources")
    if not isinstance(resources, list) or resources.count(WORKSPACE) != 1:
        fail("authoritative apps Kustomization must include hermes-workspace exactly once")

    workspace = apps / WORKSPACE
    source_names = {
        path.name for path in workspace.iterdir() if path.suffix in {".yaml", ".yml"}
    }
    if source_names not in (FOUNDATION_SOURCE_NAMES, DEPLOYED_SOURCE_NAMES):
        fail(
            "Hermes workspace source set must be exactly the foundation or deployed phase: "
            f"got {sorted(source_names)!r}"
        )
    deployed = source_names == DEPLOYED_SOURCE_NAMES
    expected_kustomization = (
        EXPECTED_DEPLOYED_KUSTOMIZATION if deployed else EXPECTED_KUSTOMIZATION
    )
    if load_object(workspace / "kustomization.yaml") != expected_kustomization:
        fail("Hermes workspace Kustomization differs from its exact phase contract")
    validate_workspace_objects([load_object(workspace / POLICY_FILE)], "policy source")

    workspace_objects = render(workspace)
    identities = sorted(
        (
            item.get("kind", ""),
            (item.get("metadata") or {}).get("namespace", ""),
            (item.get("metadata") or {}).get("name", ""),
        )
        for item in workspace_objects
    )
    expected_identities = [("CiliumNetworkPolicy", "default", WORKSPACE)]
    if deployed:
        expected_identities.extend(
            [
                ("Deployment", "default", WORKSPACE),
                ("PersistentVolumeClaim", "default", PVC),
                ("Service", "default", WORKSPACE),
            ]
        )
    if identities != sorted(expected_identities):
        fail(f"workspace render identities differ from the exact phase: {identities!r}")
    validate_workspace_objects(
        [item for item in workspace_objects if item.get("kind") == "CiliumNetworkPolicy"],
        "workspace policy render",
    )

    target = [
        item
        for item in render(apps)
        if item.get("kind") == "CiliumNetworkPolicy"
        and (item.get("metadata") or {}).get("namespace") == "default"
        and (item.get("metadata") or {}).get("name") == WORKSPACE
    ]
    validate_workspace_objects(target, "authoritative apps render")


def rejected(label: str, mutate: Callable[[list[dict[str, Any]]], None]) -> None:
    objects = [copy.deepcopy(EXPECTED_POLICY)]
    mutate(objects)
    try:
        validate_workspace_objects(objects, label)
    except AssertionError:
        print(f"PASS: {label} rejected")
        return
    fail(f"{label}: mutation escaped validation")


def add_forbidden_kind(objects: list[dict[str, Any]], kind: str) -> None:
    resource: dict[str, Any] = {
        "apiVersion": "apps/v1" if kind == "Deployment" else "v1",
        "kind": kind,
        "metadata": {"name": "forbidden", "namespace": "default"},
    }
    if kind == "Deployment":
        labels = {"app": "forbidden"}
        resource["spec"] = {
            "selector": {"matchLabels": labels},
            "template": {
                "metadata": {"labels": labels},
                "spec": {"containers": [{"name": "forbidden", "image": "example.invalid/forbidden:1"}]},
            },
        }
    elif kind == "PersistentVolumeClaim":
        resource["spec"] = {
            "accessModes": ["ReadWriteOnce"],
            "resources": {"requests": {"storage": "1Gi"}},
        }
    else:
        resource.update({"type": "Opaque", "data": {}})
    objects.append(resource)


def run_mutations() -> None:
    cases: list[tuple[str, Callable[[list[dict[str, Any]]], None]]] = [
        ("gateway selector drift", lambda docs: docs[0]["spec"]["endpointSelector"]["matchLabels"].update({APP_LABEL: "hermes-agent"})),
        ("broad ingress", lambda docs: docs[0]["spec"]["ingress"][0]["fromEndpoints"].append({})),
        ("wrong SSH port", lambda docs: docs[0]["spec"]["ingress"][0]["toPorts"][0]["ports"][0].update({"port": "22"})),
        ("missing DNS UDP", lambda docs: docs[0]["spec"]["egress"][0]["toPorts"][0]["ports"].pop(0)),
        ("missing DNS TCP", lambda docs: docs[0]["spec"]["egress"][0]["toPorts"][0]["ports"].pop()),
        ("private CIDR exception removal", lambda docs: docs[0]["spec"]["egress"][1]["toCIDRSet"][0]["except"].remove("10.0.0.0/8")),
        ("extra egress port", lambda docs: docs[0]["spec"]["egress"][1]["toPorts"][0]["ports"].append({"port": "22", "protocol": "TCP"})),
        ("extra egress entity", lambda docs: docs[0]["spec"]["egress"].append({"toEntities": ["world"]})),
    ]
    for kind in ("Deployment", "PersistentVolumeClaim", "Secret"):
        cases.append(
            (f"added {kind}", lambda docs, value=kind: add_forbidden_kind(docs, value))
        )
    for label, mutate in cases:
        rejected(label, mutate)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, default=ROOT, help=argparse.SUPPRESS)
    args = parser.parse_args()
    validate_repository(args.repo_root.resolve())
    run_mutations()
    print("Hermes workspace foundation validation passed")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, yaml.YAMLError) as error:
        print(f"Hermes workspace foundation validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
