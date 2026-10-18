#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML==6.0.3"]
# ///
"""Local inactive-preparation contract, not production admission or integration proof."""
import argparse
import copy
import json
import tempfile
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
BACKUP_SCHEDULE = {"suspend": True, "schedule": "0 1 * * *", "timeZone": "Europe/London",
                   "concurrencyPolicy": "Forbid", "startingDeadlineSeconds": 1800,
                   "successfulJobsHistoryLimit": 2, "failedJobsHistoryLimit": 2}
BACKUP_RESOURCES = {"requests": {"cpu": "100m", "memory": "512Mi"}, "limits": {"memory": "2Gi"}}
DISABLED_BACKUP_TYPES = 'external_diffs,terraform_state,pages,ci_secure_files,agent_plan_content,ci_catalog_bundles'
NATIVE_BACKUP_ARGS = ['/bin/bash', '-c', 'test -f /etc/gitlab/.s3cfg && cp /etc/gitlab/.s3cfg $HOME/.s3cfg; backup-utility --skip ' + DISABLED_BACKUP_TYPES + ' --skip-cleanup']
SITE_BACKUP_ARGS = ['/bin/bash', '-c', 'test -f /etc/gitlab/.s3cfg && cp /etc/gitlab/.s3cfg $HOME/.s3cfg; exec python3 /backup-script/nas-export.py']
BACKUP_TARGET = {'group': 'batch', 'version': 'v1', 'kind': 'CronJob', 'name': '^gitlab-helm-toolbox-backup$', 'namespace': 'default'}
BACKUP_VOLUMES = [
    {'name': 'backup-recovery', 'persistentVolumeClaim': {'claimName': 'gitlab-helm-recovery-windsor'}},
    {'name': 'backup-script', 'configMap': {'name': 'gitlab-helm-native-backup', 'defaultMode': 292}},
]
BACKUP_MOUNTS = [{'name': 'backup-recovery', 'mountPath': '/recovery'},
                 {'name': 'backup-script', 'mountPath': '/backup-script', 'readOnly': True}]


HOOK_NAME = "gitlab-helm-gitlab-upgrade-check"
ADMISSION_IMAGE = "docker.io/library/postgres@sha256:9b18b78397054fce88a9552e9d5a3ad5bb7fd258c5b3cc1c5028e46373d6ea8f"
HOOK_TARGET = {"group": "batch", "version": "v1", "kind": "Job", "name": f"^{HOOK_NAME}$", "namespace": "default"}


def hook_jobs(docs):
    return [d for d in docs if d and d.get("apiVersion") == "batch/v1" and d.get("kind") == "Job"
            and d.get("metadata", {}).get("name") == HOOK_NAME and d["metadata"].get("namespace") == "default"]


def validate_hook_input(docs):
    hooks = hook_jobs(docs)
    if len(hooks) != 1:
        return [f"native upgrade target: expected exactly one, got {len(hooks)}"]
    hook = hooks[0]
    spec = hook["spec"]["template"]["spec"]
    containers = spec.get("containers", [])
    if len(containers) != 1 or containers[0].get("name") != "run-check":
        return ["native upgrade container shape changed"]
    if ([e.get("name") for e in containers[0].get("env", [])] != ["GITLAB_VERSION", "CHART_VERSION"]
            or containers[0].get("command") != ["/bin/sh", "/scripts/runcheck"]
            or spec.get("initContainers") or [v.get("name") for v in spec.get("volumes", [])] != ["chart-info", "scripts"]):
        return ["native upgrade env/init/volume/command shape changed"]
    errors = []
    if hook["metadata"].get("annotations", {}).get("helm.sh/hook") != "pre-upgrade":
        errors.append("native pre-upgrade annotation changed")
    if "fsGroup" in spec.get("securityContext", {}):
        errors.append("upgrade pod must not change NAS ownership via fsGroup")
    return errors


def backup_crons(docs):
    return [d for d in docs if d and d.get('apiVersion') == 'batch/v1' and d.get('kind') == 'CronJob'
            and d.get('metadata', {}).get('name') == 'gitlab-helm-toolbox-backup'
            and d['metadata'].get('namespace') == 'default']


def validate_backup_input(docs):
    crons = backup_crons(docs)
    if len(crons) != 1:
        return ['native backup target: expected exactly one']
    spec = crons[0]['spec']['jobTemplate']['spec']['template']['spec']
    containers = spec.get('containers', [])
    if (len(containers) != 1 or containers[0].get('name') != 'toolbox-backup'
            or containers[0].get('args') != NATIVE_BACKUP_ARGS
            or spec.get('securityContext', {}).get('fsGroup') != 1000):
        return ['native backup container/command/security shape changed']
    return []


def apply_postrender(docs, release, check_input=True):
    """Offline native Kustomize on the real Helm4 combined manifest/hook stream.

    This is CI's exact-match oracle, NOT a replacement runtime sequencer.
    Kustomize itself silently ignores unmatched targets; never accept that as a pass.
    """
    errors = validate_hook_input(docs) + validate_backup_input(docs) if check_input else []
    if errors:
        raise ValueError("; ".join(errors))
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "resources.yaml").write_text(yaml.safe_dump_all(docs))
        settings = release["spec"]["postRenderers"][0]["kustomize"]
        (root / "kustomization.yaml").write_text(yaml.safe_dump({
            "apiVersion": "kustomize.config.k8s.io/v1beta1", "kind": "Kustomization",
            "resources": ["resources.yaml"], **settings,
        }))
        return kustomize(root, ".")


def admission_settings(release):
    db = release["spec"]["values"]["global"]["psql"]
    ci = db["ci"]
    return {"PGHOST": str(db["host"]), "PGPORT": str(db["port"]), "PGDATABASE": db["database"], "PGUSER": db["username"],
            "CI_DB_HOST": str(ci.get("host", db["host"])), "CI_DB_PORT": str(ci.get("port", db["port"])),
            "CI_DB_NAME": ci["database"], "CI_DATABASE_TASKS": str(ci["databaseTasks"]).lower()}


def validate_postrender(before, after, release):
    errors = validate_hook_input(before)
    if errors or len(hook_jobs(after)) != 1:
        return errors + ["postrender must retain exactly one native upgrade Job"]
    old, new = hook_jobs(before)[0], hook_jobs(after)[0]
    spec = new["spec"]["template"]["spec"]
    inits = spec.get("initContainers", [])
    if len(inits) != 1 or inits[0].get("name") != "site-upgrade-admission":
        return ["exactly one site admission init required"]
    admission = inits[0]
    upstream_env = old["spec"]["template"]["spec"]["containers"][0]["env"]
    expected_env = upstream_env + [{"name": k, "value": v} for k, v in admission_settings(release).items()]
    expect(errors, admission, "env", expected_env)
    expect(errors, admission, "image", ADMISSION_IMAGE)
    expect(errors, admission, "command", ["/bin/bash", "/admission-script/upgrade-admission.sh"])
    expect(errors, admission, "securityContext", {"runAsNonRoot": True, "runAsUser": 1000, "runAsGroup": 1000,
           "allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}})
    expect(errors, spec, "automountServiceAccountToken", False)
    expected_mounts = [{"name": n, "mountPath": p, **({"readOnly": True} if ro else {})} for n, p, ro in (
        ("chart-info", "/chart-info", True), ("admission-script", "/admission-script", True),
        ("admission-db-password", "/db-secret", True), ("admission-recovery", "/recovery", False),
        ("admission-work", "/admission-work", False))]
    expect(errors, admission, "volumeMounts", expected_mounts)
    expected_volumes = [
        {"name": "admission-script", "configMap": {"name": "gitlab-helm-upgrade-admission", "defaultMode": 292}},
        {"name": "admission-db-password", "secret": {"secretName": "gitlab-secrets", "defaultMode": 292,
         "items": [{"key": "db_password", "path": "db_password"}]}},
        {"name": "admission-recovery", "persistentVolumeClaim": {"claimName": "gitlab-helm-recovery-windsor"}},
        {"name": "admission-work", "emptyDir": {"medium": "Memory", "sizeLimit": "16Mi"}},
    ]
    expect(errors, spec, "volumes", old["spec"]["template"]["spec"]["volumes"] + expected_volumes)
    restored = copy.deepcopy(new)
    restored_spec = restored["spec"]["template"]["spec"]
    restored_spec.pop("initContainers", None)
    restored_spec.pop("automountServiceAccountToken", None)
    restored_spec["volumes"] = restored_spec["volumes"][:2]
    if restored != old:
        errors.append("postrender changed upstream hook beyond admission extension")
    errors.extend(validate_backup_postrender(before, after))
    # All upstream scripts, chart-info, ordinary migrations/app resources and
    # weights/waits remain exactly as Helm rendered them (order is immaterial).
    def other_docs(ds):
        result = set()
        hooks = hook_jobs(ds) + backup_crons(ds)
        for doc in ds:
            if not doc or doc in hooks:
                continue
            doc = copy.deepcopy(doc)
            # Native Kustomize drops null metadata.annotations. Normalize ONLY
            # this observed non-semantic difference; do not scrub spec fields.
            if doc.get("metadata", {}).get("annotations", {}) is None:
                doc["metadata"].pop("annotations")
            result.add(json.dumps(doc, sort_keys=True))
        return result
    if len(before) != len(after) or other_docs(before) != other_docs(after):
        errors.append("postrender changed resources outside the native upgrade/backup targets")
    return errors


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
    expect(errors, release, "spec.postRenderStrategy", "combined")
    renderers = get(release, "spec.postRenderers") or []
    if len(renderers) != 1 or set(renderers[0]) != {"kustomize"}:
        errors.append("exactly one native Kustomize postrenderer required")
    else:
        patches = renderers[0]["kustomize"].get("patches", [])
        if len(patches) != 2 or patches[0].get("target") != HOOK_TARGET or patches[1].get("target") != BACKUP_TARGET:
            errors.append("exactly one targeted native upgrade and one native backup patch required")
        else:
            operations = yaml.safe_load(patches[0].get("patch", "")) or []
            if {"op": "copy", "from": "/spec/template/spec/containers/0/env", "path": "/spec/template/spec/initContainers/0/env"} not in operations:
                errors.append("target env must be copied from native run-check")
    values = get(release, "spec.values") or {}
    expect(errors, values, "upgradeCheck.securityContext", {"fsGroup": None})
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
        "registry.storage": {"secret": "gitlab-helm-registry-storage", "key": "config", "redirect": {"disable": True}},
        "gitlab.toolbox.backups.objectStorage.config": {"secret": "gitlab-helm-backup-config", "key": "config"},
        "global.appConfig.object_store.enabled": True, "global.appConfig.object_store.proxy_download": True,
        "global.registry.bucket": "gitlab-registry", "global.pages.enabled": False,
        "global.pages.objectStore.enabled": False,
        "global.appConfig.backups": {"bucket": "gitlab-backups", "tmpBucket": "gitlab-restore-scratch"},
    }.items():
        expect(errors, values, path, wanted)
    for name in ("artifacts", "lfs", "uploads", "packages"):
        expect(errors, values, f"global.appConfig.{name}.enabled", True)
        expect(errors, values, f"global.appConfig.{name}.bucket", f"gitlab-{name}")
    for name in ("externalDiffs", "terraformState", "dependencyProxy", "ciSecureFiles", "agentPlanContent", "ciCatalogBundles"):
        expect(errors, values, f"global.appConfig.{name}.enabled", False)
    for key, wanted in {**BACKUP_SCHEDULE, "enabled": True, "activeDeadlineSeconds": 10800,
                        "backoffLimit": 0, "restartPolicy": "Never", "extraArgs": '--skip ' + DISABLED_BACKUP_TYPES + ' --skip-cleanup',
                        "resources": BACKUP_RESOURCES,
                        "persistence": {"enabled": True, "storageClass": "local-path-retain", "size": "100Gi"}}.items():
        expect(errors, values, f"gitlab.toolbox.backups.cron.{key}", wanted)
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
    prepared = kustomize(root, "apps/gitlab-helm")
    pvc = next((d for d in prepared if d.get("kind") == "PersistentVolumeClaim" and d["metadata"]["name"] == "gitlab-helm-recovery-windsor"), {})
    expect(errors, pvc, "spec", {"storageClassName": "windsor-nfs-rwx", "accessModes": ["ReadWriteMany"],
           "resources": {"requests": {"storage": "100Gi"}}})
    if pvc.get("metadata", {}).get("annotations") != {"kustomize.toolkit.fluxcd.io/prune": "disabled", "helm.sh/resource-policy": "keep"}:
        errors.append("independent recovery PVC must be retained/prune-disabled")
    script = next((d for d in prepared if d.get("kind") == "ConfigMap" and d["metadata"]["name"] == "gitlab-helm-upgrade-admission"), {})
    expect(errors, script, "data", {"upgrade-admission.sh": (candidate / "files/upgrade-admission.sh").read_text()})
    exporter = next((d for d in prepared if d.get("kind") == "ConfigMap" and d["metadata"]["name"] == "gitlab-helm-native-backup"), {})
    expect(errors, exporter, "data", {"nas-export.py": (candidate / "files/nas-export.py").read_text()})
    exports = [d for d in prepared if d.get("kind") == "CronJob"]
    if exports:
        errors.append("no standalone export CronJob: publication belongs to native producer")
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


def validate_backup_postrender(before, after):
    errors = validate_backup_input(before)
    if errors or len(backup_crons(after)) != 1:
        return errors + ['postrender must retain exactly one native backup CronJob']
    old, new = backup_crons(before)[0], backup_crons(after)[0]
    spec = new['spec']['jobTemplate']['spec']['template']['spec']
    c = spec.get('containers', [{}])[0]
    original = old['spec']['jobTemplate']['spec']['template']['spec']
    expect(errors, c, 'args', SITE_BACKUP_ARGS)
    expect(errors, c, 'volumeMounts', original['containers'][0]['volumeMounts'] + BACKUP_MOUNTS)
    expect(errors, spec, 'volumes', original['volumes'] + BACKUP_VOLUMES)
    expect(errors, spec, 'automountServiceAccountToken', False)
    if 'fsGroup' in spec.get('securityContext', {}):
        errors.append('native backup must not repair NAS ownership via fsGroup')
    restored = copy.deepcopy(new)
    restored_spec = restored['spec']['jobTemplate']['spec']['template']['spec']
    restored_spec.pop('automountServiceAccountToken', None)
    restored_spec['securityContext']['fsGroup'] = 1000
    restored_spec['containers'][0]['args'] = NATIVE_BACKUP_ARGS
    restored_spec['containers'][0]['volumeMounts'] = restored_spec['containers'][0]['volumeMounts'][:-2]
    restored_spec['volumes'] = restored_spec['volumes'][:-2]
    if restored != old:
        errors.append('postrender changed native backup beyond producer publication extension')
    return errors


def validate_backup_render(docs, patched=False):
    errors = []
    crons = [d for d in docs if d.get("kind") == "CronJob"]
    if len(crons) != 1:
        return ["exactly one native Toolbox backup CronJob required"]
    cron = crons[0]
    expect(errors, cron, "metadata.name", "gitlab-helm-toolbox-backup")
    for key, wanted in BACKUP_SCHEDULE.items():
        expect(errors, cron, f"spec.{key}", wanted)
    job = get(cron, "spec.jobTemplate.spec") or {}
    expect(errors, job, "activeDeadlineSeconds", 10800)
    expect(errors, job, "backoffLimit", 0)
    spec = get(job, "template.spec") or {}
    expect(errors, spec, "restartPolicy", "Never")
    containers = spec.get("containers", [])
    if len(containers) != 1:
        return errors + ["native backup container shape changed"]
    c = containers[0]
    expect(errors, c, "name", "toolbox-backup")
    expect(errors, c, "image", "registry.gitlab.com/gitlab-org/build/cng/gitlab-toolbox-ce:v19.5.0")
    expect(errors, c, "resources", BACKUP_RESOURCES)
    expect(errors, c, "args", SITE_BACKUP_ARGS if patched else NATIVE_BACKUP_ARGS)
    env = {e["name"]: e.get("value") for e in c.get("env", [])}
    for name, bucket in {"ARTIFACTS": "gitlab-artifacts", "REGISTRY": "gitlab-registry", "LFS": "gitlab-lfs",
                         "UPLOADS": "gitlab-uploads", "PACKAGES": "gitlab-packages", "BACKUP": "gitlab-backups",
                         "TMP": "gitlab-restore-scratch"}.items():
        expect(errors, env, name + "_BUCKET_NAME", bucket)
    if not any(i["name"] == "configure" for i in spec.get("initContainers", [])):
        errors.append("native Toolbox configure init missing")
    tmp = next((v for v in spec.get("volumes", []) if v["name"] == "toolbox-tmp"), {})
    expect(errors, tmp, "persistentVolumeClaim.claimName", "gitlab-helm-toolbox-backup-tmp")
    pvc = next((d for d in docs if d.get("kind") == "PersistentVolumeClaim" and d["metadata"]["name"] == "gitlab-helm-toolbox-backup-tmp"), {})
    expect(errors, pvc, "spec.storageClassName", "local-path-retain")
    expect(errors, pvc, "spec.resources.requests.storage", "100Gi")
    return errors


def validate_render(docs, patched=False):
    errors = []
    docs = [d for d in docs if d]
    errors.extend(validate_backup_render(docs, patched))
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
    parser.add_argument("--write-postrender", type=Path)
    parser.add_argument("--write-values", type=Path)
    parser.add_argument("--check-archive", type=Path)
    parser.add_argument("--index", type=Path)
    args = parser.parse_args()
    errors = validate_source(ROOT)
    if args.rendered:
        docs = [d for d in yaml.safe_load_all(args.rendered.read_text()) if d]
        errors.extend(validate_render(docs))
        release = yaml.safe_load((ROOT / "apps/gitlab-helm/helmrelease.yaml").read_text())
        try:
            patched = apply_postrender(docs, release)
            errors.extend(validate_postrender(docs, patched, release))
            errors.extend(validate_render(patched, patched=True))
            if args.write_postrender and not errors:
                args.write_postrender.write_text(yaml.safe_dump_all(patched))
        except (ValueError, subprocess.CalledProcessError) as error:
            errors.append(f"native upgrade postrender rejected: {error}")
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
