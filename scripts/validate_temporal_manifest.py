#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML==6.0.3"]
# ///

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parent.parent
NAMESPACE = "temporal"
SERVER_IMAGE = "temporalio/server@sha256:b5ecdb8282bededae2a10c36e8d862e27d0bc2d247fc73c5416025997ab4a1da"
ADMIN_IMAGE = "temporalio/admin-tools@sha256:dbc5fcd6ee8f0f4d808bf765af9a87dea9d8a283abfdcfbd2fc148496ba66107"
SERVICES = {"frontend", "history", "matching", "worker"}
EXPECTED_SHARDS = 128
EXPECTED_DATABASES = {"temporal", "temporal_visibility"}
SECRET_NAME = "temporal-postgres"
FRONTEND_MTLS_SECRET_NAME = "temporal-frontend-mtls"
FRONTEND_MTLS_KEYS = {
    "ca.crt",
    "server.crt",
    "server.key",
    "system-worker.crt",
    "system-worker.key",
}
FLUX_FILES = {
    "temporal-schema-setup": "kustomization-temporal-schema-setup.yaml",
    "temporal-schema-upgrade": "kustomization-temporal-schema-upgrade.yaml",
    "temporal": "kustomization-temporal.yaml",
}


def render(root: Path, path: str) -> list[dict[str, Any]]:
    executable = shutil.which("kustomize")
    command = [executable, "build", path] if executable else ["kubectl", "kustomize", path]
    result = subprocess.run(command, cwd=root, capture_output=True, text=True, check=False)
    if result.returncode:
        raise ValueError(f"render {path}: {result.stderr.strip()}")
    return [doc for doc in yaml.safe_load_all(result.stdout) if isinstance(doc, dict)]


def key(resource: dict[str, Any]) -> tuple[str, str, str | None]:
    metadata = resource.get("metadata") or {}
    return resource.get("kind", ""), metadata.get("name", ""), metadata.get("namespace")


def containers(resource: dict[str, Any]) -> list[dict[str, Any]]:
    return resource.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])


def pod_spec(resource: dict[str, Any]) -> dict[str, Any]:
    return resource.get("spec", {}).get("template", {}).get("spec", {})


def env_map(container: dict[str, Any]) -> dict[str, Any]:
    return {item.get("name"): item for item in container.get("env", [])}


def parse_server_config(config: str) -> dict[str, Any]:
    normalized = re.sub(r"{{.*?}}", '"template"', config)
    parsed = yaml.safe_load(normalized)
    if not isinstance(parsed, dict):
        raise ValueError("server config template must render to a mapping")
    return parsed


def validate(root: Path) -> list[str]:
    errors: list[str] = []
    temporal_root = root / "apps/temporal"
    if not temporal_root.is_dir():
        return ["apps/temporal desired state is missing"]

    entrypoints = {
        "setup": "apps/temporal/schema-setup",
        "upgrade": "apps/temporal/schema-upgrade",
        "server": "apps/temporal/server",
    }
    rendered: dict[str, list[dict[str, Any]]] = {}
    for name, path in entrypoints.items():
        try:
            rendered[name] = render(root, path)
        except (ValueError, yaml.YAMLError) as exc:
            errors.append(str(exc))
    if errors:
        return errors

    all_resources = [item for resources in rendered.values() for item in resources]
    if any(resource.get("kind") == "Secret" for resource in all_resources):
        errors.append("Temporal desired state must not contain Secret resources")
    for resource in all_resources:
        kind, name, namespace = key(resource)
        if kind != "Namespace" and namespace != NAMESPACE:
            errors.append(f"{kind}/{name}: expected namespace temporal")

    namespaces = [r for r in all_resources if key(r)[:2] == ("Namespace", NAMESPACE)]
    if len(namespaces) != 1:
        errors.append(f"expected exactly one temporal Namespace, got {len(namespaces)}")
    else:
        labels = namespaces[0].get("metadata", {}).get("labels", {})
        for label in ("enforce", "audit", "warn"):
            if labels.get(f"pod-security.kubernetes.io/{label}") != "restricted":
                errors.append(f"Namespace missing restricted {label} label")

    setup_jobs = [r for r in rendered["setup"] if r.get("kind") == "Job"]
    upgrade_jobs = [r for r in rendered["upgrade"] if r.get("kind") == "Job"]
    for phase, jobs, command in (
        ("setup", setup_jobs, "setup-schema -v 0.0"),
        ("upgrade", upgrade_jobs, "update-schema --schema-dir /etc/temporal/schema/postgresql/v12/"),
    ):
        if len(jobs) != 2:
            errors.append(f"expected two {phase} Jobs, got {len(jobs)}")
        databases: set[str] = set()
        for job in jobs:
            name = key(job)[1]
            if "1-31-2" not in name:
                errors.append(f"Job/{name}: name is not version-matched to 1.31.2")
            spec = pod_spec(job)
            if spec.get("automountServiceAccountToken") is not False:
                errors.append(f"Job/{name}: service-account token must be disabled")
            if len(containers(job)) != 1:
                errors.append(f"Job/{name}: expected one container")
                continue
            container = containers(job)[0]
            if container.get("image") != ADMIN_IMAGE:
                errors.append(f"Job/{name}: admin-tools digest mismatch")
            args_text = " ".join(container.get("args", []))
            command_text = " ".join(container.get("command", [])) + " " + args_text
            if command not in command_text:
                errors.append(f"Job/{name}: missing {phase} command")
            env = env_map(container)
            database = env.get("SQL_DATABASE", {}).get("value")
            if database:
                databases.add(database)
            for variable in ("SQL_USER", "SQL_PASSWORD"):
                ref = env.get(variable, {}).get("valueFrom", {}).get("secretKeyRef", {})
                if ref.get("name") != SECRET_NAME:
                    errors.append(f"Job/{name}: {variable} must reference {SECRET_NAME}")
            if env.get("SQL_TLS", {}).get("value") != "true":
                errors.append(f"Job/{name}: SQL TLS is not required")
            if env.get("SQL_TLS_DISABLE_HOST_VERIFICATION", {}).get("value") != "false":
                errors.append(f"Job/{name}: PostgreSQL host verification is not fail closed")
            validate_pod_hardening(job, errors)
        if databases != EXPECTED_DATABASES:
            errors.append(f"{phase} Jobs databases: expected {sorted(EXPECTED_DATABASES)}, got {sorted(databases)}")

    server_resources = rendered["server"]
    deployments = [r for r in server_resources if r.get("kind") == "Deployment"]
    components = {r.get("metadata", {}).get("labels", {}).get("app.kubernetes.io/component") for r in deployments}
    if components != SERVICES:
        errors.append(f"server components: expected {sorted(SERVICES)}, got {sorted(str(x) for x in components)}")
    for deployment in deployments:
        name = key(deployment)[1]
        if len(containers(deployment)) != 1:
            errors.append(f"Deployment/{name}: expected one container")
            continue
        container = containers(deployment)[0]
        if container.get("image") != SERVER_IMAGE:
            errors.append(f"Deployment/{name}: server digest mismatch")
        env = env_map(container)
        if "TEMPORAL_ALLOW_NO_AUTH" in env:
            errors.append(f"Deployment/{name}: must not opt into unauthenticated server admission")
        for variable in ("TEMPORAL_DEFAULT_STORE_PASSWORD", "TEMPORAL_VISIBILITY_STORE_PASSWORD", "TEMPORAL_POSTGRES_USER"):
            ref = env.get(variable, {}).get("valueFrom", {}).get("secretKeyRef", {})
            if ref.get("name") != SECRET_NAME:
                errors.append(f"Deployment/{name}: {variable} must reference {SECRET_NAME}")
        scheduling_identity = {
            "nodeName": pod_spec(deployment).get("nodeName"),
            "nodeSelector": pod_spec(deployment).get("nodeSelector"),
            "requiredNodeAffinity": pod_spec(deployment)
            .get("affinity", {})
            .get("nodeAffinity", {})
            .get("requiredDuringSchedulingIgnoredDuringExecution"),
        }
        if "hestia" in str(scheduling_identity).lower():
            errors.append(f"Deployment/{name}: workload must not be pinned to Hestia")
        annotations = deployment.get("spec", {}).get("template", {}).get("metadata", {}).get("annotations", {})
        if annotations.get("prometheus.io/scrape") != "true" or "elastic.co/dataset" not in annotations:
            errors.append(f"Deployment/{name}: logs/metrics annotations incomplete")
        mounts = {item.get("name"): item for item in container.get("volumeMounts", [])}
        volumes = {item.get("name"): item for item in pod_spec(deployment).get("volumes", [])}
        if mounts.get("config-runtime", {}).get("mountPath") != "/etc/temporal/config":
            errors.append(f"Deployment/{name}: writable config runtime mount is missing")
        if volumes.get("config-runtime", {}).get("emptyDir") != {}:
            errors.append(f"Deployment/{name}: config runtime must be ephemeral")
        if mounts.get("frontend-mtls", {}).get("mountPath") != "/etc/temporal/frontend-mtls":
            errors.append(f"Deployment/{name}: frontend mTLS material mount is missing")
        mtls_secret = volumes.get("frontend-mtls", {}).get("secret", {})
        mtls_keys = {item.get("key") for item in mtls_secret.get("items", [])}
        if mtls_secret.get("secretName") != FRONTEND_MTLS_SECRET_NAME or mtls_keys != FRONTEND_MTLS_KEYS:
            errors.append(f"Deployment/{name}: frontend mTLS Secret contract is incomplete")
        validate_pod_hardening(deployment, errors)

    configmaps = [r for r in server_resources if key(r)[:2] == ("ConfigMap", "temporal-server-config")]
    if len(configmaps) != 1:
        errors.append("expected one ConfigMap/temporal-server-config")
    else:
        config = configmaps[0].get("data", {}).get("config_template.yaml", "")
        if not config.startswith("# enable-template\n"):
            errors.append("server config must explicitly enable Temporal 1.31 sprig templating")
        if config.count("maxConns: 2\n") != 1 or config.count("maxConns: 1\n") != 1:
            errors.append("server PostgreSQL pools must remain within the 24-connection Temporal budget")
        for required in (
            f"numHistoryShards: {EXPECTED_SHARDS}",
            "databaseName: temporal\n",
            "databaseName: temporal_visibility\n",
            "connectAddr: 192.168.1.10:5433",
            "enabled: true",
            "enableHostVerification: true",
            'currentClusterName: "homelab-temporal-v1"',
        ):
            if required not in config:
                errors.append(f"server config missing immutable/runtime contract: {required.strip()}")
        password_lines = [
            line.strip() for line in config.splitlines() if line.strip().startswith("password:")
        ]
        if any('{{ env "TEMPORAL_' not in line for line in password_lines):
            errors.append("server config contains a non-environment PostgreSQL password")
        try:
            parsed_config = parse_server_config(config)
        except (ValueError, yaml.YAMLError) as exc:
            errors.append(f"server config template is invalid: {exc}")
        else:
            tls = parsed_config.get("global", {}).get("tls", {})
            frontend = tls.get("frontend", {})
            server = frontend.get("server", {})
            client = frontend.get("client", {})
            system_worker = tls.get("systemWorker", {})
            if server.get("requireClientAuth") is not True:
                errors.append("frontend mTLS client authentication must be required")
            if server.get("clientCaFiles") != ["/etc/temporal/frontend-mtls/ca.crt"]:
                errors.append("frontend mTLS client CA trust is missing")
            if (
                server.get("certFile") != "/etc/temporal/frontend-mtls/server.crt"
                or server.get("keyFile") != "/etc/temporal/frontend-mtls/server.key"
            ):
                errors.append("frontend mTLS server identity is incomplete")
            expected_client = {
                "serverName": "temporal-frontend.temporal.svc.cluster.local",
                "disableHostVerification": False,
                "rootCaFiles": ["/etc/temporal/frontend-mtls/ca.crt"],
            }
            if client != expected_client:
                errors.append("frontend TLS client verification is not fail closed")
            if (
                system_worker.get("certFile")
                != "/etc/temporal/frontend-mtls/system-worker.crt"
                or system_worker.get("keyFile")
                != "/etc/temporal/frontend-mtls/system-worker.key"
            ):
                errors.append("system-worker mTLS client identity is incomplete")
            if system_worker.get("client") != expected_client:
                errors.append("system-worker frontend TLS verification is not fail closed")

    services = [r for r in server_resources if r.get("kind") == "Service"]
    frontend = [r for r in services if key(r)[1] == "temporal-frontend"]
    if len(frontend) != 1:
        errors.append("expected one Service/temporal-frontend")
    else:
        spec = frontend[0].get("spec", {})
        if spec.get("type", "ClusterIP") != "ClusterIP" or any("nodePort" in p for p in spec.get("ports", [])):
            errors.append("frontend must be ClusterIP-only")
        if {p.get("port") for p in spec.get("ports", [])} != {7233}:
            errors.append("frontend must expose only port 7233")
    forbidden = {"Ingress", "IngressRoute"}
    if any(r.get("kind") in forbidden for r in server_resources):
        errors.append("Temporal UI/ingress exposure is forbidden")

    policies = [r for r in server_resources if r.get("kind") == "CiliumNetworkPolicy"]
    if len(policies) != 1:
        errors.append("expected one Temporal CiliumNetworkPolicy")
    else:
        text = yaml.safe_dump(policies[0], sort_keys=True)
        for required in (
            "192.168.1.5/32",
            "192.168.1.10/32",
            "'7233'",
            "'5433'",
            "'53'",
            "app.kubernetes.io/instance: victoriametrics",
            "k8s:io.kubernetes.pod.namespace: default",
        ):
            if required not in text:
                errors.append(f"Cilium policy missing topology restriction {required}")

    pdb_components = {r.get("metadata", {}).get("labels", {}).get("app.kubernetes.io/component") for r in server_resources if r.get("kind") == "PodDisruptionBudget"}
    if pdb_components != SERVICES:
        errors.append("each Temporal service requires a PodDisruptionBudget")

    flux_root = root / "clusters/k3s-homelab/flux-system"
    root_kustomization = (flux_root / "kustomization.yaml").read_text()
    flux: dict[str, dict[str, Any]] = {}
    for name, filename in FLUX_FILES.items():
        if f"- {filename}\n" not in root_kustomization:
            errors.append(f"Flux root missing {filename}")
            continue
        resource = yaml.safe_load((flux_root / filename).read_text())
        flux[name] = resource
        spec = resource.get("spec", {})
        if spec.get("wait") is not True or spec.get("prune") is not True:
            errors.append(f"Flux Kustomization/{name}: wait and prune must be true")
    if flux:
        expected = {
            "temporal-schema-setup": ("./apps/temporal/schema-setup", {"shared-services"}),
            "temporal-schema-upgrade": ("./apps/temporal/schema-upgrade", {"temporal-schema-setup"}),
            "temporal": ("./apps/temporal/server", {"temporal-schema-upgrade"}),
        }
        for name, (path, dependencies) in expected.items():
            spec = flux.get(name, {}).get("spec", {})
            actual = {item.get("name") for item in spec.get("dependsOn", [])}
            if spec.get("path") != path or actual != dependencies:
                errors.append(f"Flux Kustomization/{name}: unsafe path/dependency ordering")

    return errors


def validate_pod_hardening(resource: dict[str, Any], errors: list[str]) -> None:
    kind, name, _ = key(resource)
    spec = pod_spec(resource)
    security = spec.get("securityContext", {})
    if security.get("runAsNonRoot") is not True or security.get("seccompProfile", {}).get("type") != "RuntimeDefault":
        errors.append(f"{kind}/{name}: pod security context incomplete")
    if spec.get("automountServiceAccountToken") is not False:
        errors.append(f"{kind}/{name}: service-account token must be disabled")
    for container in containers(resource):
        context = container.get("securityContext", {})
        if context.get("allowPrivilegeEscalation") is not False or context.get("readOnlyRootFilesystem") is not True:
            errors.append(f"{kind}/{name}: container hardening incomplete")
        if context.get("capabilities", {}).get("drop") != ["ALL"]:
            errors.append(f"{kind}/{name}: all capabilities must be dropped")
        resources = container.get("resources", {})
        if not resources.get("requests") or not resources.get("limits"):
            errors.append(f"{kind}/{name}: conservative requests and limits are required")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    args = parser.parse_args()
    errors = validate(args.repo_root.resolve())
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("Temporal 1.31.2 desired-state validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
