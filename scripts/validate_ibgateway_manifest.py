#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "PyYAML==6.0.3",
# ]
# ///

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path, PurePosixPath
from typing import Any

import yaml


DEFAULT_REPO_ROOT = Path(__file__).resolve().parent.parent
APPS_FLUX_KUSTOMIZATION = Path(
    "clusters/k3s-homelab/flux-system/kustomization-apps.yaml"
)
STORAGE_FLUX_KUSTOMIZATION = Path(
    "clusters/k3s-homelab/flux-system/kustomization-storage-classes.yaml"
)
IB_DEPLOYMENT_POLICY_RECORD = Path(
    "autonomous-investing/ib-gateway-paper-deployment-policy.yaml"
)
BROKER_DEPLOYMENT_POLICY_RECORD = Path(
    "autonomous-investing/broker-observer-deployment-policy.yaml"
)
DEPLOYMENT_SOURCE_SET = (
    Path(
        "autonomous-investing/"
        "deployment-autonomous-investing-ib-gateway-paper.yaml"
    ),
    Path(
        "autonomous-investing/"
        "persistentvolumeclaim-autonomous-investing-ib-gateway-settings.yaml"
    ),
    IB_DEPLOYMENT_POLICY_RECORD,
    BROKER_DEPLOYMENT_POLICY_RECORD,
)
NAMESPACE = "autonomous-investing"
APP_LABELS = {"app.kubernetes.io/name": "ib-gateway-paper"}
NAMESPACE_LABELS = {
    "app.kubernetes.io/part-of": NAMESPACE,
    "kubernetes.io/metadata.name": NAMESPACE,
    "pod-security.kubernetes.io/audit": "restricted",
    "pod-security.kubernetes.io/audit-version": "latest",
    "pod-security.kubernetes.io/enforce": "restricted",
    "pod-security.kubernetes.io/enforce-version": "latest",
    "pod-security.kubernetes.io/warn": "restricted",
    "pod-security.kubernetes.io/warn-version": "latest",
}
GATEWAY_IMAGE_PATTERN = re.compile(
    r"^registry\.brmartin\.co\.uk:443/autonomous-investing/system/"
    r"ib-gateway@sha256:[0-9a-f]{64}$"
)
BROKER_IMAGE_PATTERN = re.compile(
    r"^registry\.brmartin\.co\.uk:443/autonomous-investing/system/"
    r"broker-observer@sha256:[0-9a-f]{64}$"
)
ADMITTED_REPOSITORY = (
    "registry.brmartin.co.uk:443/autonomous-investing/system/ib-gateway"
)
ADMITTED_DIGEST = (
    "sha256:fd88e62b91efcd392ee9da607ceaee98569f2278d830a33466b9b729725b59d0"
)
ADMITTED_IMAGE = f"{ADMITTED_REPOSITORY}@{ADMITTED_DIGEST}"
BROKER_ADMITTED_REPOSITORY = (
    "registry.brmartin.co.uk:443/autonomous-investing/system/broker-observer"
)
BROKER_ADMITTED_DIGEST = (
    "sha256:28ffe718b8b200a67904ad16fbf7eef7d03e800490d7a112c73261951304d546"
)
BROKER_ADMITTED_IMAGE = f"{BROKER_ADMITTED_REPOSITORY}@{BROKER_ADMITTED_DIGEST}"
IB_PROVENANCE = {
    "systemProjectId": 35,
    "protectedMainPipelineId": 5591,
    "sourceCommit": "6d37a1a275f50acccfe35e341e0d16d36ab6c701",
}
BROKER_PROVENANCE = {
    "systemProjectId": 35,
    "protectedMainPipelineId": 5597,
    "sourceCommit": "1171a986c6517599ef65f8d8581ab0c964c27d17",
}
EXPECTED_IB_DEPLOYMENT_POLICY = {
    "schemaVersion": 1,
    "artifact": {
        "repository": ADMITTED_REPOSITORY,
        "digest": ADMITTED_DIGEST,
        "reference": ADMITTED_IMAGE,
    },
    "provenance": {**IB_PROVENANCE, "admissionJobId": 20419},
}
EXPECTED_BROKER_DEPLOYMENT_POLICY = {
    "schemaVersion": 1,
    "artifact": {
        "repository": BROKER_ADMITTED_REPOSITORY,
        "digest": BROKER_ADMITTED_DIGEST,
        "reference": BROKER_ADMITTED_IMAGE,
    },
    "provenance": {**BROKER_PROVENANCE, "admissionJobId": 20432},
}
DNS_NAMES = [
    "zdc1.ibllc.com",
    "zdc1-hb1.ibllc.com",
    "zdc1-hb2.ibllc.com",
    "ndc1.ibllc.com",
    "ndc1-hb1.ibllc.com",
    "ndc1-hb2.ibllc.com",
    "cdc1.ibllc.com",
    "cdc1-hb1.ibllc.com",
    "cdc1-hb2.ibllc.com",
]


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

    def absent(self, mapping: dict[str, Any], fields: set[str], path: str) -> None:
        present = sorted(fields.intersection(mapping))
        if present:
            self.errors.append(f"{path}: forbidden fields present: {', '.join(present)}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Render and validate the governed IB Gateway paper workload."
    )
    parser.add_argument(
        "--phase",
        choices=("auto", "foundation", "deployment"),
        default="auto",
        help=(
            "Validation phase. 'auto' selects deployment when any Deployment is "
            "rendered in the governed namespace and foundation otherwise."
        ),
    )
    parser.add_argument(
        "--expected-image",
        help=(
            "Optionally require the exact admitted IB Gateway image reference to "
            "equal both the Deployment and its deployment policy record."
        ),
    )
    parser.add_argument(
        "--expected-broker-observer-image",
        help=(
            "Optionally require the exact admitted Broker Observer image reference "
            "to equal both the Deployment and its deployment policy record."
        ),
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=DEFAULT_REPO_ROOT,
        help=argparse.SUPPRESS,
    )
    return parser.parse_args()


def render_entrypoint(path: Path) -> str:
    if shutil.which("kustomize"):
        command = ["kustomize", "build", str(path)]
    elif shutil.which("kubectl"):
        command = ["kubectl", "kustomize", str(path)]
    else:
        raise RuntimeError("kustomize or kubectl is required to render manifests")

    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(
            f"{' '.join(command)} failed:\n{result.stderr.strip()}"
        )
    return result.stdout


def discover_flux_entrypoint(
    repo_root: Path,
    flux_kustomization: Path,
    expected_name: str,
    *,
    require_wait: bool = False,
) -> Path:
    flux_path = repo_root / flux_kustomization
    flux_resource = yaml.safe_load(flux_path.read_text())
    if not isinstance(flux_resource, dict):
        raise ValueError(f"{flux_path} does not contain a YAML object")

    identity = (
        flux_resource.get("apiVersion"),
        flux_resource.get("kind"),
        flux_resource.get("metadata", {}).get("name"),
        flux_resource.get("metadata", {}).get("namespace"),
    )
    expected_identity = (
        "kustomize.toolkit.fluxcd.io/v1",
        "Kustomization",
        expected_name,
        "flux-system",
    )
    if identity != expected_identity:
        raise ValueError(
            f"{flux_path} has Flux Kustomization identity {identity!r}; "
            f"expected {expected_identity!r}"
        )

    spec = flux_resource.get("spec")
    if not isinstance(spec, dict):
        raise ValueError(f"{flux_path}: spec must be an object")
    if require_wait and spec.get("wait") is not True:
        raise ValueError(f"{flux_path}: spec.wait must be true")

    declared_path = spec.get("path")
    if not isinstance(declared_path, str) or not declared_path.startswith("./"):
        raise ValueError(f"{flux_path}: spec.path must start with './'")

    relative_text = declared_path.removeprefix("./")
    relative_path = PurePosixPath(relative_text)
    if (
        not relative_text
        or "\\" in relative_text
        or relative_path.is_absolute()
        or relative_path.as_posix() != relative_text
        or any(part in {"", ".", ".."} for part in relative_path.parts)
    ):
        raise ValueError(
            f"{flux_path}: spec.path must be a normalized safe repository-relative path"
        )

    entrypoint = (repo_root / Path(*relative_path.parts)).resolve()
    resolved_root = repo_root.resolve()
    if not entrypoint.is_relative_to(resolved_root) or entrypoint == resolved_root:
        raise ValueError(f"{flux_path}: spec.path escapes or names the repository root")
    if not (entrypoint / "kustomization.yaml").is_file():
        raise ValueError(f"{flux_path}: spec.path is not a Kustomize entrypoint")
    return entrypoint


def discover_apps_entrypoint(repo_root: Path) -> Path:
    return discover_flux_entrypoint(
        repo_root,
        APPS_FLUX_KUSTOMIZATION,
        "apps",
        require_wait=True,
    )


def discover_storage_entrypoint(repo_root: Path) -> Path:
    return discover_flux_entrypoint(
        repo_root,
        STORAGE_FLUX_KUSTOMIZATION,
        "storage-classes",
    )


def validate_policy_records_not_rendered(
    apps_entrypoint: Path, checks: Checks
) -> None:
    app_kustomization = (
        apps_entrypoint / "autonomous-investing" / "kustomization.yaml"
    )
    document = yaml.safe_load(app_kustomization.read_text())
    resources = document.get("resources", []) if isinstance(document, dict) else []
    checks.true(
        isinstance(resources, list) and all(isinstance(item, str) for item in resources),
        "autonomous-investing Kustomization resources",
    )
    rendered_names = {
        PurePosixPath(item).name for item in resources if isinstance(item, str)
    }
    for policy_record in (
        IB_DEPLOYMENT_POLICY_RECORD,
        BROKER_DEPLOYMENT_POLICY_RECORD,
    ):
        checks.true(
            policy_record.name not in rendered_names,
            f"deployment policy record must not be rendered: {policy_record.name}",
        )


def classify_deployment_source_set(
    apps_entrypoint: Path, checks: Checks
) -> str:
    present = [
        path for path in DEPLOYMENT_SOURCE_SET if (apps_entrypoint / path).is_file()
    ]
    if len(present) == len(DEPLOYMENT_SOURCE_SET):
        return "deployment"
    if not present:
        return "foundation"

    missing = [path for path in DEPLOYMENT_SOURCE_SET if path not in present]
    details = [
        "partial deployment source set: present "
        f"{[str(path) for path in present]!r}; missing "
        f"{[str(path) for path in missing]!r}"
    ]
    if IB_DEPLOYMENT_POLICY_RECORD in missing:
        details.append(
            "deployment policy record is required: "
            f"{apps_entrypoint / IB_DEPLOYMENT_POLICY_RECORD}"
        )
    if BROKER_DEPLOYMENT_POLICY_RECORD in missing:
        details.append(
            "broker observer deployment policy record is required: "
            f"{apps_entrypoint / BROKER_DEPLOYMENT_POLICY_RECORD}"
        )
    checks.errors.append(details[0])
    checks.errors.extend(details[1:])
    return "partial"


def validate_deployment_policy(
    path: Path,
    checks: Checks,
    expected_policy: dict[str, Any],
    role: str,
) -> str | None:
    record_label = f"{role}deployment policy record"
    if not path.is_file():
        checks.errors.append(f"{record_label} is required: {path}")
        return None

    record = yaml.safe_load(path.read_text())
    checks.equal(record, expected_policy, record_label)
    if not isinstance(record, dict):
        return None

    artifact = record.get("artifact")
    if not isinstance(artifact, dict):
        return None
    repository = artifact.get("repository")
    digest = artifact.get("digest")
    reference = artifact.get("reference")
    derived_reference = (
        f"{repository}@{digest}"
        if isinstance(repository, str) and isinstance(digest, str)
        else None
    )
    checks.equal(
        reference,
        derived_reference,
        f"{role}deployment policy artifact reference",
    )
    return reference if isinstance(reference, str) else None


def load_resources(rendered: str) -> list[dict[str, Any]]:
    resources = [resource for resource in yaml.safe_load_all(rendered) if resource]
    if not all(isinstance(resource, dict) for resource in resources):
        raise ValueError("rendered output contains a non-object YAML document")
    return resources


def resource_id(resource: dict[str, Any]) -> tuple[str, str, str | None]:
    metadata = resource.get("metadata", {})
    return resource.get("kind", ""), metadata.get("name", ""), metadata.get("namespace")


def index_resources(
    resources: list[dict[str, Any]], checks: Checks
) -> dict[tuple[str, str, str | None], dict[str, Any]]:
    indexed: dict[tuple[str, str, str | None], dict[str, Any]] = {}
    for resource in resources:
        identifier = resource_id(resource)
        if identifier in indexed:
            checks.errors.append(f"duplicate rendered resource: {identifier!r}")
        indexed[identifier] = resource
    return indexed


def validate_namespace(namespace: dict[str, Any], checks: Checks) -> None:
    checks.equal(
        set(namespace),
        {"apiVersion", "kind", "metadata"},
        "Namespace fields",
    )
    checks.equal(namespace.get("apiVersion"), "v1", "Namespace apiVersion")
    checks.equal(namespace.get("kind"), "Namespace", "Namespace kind")
    checks.equal(
        namespace.get("metadata"),
        {"labels": NAMESPACE_LABELS, "name": NAMESPACE},
        "Namespace metadata and labels",
    )


def validate_pvc(pvc: dict[str, Any], checks: Checks) -> None:
    checks.equal(
        set(pvc),
        {"apiVersion", "kind", "metadata", "spec"},
        "PVC fields",
    )
    checks.equal(pvc.get("apiVersion"), "v1", "PVC apiVersion")
    checks.equal(pvc.get("kind"), "PersistentVolumeClaim", "PVC kind")
    checks.equal(
        pvc.get("metadata"),
        {"name": "ib-gateway-settings", "namespace": NAMESPACE},
        "PVC metadata",
    )
    checks.equal(
        pvc.get("spec"),
        {
            "accessModes": ["ReadWriteOnce"],
            "resources": {"requests": {"storage": "2Gi"}},
            "storageClassName": "local-path-retain",
        },
        "PVC spec",
    )


def validate_storage_class(storage_class: dict[str, Any], checks: Checks) -> None:
    checks.equal(
        storage_class.get("apiVersion"),
        "storage.k8s.io/v1",
        "local-path-retain apiVersion",
    )
    checks.equal(storage_class.get("kind"), "StorageClass", "local-path-retain kind")
    checks.equal(
        storage_class.get("metadata", {}).get("name"),
        "local-path-retain",
        "StorageClass name",
    )
    checks.equal(
        storage_class.get("provisioner"),
        "rancher.io/local-path",
        "local-path-retain provisioner",
    )
    checks.equal(
        storage_class.get("volumeBindingMode"),
        "WaitForFirstConsumer",
        "local-path-retain volumeBindingMode",
    )
    checks.equal(
        storage_class.get("reclaimPolicy"),
        "Retain",
        "local-path-retain reclaimPolicy",
    )


def validate_deployment(
    deployment: dict[str, Any],
    checks: Checks,
    policy_image: str | None,
    broker_policy_image: str | None,
    expected_image: str | None,
    expected_broker_observer_image: str | None,
) -> None:
    checks.equal(deployment.get("apiVersion"), "apps/v1", "Deployment apiVersion")
    checks.equal(deployment.get("metadata", {}).get("labels"), APP_LABELS, "Deployment labels")

    spec = deployment.get("spec", {})
    checks.equal(
        set(spec),
        {"replicas", "selector", "strategy", "template"},
        "Deployment spec fields",
    )
    checks.equal(spec.get("replicas"), 1, "Deployment replicas")
    checks.equal(spec.get("strategy"), {"type": "Recreate"}, "Deployment strategy")
    checks.equal(spec.get("selector"), {"matchLabels": APP_LABELS}, "Deployment selector")

    template = spec.get("template", {})
    checks.equal(template.get("metadata"), {"labels": APP_LABELS}, "Pod template metadata")
    pod = template.get("spec", {})
    expected_pod_fields = {
        "automountServiceAccountToken",
        "containers",
        "dnsConfig",
        "enableServiceLinks",
        "imagePullSecrets",
        "nodeSelector",
        "securityContext",
        "shareProcessNamespace",
        "terminationGracePeriodSeconds",
        "volumes",
    }
    checks.equal(set(pod), expected_pod_fields, "Pod spec fields")
    checks.absent(
        pod,
        {
            "ephemeralContainers",
            "hostIPC",
            "hostNetwork",
            "hostPID",
            "initContainers",
        },
        "Pod spec",
    )
    checks.equal(
        pod.get("automountServiceAccountToken"),
        False,
        "Pod automountServiceAccountToken",
    )
    checks.equal(
        pod.get("dnsConfig"),
        {"options": [{"name": "ndots", "value": "1"}]},
        "Pod dnsConfig",
    )
    checks.equal(pod.get("enableServiceLinks"), False, "Pod enableServiceLinks")
    checks.equal(pod.get("shareProcessNamespace"), False, "Pod shareProcessNamespace")
    checks.equal(
        pod.get("terminationGracePeriodSeconds"),
        120,
        "Pod terminationGracePeriodSeconds",
    )
    checks.equal(
        pod.get("nodeSelector"),
        {"kubernetes.io/arch": "amd64", "kubernetes.io/hostname": "hestia"},
        "Pod nodeSelector",
    )
    checks.equal(
        pod.get("imagePullSecrets"),
        [{"name": "gitlab-registry"}],
        "Pod imagePullSecrets",
    )
    checks.equal(
        pod.get("securityContext"),
        {
            "fsGroup": 10001,
            "fsGroupChangePolicy": "OnRootMismatch",
            "runAsGroup": 10001,
            "runAsNonRoot": True,
            "runAsUser": 10001,
            "seccompProfile": {"type": "RuntimeDefault"},
        },
        "Pod securityContext",
    )

    containers = pod.get("containers", [])
    checks.equal(len(containers), 2, "Pod container count")
    container_names = [
        container.get("name") if isinstance(container, dict) else None
        for container in containers
    ]
    checks.equal(
        container_names,
        ["ib-gateway-paper", "broker-observer"],
        "Pod container names",
    )
    if len(containers) != 2 or not all(
        isinstance(container, dict) for container in containers
    ):
        return

    gateway, broker_observer = containers
    expected_container_fields = {
        "image",
        "imagePullPolicy",
        "name",
        "resources",
        "securityContext",
        "volumeMounts",
    }
    forbidden_runtime_fields = {
        "args",
        "command",
        "env",
        "envFrom",
        "lifecycle",
        "livenessProbe",
        "ports",
        "readinessProbe",
        "startupProbe",
    }
    for container, role in (
        (gateway, "Gateway"),
        (broker_observer, "Broker Observer"),
    ):
        checks.equal(
            set(container),
            expected_container_fields,
            f"{role} container fields",
        )
        checks.absent(
            container,
            forbidden_runtime_fields,
            f"{role} container",
        )

    checks.equal(gateway.get("name"), "ib-gateway-paper", "Gateway container name")
    image = gateway.get("image", "")
    checks.true(
        isinstance(image, str) and GATEWAY_IMAGE_PATTERN.fullmatch(image) is not None,
        "Gateway image must use the governed repository and exactly one sha256 digest",
    )
    if policy_image is not None:
        checks.equal(image, policy_image, "Gateway deployment policy image")
    if expected_image is not None:
        checks.true(
            GATEWAY_IMAGE_PATTERN.fullmatch(expected_image) is not None,
            "--expected-image must itself be a valid governed sha256 reference",
        )
        checks.equal(image, expected_image, "Gateway admitted image")
        if policy_image is not None:
            checks.equal(
                policy_image,
                expected_image,
                "Deployment policy admitted image",
            )
    checks.equal(gateway.get("imagePullPolicy"), "IfNotPresent", "Gateway imagePullPolicy")
    checks.equal(
        gateway.get("resources"),
        {
            "limits": {"cpu": "1", "memory": "2Gi"},
            "requests": {"cpu": "250m", "memory": "768Mi"},
        },
        "Gateway resources",
    )
    checks.equal(
        gateway.get("securityContext"),
        {
            "allowPrivilegeEscalation": False,
            "capabilities": {"drop": ["ALL"]},
            "readOnlyRootFilesystem": True,
            "runAsGroup": 10001,
            "runAsNonRoot": True,
            "runAsUser": 10001,
            "seccompProfile": {"type": "RuntimeDefault"},
        },
        "Gateway securityContext",
    )

    gateway_mounts = gateway.get("volumeMounts", [])
    gateway_mounts_by_name = {
        mount.get("name"): mount
        for mount in gateway_mounts
        if isinstance(mount, dict)
    }
    checks.equal(
        len(gateway_mounts_by_name),
        len(gateway_mounts),
        "Gateway volumeMount names",
    )
    checks.equal(
        gateway_mounts_by_name,
        {
            "settings": {"mountPath": "/var/lib/ibgateway", "name": "settings"},
            "ibc-runtime": {
                "mountPath": "/run/ibc",
                "mountPropagation": "None",
                "name": "ibc-runtime",
            },
            "tmp": {"mountPath": "/tmp", "name": "tmp"},
            "credentials": {
                "mountPath": "/run/secrets",
                "name": "credentials",
                "readOnly": True,
            },
        },
        "Gateway volumeMounts",
    )

    checks.equal(
        broker_observer.get("name"),
        "broker-observer",
        "Broker Observer container name",
    )
    broker_image = broker_observer.get("image", "")
    checks.true(
        isinstance(broker_image, str)
        and BROKER_IMAGE_PATTERN.fullmatch(broker_image) is not None,
        "Broker Observer image must use the governed repository and exactly one sha256 digest",
    )
    if broker_policy_image is not None:
        checks.equal(
            broker_image,
            broker_policy_image,
            "Broker Observer deployment policy image",
        )
    if expected_broker_observer_image is not None:
        checks.true(
            BROKER_IMAGE_PATTERN.fullmatch(expected_broker_observer_image) is not None,
            "--expected-broker-observer-image must itself be a valid governed sha256 reference",
        )
        checks.equal(
            broker_image,
            expected_broker_observer_image,
            "Broker Observer admitted image",
        )
        if broker_policy_image is not None:
            checks.equal(
                broker_policy_image,
                expected_broker_observer_image,
                "Broker Observer deployment policy admitted image",
            )
    checks.equal(
        broker_observer.get("imagePullPolicy"),
        "IfNotPresent",
        "Broker Observer imagePullPolicy",
    )
    checks.equal(
        broker_observer.get("resources"),
        {
            "limits": {"cpu": "250m", "memory": "256Mi"},
            "requests": {"cpu": "25m", "memory": "64Mi"},
        },
        "Broker Observer resources",
    )
    checks.equal(
        broker_observer.get("securityContext"),
        {
            "allowPrivilegeEscalation": False,
            "capabilities": {"drop": ["ALL"]},
            "readOnlyRootFilesystem": True,
            "runAsGroup": 10001,
            "runAsNonRoot": True,
            "runAsUser": 10001,
            "seccompProfile": {"type": "RuntimeDefault"},
        },
        "Broker Observer securityContext",
    )
    checks.equal(
        broker_observer.get("volumeMounts"),
        [
            {
                "mountPath": "/tmp",
                "mountPropagation": "None",
                "name": "observer-tmp",
            }
        ],
        "Broker Observer volumeMounts",
    )

    volumes = pod.get("volumes", [])
    volumes_by_name = {
        volume.get("name"): volume for volume in volumes if isinstance(volume, dict)
    }
    checks.equal(len(volumes_by_name), len(volumes), "Pod volume names")
    checks.equal(
        volumes,
        [
            {
                "name": "settings",
                "persistentVolumeClaim": {"claimName": "ib-gateway-settings"},
            },
            {
                "emptyDir": {"medium": "Memory", "sizeLimit": "16Mi"},
                "name": "ibc-runtime",
            },
            {
                "emptyDir": {"medium": "Memory", "sizeLimit": "512Mi"},
                "name": "tmp",
            },
            {
                "name": "credentials",
                "secret": {
                    "defaultMode": 0o440,
                    "items": [
                        {"key": "TWS_USERID", "path": "TWS_USERID"},
                        {"key": "TWS_PASSWORD", "path": "TWS_PASSWORD"},
                    ],
                    "secretName": "ibkr-paper-gateway-credentials",
                },
            },
            {
                "emptyDir": {"medium": "Memory", "sizeLimit": "16Mi"},
                "name": "observer-tmp",
            },
        ],
        "Pod volumes",
    )

    all_container_specs = containers + pod.get("initContainers", []) + pod.get(
        "ephemeralContainers", []
    )
    runtime_mounts = [
        (container_spec.get("name"), mount)
        for container_spec in all_container_specs
        if isinstance(container_spec, dict)
        for mount in container_spec.get("volumeMounts", [])
        if isinstance(mount, dict) and mount.get("name") == "ibc-runtime"
    ]
    checks.equal(
        runtime_mounts,
        [
            (
                "ib-gateway-paper",
                {
                    "mountPath": "/run/ibc",
                    "mountPropagation": "None",
                    "name": "ibc-runtime",
                },
            )
        ],
        "exclusive ibc-runtime mount",
    )
    observer_tmp_mounts = [
        (container_spec.get("name"), mount)
        for container_spec in all_container_specs
        if isinstance(container_spec, dict)
        for mount in container_spec.get("volumeMounts", [])
        if isinstance(mount, dict) and mount.get("name") == "observer-tmp"
    ]
    checks.equal(
        observer_tmp_mounts,
        [
            (
                "broker-observer",
                {
                    "mountPath": "/tmp",
                    "mountPropagation": "None",
                    "name": "observer-tmp",
                },
            )
        ],
        "exclusive observer-tmp mount",
    )
    writable_mounts = [
        (container_spec.get("name"), mount.get("name"))
        for container_spec in all_container_specs
        if isinstance(container_spec, dict)
        for mount in container_spec.get("volumeMounts", [])
        if isinstance(mount, dict)
        and mount.get("name") in {"settings", "ibc-runtime", "tmp", "observer-tmp"}
    ]
    checks.equal(
        writable_mounts,
        [
            ("ib-gateway-paper", "settings"),
            ("ib-gateway-paper", "ibc-runtime"),
            ("ib-gateway-paper", "tmp"),
            ("broker-observer", "observer-tmp"),
        ],
        "exclusive writable volume mounts",
    )


def validate_network_policy(policy: dict[str, Any], checks: Checks) -> None:
    checks.equal(
        policy.get("apiVersion"),
        "networking.k8s.io/v1",
        "NetworkPolicy apiVersion",
    )
    checks.equal(
        policy.get("spec"),
        {
            "egress": [],
            "ingress": [],
            "podSelector": {"matchLabels": APP_LABELS},
            "policyTypes": ["Ingress", "Egress"],
        },
        "default-deny NetworkPolicy spec",
    )


def validate_cilium_policy(policy: dict[str, Any], checks: Checks) -> None:
    checks.equal(policy.get("apiVersion"), "cilium.io/v2", "CiliumNetworkPolicy apiVersion")
    exact_names = [{"matchName": name} for name in DNS_NAMES]
    expected_spec = {
        "egress": [
            {
                "toEndpoints": [
                    {
                        "matchLabels": {
                            "k8s:io.kubernetes.pod.namespace": "kube-system",
                            "k8s:k8s-app": "kube-dns",
                        }
                    }
                ],
                "toPorts": [
                    {
                        "ports": [
                            {"port": "53", "protocol": "UDP"},
                            {"port": "53", "protocol": "TCP"},
                        ],
                        "rules": {"dns": exact_names},
                    }
                ],
            },
            {
                "toFQDNs": exact_names,
                "toPorts": [
                    {
                        "ports": [
                            {"port": "4000", "protocol": "TCP"},
                            {"port": "4001", "protocol": "TCP"},
                        ]
                    }
                ],
            },
        ],
        "endpointSelector": {"matchLabels": APP_LABELS},
    }
    checks.equal(policy.get("spec"), expected_spec, "CiliumNetworkPolicy spec")

    broad_egress_keys = {
        "toCIDR",
        "toCIDRSet",
        "toEntities",
        "toNodes",
        "toServices",
    }
    for index, rule in enumerate(policy.get("spec", {}).get("egress", [])):
        checks.absent(rule, broad_egress_keys, f"Cilium egress rule {index}")
        for fqdn in rule.get("toFQDNs", []):
            checks.absent(fqdn, {"matchPattern"}, f"Cilium egress rule {index} FQDN")


def is_governed_resource(resource: dict[str, Any]) -> bool:
    kind, name, namespace = resource_id(resource)
    return namespace == NAMESPACE or (kind == "Namespace" and name == NAMESPACE)


def validate(
    repo_root: Path,
    requested_phase: str,
    expected_image: str | None,
    expected_broker_observer_image: str | None,
) -> tuple[list[str], str]:
    checks = Checks()
    repo_root = repo_root.resolve()
    apps_entrypoint = discover_apps_entrypoint(repo_root)
    validate_policy_records_not_rendered(apps_entrypoint, checks)
    source_phase = classify_deployment_source_set(apps_entrypoint, checks)
    resources = [
        resource
        for resource in load_resources(render_entrypoint(apps_entrypoint))
        if is_governed_resource(resource)
    ]
    indexed = index_resources(resources, checks)
    foundation_ids = {
        ("Namespace", NAMESPACE, None),
        ("NetworkPolicy", "ib-gateway-paper-default-deny", NAMESPACE),
        ("CiliumNetworkPolicy", "ib-gateway-paper", NAMESPACE),
    }
    pvc_id = ("PersistentVolumeClaim", "ib-gateway-settings", NAMESPACE)
    deployment_id = ("Deployment", "ib-gateway-paper", NAMESPACE)
    rendered_pvcs = [
        resource
        for resource in resources
        if resource.get("kind") == "PersistentVolumeClaim"
    ]
    rendered_deployments = [
        resource for resource in resources if resource.get("kind") == "Deployment"
    ]
    detected_phase = "deployment" if rendered_deployments else "foundation"
    phase = detected_phase if requested_phase == "auto" else requested_phase
    checks.equal(source_phase, phase, "deployment source set phase")
    expected_ids = foundation_ids | (
        {pvc_id, deployment_id} if phase == "deployment" else set()
    )
    checks.equal(set(indexed), expected_ids, "rendered resource set")

    if phase == "foundation":
        if rendered_pvcs:
            checks.errors.append(
                "foundation phase forbids PersistentVolumeClaim resources in "
                "autonomous-investing"
            )
        if rendered_deployments:
            checks.errors.append(
                "foundation phase forbids Deployment resources in autonomous-investing"
            )
    if phase == "deployment":
        pvc_ids = sorted(resource_id(resource) for resource in rendered_pvcs)
        checks.equal(
            pvc_ids,
            [pvc_id],
            "deployment phase PersistentVolumeClaim resources",
        )
        deployment_ids = sorted(resource_id(resource) for resource in rendered_deployments)
        checks.equal(
            deployment_ids,
            [deployment_id],
            "deployment phase Deployment resources",
        )

    forbidden_exposure_kinds = {
        "Gateway",
        "HTTPRoute",
        "Ingress",
        "IngressRoute",
        "Service",
    }
    present_exposure = sorted(
        f"{resource.get('kind', '')}/{resource.get('metadata', {}).get('name', '')}"
        for resource in resources
        if resource.get("kind") in forbidden_exposure_kinds
    )
    checks.equal(present_exposure, [], "forbidden external exposure resources")

    if expected_image is not None:
        checks.true(
            GATEWAY_IMAGE_PATTERN.fullmatch(expected_image) is not None,
            "--expected-image must itself be a valid governed sha256 reference",
        )
        if phase != "deployment":
            checks.errors.append("--expected-image requires deployment phase")
    if expected_broker_observer_image is not None:
        checks.true(
            BROKER_IMAGE_PATTERN.fullmatch(expected_broker_observer_image) is not None,
            "--expected-broker-observer-image must itself be a valid governed sha256 reference",
        )
        if phase != "deployment":
            checks.errors.append(
                "--expected-broker-observer-image requires deployment phase"
            )

    namespace = indexed.get(("Namespace", NAMESPACE, None))

    pvc = indexed.get(pvc_id)
    deployment = indexed.get(deployment_id)
    network_policy = indexed.get(
        ("NetworkPolicy", "ib-gateway-paper-default-deny", NAMESPACE)
    )
    cilium_policy = indexed.get(("CiliumNetworkPolicy", "ib-gateway-paper", NAMESPACE))

    policy_image = None
    broker_policy_image = None
    if phase == "deployment":
        policy_image = validate_deployment_policy(
            apps_entrypoint / IB_DEPLOYMENT_POLICY_RECORD,
            checks,
            EXPECTED_IB_DEPLOYMENT_POLICY,
            "",
        )
        broker_policy_image = validate_deployment_policy(
            apps_entrypoint / BROKER_DEPLOYMENT_POLICY_RECORD,
            checks,
            EXPECTED_BROKER_DEPLOYMENT_POLICY,
            "broker observer ",
        )

    if namespace:
        validate_namespace(namespace, checks)
    if pvc:
        validate_pvc(pvc, checks)
    if deployment:
        validate_deployment(
            deployment,
            checks,
            policy_image,
            broker_policy_image,
            expected_image,
            expected_broker_observer_image,
        )
    if network_policy:
        validate_network_policy(network_policy, checks)
    if cilium_policy:
        validate_cilium_policy(cilium_policy, checks)

    storage_resources = load_resources(
        render_entrypoint(discover_storage_entrypoint(repo_root))
    )
    local_path_retain = [
        resource
        for resource in storage_resources
        if resource.get("kind") == "StorageClass"
        and resource.get("metadata", {}).get("name") == "local-path-retain"
    ]
    checks.equal(
        len(local_path_retain),
        1,
        "authoritative storage render local-path-retain count",
    )
    if len(local_path_retain) == 1:
        validate_storage_class(local_path_retain[0], checks)
    return checks.errors, phase


def main() -> int:
    args = parse_args()
    try:
        errors, phase = validate(
            args.repo_root,
            args.phase,
            args.expected_image,
            args.expected_broker_observer_image,
        )
    except (
        AttributeError,
        KeyError,
        OSError,
        RuntimeError,
        TypeError,
        ValueError,
        yaml.YAMLError,
    ) as exc:
        print(f"IB Gateway manifest validation failed: {exc}", file=sys.stderr)
        return 1

    if errors:
        print("IB Gateway manifest validation failed:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1

    print("Validating governed IB Gateway paper manifest")
    print(f"  phase: {phase}")
    print("  authoritative Flux apps render: ok")
    print("  autonomous-investing resources: ok")
    if phase == "deployment":
        print("  deployment policy records: ok")
    print("  local-path-retain StorageClass: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
