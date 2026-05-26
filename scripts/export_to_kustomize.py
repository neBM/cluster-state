#!/usr/bin/env python3

from __future__ import annotations

import base64
import json
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml


REPO_ROOT = Path(__file__).resolve().parent.parent

NAMESPACED_TYPES = [
    "deployments.apps",
    "statefulsets.apps",
    "daemonsets.apps",
    "services",
    "configmaps",
    "persistentvolumeclaims",
    "serviceaccounts",
    "roles.rbac.authorization.k8s.io",
    "rolebindings.rbac.authorization.k8s.io",
    "cronjobs.batch",
    "ingresses.networking.k8s.io",
    "ingressroutes.traefik.io",
    "middlewares.traefik.io",
    "certificates.cert-manager.io",
    "verticalpodautoscalers.autoscaling.k8s.io",
    "ciliumnetworkpolicies.cilium.io",
    "resourceclaims.resource.k8s.io",
]

CLUSTER_TYPES = [
    "clusterroles.rbac.authorization.k8s.io",
    "clusterrolebindings.rbac.authorization.k8s.io",
    "storageclasses.storage.k8s.io",
    "customresourcedefinitions.apiextensions.k8s.io",
    "mutatingwebhookconfigurations.admissionregistration.k8s.io",
    "validatingwebhookconfigurations.admissionregistration.k8s.io",
    "apiservices.apiregistration.k8s.io",
    "deviceclasses.resource.k8s.io",
    "persistentvolumes",
]

RUNTIME_METADATA_KEYS = {
    "creationTimestamp",
    "deletionGracePeriodSeconds",
    "deletionTimestamp",
    "generation",
    "managedFields",
    "resourceVersion",
    "selfLink",
    "uid",
}

RUNTIME_ANNOTATIONS = {
    "deployment.kubernetes.io/revision",
    "kubectl.kubernetes.io/last-applied-configuration",
    "kubectl.kubernetes.io/restartedAt",
    "reloader.stakater.com/last-reloaded-from",
    "pv.kubernetes.io/bind-completed",
    "pv.kubernetes.io/bound-by-controller",
    "volume.beta.kubernetes.io/storage-provisioner",
    "volume.kubernetes.io/storage-provisioner",
}

MANAGED_BY_LABEL_KEYS = {
    "managed-by",
    "app.kubernetes.io/managed-by",
}

RUNTIME_LABELS = {
    "kustomize.toolkit.fluxcd.io/name",
    "kustomize.toolkit.fluxcd.io/namespace",
}

STRING_REPLACEMENTS = {
    "Managed by Terraform": "Managed in cluster-state",
}

GITLAB_CNG_IMAGES = {
    "gitlab-gitaly": "registry.gitlab.com/gitlab-org/build/cng/gitaly",
    "gitlab-registry": "registry.gitlab.com/gitlab-org/build/cng/gitlab-container-registry",
    "gitlab-sidekiq": "registry.gitlab.com/gitlab-org/build/cng/gitlab-sidekiq-ce",
    "gitlab-webservice": "registry.gitlab.com/gitlab-org/build/cng/gitlab-webservice-ce",
    "gitlab-workhorse": "registry.gitlab.com/gitlab-org/build/cng/gitlab-workhorse-ce",
}


@dataclass
class ExplicitResource:
    resource_type: str
    names: list[str]
    namespace: str | None = None


@dataclass
class Component:
    path: str
    selectors: dict[str, str] = field(default_factory=dict)
    explicit_namespaced: list[ExplicitResource] = field(default_factory=list)
    explicit_cluster: list[ExplicitResource] = field(default_factory=list)
    postprocess: str | None = None


def run_kubectl(*args: str) -> str:
    cmd = ["kubectl", *args]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} failed: {result.stderr.strip()}")
    return result.stdout


def get_yaml(resource_type: str, namespace: str | None = None, selector: str | None = None, names: list[str] | None = None) -> list[dict[str, Any]]:
    cmd = ["get", resource_type]
    if names:
        cmd.extend(names)
    if namespace:
        cmd.extend(["-n", namespace])
    if selector:
        cmd.extend(["-l", selector])
    cmd.extend(["-o", "yaml", "--ignore-not-found=true"])
    raw = run_kubectl(*cmd)
    if not raw.strip():
        return []
    data = yaml.safe_load(raw)
    if not data:
        return []
    if data.get("kind") == "List":
        return [item for item in data.get("items", []) if item]
    return [data]


def normalize_embedded_strings(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: normalize_embedded_strings(item) for key, item in value.items()}
    if isinstance(value, list):
        return [normalize_embedded_strings(item) for item in value]
    if isinstance(value, str):
        for old, new in STRING_REPLACEMENTS.items():
            value = value.replace(old, new)
    return value


def requires_managed_by_labels(value: Any) -> bool:
    if isinstance(value, dict):
        for key, item in value.items():
            if key in {"selector", "matchLabels"} and isinstance(item, dict):
                if any(label_key in item for label_key in MANAGED_BY_LABEL_KEYS):
                    return True
            if requires_managed_by_labels(item):
                return True
    elif isinstance(value, list):
        for item in value:
            if requires_managed_by_labels(item):
                return True
    return False


def restore_statefulset_volume_claim_labels(resource: dict[str, Any], original: dict[str, Any]) -> None:
    if resource.get("kind") != "StatefulSet":
        return

    original_templates = original.get("spec", {}).get("volumeClaimTemplates", [])
    desired_templates = resource.get("spec", {}).get("volumeClaimTemplates", [])
    original_by_name = {
        template.get("metadata", {}).get("name"): {
            key: value
            for key, value in (template.get("metadata", {}).get("labels", {}) or {}).items()
            if key in MANAGED_BY_LABEL_KEYS
        }
        for template in original_templates
    }

    for template in desired_templates:
        metadata = template.setdefault("metadata", {})
        name = metadata.get("name")
        managed_by_labels = original_by_name.get(name, {})
        if not managed_by_labels:
            continue
        labels = metadata.setdefault("labels", {})
        labels.update(managed_by_labels)


def scrub_runtime_fields(value: Any, preserve_managed_by: bool) -> None:
    if isinstance(value, dict):
        for key in list(value.keys()):
            item = value[key]
            if key in RUNTIME_LABELS:
                value.pop(key, None)
                continue
            if not preserve_managed_by and key in MANAGED_BY_LABEL_KEYS and item == "terraform":
                value.pop(key, None)
                continue
            if key in RUNTIME_ANNOTATIONS:
                value.pop(key, None)
                continue

            scrub_runtime_fields(item, preserve_managed_by)

            if key in {"annotations", "labels", "matchLabels"} and isinstance(value.get(key), dict) and not value[key]:
                value.pop(key, None)
    elif isinstance(value, list):
        for item in value:
            scrub_runtime_fields(item, preserve_managed_by)


def strip_resource(resource: dict[str, Any]) -> dict[str, Any]:
    original = json.loads(json.dumps(resource))
    preserve_managed_by = requires_managed_by_labels(original)
    resource = normalize_embedded_strings(original)
    scrub_runtime_fields(resource, preserve_managed_by)
    metadata = resource.setdefault("metadata", {})
    for key in RUNTIME_METADATA_KEYS:
        metadata.pop(key, None)

    annotations = metadata.get("annotations")
    if annotations:
        for key in RUNTIME_ANNOTATIONS:
            annotations.pop(key, None)
        if not annotations:
            metadata.pop("annotations", None)

    labels = metadata.get("labels")
    if labels:
        for key in MANAGED_BY_LABEL_KEYS:
            if labels.get(key) == "terraform":
                labels.pop(key, None)
        if not labels:
            metadata.pop("labels", None)

    resource.pop("status", None)

    kind = resource.get("kind")

    if kind == "Service":
        spec = resource.get("spec", {})
        if spec.get("clusterIP") != "None":
            spec.pop("clusterIP", None)
            spec.pop("clusterIPs", None)
        spec.pop("healthCheckNodePort", None)
        spec.pop("ipFamilies", None)
        spec.pop("ipFamilyPolicy", None)
        if not spec.get("sessionAffinityConfig"):
            spec.pop("sessionAffinityConfig", None)

    elif kind == "PersistentVolumeClaim":
        resource.get("spec", {}).pop("volumeName", None)

    elif kind == "PersistentVolume":
        resource.get("spec", {}).pop("claimRef", None)

    elif kind == "ServiceAccount":
        resource.pop("secrets", None)

    elif kind == "Namespace":
        labels = metadata.get("labels", {})
        resource = {
            "apiVersion": "v1",
            "kind": "Namespace",
            "metadata": {
                "name": metadata["name"],
                "labels": labels,
            },
        }

    elif kind == "Node":
        labels = metadata.get("labels", {})
        desired_labels = {k: v for k, v in labels.items() if k == "nvidia.com/gpu.present"}
        resource = {
            "apiVersion": "v1",
            "kind": "Node",
            "metadata": {
                "name": metadata["name"],
                "labels": desired_labels,
            },
        }

    restore_statefulset_volume_claim_labels(resource, original)

    return resource


def resource_key(resource: dict[str, Any]) -> tuple[str, str, str, str]:
    metadata = resource.get("metadata", {})
    return (
        resource.get("apiVersion", ""),
        resource.get("kind", ""),
        metadata.get("namespace", ""),
        metadata.get("name", ""),
    )


def filename_for(resource: dict[str, Any]) -> str:
    kind = resource["kind"].lower()
    name = resource["metadata"]["name"]
    namespace = resource["metadata"].get("namespace")
    safe_name = name.replace("/", "-").replace(":", "-")
    if namespace:
        return f"{kind}-{namespace}-{safe_name}.yaml"
    return f"{kind}-{safe_name}.yaml"


def dump_yaml(doc: dict[str, Any]) -> str:
    return yaml.safe_dump(doc, sort_keys=False)


def split_image_tag(image: str) -> tuple[str, str]:
    if "@" in image:
        raise RuntimeError(f"image digests are not supported for GitLab CNG version management: {image}")

    name, sep, tag = image.rpartition(":")
    if not sep or not name or not tag:
        raise RuntimeError(f"image is missing a tag: {image}")

    return name, tag


def write_component(component: Component, resources: list[dict[str, Any]]) -> None:
    path = REPO_ROOT / component.path
    path.mkdir(parents=True, exist_ok=True)

    filenames: list[str] = []
    for resource in sorted(resources, key=lambda item: (item["kind"], item["metadata"].get("namespace", ""), item["metadata"]["name"])):
        filename = filename_for(resource)
        (path / filename).write_text(dump_yaml(resource))
        filenames.append(filename)

    kustomization = {
        "apiVersion": "kustomize.config.k8s.io/v1beta1",
        "kind": "Kustomization",
        "resources": filenames,
    }
    (path / "kustomization.yaml").write_text(dump_yaml(kustomization))

    if component.postprocess == "grafana":
        write_grafana_files(path)
    elif component.postprocess == "gitlab":
        write_gitlab_files(path, resources)


def write_aggregate(path_str: str, children: list[str]) -> None:
    path = REPO_ROOT / path_str
    path.mkdir(parents=True, exist_ok=True)
    doc = {
        "apiVersion": "kustomize.config.k8s.io/v1beta1",
        "kind": "Kustomization",
        "resources": children,
    }
    (path / "kustomization.yaml").write_text(dump_yaml(doc))


def fetch_component_resources(component: Component) -> list[dict[str, Any]]:
    seen: set[tuple[str, str, str, str]] = set()
    collected: list[dict[str, Any]] = []

    def add(resources: list[dict[str, Any]]) -> None:
        for resource in resources:
            stripped = strip_resource(resource)
            key = resource_key(stripped)
            if key in seen:
                continue
            seen.add(key)
            collected.append(stripped)

    for namespace, selector in component.selectors.items():
        for resource_type in NAMESPACED_TYPES:
            add(get_yaml(resource_type, namespace=namespace, selector=selector))
        for resource_type in CLUSTER_TYPES:
            add(get_yaml(resource_type, selector=selector))

    for explicit in component.explicit_namespaced:
        add(get_yaml(explicit.resource_type, namespace=explicit.namespace, names=explicit.names))

    for explicit in component.explicit_cluster:
        add(get_yaml(explicit.resource_type, names=explicit.names))

    if component.postprocess == "grafana":
        collected = [resource for resource in collected if not (resource["kind"] == "ConfigMap" and resource["metadata"]["name"] in {"grafana-alerting", "grafana-datasources"})]

    return collected


def write_grafana_files(grafana_dir: Path) -> None:
    grafana_dir.mkdir(parents=True, exist_ok=True)
    files_dir = grafana_dir / "files"
    files_dir.mkdir(parents=True, exist_ok=True)

    (files_dir / "loki.yaml").write_text(
        dump_yaml(
            {
                "apiVersion": 1,
                "datasources": [
                    {
                        "access": "proxy",
                        "editable": True,
                        "isDefault": False,
                        "jsonData": {
                            "maxLines": 1000,
                            "timeout": 60,
                        },
                        "name": "Loki",
                        "type": "loki",
                        "uid": "loki",
                        "url": "http://loki.default.svc.cluster.local:3100",
                        "version": 1,
                    }
                ],
            }
        )
    )
    (files_dir / "prometheus.yaml").write_text(
        dump_yaml(
            {
                "apiVersion": 1,
                "datasources": [
                    {
                        "access": "proxy",
                        "editable": False,
                        "isDefault": True,
                        "name": "Prometheus",
                        "type": "prometheus",
                        "uid": "prometheus",
                        "url": "http://victoriametrics.default.svc.cluster.local:8428",
                    }
                ],
            }
        )
    )
    (files_dir / "contactpoints.yaml").write_text(
        dump_yaml(
            {
                "apiVersion": 1,
                "contactPoints": [
                    {
                        "name": "email",
                        "orgId": 1,
                        "receivers": [
                            {
                                "settings": {
                                    "addresses": "${GF_ALERT_EMAIL_TO}",
                                },
                                "type": "email",
                                "uid": "email-alerts",
                            }
                        ],
                    }
                ],
            }
        )
    )
    (files_dir / "policies.yaml").write_text(
        dump_yaml(
            {
                "apiVersion": 1,
                "policies": [
                    {
                        "orgId": 1,
                        "receiver": "email",
                    }
                ],
            }
        )
    )

    password_b64 = run_kubectl("get", "secret", "grafana-secrets", "-n", "default", "-o", "jsonpath={.data.GF_SECURITY_ADMIN_PASSWORD}")
    password = base64.b64decode(password_b64).decode().strip()
    rules = subprocess.run(
        [
            "curl",
            "-fsS",
            "-u",
            f"admin:{password}",
            "https://grafana.brmartin.co.uk/api/v1/provisioning/alert-rules/export?format=yaml",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if rules.returncode != 0:
        raise RuntimeError(f"failed to export Grafana alert rules: {rules.stderr.strip()}")
    (grafana_dir / "_grafana_alert_rules.yaml").write_text(rules.stdout)

    deployment_path = grafana_dir / "deployment-default-grafana.yaml"
    deployment = yaml.safe_load(deployment_path.read_text())
    for volume in deployment.get("spec", {}).get("template", {}).get("spec", {}).get("volumes", []):
        config_map = volume.get("configMap")
        if not config_map:
            continue
        name = config_map.get("name", "")
        if name.startswith("grafana-datasources"):
            config_map["name"] = "grafana-datasources"
        elif name.startswith("grafana-alerting"):
            config_map["name"] = "grafana-alerting"
    deployment_path.write_text(dump_yaml(deployment))

    kustomization = yaml.safe_load((grafana_dir / "kustomization.yaml").read_text())
    kustomization["namespace"] = "default"
    kustomization["configMapGenerator"] = [
        {
            "name": "grafana-datasources",
            "files": [
                "loki.yaml=files/loki.yaml",
                "prometheus.yaml=files/prometheus.yaml",
            ],
        },
        {
            "name": "grafana-alerting",
            "files": [
                "contactpoints.yaml=files/contactpoints.yaml",
                "policies.yaml=files/policies.yaml",
                "rules.yaml=_grafana_alert_rules.yaml",
            ],
        },
    ]
    (grafana_dir / "kustomization.yaml").write_text(dump_yaml(kustomization))


def write_gitlab_files(gitlab_dir: Path, resources: list[dict[str, Any]]) -> None:
    deployments = {
        resource["metadata"]["name"]: resource
        for resource in resources
        if resource.get("kind") == "Deployment"
    }

    versions: dict[str, str] = {}
    for deployment_name, expected_image in GITLAB_CNG_IMAGES.items():
        deployment = deployments.get(deployment_name)
        if deployment is None:
            raise RuntimeError(f"missing GitLab deployment for migrations postprocess: {deployment_name}")

        containers = deployment.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
        if len(containers) != 1:
            raise RuntimeError(f"expected a single container in {deployment_name}, found {len(containers)}")

        image_name, image_tag = split_image_tag(containers[0]["image"])
        if image_name != expected_image:
            raise RuntimeError(
                f"unexpected image for {deployment_name}: expected {expected_image}, found {image_name}"
            )
        versions[deployment_name] = image_tag

    unique_versions = sorted(set(versions.values()))
    if len(unique_versions) != 1:
        raise RuntimeError(f"GitLab CNG images do not share a single version: {versions}")

    gitlab_version = unique_versions[0]
    job_filename = "job-default-gitlab-migrations.yaml"
    job = {
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {
            "name": "gitlab-migrations-placeholder",
            "namespace": "default",
            "labels": {
                "app": "gitlab",
                "component": "migrations",
            },
        },
        "spec": {
            "backoffLimit": 6,
            "template": {
                "metadata": {
                    "annotations": {
                        "elastic.co/dataset": "kubernetes.container_logs.gitlab",
                    },
                    "labels": {
                        "app": "gitlab",
                        "component": "migrations",
                    },
                },
                "spec": {
                    "automountServiceAccountToken": True,
                    "containers": [
                        {
                            "name": "migrations",
                            "image": f"{GITLAB_CNG_IMAGES['gitlab-webservice']}:placeholder",
                            "imagePullPolicy": "IfNotPresent",
                            "args": [
                                "/scripts/db-migrate",
                            ],
                            "env": [
                                {
                                    "name": "CONFIG_TEMPLATE_DIRECTORY",
                                    "value": "/var/opt/gitlab/config/templates",
                                },
                                {
                                    "name": "CONFIG_DIRECTORY",
                                    "value": "/srv/gitlab/config",
                                },
                                {
                                    "name": "GITLAB_HOST",
                                    "value": "git.brmartin.co.uk",
                                },
                                {
                                    "name": "GITLAB_PORT",
                                    "value": "443",
                                },
                                {
                                    "name": "GITLAB_HTTPS",
                                    "value": "true",
                                },
                                {
                                    "name": "ENABLE_BOOTSNAP",
                                    "value": "1",
                                },
                                {
                                    "name": "ACTION_CABLE_IN_APP",
                                    "value": "true",
                                },
                                {
                                    "name": "GITALY_TOKEN",
                                    "valueFrom": {
                                        "secretKeyRef": {
                                            "key": "token",
                                            "name": "gitlab-gitaly",
                                            "optional": False,
                                        }
                                    },
                                },
                                {
                                    "name": "GITLAB_SMTP_USERNAME",
                                    "valueFrom": {
                                        "secretKeyRef": {
                                            "key": "SMTP_USERNAME",
                                            "name": "gitlab-smtp-secret",
                                            "optional": False,
                                        }
                                    },
                                },
                                {
                                    "name": "GITLAB_SMTP_PASSWORD",
                                    "valueFrom": {
                                        "secretKeyRef": {
                                            "key": "SMTP_PASSWORD",
                                            "name": "gitlab-smtp-secret",
                                            "optional": False,
                                        }
                                    },
                                },
                            ],
                            "resources": {
                                "limits": {
                                    "memory": "3Gi",
                                },
                                "requests": {
                                    "cpu": "75m",
                                    "memory": "2100Mi",
                                },
                            },
                            "volumeMounts": [
                                {
                                    "mountPath": "/var/opt/gitlab/config/templates",
                                    "name": "config-templates",
                                },
                                {
                                    "mountPath": "/srv/gitlab/public/uploads",
                                    "mountPropagation": "HostToContainer",
                                    "name": "uploads",
                                },
                                {
                                    "mountPath": "/srv/gitlab/shared",
                                    "mountPropagation": "HostToContainer",
                                    "name": "shared",
                                },
                                {
                                    "mountPath": "/etc/gitlab/postgres",
                                    "name": "db-password",
                                    "readOnly": True,
                                },
                                {
                                    "mountPath": "/srv/gitlab/config/secrets.yml",
                                    "name": "rails-secret",
                                    "readOnly": True,
                                    "subPath": "secrets.yml",
                                },
                                {
                                    "mountPath": "/etc/gitlab/gitlab-workhorse",
                                    "name": "workhorse-secret",
                                    "readOnly": True,
                                },
                                {
                                    "mountPath": "/etc/gitlab/gitlab-shell",
                                    "name": "shell-secret",
                                    "readOnly": True,
                                },
                                {
                                    "mountPath": "/etc/gitlab/registry",
                                    "name": "registry-auth",
                                    "readOnly": True,
                                },
                                {
                                    "mountPath": "/srv/gitlab/config/initializers/smtp_settings.rb",
                                    "name": "smtp-config",
                                    "readOnly": True,
                                    "subPath": "smtp_settings.rb",
                                },
                            ],
                        }
                    ],
                    "dnsPolicy": "ClusterFirst",
                    "enableServiceLinks": True,
                    "restartPolicy": "OnFailure",
                    "schedulerName": "default-scheduler",
                    "securityContext": {
                        "fsGroup": 1000,
                        "runAsGroup": 1000,
                        "runAsNonRoot": False,
                        "runAsUser": 1000,
                    },
                    "shareProcessNamespace": False,
                    "terminationGracePeriodSeconds": 30,
                    "volumes": [
                        {
                            "configMap": {
                                "defaultMode": 420,
                                "name": "gitlab-config-templates",
                                "optional": False,
                            },
                            "name": "config-templates",
                        },
                        {
                            "name": "uploads",
                            "persistentVolumeClaim": {
                                "claimName": "gitlab-uploads-sw",
                            },
                        },
                        {
                            "name": "shared",
                            "persistentVolumeClaim": {
                                "claimName": "gitlab-shared-sw",
                            },
                        },
                        {
                            "name": "db-password",
                            "secret": {
                                "defaultMode": 420,
                                "items": [
                                    {
                                        "key": "db_password",
                                        "path": "password",
                                    }
                                ],
                                "optional": False,
                                "secretName": "gitlab-secrets",
                            },
                        },
                        {
                            "name": "rails-secret",
                            "secret": {
                                "defaultMode": 420,
                                "optional": False,
                                "secretName": "gitlab-rails-secret",
                            },
                        },
                        {
                            "name": "workhorse-secret",
                            "secret": {
                                "defaultMode": 420,
                                "optional": False,
                                "secretName": "gitlab-workhorse",
                            },
                        },
                        {
                            "name": "shell-secret",
                            "secret": {
                                "defaultMode": 420,
                                "optional": False,
                                "secretName": "gitlab-shell",
                            },
                        },
                        {
                            "name": "registry-auth",
                            "secret": {
                                "defaultMode": 420,
                                "optional": False,
                                "secretName": "gitlab-registry-auth",
                            },
                        },
                        {
                            "configMap": {
                                "defaultMode": 420,
                                "name": "gitlab-smtp-config",
                                "optional": False,
                            },
                            "name": "smtp-config",
                        },
                    ],
                },
            },
        },
    }
    (gitlab_dir / job_filename).write_text(dump_yaml(job))

    kustomization = yaml.safe_load((gitlab_dir / "kustomization.yaml").read_text())
    kustomization["namespace"] = "default"
    resources = kustomization.setdefault("resources", [])
    if job_filename not in resources:
        resources.append(job_filename)

    kustomization["generatorOptions"] = {
        "disableNameSuffixHash": True,
    }
    kustomization["configMapGenerator"] = [
        {
            "name": "gitlab-release",
            "literals": [
                f"appVersion={gitlab_version}",
                f"migrationVersion={gitlab_version}",
            ],
        }
    ]
    kustomization["replacements"] = [
        {
            "source": {
                "kind": "ConfigMap",
                "name": "gitlab-release",
                "fieldPath": "data.migrationVersion",
            },
            "targets": [
                {
                    "select": {
                        "kind": "Job",
                        "labelSelector": "app=gitlab,component=migrations",
                    },
                    "fieldPaths": [
                        "metadata.name",
                    ],
                    "options": {
                        "delimiter": "-",
                        "index": 2,
                    },
                },
                {
                    "select": {
                        "kind": "Job",
                        "labelSelector": "app=gitlab,component=migrations",
                    },
                    "fieldPaths": [
                        "spec.template.spec.containers.0.image",
                    ],
                    "options": {
                        "delimiter": ":",
                        "index": 1,
                    },
                },
            ],
        },
        {
            "source": {
                "kind": "ConfigMap",
                "name": "gitlab-release",
                "fieldPath": "data.appVersion",
            },
            "targets": [
                {
                    "select": {
                        "kind": "Deployment",
                        "name": "gitlab-gitaly",
                    },
                    "fieldPaths": [
                        "spec.template.spec.containers.0.image",
                    ],
                    "options": {
                        "delimiter": ":",
                        "index": 1,
                    },
                },
                {
                    "select": {
                        "kind": "Deployment",
                        "name": "gitlab-registry",
                    },
                    "fieldPaths": [
                        "spec.template.spec.containers.0.image",
                    ],
                    "options": {
                        "delimiter": ":",
                        "index": 1,
                    },
                },
                {
                    "select": {
                        "kind": "Deployment",
                        "name": "gitlab-sidekiq",
                    },
                    "fieldPaths": [
                        "spec.template.spec.containers.0.image",
                    ],
                    "options": {
                        "delimiter": ":",
                        "index": 1,
                    },
                },
                {
                    "select": {
                        "kind": "Deployment",
                        "name": "gitlab-webservice",
                    },
                    "fieldPaths": [
                        "spec.template.spec.containers.0.image",
                    ],
                    "options": {
                        "delimiter": ":",
                        "index": 1,
                    },
                },
                {
                    "select": {
                        "kind": "Deployment",
                        "name": "gitlab-workhorse",
                    },
                    "fieldPaths": [
                        "spec.template.spec.containers.0.image",
                    ],
                    "options": {
                        "delimiter": ":",
                        "index": 1,
                    },
                },
            ],
        }
    ]
    (gitlab_dir / "kustomization.yaml").write_text(dump_yaml(kustomization))


def clean_outputs() -> None:
    for path in [
        REPO_ROOT / "apps",
        REPO_ROOT / "infrastructure",
    ]:
        if path.exists():
            shutil.rmtree(path)


def main() -> int:
    clean_outputs()

    components = [
        Component("infrastructure/storage/local-path-retain", explicit_cluster=[ExplicitResource("storageclasses.storage.k8s.io", ["local-path-retain"])]),
        Component(
            "infrastructure/storage/seaweedfs",
            selectors={"default": "app=seaweedfs"},
            explicit_cluster=[
                ExplicitResource("storageclasses.storage.k8s.io", ["seaweedfs"]),
            ],
        ),
        Component(
            "infrastructure/storage/restic-backup",
            selectors={"default": "app=restic-backup"},
            explicit_cluster=[ExplicitResource("persistentvolumes", ["restic-seaweedfs-filer-root"])],
        ),
        Component(
            "infrastructure/platform/cert-manager",
            selectors={
                "cert-manager": "app.kubernetes.io/instance=cert-manager",
                "kube-system": "app.kubernetes.io/instance=cert-manager",
                "default": "app=cert-manager",
            },
            explicit_namespaced=[
                ExplicitResource("certificates.cert-manager.io", ["wildcard-brmartin-tls"], namespace="kube-system"),
            ],
            explicit_cluster=[
                ExplicitResource("namespaces", ["cert-manager"]),
                ExplicitResource("clusterissuers.cert-manager.io", ["letsencrypt-cloudflare"]),
            ],
        ),
        Component(
            "infrastructure/platform/reloader",
            selectors={"reloader": "app.kubernetes.io/instance=reloader"},
            explicit_cluster=[ExplicitResource("namespaces", ["reloader"])],
        ),
        Component(
            "infrastructure/platform/goldilocks",
            selectors={"kube-system": "app=goldilocks"},
            explicit_namespaced=[ExplicitResource("ingressroutes.traefik.io", ["goldilocks-dashboard"], namespace="kube-system")],
            explicit_cluster=[ExplicitResource("namespaces", ["default", "kube-system"])],
        ),
        Component(
            "infrastructure/platform/hubble-ui",
            explicit_namespaced=[ExplicitResource("ingresses.networking.k8s.io", ["hubble-ui"], namespace="kube-system")],
        ),
        Component(
            "infrastructure/platform/headlamp",
            selectors={"kube-system": "app.kubernetes.io/instance=headlamp"},
        ),
        Component(
            "infrastructure/platform/rpi5-dra-driver",
            selectors={"kube-system": "app=rpi5-dra-driver"},
        ),
        Component(
            "infrastructure/platform/nvidia-dra-driver",
            selectors={"nvidia-dra-driver": "app.kubernetes.io/instance=nvidia-dra-driver-gpu"},
            explicit_cluster=[
                ExplicitResource("deviceclasses.resource.k8s.io", [
                    "compute-domain-daemon.nvidia.com",
                    "compute-domain-default-channel.nvidia.com",
                    "gpu.nvidia.com",
                    "mig.nvidia.com",
                    "vfio.gpu.nvidia.com",
                ]),
                ExplicitResource("nodes", ["hestia"]),
                ExplicitResource("namespaces", ["nvidia-dra-driver"]),
            ],
        ),
        Component(
            "infrastructure/platform/device-classes",
            explicit_cluster=[ExplicitResource("deviceclasses.resource.k8s.io", ["nvidia-gpu", "iris-transcode-hw"])],
            explicit_namespaced=[ExplicitResource("resourceclaims.resource.k8s.io", ["hestia-gpu"], namespace="default")],
        ),
        Component(
            "infrastructure/platform/rpi-throttle-monitor",
            selectors={"default": "app.kubernetes.io/instance=rpi-throttle-monitor"},
        ),
        Component(
            "infrastructure/shared-services/valkey",
            selectors={"default": "app=valkey"},
        ),
        Component(
            "infrastructure/shared-services/clickhouse",
            selectors={"default": "app=clickhouse"},
        ),
        Component(
            "infrastructure/shared-services/ollama",
            selectors={"default": "app=ollama"},
        ),
        Component(
            "infrastructure/shared-services/gitlab-runner",
            selectors={"default": "app=gitlab-runner"},
        ),
        Component(
            "infrastructure/observability-core/alloy",
            selectors={"default": "app.kubernetes.io/instance=alloy"},
        ),
        Component(
            "infrastructure/observability-core/loki",
            selectors={"default": "app.kubernetes.io/instance=loki"},
        ),
        Component(
            "infrastructure/observability-core/victoriametrics",
            selectors={"default": "app.kubernetes.io/instance=victoriametrics"},
        ),
        Component(
            "infrastructure/observability-core/node-exporter",
            selectors={"default": "app.kubernetes.io/instance=node-exporter"},
        ),
        Component(
            "infrastructure/observability-core/kube-state-metrics",
            selectors={"default": "app.kubernetes.io/instance=kube-state-metrics"},
        ),
        Component(
            "infrastructure/observability-ui/grafana",
            selectors={"default": "app.kubernetes.io/instance=grafana"},
            postprocess="grafana",
        ),
        Component(
            "infrastructure/observability-ui/meshery",
            selectors={"default": "app.kubernetes.io/instance=meshery"},
        ),
        Component("apps/athenaeum", selectors={"default": "app=athenaeum"}),
        Component("apps/glitchtip", selectors={"default": "app=glitchtip"}),
        Component("apps/jayne-martin-counselling", selectors={"default": "app=jayne-martin-counselling"}, explicit_namespaced=[ExplicitResource("verticalpodautoscalers.autoscaling.k8s.io", ["jayne-martin-counselling-vpa"], namespace="default")]),
        Component("apps/keycloak", selectors={"default": "app=keycloak"}),
        Component(
            "apps/langfuse",
            selectors={"default": "app=langfuse"},
        ),
        Component(
            "apps/lldap",
            selectors={"default": "app=lldap"},
            explicit_namespaced=[ExplicitResource("ciliumnetworkpolicies.cilium.io", ["lldap"], namespace="default")],
        ),
        Component(
            "apps/mail",
            selectors={
                "default": "app in (mail-redis,rspamd,postfix,dovecot,sogo)",
            },
            explicit_namespaced=[
                ExplicitResource("ciliumnetworkpolicies.cilium.io", ["mail-redis", "rspamd", "dovecot", "postfix", "sogo"], namespace="default"),
            ],
        ),
        Component(
            "apps/matrix",
            selectors={"default": "app=matrix"},
            explicit_namespaced=[
                ExplicitResource("configmaps", ["synapse-config", "matrix-nginx-config", "element-config", "cinny-config"], namespace="default"),
                ExplicitResource("middlewares.traefik.io", ["mas-cors", "synapse-buffering", "synapse-headers", "wellknown-cors"], namespace="default"),
            ],
        ),
        Component(
            "apps/media-centre",
            selectors={"default": "app=media-centre"},
            explicit_cluster=[ExplicitResource("persistentvolumes", ["media-synology-docker", "media-synology-share"])],
        ),
        Component(
            "apps/nextcloud",
            selectors={"default": "app=nextcloud"},
            explicit_namespaced=[ExplicitResource("middlewares.traefik.io", ["nextcloud-webdav-redirect"], namespace="default")],
        ),
        Component("apps/nginx-sites", selectors={"default": "app=nginx-sites"}),
        Component("apps/open-webui", selectors={"default": "app=open-webui"}),
        Component(
            "apps/overseerr",
            selectors={"default": "app=overseerr"},
            explicit_namespaced=[ExplicitResource("verticalpodautoscalers.autoscaling.k8s.io", ["overseerr-vpa"], namespace="default")],
        ),
        Component("apps/searxng", selectors={"default": "app=searxng"}),
        Component("apps/vaultwarden", selectors={"default": "app=vaultwarden"}),
        Component(
            "apps/gitlab",
            selectors={"default": "app=gitlab"},
            postprocess="gitlab",
        ),
        Component(
            "apps/iris",
            selectors={"default": "app=iris"},
            explicit_cluster=[ExplicitResource("persistentvolumes", ["iris-synology-media"])],
            explicit_namespaced=[ExplicitResource("resourceclaims.resource.k8s.io", ["iris-transcode"], namespace="default")],
        ),
    ]

    for component in components:
        resources = fetch_component_resources(component)
        write_component(component, resources)

    write_aggregate(
        "infrastructure/storage",
        [
            "local-path-retain",
            "seaweedfs",
            "restic-backup",
        ],
    )
    write_aggregate(
        "infrastructure/platform",
        [
            "cert-manager",
            "reloader",
            "goldilocks",
            "hubble-ui",
            "headlamp",
            "rpi5-dra-driver",
            "nvidia-dra-driver",
            "device-classes",
            "rpi-throttle-monitor",
        ],
    )
    write_aggregate(
        "infrastructure/shared-services",
        [
            "valkey",
            "clickhouse",
            "ollama",
            "gitlab-runner",
        ],
    )
    write_aggregate(
        "infrastructure/observability-core",
        [
            "alloy",
            "loki",
            "victoriametrics",
            "node-exporter",
            "kube-state-metrics",
        ],
    )
    write_aggregate(
        "infrastructure/observability-ui",
        [
            "grafana",
            "meshery",
        ],
    )
    write_aggregate(
        "apps",
        [
            "athenaeum",
            "glitchtip",
            "jayne-martin-counselling",
            "keycloak",
            "langfuse",
            "lldap",
            "mail",
            "matrix",
            "media-centre",
            "nextcloud",
            "nginx-sites",
            "open-webui",
            "overseerr",
            "searxng",
            "vaultwarden",
            "gitlab",
            "iris",
        ],
    )

    print("Generated apps/, infrastructure/, and Grafana alert rule export.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
