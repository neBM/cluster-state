#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML==6.0.3"]
# ///
"""Validate the deployed, dedicated Hermes SSH workspace."""

from __future__ import annotations

import argparse
import copy
import sys
from collections.abc import Callable
from pathlib import Path
from typing import Any, NoReturn

import yaml

from test_validate_hermes_workspace_foundation import (
    EXPECTED_POLICY,
    authoritative_apps,
    load_object,
    render,
)

ROOT = Path(__file__).resolve().parent.parent
WORKSPACE = "hermes-workspace"
NAMESPACE = "default"
APP_LABEL = "app.kubernetes.io/name"
LABELS = {APP_LABEL: WORKSPACE}
IMAGE = (
    "registry.brmartin.co.uk:443/ben/cluster-state/hermes-workspace@sha256:"
    "b5e9837584ac4f7719d02591ee9338ec8ce03e70ee543b34a2c7cbc02121942c"
)
SECRET = "hermes-workspace-ssh-server"
HEALTHCHECK = ["/usr/local/bin/hermes-workspace-healthcheck"]
RESOURCE_FILES = [
    "ciliumnetworkpolicy-default-hermes-workspace.yaml",
    "deployment-default-hermes-workspace.yaml",
    "persistentvolumeclaim-default-hermes-workspace.yaml",
    "service-default-hermes-workspace.yaml",
]
EXPECTED_KUSTOMIZATION = {
    "apiVersion": "kustomize.config.k8s.io/v1beta1",
    "kind": "Kustomization",
    "resources": RESOURCE_FILES,
}
CONTAINER_SECURITY = {
    "runAsUser": 0,
    "runAsGroup": 0,
    "privileged": False,
    "allowPrivilegeEscalation": False,
    "readOnlyRootFilesystem": True,
    "seccompProfile": {"type": "RuntimeDefault"},
    "capabilities": {
        "drop": ["ALL"],
        "add": ["CHOWN", "DAC_OVERRIDE", "SETGID", "SETUID", "SYS_CHROOT"],
    },
}
INIT_SECURITY = {
    "runAsUser": 0,
    "runAsGroup": 0,
    "privileged": False,
    "allowPrivilegeEscalation": False,
    "readOnlyRootFilesystem": True,
    "seccompProfile": {"type": "RuntimeDefault"},
    "capabilities": {"drop": ["ALL"], "add": ["CHOWN"]},
}

def probe(period: int, failures: int) -> dict[str, Any]:
    return {"exec": {"command": HEALTHCHECK}, "periodSeconds": period,
            "timeoutSeconds": 1, "failureThreshold": failures}


EXPECTED_DEPLOYMENT = {
    "apiVersion": "apps/v1",
    "kind": "Deployment",
    "metadata": {"name": WORKSPACE, "namespace": NAMESPACE, "labels": LABELS},
    "spec": {
        "replicas": 1,
        "revisionHistoryLimit": 2,
        "progressDeadlineSeconds": 600,
        "strategy": {"type": "Recreate"},
        "selector": {"matchLabels": LABELS},
        "template": {
            "metadata": {"labels": LABELS},
            "spec": {
                "automountServiceAccountToken": False,
                "enableServiceLinks": False,
                "hostNetwork": False,
                "hostPID": False,
                "hostIPC": False,
                "shareProcessNamespace": False,
                "dnsPolicy": "ClusterFirst",
                "dnsConfig": {"options": [{"name": "ndots", "value": "1"}]},
                "restartPolicy": "Always",
                "terminationGracePeriodSeconds": 30,
                "nodeSelector": {"kubernetes.io/arch": "amd64",
                                 "kubernetes.io/hostname": "hestia"},
                "initContainers": [
                    {
                        "name": "prepare-workspace",
                        "image": IMAGE,
                        "imagePullPolicy": "IfNotPresent",
                        "command": [
                            "/bin/sh",
                            "-ceu",
                            "chown 0:0 /workspace /run /tmp\n"
                            "chmod 0700 /workspace\n"
                            "chmod 0755 /run\n"
                            "chmod 1777 /tmp\n"
                            "chown 10000:10000 /workspace",
                        ],
                        "resources": {
                            "requests": {"cpu": "10m", "memory": "16Mi",
                                         "ephemeral-storage": "16Mi"},
                            "limits": {"cpu": "100m", "memory": "64Mi",
                                       "ephemeral-storage": "64Mi"},
                        },
                        "securityContext": INIT_SECURITY,
                        "volumeMounts": [
                            {"name": "workspace", "mountPath": "/workspace"},
                            {"name": "run", "mountPath": "/run"},
                            {"name": "tmp", "mountPath": "/tmp"},
                        ],
                    }
                ],
                "containers": [
                    {
                        "name": WORKSPACE,
                        "image": IMAGE,
                        "imagePullPolicy": "IfNotPresent",
                        "ports": [
                            {"name": "ssh", "containerPort": 2222, "protocol": "TCP"}
                        ],
                        "startupProbe": probe(2, 60),
                        "readinessProbe": probe(5, 3),
                        "livenessProbe": probe(10, 3),
                        "resources": {
                            "requests": {"cpu": "250m", "memory": "512Mi",
                                         "ephemeral-storage": "512Mi"},
                            "limits": {"cpu": "2", "memory": "4Gi",
                                       "ephemeral-storage": "4Gi"},
                        },
                        "securityContext": CONTAINER_SECURITY,
                        "volumeMounts": [
                            {"name": "workspace", "mountPath": "/workspace"},
                            {"name": "run", "mountPath": "/run"},
                            {"name": "tmp", "mountPath": "/tmp"},
                            {
                                "name": "ssh-server",
                                "mountPath": "/run/secrets/hermes-workspace",
                                "readOnly": True,
                            },
                        ],
                    }
                ],
                "volumes": [
                    {
                        "name": "workspace",
                        "persistentVolumeClaim": {"claimName": WORKSPACE},
                    },
                    {"name": "run", "emptyDir": {"medium": "Memory", "sizeLimit": "64Mi"}},
                    {"name": "tmp", "emptyDir": {"sizeLimit": "2Gi"}},
                    {
                        "name": "ssh-server",
                        "secret": {
                            "secretName": SECRET,
                            "defaultMode": 0o400,
                            "items": [
                                {
                                    "key": "ssh_host_ed25519_key",
                                    "path": "ssh_host_ed25519_key",
                                },
                                {"key": "authorized_keys", "path": "authorized_keys"},
                            ],
                        },
                    },
                ],
            },
        },
    },
}
EXPECTED_PVC = {
    "apiVersion": "v1",
    "kind": "PersistentVolumeClaim",
    "metadata": {
        "name": WORKSPACE,
        "namespace": NAMESPACE,
        "annotations": {"kustomize.toolkit.fluxcd.io/prune": "disabled"},
        "labels": LABELS,
    },
    "spec": {
        "accessModes": ["ReadWriteOnce"],
        "resources": {"requests": {"storage": "20Gi"}},
        "storageClassName": "local-path-retain",
        "volumeMode": "Filesystem",
    },
}
EXPECTED_SERVICE = {
    "apiVersion": "v1",
    "kind": "Service",
    "metadata": {"name": WORKSPACE, "namespace": NAMESPACE, "labels": LABELS},
    "spec": {
        "type": "ClusterIP",
        "selector": LABELS,
        "ports": [{"name": "ssh", "port": 2222, "protocol": "TCP", "targetPort": "ssh"}],
    },
}
EXPECTED_OBJECTS = [EXPECTED_POLICY, EXPECTED_DEPLOYMENT, EXPECTED_PVC, EXPECTED_SERVICE]

def fail(message: str) -> NoReturn:
    raise AssertionError(message)

def strict_equal(actual: Any, expected: Any) -> bool:
    if type(actual) is not type(expected):
        return False
    if isinstance(expected, dict):
        return actual.keys() == expected.keys() and all(
            strict_equal(actual[key], value) for key, value in expected.items()
        )
    if isinstance(expected, list):
        return len(actual) == len(expected) and all(
            strict_equal(left, right) for left, right in zip(actual, expected, strict=True)
        )
    return actual == expected

def resource_id(item: dict[str, Any]) -> tuple[str, str, str]:
    metadata = item.get("metadata") or {}
    return item.get("kind", ""), metadata.get("namespace", ""), metadata.get("name", "")

def validate_object_set(objects: list[dict[str, Any]], label: str) -> None:
    indexed: dict[tuple[str, str, str], dict[str, Any]] = {}
    for item in objects:
        identifier = resource_id(item)
        if identifier in indexed:
            fail(f"{label}: duplicate resource {identifier!r}")
        indexed[identifier] = item
    expected = {resource_id(item): item for item in EXPECTED_OBJECTS}
    if indexed.keys() != expected.keys():
        fail(f"{label}: expected identities {sorted(expected)!r}, got {sorted(indexed)!r}")
    for identifier, wanted in expected.items():
        if not strict_equal(indexed[identifier], wanted):
            fail(f"{label}: {identifier!r} semantics differ from the exact contract")

def governed(item: dict[str, Any]) -> bool:
    metadata = item.get("metadata") or {}
    if metadata.get("namespace") != NAMESPACE:
        return False
    if metadata.get("name") in {WORKSPACE, SECRET}:
        return True
    if (metadata.get("labels") or {}).get(APP_LABEL) == WORKSPACE:
        return True
    spec = item.get("spec") or {}
    return (spec.get("selector") or {}).get(APP_LABEL) == WORKSPACE

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
    expected_names = {"kustomization.yaml", *RESOURCE_FILES}
    if source_names != expected_names:
        fail(f"deployment source set: expected {sorted(expected_names)!r}, got {sorted(source_names)!r}")
    if not strict_equal(load_object(workspace / "kustomization.yaml"), EXPECTED_KUSTOMIZATION):
        fail("Hermes workspace Kustomization differs from the deployed contract")

    source_objects = [load_object(workspace / name) for name in RESOURCE_FILES]
    validate_object_set(source_objects, "deployment source")
    validate_object_set(render(workspace), "workspace render")
    validate_object_set([item for item in render(apps) if governed(item)], "authoritative apps render")

    source_text = "\n".join((workspace / name).read_text() for name in RESOURCE_FILES)
    rejected_prefix = "e8b12" + "e8f"
    if rejected_prefix in source_text:
        fail("rejected prior image digest is present")

def object_of(objects: list[dict[str, Any]], kind: str) -> dict[str, Any]:
    return next(item for item in objects if item.get("kind") == kind)

def rejected(label: str, mutate: Callable[[list[dict[str, Any]]], None]) -> None:
    objects = copy.deepcopy(EXPECTED_OBJECTS)
    mutate(objects)
    try:
        validate_object_set(objects, label)
    except AssertionError:
        print(f"PASS: {label} rejected")
        return
    fail(f"{label}: mutation escaped validation")

def run_mutations() -> None:
    deploy = lambda docs: object_of(docs, "Deployment")["spec"]["template"]["spec"]
    main = lambda docs: deploy(docs)["containers"][0]
    init = lambda docs: deploy(docs)["initContainers"][0]
    service = lambda docs: object_of(docs, "Service")["spec"]
    pvc = lambda docs: object_of(docs, "PersistentVolumeClaim")
    cases: list[tuple[str, Callable[[list[dict[str, Any]]], None]]] = [
        ("mutable image", lambda docs: main(docs).update(image=IMAGE.split("@", 1)[0] + ":latest")),
        ("rejected image", lambda docs: main(docs).update(image=IMAGE.split("@", 1)[0] + "@sha256:" + ("e8b12" + "e8f").ljust(64, "0"))),
        ("wrong Secret source", lambda docs: deploy(docs)["volumes"][3]["secret"].update(secretName="wrong")),
        ("Secret manifest/data", lambda docs: docs.append({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": SECRET, "namespace": NAMESPACE}, "data": {}})),
        ("service-account token", lambda docs: deploy(docs).update(automountServiceAccountToken=True)),
        ("hostPath", lambda docs: deploy(docs)["volumes"][1].update(emptyDir=None, hostPath={"path": "/run"})),
        ("host network", lambda docs: deploy(docs).update(hostNetwork=True)),
        ("privileged container", lambda docs: main(docs)["securityContext"].update(privileged=True)),
        ("wrong main UID", lambda docs: main(docs)["securityContext"].update(runAsUser=10000)),
        ("extra init capability", lambda docs: init(docs)["securityContext"]["capabilities"]["add"].append("FOWNER")),
        ("network capability", lambda docs: main(docs)["securityContext"]["capabilities"]["add"].append("NET_RAW")),
        ("writable root", lambda docs: main(docs)["securityContext"].update(readOnlyRootFilesystem=False)),
        ("missing resource limits", lambda docs: main(docs)["resources"].pop("limits")),
        ("missing startup probe", lambda docs: main(docs).pop("startupProbe")),
        ("NodePort exposure", lambda docs: service(docs).update(type="NodePort")),
        ("wrong Service selector", lambda docs: service(docs).update(selector={APP_LABEL: "other"})),
        ("wrong Service port", lambda docs: service(docs)["ports"][0].update(port=22)),
        ("wrong PVC class", lambda docs: pvc(docs)["spec"].update(storageClassName="local-path")),
        ("wrong PVC access", lambda docs: pvc(docs)["spec"].update(accessModes=["ReadWriteMany"])),
        ("prunable PVC", lambda docs: pvc(docs)["metadata"].pop("annotations")),
        ("extra workload", lambda docs: docs.append({"apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"name": "workspace-helper", "namespace": NAMESPACE, "labels": LABELS}, "spec": {}})),
        ("extra container", lambda docs: deploy(docs)["containers"].append(copy.deepcopy(main(docs)))),
        ("extra mount", lambda docs: main(docs)["volumeMounts"].append({"name": "extra", "mountPath": "/extra"})),
    ]
    for label, mutate in cases:
        rejected(label, mutate)

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, default=ROOT, help=argparse.SUPPRESS)
    args = parser.parse_args()
    validate_repository(args.repo_root.resolve())
    run_mutations()
    print("Hermes workspace deployment validation passed")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, StopIteration, yaml.YAMLError) as error:
        print(f"Hermes workspace deployment validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
