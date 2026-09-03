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
from typing import Any, cast

import yaml

ROOT = Path(__file__).resolve().parent.parent
GC_IMAGE = (
    "quay.io/podman/stable@"
    "sha256:c6c3feef40a5c825a98e62a11c8ed4c36ec603327d56eb629230a671e527c3dd"
)
GC_HOST_PATH = "/var/lib/ci-containers-nocow/storage"
GC_MOUNT_PATH = "/var/lib/containers/storage"
GC_TMPDIR = "/tmp"
GC_RUN_LOCK_PATH = "/run/lock"
GC_SHM_PATH = "/dev/shm"
SA_TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
SA_CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
JOB_LABEL = "ci.brmartin.co.uk/job"
MAINTENANCE_LABEL = "ci.brmartin.co.uk/maintenance"
FORBIDDEN_HOST_PATHS = (
    "/var/lib/ci-cache-nocow",
    "/var/lib/ci-builds-nocow",
    "/var/lib/rancher/k3s",
    "/var/lib/containerd",
)
GC_SCRIPT = f'''set -euo pipefail

api="https://${{KUBERNETES_SERVICE_HOST:?Kubernetes API host is unavailable}}:${{KUBERNETES_SERVICE_PORT_HTTPS:?Kubernetes API port is unavailable}}"
token={SA_TOKEN_PATH}
ca={SA_CA_PATH}
[ -r "$token" ] && [ -r "$ca" ]
[ "${{NODE_NAME:?Pod node identity is unavailable}}" = hestia ]
[ -n "${{POD_UID:?Pod UID is unavailable}}" ]

curl --fail --silent --show-error \\
  --cacert "$ca" \\
  --header "Authorization: Bearer $(cat "$token")" \\
  --output /tmp/pods.json \\
  "$api/api/v1/namespaces/ci/pods?limit=500"

python3 - <<'PY'
import json
import os

with open("/tmp/pods.json", "rb") as stream:
    payload = json.load(stream)
if type(payload) is not dict or type(payload.get("items")) is not list:
    raise SystemExit("Kubernetes API pod list has an invalid shape; refusing cleanup")
metadata = payload.get("metadata")
if type(metadata) is not dict or metadata.get("continue", "") != "":
    raise SystemExit("Kubernetes API pod list is incomplete; refusing cleanup")
self_uid = os.environ["POD_UID"]
self_seen = False
active = []
for pod in payload["items"]:
    if type(pod) is not dict:
        raise SystemExit("Kubernetes API pod list contains an invalid item; refusing cleanup")
    pod_metadata = pod.get("metadata")
    pod_spec = pod.get("spec")
    status = pod.get("status")
    if type(pod_metadata) is not dict or type(pod_spec) is not dict or type(status) is not dict:
        raise SystemExit("Kubernetes API pod list contains incomplete identity; refusing cleanup")
    uid = pod_metadata.get("uid")
    name = pod_metadata.get("name")
    labels = pod_metadata.get("labels")
    phase = status.get("phase")
    node = pod_spec.get("nodeName", "")
    if type(uid) is not str or type(name) is not str or type(labels) is not dict or type(phase) is not str or type(node) is not str:
        raise SystemExit("Kubernetes API pod list contains invalid identity types; refusing cleanup")
    if uid == self_uid:
        if self_seen or labels.get("{MAINTENANCE_LABEL}") != "true" or labels.get("{JOB_LABEL}") != "true" or phase != "Running" or node != "hestia":
            raise SystemExit("maintenance Pod identity is inconsistent; refusing cleanup")
        self_seen = True
        continue
    if labels.get("{JOB_LABEL}") == "true" and phase in {{"Running", "Pending"}}:
        active.append(f"ci/{{name}} ({{phase}}, node={{node or 'unscheduled'}})")
if not self_seen:
    raise SystemExit("maintenance Pod is absent from the Kubernetes API snapshot; refusing cleanup")
if active:
    raise SystemExit("active GitLab job pod(s) block cleanup: " + ", ".join(sorted(active)))
print("Kubernetes API gate passed: scheduler lock is present and no other Running or Pending CI job Pods exist")
PY

podman_store=(
  podman
  --tmpdir=/tmp/libpod
  --root={GC_MOUNT_PATH}
  --runroot=/run/containers/storage
  --storage-driver=overlay
)
"${{podman_store[@]}}" container prune --force --filter until=168h
"${{podman_store[@]}}" ps -a --external --filter until=168h --format json > /tmp/external-containers.json
python3 - <<'PY' > /tmp/external-container-ids
import json
import re
import time

with open("/tmp/external-containers.json", "rb") as stream:
    containers = json.load(stream)
if type(containers) is not list:
    raise SystemExit("Podman external-container list has an invalid shape; refusing cleanup")
cutoff = int(time.time()) - 168 * 60 * 60
for container in containers:
    if type(container) is not dict:
        raise SystemExit("Podman external-container list has an invalid item; refusing cleanup")
    container_id = container.get("Id")
    created = container.get("Created")
    if type(container_id) is not str or re.fullmatch(r"[0-9a-f]{{64}}", container_id) is None or type(created) is not int:
        raise SystemExit("Podman external-container identity is invalid; refusing cleanup")
    if created > cutoff:
        raise SystemExit("Podman returned a recent external container through the 168h filter; refusing cleanup")
    print(container_id)
PY
mapfile -t stale_external_ids < /tmp/external-container-ids
if (( ${{#stale_external_ids[@]}} )); then
  "${{podman_store[@]}}" rm --force "${{stale_external_ids[@]}}"
fi
"${{podman_store[@]}}" image prune --all --force --filter until=168h
'''

ALERT_EXPR = '''
(
  label_replace(
    min by(instance) (
      (
        node_filesystem_avail_bytes{job="kubernetes-service-endpoints",app_kubernetes_io_name="node-exporter",mountpoint="/srv/noisy",fstype="xfs"}
        /
        node_filesystem_size_bytes{job="kubernetes-service-endpoints",app_kubernetes_io_name="node-exporter",mountpoint="/srv/noisy",fstype="xfs"}
      ) * 100
    ),
    "internal_ip", "$1", "instance", "(.*):.*"
  )
  * on(internal_ip) group_left(node)
    max by(internal_ip, node) (kube_node_info{node="hestia"})
)
or
(
  label_replace(
    0 * max by(internal_ip, node) (kube_node_info{node="hestia"}),
    "instance", "$1:9100", "internal_ip", "(.*)"
  )
  unless on(node)
  (
    label_replace(
      min by(instance) (
        (
          node_filesystem_avail_bytes{job="kubernetes-service-endpoints",app_kubernetes_io_name="node-exporter",mountpoint="/srv/noisy",fstype="xfs"}
          /
          node_filesystem_size_bytes{job="kubernetes-service-endpoints",app_kubernetes_io_name="node-exporter",mountpoint="/srv/noisy",fstype="xfs"}
        ) * 100
      ),
      "internal_ip", "$1", "instance", "(.*):.*"
    )
    * on(internal_ip) group_left(node)
      max by(internal_ip, node) (kube_node_info{node="hestia"})
  )
)
'''
ALERT_DESCRIPTION = (
    "The canonical node-exporter service-endpoint series reports "
    "{{ $values.A.Value }}% available on {{ $values.A.Labels.node }} "
    "{{ $values.A.Labels.instance }} for /srv/noisy, or the expected series is "
    "missing and represented as 0%. Investigate the Hestia CI Podman store; "
    "do not delete CI cache/build data or k3s/containerd state."
)
ALERT_SUMMARY = "Hestia /srv/noisy is below 15% available or its canonical metric is missing"


def normalized(value: Any) -> str:
    return " ".join(value.split()) if type(value) is str else ""


def strict_equal(actual: Any, expected: Any) -> bool:
    if type(actual) is not type(expected):
        return False
    if type(expected) is dict:
        return actual.keys() == expected.keys() and all(
            strict_equal(actual[key], expected_value)
            for key, expected_value in expected.items()
        )
    if type(expected) is list:
        return len(actual) == len(expected) and all(
            strict_equal(a, e) for a, e in zip(actual, expected, strict=True)
        )
    return actual == expected


class Checks:
    def __init__(self) -> None:
        self.errors: list[str] = []

    def equal(self, actual: Any, expected: Any, path: str) -> None:
        if not strict_equal(actual, expected):
            self.errors.append(f"{path}: expected {expected!r}, got {actual!r}")

    def true(self, condition: bool, message: str) -> None:
        if not condition:
            self.errors.append(message)

    def one(self, resources: list[dict[str, Any]], kind: str, name: str) -> dict[str, Any]:
        matches = [
            resource for resource in resources
            if resource.get("kind") == kind
            and resource.get("metadata", {}).get("name") == name
        ]
        if len(matches) != 1:
            self.errors.append(f"expected exactly one {kind}/{name}, got {len(matches)}")
            return {}
        return matches[0]


def render(root: Path, relative: str) -> list[dict[str, Any]]:
    executable = shutil.which("kustomize")
    command = [executable, "build", relative] if executable else ["kubectl", "kustomize", relative]
    result = subprocess.run(command, cwd=root, capture_output=True, text=True, check=False)
    if result.returncode:
        raise ValueError(f"render {relative}: {result.stderr.strip()}")
    return [document for document in yaml.safe_load_all(result.stdout) if type(document) is dict]


def pod_spec(cronjob: dict[str, Any]) -> dict[str, Any]:
    return cronjob.get("spec", {}).get("jobTemplate", {}).get("spec", {}).get("template", {}).get("spec", {})


def validate_gc(resources: list[dict[str, Any]], checks: Checks) -> None:
    cronjob = checks.one(resources, "CronJob", "hestia-ci-store-gc")
    service_account = checks.one(resources, "ServiceAccount", "hestia-ci-store-gc")
    role = checks.one(resources, "Role", "hestia-ci-store-gc")
    binding = checks.one(resources, "RoleBinding", "hestia-ci-store-gc")
    checks.true(
        not any(r.get("kind") in {"ClusterRole", "ClusterRoleBinding"} and r.get("metadata", {}).get("name") == "hestia-ci-store-gc" for r in resources),
        "GC must not receive cluster-scoped RBAC",
    )
    if not cronjob:
        return

    checks.equal(cronjob.get("metadata", {}).get("namespace"), "ci", "CronJob namespace")
    spec = cronjob.get("spec", {})
    checks.equal(spec.get("schedule"), "17 4 * * *", "CronJob schedule")
    checks.equal(spec.get("concurrencyPolicy"), "Forbid", "CronJob concurrencyPolicy")
    checks.equal(spec.get("startingDeadlineSeconds"), 1800, "CronJob startingDeadlineSeconds")
    checks.equal(spec.get("successfulJobsHistoryLimit"), 1, "CronJob successfulJobsHistoryLimit")
    checks.equal(spec.get("failedJobsHistoryLimit"), 3, "CronJob failedJobsHistoryLimit")
    checks.equal(spec.get("suspend"), False, "CronJob suspend")
    job_spec = spec.get("jobTemplate", {}).get("spec", {})
    checks.equal(job_spec.get("backoffLimit"), 0, "CronJob backoffLimit")
    checks.equal(job_spec.get("activeDeadlineSeconds"), 1800, "CronJob activeDeadlineSeconds")
    template = job_spec.get("template", {})
    checks.equal(
        template.get("metadata", {}).get("labels"),
        {"app": "hestia-ci-store-gc", JOB_LABEL: "true", MAINTENANCE_LABEL: "true"},
        "GC Pod labels",
    )
    pod = pod_spec(cronjob)
    checks.equal(pod.get("serviceAccountName"), "hestia-ci-store-gc", "GC serviceAccountName")
    checks.equal(pod.get("automountServiceAccountToken"), True, "GC automountServiceAccountToken")
    checks.equal(pod.get("nodeSelector"), {"kubernetes.io/arch": "amd64", "kubernetes.io/hostname": "hestia"}, "GC nodeSelector")
    checks.equal(pod.get("restartPolicy"), "Never", "GC restartPolicy")
    checks.equal(pod.get("enableServiceLinks"), True, "GC enableServiceLinks")
    checks.equal(
        pod.get("affinity"),
        {"podAntiAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": [{"labelSelector": {"matchLabels": {JOB_LABEL: "true"}}, "topologyKey": "kubernetes.io/hostname"}]}},
        "GC scheduler exclusion",
    )

    containers = pod.get("containers")
    checks.true(type(containers) is list and len(containers) == 1, "GC must have exactly one container")
    if type(containers) is not list or len(containers) != 1:
        return
    container = containers[0]
    checks.equal(container.get("name"), "podman-gc", "GC container name")
    checks.equal(container.get("image"), GC_IMAGE, "GC image")
    checks.equal(container.get("imagePullPolicy"), "IfNotPresent", "GC imagePullPolicy")
    checks.equal(container.get("command"), ["/bin/bash", "-ceu", "--"], "GC command")
    checks.equal(container.get("args"), [GC_SCRIPT], "GC script")
    arguments = container.get("args")
    actual_script = arguments[0] if type(arguments) is list and len(arguments) == 1 and type(arguments[0]) is str else ""
    checks.equal(
        container.get("env"),
        [
            {"name": "NODE_NAME", "valueFrom": {"fieldRef": {"fieldPath": "spec.nodeName"}}},
            {"name": "POD_UID", "valueFrom": {"fieldRef": {"fieldPath": "metadata.uid"}}},
            {"name": "TMPDIR", "value": GC_TMPDIR},
        ],
        "GC container environment",
    )
    checks.true("--filter until=168h" in actual_script, "GC operations must be age-bounded at 168h")
    checks.true('"${podman_store[@]}" rm --force "${stale_external_ids[@]}"' in actual_script, "GC must remove stale external containers through Podman's documented force path")
    checks.true("image prune --all --force" in actual_script, "GC must prune unused images through Podman")
    checks.true("/api/v1/namespaces/ci/pods?limit=500" in actual_script, "GC must use the namespace-scoped Kubernetes API gate")
    checks.true("recent external container through the 168h filter" in actual_script, "GC must independently reject recent external containers")
    checks.true(
        not re.search(
            r"(?:^|\n)\s*(?:sudo\s+)?(?:rm\s+(?:-[^\n ]*r[^\n ]*|--recursive)|unlink\b|rmdir\b|find[^\n]+-delete)",
            actual_script,
        ),
        "GC must not raw-delete storage",
    )
    for forbidden in FORBIDDEN_HOST_PATHS:
        checks.true(forbidden not in actual_script, f"GC script must not reference {forbidden}")
    checks.equal(
        container.get("securityContext"),
        {"allowPrivilegeEscalation": True, "privileged": True, "readOnlyRootFilesystem": True, "runAsGroup": 0, "runAsNonRoot": False, "runAsUser": 0},
        "GC securityContext",
    )
    checks.equal(
        container.get("resources"),
        {"requests": {"cpu": "10m", "memory": "64Mi"}, "limits": {"cpu": "500m", "memory": "512Mi"}},
        "GC resources",
    )
    checks.equal(
        container.get("volumeMounts"),
        [
            {"mountPath": GC_MOUNT_PATH, "name": "podman-storage"},
            {"mountPath": "/run/containers", "name": "run"},
            {"mountPath": GC_RUN_LOCK_PATH, "name": "run-lock"},
            {"mountPath": "/tmp", "name": "tmp"},
            {"mountPath": GC_SHM_PATH, "name": "dev-shm"},
        ],
        "GC volumeMounts",
    )
    checks.equal(
        pod.get("volumes"),
        [
            {"hostPath": {"path": GC_HOST_PATH, "type": "Directory"}, "name": "podman-storage"},
            {"emptyDir": {}, "name": "run"},
            {"emptyDir": {"medium": "Memory"}, "name": "run-lock"},
            {"emptyDir": {}, "name": "tmp"},
            {"emptyDir": {"medium": "Memory", "sizeLimit": "64Mi"}, "name": "dev-shm"},
        ],
        "GC volumes",
    )
    checks.equal(service_account.get("metadata", {}).get("namespace"), "ci", "GC ServiceAccount namespace")
    checks.equal(service_account.get("automountServiceAccountToken"), True, "GC ServiceAccount token policy")
    checks.equal(role.get("metadata", {}).get("namespace"), "ci", "GC Role namespace")
    checks.equal(role.get("rules"), [{"apiGroups": [""], "resources": ["pods"], "verbs": ["list"]}], "GC Role rules")
    checks.equal(binding.get("metadata", {}).get("namespace"), "ci", "GC RoleBinding namespace")
    checks.equal(binding.get("roleRef"), {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": "hestia-ci-store-gc"}, "GC RoleBinding roleRef")
    checks.equal(binding.get("subjects"), [{"kind": "ServiceAccount", "name": "hestia-ci-store-gc", "namespace": "ci"}], "GC RoleBinding subjects")


def validate_alert(document: dict[str, Any], checks: Checks) -> None:
    rules = [
        rule
        for group in document.get("groups", []) if type(group) is dict
        for rule in group.get("rules", []) if type(rule) is dict
        if rule.get("uid") == "hestia-noisy-disk-space-low-api"
    ]
    if len(rules) != 1:
        checks.errors.append(f"expected exactly one hestia-noisy-disk-space-low-api alert, got {len(rules)}")
        return
    rule = rules[0]
    checks.equal(rule.get("title"), "Hestia Noisy Disk Space Low", "alert title")
    checks.equal(rule.get("condition"), "C", "alert condition")
    checks.equal(rule.get("noDataState"), "Alerting", "alert noDataState")
    checks.equal(rule.get("execErrState"), "OK", "alert execErrState")
    checks.equal(rule.get("for"), "5m", "alert for")
    checks.equal(rule.get("labels"), {"severity": "critical"}, "alert labels")
    checks.equal(rule.get("isPaused"), False, "alert isPaused")
    checks.equal(rule.get("annotations"), {"description": ALERT_DESCRIPTION, "summary": ALERT_SUMMARY}, "alert annotations")
    data = rule.get("data")
    valid = type(data) is list and len(data) == 2 and all(type(item) is dict for item in data) and [item.get("refId") for item in data] == ["A", "C"]
    checks.true(valid, "alert data must contain exactly A and C")
    if not valid:
        return
    query, threshold = cast(list[dict[str, Any]], data)
    expression = query.get("model", {}).get("expr")
    checks.equal(normalized(expression), normalized(ALERT_EXPR), "alert PromQL")
    if type(expression) is str:
        checks.equal(expression.count('mountpoint="/srv/noisy"'), 4, "alert canonical mount selector count")
        checks.equal(expression.count('fstype="xfs"'), 4, "alert filesystem type selector count")
        checks.equal(expression.count("min by(instance)"), 2, "alert scrape-series deduplication count")
        checks.equal(expression.count("max by(internal_ip, node)"), 3, "alert node-series deduplication count")
        checks.equal(expression.count("unless on(node)"), 1, "alert missing-series fallback count")
        checks.true('mountpoint="/"' not in expression and "kubernetes-pods" not in expression, "alert must not admit root, pod, or bind-mount series")
    conditions = threshold.get("model", {}).get("conditions")
    checks.equal(conditions, [{"evaluator": {"params": [15], "type": "lt"}}], "alert threshold conditions")
    checks.equal(threshold.get("model", {}).get("expression"), "A", "alert threshold expression")
    checks.equal(threshold.get("model", {}).get("type"), "threshold", "alert threshold type")


def validate_wiring(root: Path, checks: Checks) -> None:
    wrapper = (root / "scripts/validate_kustomize.sh").read_text()
    gitlab_ci = (root / ".gitlab-ci.yml").read_text()
    runner_affinity = (root / "infrastructure/shared-services/gitlab-runner/runner-base/fragments/70-pod-labels-affinity.toml").read_text()
    validator_call = 'uv --no-config run --locked --script "${repo_root}/scripts/validate_hestia_ci_store_gc_alert.py"'
    test_call = 'uv --no-config run --locked --script "${repo_root}/scripts/test_validate_hestia_ci_store_gc_alert.py"'
    checks.equal(wrapper.count(validator_call), 1, "validate_kustomize GC/alert validator call count")
    checks.equal(wrapper.count(test_call), 1, "validate_kustomize GC/alert test call count")
    ci_lines = [line.strip() for line in gitlab_ci.splitlines()]
    checks.equal(ci_lines.count("- scripts/validate_hestia_ci_store_gc_alert.py"), 2, "GitLab CI GC/alert validator change-rule count")
    checks.equal(ci_lines.count("- scripts/validate_hestia_ci_store_gc_alert.py.lock"), 2, "GitLab CI GC/alert validator lock change-rule count")
    checks.equal(ci_lines.count("- scripts/test_validate_hestia_ci_store_gc_alert.py"), 2, "GitLab CI GC/alert test change-rule count")
    checks.equal(ci_lines.count("- scripts/test_validate_hestia_ci_store_gc_alert.py.lock"), 2, "GitLab CI GC/alert test lock change-rule count")
    checks.equal(runner_affinity.count(f'"{JOB_LABEL}" = "true"'), 2, "runner job label/scheduler-lock count")
    checks.true('topology_key = "kubernetes.io/hostname"' in runner_affinity, "runner jobs must retain hostname scheduler exclusion")


def validate(root: Path) -> list[str]:
    checks = Checks()
    try:
        resources = render(root, "infrastructure/shared-services")
    except (ValueError, yaml.YAMLError) as exc:
        checks.errors.append(str(exc))
        resources = []
    validate_gc(resources, checks)
    try:
        document = yaml.safe_load((root / "infrastructure/observability-ui/grafana/_grafana_alert_rules.yaml").read_text())
    except (OSError, yaml.YAMLError) as exc:
        checks.errors.append(f"read Grafana alert rules: {exc}")
    else:
        if type(document) is not dict:
            checks.errors.append("Grafana alert rules must be a mapping")
        else:
            validate_alert(document, checks)
    try:
        validate_wiring(root, checks)
    except OSError as exc:
        checks.errors.append(f"read validation wiring: {exc}")
    return checks.errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    args = parser.parse_args()
    errors = validate(args.repo_root.resolve())
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("Hestia CI store GC and /srv/noisy alert validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
