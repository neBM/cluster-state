#!/usr/bin/env python3
from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VALIDATOR = ROOT / "scripts/validate_temporal_manifest.py"


def run(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "uv",
            "--no-config",
            "run",
            "--locked",
            "--script",
            str(VALIDATOR),
            "--repo-root",
            str(root),
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    if text.count(old) != 1:
        raise AssertionError(f"{path}: expected exactly one mutation target {old!r}")
    path.write_text(text.replace(old, new, 1))


def fixture(parent: Path, name: str) -> Path:
    root = parent / name
    shutil.copytree(ROOT / "apps", root / "apps")
    shutil.copytree(ROOT / "infrastructure/platform", root / "infrastructure/platform")
    target = root / "clusters/k3s-homelab/flux-system"
    target.mkdir(parents=True)
    for path in (ROOT / "clusters/k3s-homelab/flux-system").glob("kustomization*.yaml"):
        shutil.copy2(path, target / path.name)
    return root


def cilium_prerequisite_mutation(
    parent: Path, name: str, relative: str, old: str, new: str, expected: str
) -> None:
    root = fixture(parent, name)
    prerequisite = root / "infrastructure/platform/cilium-node-selector-labels.yaml"
    if not prerequisite.exists():
        prerequisite.write_text(
            """apiVersion: cilium.io/v2
kind: CiliumNodeConfig
metadata:
  name: node-selector-labels
  namespace: kube-system
spec:
  nodeSelector: {}
  defaults:
    enable-node-selector-labels: \"true\"
    node-labels: kubernetes.io/hostname
"""
        )
        kustomization = root / "infrastructure/platform/kustomization.yaml"
        kustomization.write_text(kustomization.read_text() + "- cilium-node-selector-labels.yaml\n")
    replace_once(root / relative, old, new)
    result = run(root)
    combined = result.stdout + result.stderr
    if result.returncode == 0:
        raise AssertionError(f"{name}: mutation was accepted")
    if expected not in combined:
        raise AssertionError(f"{name}: expected {expected!r}, got:\n{combined}")
    print(f"PASS mutation {name}")


def cilium_global_config_mutation(parent: Path) -> None:
    root = fixture(parent, "cilium-global-node-selector-prerequisite-omitted")
    config = root / "infrastructure/platform/cilium-config.yaml"
    kustomization = root / "infrastructure/platform/kustomization.yaml"
    config.unlink()
    replace_once(kustomization, "- cilium-config.yaml\n", "")
    result = run(root)
    combined = result.stdout + result.stderr
    if result.returncode == 0:
        raise AssertionError("cilium-global-node-selector-prerequisite-omitted: mutation was accepted")
    if "expected one merged kube-system ConfigMap/cilium-config prerequisite" not in combined:
        raise AssertionError(
            "cilium-global-node-selector-prerequisite-omitted: expected global prerequisite error, got:\n"
            f"{combined}"
        )
    print("PASS mutation cilium-global-node-selector-prerequisite-omitted")


def ineffective_cluster_dns_pattern_mutation(parent: Path) -> None:
    root = fixture(parent, "ineffective-cluster-dns-pattern")
    policy = root / "apps/temporal/server/ciliumnetworkpolicy.yaml"
    replace_once(
        policy,
        'matchPattern: "*.*.svc.cluster.local"',
        'matchPattern: "*.cluster.local"',
    )
    result = run(root)
    combined = result.stdout + result.stderr
    if result.returncode == 0:
        raise AssertionError("ineffective-cluster-dns-pattern: mutation was accepted")
    if "DNS egress must allow exactly Kubernetes service FQDNs" not in combined:
        raise AssertionError(f"ineffective-cluster-dns-pattern: expected exact DNS error, got:\n{combined}")
    print("PASS mutation ineffective-cluster-dns-pattern")


def mutation(parent: Path, name: str, relative: str, old: str, new: str, expected: str) -> None:
    root = fixture(parent, name)
    replace_once(root / relative, old, new)
    result = run(root)
    combined = result.stdout + result.stderr
    if result.returncode == 0:
        raise AssertionError(f"{name}: mutation was accepted")
    if expected not in combined:
        raise AssertionError(f"{name}: expected {expected!r}, got:\n{combined}")
    print(f"PASS mutation {name}")


def main() -> int:
    baseline = run(ROOT)
    combined = baseline.stdout + baseline.stderr
    if not (ROOT / "apps/temporal").exists():
        if baseline.returncode == 0 or "apps/temporal desired state is missing" not in combined:
            print(combined, file=sys.stderr)
            return 2
        print("AUTHENTIC RED: Temporal desired state is missing", file=sys.stderr)
        return 1
    if baseline.returncode:
        print(combined, file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="temporal-mutations-") as temp:
        parent = Path(temp)
        cilium_global_config_mutation(parent)
        ineffective_cluster_dns_pattern_mutation(parent)
        mutation(
            parent,
            "cilium-global-node-selector-prerequisite-disabled",
            "infrastructure/platform/cilium-config.yaml",
            'enable-node-selector-labels: "true"',
            'enable-node-selector-labels: "false"',
            "Cilium global node-selector-label prerequisite must be enabled",
        )
        mutation(
            parent,
            "cilium-global-node-identity-labels-broadened",
            "infrastructure/platform/cilium-config.yaml",
            "node-labels: kubernetes.io/hostname",
            "node-labels: kubernetes.io/hostname,node-role.kubernetes.io/control-plane",
            "hostname-only identities",
        )
        mutation(
            parent,
            "cilium-global-config-merge-ownership-removed",
            "infrastructure/platform/cilium-config.yaml",
            "    kustomize.toolkit.fluxcd.io/ssa: Merge\n",
            "",
            "Cilium global configuration must use non-pruning Flux SSA merge ownership",
        )
        mutation(
            parent,
            "cilium-global-config-prune-protection-removed",
            "infrastructure/platform/cilium-config.yaml",
            "    kustomize.toolkit.fluxcd.io/prune: Disabled\n",
            "",
            "Cilium global configuration must use non-pruning Flux SSA merge ownership",
        )
        cilium_prerequisite_mutation(
            parent,
            "cilium-node-selector-prerequisite-disabled",
            "infrastructure/platform/cilium-node-selector-labels.yaml",
            'enable-node-selector-labels: "true"',
            'enable-node-selector-labels: "false"',
            "Cilium node-selector-label prerequisite must be enabled",
        )
        cilium_prerequisite_mutation(
            parent,
            "cilium-node-identity-labels-broadened",
            "infrastructure/platform/cilium-node-selector-labels.yaml",
            "node-labels: kubernetes.io/hostname",
            "node-labels: kubernetes.io/hostname,node-role.kubernetes.io/control-plane",
            "hostname-only identities",
        )
        cilium_prerequisite_mutation(
            parent,
            "cilium-node-selector-prerequisite-omitted",
            "infrastructure/platform/kustomization.yaml",
            "- cilium-node-selector-labels.yaml\n",
            "",
            "expected one kube-system CiliumNodeConfig/node-selector-labels prerequisite",
        )
        cilium_prerequisite_mutation(
            parent,
            "cilium-node-selector-prerequisite-narrowed",
            "infrastructure/platform/cilium-node-selector-labels.yaml",
            "  nodeSelector: {}\n",
            "  nodeSelector:\n    matchLabels:\n      kubernetes.io/hostname: hestia\n",
            "must select every cluster node",
        )
        cilium_prerequisite_mutation(
            parent,
            "temporal-platform-prerequisite-dependency-omitted",
            "clusters/k3s-homelab/flux-system/kustomization-temporal.yaml",
            "  - name: platform\n",
            "",
            "unsafe path/dependency ordering",
        )
        mutation(
            parent,
            "mutable-server-tag",
            "apps/temporal/server/deployments.yaml",
            "name: temporal-frontend\n        image: &server-image temporalio/server@sha256:b5ecdb8282bededae2a10c36e8d862e27d0bc2d247fc73c5416025997ab4a1da",
            "name: temporal-frontend\n        image: temporalio/server:1.31.2",
            "server digest mismatch",
        )
        mutation(
            parent,
            "history-shard-drift",
            "apps/temporal/server/configmap.yaml",
            "numHistoryShards: 128",
            "numHistoryShards: 512",
            "numHistoryShards: 128",
        )
        mutation(
            parent,
            "sprig-templating-disabled",
            "apps/temporal/server/configmap.yaml",
            "  config_template.yaml: |-\n    # enable-template\n",
            "  config_template.yaml: |-\n",
            "must explicitly enable Temporal 1.31 sprig templating",
        )
        mutation(
            parent,
            "postgres-pool-budget-broadened",
            "apps/temporal/server/configmap.yaml",
            "maxConns: 2",
            "maxConns: 20",
            "must remain within the 24-connection Temporal budget",
        )
        mutation(
            parent,
            "unauthenticated-server-admission-reintroduced",
            "apps/temporal/server/deployments.yaml",
            "        - name: TEMPORAL_SERVER_CONFIG_FILE_PATH\n          value: /etc/temporal/config/config_template.yaml\n",
            "        - name: TEMPORAL_SERVER_CONFIG_FILE_PATH\n          value: /etc/temporal/config/config_template.yaml\n        - name: TEMPORAL_ALLOW_NO_AUTH\n          value: \"true\"\n",
            "must not opt into unauthenticated server admission",
        )
        mutation(
            parent,
            "frontend-mtls-client-auth-disabled",
            "apps/temporal/server/configmap.yaml",
            "requireClientAuth: true",
            "requireClientAuth: false",
            "frontend mTLS client authentication must be required",
        )
        mutation(
            parent,
            "frontend-mtls-client-ca-removed",
            "apps/temporal/server/configmap.yaml",
            "            clientCaFiles:\n            - /etc/temporal/frontend-mtls/ca.crt\n",
            "",
            "frontend mTLS client CA trust is missing",
        )
        mutation(
            parent,
            "system-worker-mtls-identity-removed",
            "apps/temporal/server/configmap.yaml",
            "          certFile: /etc/temporal/frontend-mtls/system-worker.crt\n",
            "",
            "system-worker mTLS client identity is incomplete",
        )
        mutation(
            parent,
            "postgres-tls-host-verification-off",
            "apps/temporal/schema-upgrade/jobs.yaml",
            'value: "false" # SQL_TLS_DISABLE_HOST_VERIFICATION',
            'value: "true" # SQL_TLS_DISABLE_HOST_VERIFICATION',
            "host verification is not fail closed",
        )
        mutation(
            parent,
            "frontend-nodeport",
            "apps/temporal/server/services.yaml",
            "name: temporal-frontend\n  namespace: temporal\n  labels:\n    app.kubernetes.io/name: temporal\n    app.kubernetes.io/component: frontend\nspec:\n  type: ClusterIP",
            "name: temporal-frontend\n  namespace: temporal\n  labels:\n    app.kubernetes.io/name: temporal\n    app.kubernetes.io/component: frontend\nspec:\n  type: NodePort",
            "frontend must be ClusterIP-only",
        )
        mutation(
            parent,
            "hestia-node-selector-broadened",
            "apps/temporal/server/ciliumnetworkpolicy.yaml",
            "        kubernetes.io/hostname: hestia\n",
            "        kubernetes.io/hostname: heracles\n",
            "Hestia node selector must be exact",
        )
        mutation(
            parent,
            "hestia-host-entity-broadened",
            "apps/temporal/server/ciliumnetworkpolicy.yaml",
            "  - fromNodes:\n    - matchLabels:\n        kubernetes.io/hostname: hestia\n",
            "  - fromEntities:\n    - host\n",
            "Hestia frontend ingress rule must use fromNodes",
        )
        mutation(
            parent,
            "hestia-world-ingress-broadened",
            "apps/temporal/server/ciliumnetworkpolicy.yaml",
            "  - fromNodes:\n    - matchLabels:\n        kubernetes.io/hostname: hestia\n",
            "  - fromEntities:\n    - world\n",
            "Hestia frontend ingress rule must use fromNodes",
        )
        mutation(
            parent,
            "hestia-lan-ingress-broadened",
            "apps/temporal/server/ciliumnetworkpolicy.yaml",
            "  - fromNodes:\n    - matchLabels:\n        kubernetes.io/hostname: hestia\n",
            "  - fromCIDR:\n    - 192.168.1.0/24\n",
            "Hestia frontend ingress rule must use fromNodes",
        )
        mutation(
            parent,
            "hestia-frontend-port-broadened",
            "apps/temporal/server/ciliumnetworkpolicy.yaml",
            "      - port: \"7233\"\n        protocol: TCP\n",
            "      - port: \"7233\"\n        protocol: TCP\n      - port: \"7234\"\n        protocol: TCP\n",
            "Hestia frontend ingress must allow only TCP 7233",
        )
        mutation(
            parent,
            "dns-service-account-substituted",
            "apps/temporal/server/ciliumnetworkpolicy.yaml",
            "        k8s:io.cilium.k8s.policy.serviceaccount: coredns\n",
            "        k8s:io.cilium.k8s.policy.serviceaccount: default\n",
            "DNS egress must select only the CoreDNS service account",
        )
        mutation(
            parent,
            "dns-endpoint-selector-broadened",
            "apps/temporal/server/ciliumnetworkpolicy.yaml",
            "        k8s:io.cilium.k8s.policy.serviceaccount: coredns\n",
            "",
            "DNS egress must select only the CoreDNS service account",
        )
        mutation(
            parent,
            "schema-order-bypass",
            "clusters/k3s-homelab/flux-system/kustomization-temporal.yaml",
            "name: temporal-schema-upgrade",
            "name: shared-services",
            "unsafe path/dependency ordering",
        )
    print("Temporal mutation suite passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
