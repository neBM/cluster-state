#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML==6.0.3"]
# ///
"""Local inactive-preparation contract, not production admission or integration proof."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess

import yaml

ROOT = Path(__file__).resolve().parent.parent
# cpu request, memory request, memory limit; no new CPU ceilings.
RESOURCES = {
    "gitaly": ("50m", "300Mi", "512Mi"),
    "kas": ("50m", "128Mi", "512Mi"),
    "registry": ("100m", "64Mi", "256Mi"),
    "sidekiq": ("150m", "1600Mi", "2Gi"),
    "webservice": ("75m", "2100Mi", "3Gi"),
    "gitlab-workhorse": ("100m", "32Mi", "256Mi"),
    "toolbox": ("50m", "350M", None),
    "migrations": ("75m", "2100Mi", "3Gi"),
}
WORKLOADS = {"gitaly", "kas", "registry", "sidekiq", "webservice", "toolbox"}


def resources(name):
    cpu, memory, limit = RESOURCES[name]
    result = {"requests": {"cpu": cpu, "memory": memory}}
    if limit:
        result["limits"] = {"memory": limit}
    return result


def get(value, path):
    for key in path.split("."):
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


def expect(errors, value, path, wanted):
    actual = get(value, path)
    if type(actual) is not type(wanted) or actual != wanted:
        errors.append(f"{path}: expected {wanted!r}, got {actual!r}")


def validate_release(release):
    errors = []
    for path, wanted in {
        "apiVersion": "helm.toolkit.fluxcd.io/v2", "kind": "HelmRelease",
        "metadata.name": "gitlab-helm", "metadata.namespace": "default",
        "spec.suspend": True, "spec.releaseName": "gitlab-helm", "spec.targetNamespace": "default",
        "spec.chart.spec.chart": "gitlab", "spec.chart.spec.version": "10.5.0",
        "spec.chart.spec.sourceRef": {"kind": "HelmRepository", "name": "gitlab", "namespace": "default"},
    }.items():
        expect(errors, release, path, wanted)
    for phase in ("install", "upgrade"):
        for field in ("disableWait", "disableWaitForJobs", "disableHooks"):
            expect(errors, release, f"spec.{phase}.{field}", False)
        expect(errors, release, f"spec.{phase}.remediation.retries", 0)
        expect(errors, release, f"spec.{phase}.remediation.remediateLastFailure", False)
        # RetryOnFailure would bypass the intentional no-retry preparation policy.
        if get(release, f"spec.{phase}.strategy") is not None:
            errors.append(f"{phase}: do not override native remediation strategy")
    values = get(release, "spec.values") or {}
    for path, wanted in {
        "global.edition": "ce", "global.gitlabVersion": None,
        "global.gatewayApi.enabled": False, "global.gatewayApi.installEnvoy": False,
        "global.gatewayApi.configureCertmanager": False,
        "global.ingress.enabled": False, "global.ingress.configureCertmanager": False,
        "installCertmanager": False, "gitlab-runner.install": False,
        "nginx-ingress.enabled": False, "nginx-ingress-geo.enabled": False,
        "traefik.install": False, "haproxy.install": False,
        "prometheus.install": False, "shared-secrets.enabled": False,
        "gitlab.gitlab-shell.enabled": False, "gitlab.gitlab-exporter.enabled": False,
        "gitlab.migrations.enabled": True, "registry.database.enabled": False,
        "gitlab.webservice.workerProcesses": 1, "gitlab.webservice.puma.threads.min": 1,
        "gitlab.webservice.puma.threads.max": 4, "gitlab.sidekiq.concurrency": 5,
        "global.psql.host": "192.168.1.10", "global.psql.port": 5433,
        "global.psql.database": "gitlabhq_production", "global.psql.preparedStatements": False,
        "global.psql.ci.database": "gitlabhq_production", "global.psql.ci.databaseTasks": False,
        "global.redis.host": "gitlab-redis", "global.redis.auth.enabled": False,
        "global.appConfig.object_store.connection": {"secret": "gitlab-helm-objectstore", "key": "connection"},
        "registry.storage": {"secret": "gitlab-helm-registry-storage", "key": "config"},
        "gitlab.toolbox.backups.objectStorage.config": {"secret": "gitlab-helm-backup-config", "key": "config"},
    }.items():
        expect(errors, values, path, wanted)
    for name, db in {"cache": 1, "queues": 2, "shared_state": 3, "trace_chunks": 4, "rate_limiting": 5, "sessions": 6}.items():
        expect(errors, values, f"global.redis.redisYmlOverride.{name}.url", f"redis://gitlab-redis:6379/{db}")
    expect(errors, values, "gitlab.kas.customConfig.redis.database_index", 3)
    for name in ("webservice", "sidekiq", "kas"):
        for bound in ("minReplicas", "maxReplicas"):
            expect(errors, values, f"gitlab.{name}.{bound}", 1)
    for bound in ("minReplicas", "maxReplicas"):
        expect(errors, values, f"registry.hpa.{bound}", 1)
    for name in RESOURCES:
        path = "registry" if name == "registry" else "gitlab.webservice.workhorse" if name == "gitlab-workhorse" else f"gitlab.{name}"
        expect(errors, values, f"{path}.resources", resources(name))

    def pins(obj):
        if isinstance(obj, dict):
            if "tag" in obj or "digest" in obj:
                errors.append("values must not freeze per-component images independently of chart")
            for item in obj.values():
                pins(item)
        elif isinstance(obj, list):
            for item in obj:
                pins(item)
    pins(values)
    if "evaluation" in yaml.safe_dump(values):
        errors.append("planning-only Secret references must be normalized")
    return errors


def validate_internal_alias(service):
    errors = []
    for path, wanted in {
        "metadata.name": "gitlab-registry-internal", "metadata.namespace": "default",
        "spec.selector": {"app": "gitlab", "component": "registry"},
        "spec.ports": [{"name": "http", "port": 443, "protocol": "TCP", "targetPort": 5000}],
    }.items():
        expect(errors, service, path, wanted)
    return errors


def kustomize(root, path):
    executable = shutil.which("kustomize")
    if not executable:
        raise ValueError("standalone kustomize required (no Kubernetes API access needed)")
    result = subprocess.run([executable, "build", str(root / path)], check=True, text=True, capture_output=True)
    return [d for d in yaml.safe_load_all(result.stdout) if d]


def validate_source(root):
    errors = []
    candidate = root / "apps/gitlab-helm"
    release = yaml.safe_load((candidate / "helmrelease.yaml").read_text())
    errors.extend(validate_release(release))
    repository = yaml.safe_load((candidate / "helmrepository.yaml").read_text())
    expect(errors, repository, "spec.url", "https://charts.gitlab.io")
    flux_dir = root / "clusters/k3s-homelab/flux-system"
    leaf = yaml.safe_load((flux_dir / "kustomization-gitlab-helm.yaml").read_text())
    expect(errors, leaf, "spec.path", "./apps/gitlab-helm")
    expect(errors, leaf, "spec.suspend", True)
    # Prove absence from both actual reachable native renders, not a directory-name grep.
    for entrypoint in ("apps", "clusters/k3s-homelab/flux-system"):
        for doc in kustomize(root, entrypoint):
            if doc.get("metadata", {}).get("name", "").startswith("gitlab-helm"):
                errors.append(f"{entrypoint}: inactive candidate has entered active graph")
    errors.extend(validate_internal_alias(yaml.safe_load((root / "apps/gitlab/service-default-gitlab-registry-internal.yaml").read_text())))
    redis = yaml.safe_load((root / "apps/gitlab/deployment-default-gitlab-redis.yaml").read_text())
    expect(errors, redis, "spec.replicas", 1)
    if redis["spec"]["template"]["spec"]["containers"][0]["resources"] != {"requests": {"cpu": "50m", "memory": "32Mi"}, "limits": {"memory": "256Mi"}}:
        errors.append("retained Redis resources changed")
    controllers = kustomize(root, "clusters/k3s-homelab/flux-system")
    helm = next((d for d in controllers if d.get("kind") == "Deployment" and d["metadata"]["name"] == "helm-controller"), {})
    if not helm:
        errors.append("native helm-controller missing")
    else:
        container = helm["spec"]["template"]["spec"]["containers"][0]
        expect(errors, container, "image", "ghcr.io/fluxcd/helm-controller:v1.6.5")
        expect(errors, container, "resources.requests", {"cpu": "100m", "memory": "64Mi"})
    return errors


def validate_render(docs):
    errors = []
    docs = [d for d in docs if d]
    seen = set()
    for d in docs:
        kind = d.get("kind")
        if kind in ("Ingress", "Gateway", "HTTPRoute", "GRPCRoute", "Certificate", "Issuer"):
            errors.append(f"duplicate networking/certificate resource: {kind}")
        if kind not in ("Deployment", "StatefulSet", "Job"):
            continue
        app = d["metadata"].get("labels", {}).get("app")
        if kind != "Job":
            if app not in WORKLOADS or app in seen:
                errors.append(f"unexpected/duplicate workload: {d['metadata']['name']}")
            seen.add(app)
            if d["spec"].get("replicas", 1) != 1:
                errors.append(f"{app}: expected singleton")
        spec = d["spec"]["template"]["spec"]
        for c in spec["containers"]:
            name = c["name"]
            if name in RESOURCES and c.get("resources") != resources(name):
                errors.append(f"{name}: application resources changed")
            if name in ("webservice", "sidekiq", "gitlab-workhorse", "toolbox", "migrations") and not c["image"].endswith("-ce:v19.5.0"):
                errors.append(f"{name}: wrong CE release image")
            if name in ("gitaly", "kas") and not c["image"].endswith(":v19.5.0"):
                errors.append(f"{name}: wrong release image")
            env = {e["name"]: e.get("value") for e in c.get("env", [])}
            expected = {"WORKER_PROCESSES": "1", "PUMA_THREADS_MIN": "1", "PUMA_THREADS_MAX": "4"} if name == "webservice" else {"SIDEKIQ_CONCURRENCY": "5"} if name == "sidekiq" else {}
            for key, value in expected.items():
                if env.get(key) != value:
                    errors.append(f"{name}: {key} changed")
            if name == "migrations" and "/scripts/db-migrate" not in " ".join(c.get("args", [])):
                errors.append("native schema migration disabled")
        if app in ("webservice", "sidekiq"):
            if not any(c["name"] == "dependencies" for c in spec.get("initContainers", [])):
                errors.append(f"{app}: native init dependency checks missing")
    if seen != WORKLOADS:
        errors.append(f"expected workloads {WORKLOADS}, got {seen}")
    hpas = [d for d in docs if d.get("kind") == "HorizontalPodAutoscaler"]
    if len(hpas) != 4 or any(d["spec"].get("minReplicas") != 1 or d["spec"].get("maxReplicas") != 1 for d in hpas):
        errors.append("singleton HPA bounds changed")
    jobs = [d for d in docs if d.get("kind") == "Job"]
    if not any(d["metadata"]["name"].startswith("gitlab-helm-migrations-") for d in jobs):
        errors.append("native migration Job missing")
    if not any(d["metadata"].get("annotations", {}).get("helm.sh/hook") == "pre-upgrade" for d in jobs):
        errors.append("native pre-upgrade hook missing")
    kas = next((d for d in docs if d.get("kind") == "ConfigMap" and d["metadata"]["name"] == "gitlab-helm-kas"), {})
    config = yaml.safe_load(kas.get("data", {}).get("config.yaml", "{}"))
    expect(errors, config, "redis.database_index", 3)
    expect(errors, config, "agent.kubernetes_api.url_path_prefix", "/-/kubernetes-agent/k8s-proxy/")
    web = next((d for d in docs if d.get("kind") == "ConfigMap" and d["metadata"]["name"] == "gitlab-helm-webservice"), {})
    data = web.get("data", {})
    redis = yaml.safe_load(data.get("redis.yml.erb", "{}"))
    for name, db in {"cache": 1, "queues": 2, "shared_state": 3, "trace_chunks": 4, "rate_limiting": 5, "sessions": 6}.items():
        expect(errors, redis, f"production.{name}.url", f"redis://gitlab-redis:6379/{db}")
    for filename in ("resque.yml.erb", "cable.yml.erb"):
        expect(errors, yaml.safe_load(data.get(filename, "{}")), "production.url", "redis://gitlab-redis:6379/0")
    # Inspect only the authoritative application fragments; do not evaluate ERB.
    database = yaml.safe_load(re.sub(r"<%=.*?%>", '"secret-file-reference"', data.get("database.yml.erb", "{}")))
    for db in ("main", "ci"):
        for field, wanted in {"database": "gitlabhq_production", "host": "192.168.1.10", "port": 5433, "prepared_statements": False}.items():
            expect(errors, database, f"production.{db}.{field}", wanted)
    expect(errors, database, "production.ci.database_tasks", False)
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rendered", type=Path)
    parser.add_argument("--write-values", type=Path)
    parser.add_argument("--check-archive", type=Path)
    parser.add_argument("--index", type=Path)
    args = parser.parse_args()
    errors = validate_source(ROOT)
    if args.rendered:
        errors.extend(validate_render(list(yaml.safe_load_all(args.rendered.read_text()))))
    if args.check_archive:
        import hashlib
        lock = json.loads((ROOT / "apps/gitlab-helm/chart-lock.json").read_text())
        digest = hashlib.sha256(args.check_archive.read_bytes()).hexdigest()
        if digest != lock["sha256"]:
            errors.append("chart archive differs from reviewed identity")
        if args.index:
            entries = yaml.safe_load(args.index.read_text())["entries"]["gitlab"]
            entry = next(e for e in entries if e["version"] == "10.5.0")
            if entry["digest"].removeprefix("sha256:") != digest or entry["appVersion"] != "v19.5.0":
                errors.append("official index digest/application identity mismatch")
    if errors:
        for error in errors:
            print(error)
        return 1
    if args.write_values:
        release = yaml.safe_load((ROOT / "apps/gitlab-helm/helmrelease.yaml").read_text())
        args.write_values.write_text(yaml.safe_dump(release["spec"]["values"]))
    print("GitLab Helm inactive-preparation contract passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
