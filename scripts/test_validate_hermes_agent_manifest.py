#!/usr/bin/env python3
"""Validate the minimal inactive Hermes Agent cutover preparation."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import NoReturn

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "apps/hermes-agent"
CUTOVER = ROOT / "scripts/hermes-agent-cutover.sh"
MIGRATION = ROOT / "scripts/hermes-agent-migration.sh"


def fail(message: str) -> NoReturn:
    raise AssertionError(message)


def require(text: str, needle: str, label: str) -> None:
    if needle not in text:
        fail(f"missing {label}: {needle!r}")


def ordered(text: str, needles: list[str], label: str) -> None:
    cursor = 0
    for needle in needles:
        cursor = text.find(needle, cursor)
        if cursor < 0:
            fail(f"incorrect {label} ordering: {needles!r}")
        cursor += len(needle)


def render() -> str:
    kustomize = shutil.which("kustomize")
    command = [kustomize, "build", str(APP)] if kustomize else ["kubectl", "kustomize", str(APP)]
    env = os.environ.copy()
    env["KUBECONFIG"] = "/dev/null"
    result = subprocess.run(command, text=True, capture_output=True, env=env, check=False)
    if result.returncode:
        fail(f"render failed: {result.stderr.strip()}")
    return result.stdout


def document(rendered: str, kind: str, name: str) -> str:
    matches = []
    for item in rendered.split("\n---\n"):
        if re.search(rf"^kind: {re.escape(kind)}$", item, re.MULTILINE) and re.search(
            rf"^  name: {re.escape(name)}$", item, re.MULTILINE
        ):
            matches.append(item)
    if len(matches) != 1:
        fail(f"expected one {kind}/{name}, found {len(matches)}")
    return matches[0]


def validate() -> None:
    rendered = render()
    deployment = document(rendered, "Deployment", "hermes-agent")
    pvc = document(rendered, "PersistentVolumeClaim", "hermes-agent-state")
    service = document(rendered, "Service", "hermes-agent")
    sources = "\n".join(path.read_text() for path in sorted(APP.glob("*.yaml")))

    require(deployment, "replicas: 0", "inactive replica count")
    require(deployment, "type: Recreate", "Recreate strategy")
    require(deployment, "kubernetes.io/hostname: hestia", "Hestia node selection")
    direct = "command:\n        - /opt/hermes/docker/entrypoint-dispatch.sh\n        - gateway\n        - run"
    require(deployment, direct, "direct gateway command")
    if deployment.count("httpGet:\n            path: /health\n            port: webhook") != 2:
        fail("readiness and liveness probes must use webhook /health")
    for baseline in (
        "automountServiceAccountToken: false",
        "allowPrivilegeEscalation: false",
        "readOnlyRootFilesystem: true",
        "type: RuntimeDefault",
        "claimName: hermes-agent-state",
        "mountPath: /opt/data",
    ):
        require(deployment, baseline, "baseline deployment setting")

    require(pvc, "storageClassName: local-path-retain", "retained storage class")
    require(pvc, "- ReadWriteOnce", "RWO PVC")
    require(pvc, "storage: 20Gi", "PVC size")
    storage_class = (ROOT / "infrastructure/storage/storage-classes/storageclass-local-path-retain.yaml").read_text()
    require(storage_class, "reclaimPolicy: Retain", "Retain reclaim policy")

    require(service, "type: ClusterIP", "ClusterIP service")
    expected_ports = {("api", "8642", "8642"), ("webhook", "8644", "8644")}
    ports = set(re.findall(r"- name: (\w+)\n    port: (\d+)\n    protocol: TCP\n    targetPort: (\d+)", service))
    if ports != expected_ports:
        fail(f"unexpected service ports: {ports!r}")
    if re.search(r"\b(NodePort|LoadBalancer|externalIPs|externalName):?\b", service):
        fail("Hermes Service has external exposure")

    kinds = re.findall(r"^kind: (\S+)$", rendered, re.MULTILINE)
    if set(kinds) != {"Deployment", "PersistentVolumeClaim", "Service"} or len(kinds) != 3:
        fail(f"unexpected rendered objects: {kinds!r}")
    if re.search(r"candidate|mode=(candidate|active)|hermes-agent-state-[a-z0-9]", sources):
        fail("candidate/active mode machinery remains")

    if not CUTOVER.is_file() or not os.access(CUTOVER, os.X_OK):
        fail("cutover script is missing or not executable")
    if MIGRATION.exists():
        fail("rejected migration script still exists")
    script = CUTOVER.read_text()
    for needle in (
        "/home/ben/.hermes",
        "/home/ben/.kube/config",
        "/var/lib/rancher/k3s/storage/",
        "persistentVolumeReclaimPolicy",
        "sudo -n rsync -aHAX --delete",
        "PRAGMA quick_check;",
        "10000:10000",
    ):
        require(script, needle, "cutover safety boundary")
    for pattern in (
        "/state.db.corrupt-*",
        "/state.db.malformed-*",
        "/state.db.rebuilt-*",
        "/state-db-cutover-*",
        "/repair_state_db_cutover.sh",
    ):
        require(script, f"--exclude='{pattern}'", "obsolete recovery exclusion")
    root_only = (
        "/.git/", "/node_modules/", "/source/", "/sources/", "/repo/", "/repos/",
        "/repositories/", "/checkout/", "/checkouts/", "/hermes-agent/", "/hermes-agent-*/",
    )
    for pattern in root_only:
        require(script, f"--exclude='{pattern}'", "root-anchored source exclusion")
    if "--exclude='hermes-agent/'" in script:
        fail("unanchored hermes-agent exclusion can discard nested durable state")
    main = script[script.find("  cutover)") :]
    ordered(main, ["systemctl --user stop", "source_inactive", "copy_state", "reconcile apps", "kubectl rollout status", "reconcile observability-ui", "get service hermes-webhook", '"http://$cluster_ip:8644/health"', "reconcile cluster-state"], "cutover")
    ordered(script, ["ACTIVATION_ATTEMPTED=false", "  cutover)", "ACTIVATION_ATTEMPTED=true\n    reconcile apps"], "activation flag")
    rollback = re.search(r"^rollback\(\) \{(?P<body>.*?)^\}", script, re.MULTILINE | re.DOTALL)
    if rollback is None:
        fail("rollback function is missing")
    body = rollback.group("body")
    ordered(body, ["suspend apps", "scale deployment", "wait_for_zero", "systemctl --user start"], "target-first rollback")
    require(body, 'if [[ "$ACTIVATION_ATTEMPTED" == false ]]; then\n        if systemctl --user start', "pre-activation-only source restart")
    if body.count("systemctl --user start") != 1:
        fail("source restart must have exactly one pre-activation path")

    ci = (ROOT / ".gitlab-ci.yml").read_text()
    if ci.count("scripts/hermes-agent-cutover.sh") != 2 or ci.count("scripts/test_validate_hermes_agent_manifest.py") != 2:
        fail("both manifest CI change lists must retain Hermes validation triggers")
    if "scripts/hermes-agent-migration.sh" in ci:
        fail("migration script remains in CI change lists")


if __name__ == "__main__":
    try:
        validate()
    except (AssertionError, OSError) as error:
        print(f"Hermes Agent validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
    print("Hermes Agent manifest and cutover validation passed")
