#!/usr/bin/env python3

from __future__ import annotations

import shutil
import subprocess
import tempfile
from collections.abc import Callable
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
VALIDATOR = REPO_ROOT / "scripts" / "validate_ibgateway_manifest.py"
FLUX_APPS = Path("clusters/k3s-homelab/flux-system/kustomization-apps.yaml")
FLUX_STORAGE = Path(
    "clusters/k3s-homelab/flux-system/kustomization-storage-classes.yaml"
)
APP_KUSTOMIZATION = Path("apps/autonomous-investing/kustomization.yaml")
DEPLOYMENT = Path(
    "apps/autonomous-investing/"
    "deployment-autonomous-investing-ib-gateway-paper.yaml"
)
PVC = Path(
    "apps/autonomous-investing/"
    "persistentvolumeclaim-autonomous-investing-ib-gateway-settings.yaml"
)
POLICY_RECORD = Path(
    "apps/autonomous-investing/ib-gateway-paper-deployment-policy.yaml"
)
NAMESPACE = Path("apps/autonomous-investing/namespace-autonomous-investing.yaml")
NETWORK_POLICY = Path(
    "apps/autonomous-investing/"
    "networkpolicy-autonomous-investing-ib-gateway-paper-default-deny.yaml"
)
CILIUM_POLICY = Path(
    "apps/autonomous-investing/"
    "ciliumnetworkpolicy-autonomous-investing-ib-gateway-paper.yaml"
)
STORAGE_CLASS = Path(
    "infrastructure/storage/storage-classes/storageclass-local-path-retain.yaml"
)

DEPLOYMENT_RESOURCE = "- deployment-autonomous-investing-ib-gateway-paper.yaml\n"
PVC_RESOURCE = "- persistentvolumeclaim-autonomous-investing-ib-gateway-settings.yaml\n"
ADMITTED_REPOSITORY = (
    "registry.brmartin.co.uk:443/autonomous-investing/system/ib-gateway"
)
ADMITTED_DIGEST = (
    "sha256:71ea9b027ac9da3ca9e7b94b6e6bc04b1fc1bcdc42687d1a6231cf2239bf707e"
)
ADMITTED_IMAGE = f"{ADMITTED_REPOSITORY}@{ADMITTED_DIGEST}"
DEPLOYMENT_SOURCE_SET = (DEPLOYMENT, PVC, POLICY_RECORD)
PSS_LABEL_LINES = (
    "    pod-security.kubernetes.io/audit: restricted\n",
    "    pod-security.kubernetes.io/audit-version: latest\n",
    "    pod-security.kubernetes.io/enforce: restricted\n",
    "    pod-security.kubernetes.io/enforce-version: latest\n",
    "    pod-security.kubernetes.io/warn: restricted\n",
    "    pod-security.kubernetes.io/warn-version: latest\n",
)


def classify_source_set(root: Path) -> str:
    present = [path for path in DEPLOYMENT_SOURCE_SET if (root / path).is_file()]
    if len(present) == len(DEPLOYMENT_SOURCE_SET):
        return "deployment"
    if not present:
        return "foundation"
    missing = [path for path in DEPLOYMENT_SOURCE_SET if path not in present]
    raise AssertionError(
        "partial deployment source set: present "
        f"{[str(path) for path in present]!r}; missing "
        f"{[str(path) for path in missing]!r}"
    )


def clone_fixture(parent: Path, name: str) -> Path:
    root = parent / name
    shutil.copytree(REPO_ROOT / "apps", root / "apps")
    shutil.copytree(
        REPO_ROOT / "infrastructure" / "storage" / "storage-classes",
        root / "infrastructure" / "storage" / "storage-classes",
    )
    flux_target = root / FLUX_APPS
    flux_target.parent.mkdir(parents=True)
    shutil.copy2(REPO_ROOT / FLUX_APPS, flux_target)
    shutil.copy2(REPO_ROOT / FLUX_STORAGE, root / FLUX_STORAGE)
    return root


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise AssertionError(f"{path}: expected one mutation target, found {count}")
    path.write_text(text.replace(old, new, 1))


def remove_resource_if_present(root: Path, resource: str) -> None:
    path = root / APP_KUSTOMIZATION
    text = path.read_text()
    count = text.count(resource)
    if count > 1:
        raise AssertionError(f"{path}: duplicate resource line {resource.strip()!r}")
    if count == 1:
        path.write_text(text.replace(resource, "", 1))


def make_foundation(root: Path) -> None:
    remove_resource_if_present(root, DEPLOYMENT_RESOURCE)
    remove_resource_if_present(root, PVC_RESOURCE)
    for path in DEPLOYMENT_SOURCE_SET:
        target = root / path
        if target.exists():
            target.unlink()


def clone_foundation_fixture(parent: Path, name: str) -> Path:
    root = clone_fixture(parent, name)
    make_foundation(root)
    return root


def append_resource(root: Path, resource: str) -> None:
    path = root / APP_KUSTOMIZATION
    text = path.read_text()
    if resource in text:
        raise AssertionError(f"{path}: resource line already present: {resource.strip()}")
    path.write_text(f"{text}{resource}")


def run_validator(root: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "uv",
            "run",
            "--locked",
            "--script",
            str(VALIDATOR),
            "--repo-root",
            str(root),
            *arguments,
        ],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )


def output(result: subprocess.CompletedProcess[str]) -> str:
    return f"{result.stdout}\n{result.stderr}".strip()


def expect_success(label: str, root: Path, *arguments: str) -> None:
    result = run_validator(root, *arguments)
    if result.returncode != 0:
        raise AssertionError(f"{label}: expected success\n{output(result)}")
    print(f"PASS: {label}")


def expect_failure(
    label: str,
    root: Path,
    expected_error: str,
    *arguments: str,
) -> None:
    result = run_validator(root, *arguments)
    combined = output(result)
    if result.returncode == 0:
        raise AssertionError(f"{label}: mutation was accepted")
    if expected_error not in combined:
        raise AssertionError(
            f"{label}: expected error containing {expected_error!r}\n{combined}"
        )
    print(f"PASS: {label} rejected")


def foundation_mutation_case(
    parent: Path,
    name: str,
    mutate: Callable[[Path], None],
    expected_error: str,
    *arguments: str,
) -> None:
    root = clone_foundation_fixture(parent, name)
    mutate(root)
    expect_failure(name.replace("-", " "), root, expected_error, *arguments)


def deployment_mutation_case(
    parent: Path,
    name: str,
    mutate: Callable[[Path], None],
    expected_error: str,
    *arguments: str,
) -> None:
    root = clone_fixture(parent, name)
    mutate(root)
    expect_failure(name.replace("-", " "), root, expected_error, *arguments)


def add_outside_service(root: Path) -> None:
    outside = root / "apps" / "review-mutation"
    outside.mkdir()
    (outside / "kustomization.yaml").write_text(
        "apiVersion: kustomize.config.k8s.io/v1beta1\n"
        "kind: Kustomization\n"
        "resources:\n"
        "- service.yaml\n"
    )
    (outside / "service.yaml").write_text(
        "apiVersion: v1\n"
        "kind: Service\n"
        "metadata:\n"
        "  name: forbidden-exposure\n"
        "  namespace: autonomous-investing\n"
        "spec:\n"
        "  selector:\n"
        "    app.kubernetes.io/name: ib-gateway-paper\n"
        "  ports:\n"
        "  - port: 4002\n"
        "    targetPort: 4002\n"
    )
    apps_kustomization = root / "apps" / "kustomization.yaml"
    apps_kustomization.write_text(
        f"{apps_kustomization.read_text()}- review-mutation\n"
    )


def redirect_authoritative_apps_path(root: Path) -> None:
    shutil.copytree(root / "apps", root / "alternate-apps")
    replace_once(
        root
        / "alternate-apps"
        / "autonomous-investing"
        / "namespace-autonomous-investing.yaml",
        "    pod-security.kubernetes.io/audit: restricted\n",
        "",
    )
    replace_once(root / FLUX_APPS, "  path: ./apps\n", "  path: ./alternate-apps\n")


def add_foundation_pvc(root: Path) -> None:
    target = root / PVC
    target.write_text(
        "apiVersion: v1\n"
        "kind: PersistentVolumeClaim\n"
        "metadata:\n"
        "  name: ib-gateway-settings\n"
        "  namespace: autonomous-investing\n"
        "spec:\n"
        "  accessModes:\n"
        "  - ReadWriteOnce\n"
        "  resources:\n"
        "    requests:\n"
        "      storage: 2Gi\n"
        "  storageClassName: local-path-retain\n"
    )
    append_resource(root, PVC_RESOURCE)


def add_foundation_deployment(root: Path) -> None:
    target = root / DEPLOYMENT
    target.write_text(
        "apiVersion: apps/v1\n"
        "kind: Deployment\n"
        "metadata:\n"
        "  name: ib-gateway-paper\n"
        "  namespace: autonomous-investing\n"
        "spec: {}\n"
    )
    append_resource(root, DEPLOYMENT_RESOURCE)


def different_admitted_image() -> str:
    last = "0" if ADMITTED_IMAGE[-1] != "0" else "1"
    return f"{ADMITTED_IMAGE[:-1]}{last}"


def run_common_foundation_tests(parent: Path) -> None:
    foundation = clone_foundation_fixture(parent, "foundation-baseline")
    expect_success("explicit foundation phase", foundation, "--phase", "foundation")
    expect_success("foundation auto phase", foundation)
    expect_failure(
        "expected image in foundation phase",
        foundation,
        "--expected-image requires deployment phase",
        "--expected-image",
        ADMITTED_IMAGE,
    )

    foundation_mutation_case(
        parent,
        "authoritative-apps-path-redirect",
        redirect_authoritative_apps_path,
        "Namespace metadata and labels",
    )
    foundation_mutation_case(
        parent,
        "wrong-apps-flux-identity",
        lambda root: replace_once(
            root / FLUX_APPS,
            "  name: apps\n",
            "  name: review-mutation\n",
        ),
        "Flux Kustomization identity",
    )
    foundation_mutation_case(
        parent,
        "unsafe-apps-flux-path",
        lambda root: replace_once(
            root / FLUX_APPS,
            "  path: ./apps\n",
            "  path: ./apps/../apps\n",
        ),
        "normalized safe repository-relative path",
    )
    foundation_mutation_case(
        parent,
        "apps-flux-wait-disabled",
        lambda root: replace_once(
            root / FLUX_APPS,
            "  wait: true\n",
            "  wait: false\n",
        ),
        "spec.wait must be true",
    )

    for index, label_line in enumerate(PSS_LABEL_LINES):
        foundation_mutation_case(
            parent,
            f"missing-pss-label-{index + 1}",
            lambda root, line=label_line: replace_once(root / NAMESPACE, line, ""),
            "Namespace metadata and labels",
        )

    foundation_mutation_case(
        parent,
        "outside-same-namespace-service",
        add_outside_service,
        "forbidden external exposure resources",
    )
    foundation_mutation_case(
        parent,
        "wrong-storageclass-contract",
        lambda root: replace_once(
            root / STORAGE_CLASS,
            "provisioner: rancher.io/local-path",
            "provisioner: example.invalid/local-path",
        ),
        "local-path-retain provisioner",
    )
    foundation_mutation_case(
        parent,
        "wrong-storage-binding-mode",
        lambda root: replace_once(
            root / STORAGE_CLASS,
            "volumeBindingMode: WaitForFirstConsumer",
            "volumeBindingMode: Immediate",
        ),
        "local-path-retain volumeBindingMode",
    )
    foundation_mutation_case(
        parent,
        "wrong-coredns-label",
        lambda root: replace_once(
            root / CILIUM_POLICY,
            "        k8s:k8s-app: kube-dns\n",
            "        k8s:k8s-app: review-mutation\n",
        ),
        "CiliumNetworkPolicy spec",
    )
    foundation_mutation_case(
        parent,
        "widened-fqdn",
        lambda root: replace_once(
            root / CILIUM_POLICY,
            "  - toFQDNs:\n"
            "    - matchName: zdc1.ibllc.com\n",
            "  - toFQDNs:\n"
            "    - matchName: zdc1.ibllc.com\n"
            "    - matchPattern: \"*.ibllc.com\"\n",
        ),
        "FQDN: forbidden fields present: matchPattern",
    )
    foundation_mutation_case(
        parent,
        "missing-fqdn",
        lambda root: replace_once(
            root / CILIUM_POLICY,
            "        - matchName: ndc1-hb2.ibllc.com\n"
            "  - toFQDNs:\n",
            "  - toFQDNs:\n",
        ),
        "CiliumNetworkPolicy spec",
    )
    foundation_mutation_case(
        parent,
        "substituted-fqdn",
        lambda root: replace_once(
            root / CILIUM_POLICY,
            "    - matchName: ndc1.ibllc.com\n"
            "    - matchName: ndc1-hb1.ibllc.com\n",
            "    - matchName: ndc2.ibllc.com\n"
            "    - matchName: ndc1-hb1.ibllc.com\n",
        ),
        "CiliumNetworkPolicy spec",
    )
    foundation_mutation_case(
        parent,
        "extra-fqdn",
        lambda root: replace_once(
            root / CILIUM_POLICY,
            "    - matchName: ndc1-hb2.ibllc.com\n"
            "    toPorts:\n",
            "    - matchName: ndc1-hb2.ibllc.com\n"
            "    - matchName: extra.ibllc.com\n"
            "    toPorts:\n",
        ),
        "CiliumNetworkPolicy spec",
    )
    foundation_mutation_case(
        parent,
        "widened-ports",
        lambda root: replace_once(
            root / CILIUM_POLICY,
            "      - port: \"4001\"\n"
            "        protocol: TCP\n",
            "      - port: \"4001\"\n"
            "        protocol: TCP\n"
            "      - port: \"443\"\n"
            "        protocol: TCP\n",
        ),
        "CiliumNetworkPolicy spec",
    )
    foundation_mutation_case(
        parent,
        "weakened-default-deny",
        lambda root: replace_once(
            root / NETWORK_POLICY,
            "  ingress: []\n",
            "  ingress:\n"
            "  - {}\n",
        ),
        "default-deny NetworkPolicy spec",
    )
    foundation_mutation_case(
        parent,
        "foundation-with-pvc",
        add_foundation_pvc,
        "foundation phase forbids PersistentVolumeClaim resources",
        "--phase",
        "foundation",
    )
    foundation_mutation_case(
        parent,
        "foundation-with-deployment",
        add_foundation_deployment,
        "foundation phase forbids Deployment resources",
        "--phase",
        "foundation",
    )

    partial = clone_foundation_fixture(parent, "partial-source-set")
    (partial / POLICY_RECORD).write_text("schemaVersion: 1\n")
    try:
        classify_source_set(partial)
    except AssertionError as exc:
        if "partial deployment source set" not in str(exc):
            raise
        print("PASS: partial deployment source set rejected by test harness")
    else:
        raise AssertionError("partial deployment source set was accepted by test harness")


def run_deployment_tests(parent: Path) -> None:
    baseline = clone_fixture(parent, "deployment-baseline")
    expect_success("deployment auto phase", baseline)
    expect_success(
        "deployment exact admitted image",
        baseline,
        "--phase",
        "deployment",
        "--expected-image",
        ADMITTED_IMAGE,
    )

    deployment_mutation_case(
        parent,
        "deployment-missing-pvc",
        lambda root: remove_resource_if_present(root, PVC_RESOURCE),
        "deployment phase PersistentVolumeClaim resources",
        "--phase",
        "deployment",
    )
    deployment_mutation_case(
        parent,
        "deployment-missing-deployment",
        lambda root: remove_resource_if_present(root, DEPLOYMENT_RESOURCE),
        "deployment phase Deployment resources",
        "--phase",
        "deployment",
    )
    deployment_mutation_case(
        parent,
        "auto-pvc-without-deployment",
        lambda root: remove_resource_if_present(root, DEPLOYMENT_RESOURCE),
        "foundation phase forbids PersistentVolumeClaim resources",
    )
    deployment_mutation_case(
        parent,
        "missing-policy-record",
        lambda root: (root / POLICY_RECORD).unlink(),
        "deployment policy record is required",
    )
    deployment_mutation_case(
        parent,
        "policy-record-wrong-digest",
        lambda root: replace_once(
            root / POLICY_RECORD,
            f"  digest: {ADMITTED_DIGEST}\n",
            f"  digest: {different_admitted_image().split('@', 1)[1]}\n",
        ),
        "deployment policy record",
    )
    deployment_mutation_case(
        parent,
        "policy-record-reference-mismatch",
        lambda root: replace_once(
            root / POLICY_RECORD,
            f"  reference: {ADMITTED_IMAGE}\n",
            f"  reference: {different_admitted_image()}\n",
        ),
        "deployment policy artifact reference",
    )
    deployment_mutation_case(
        parent,
        "deployment-policy-image-mismatch",
        lambda root: replace_once(
            root / DEPLOYMENT,
            f"      - image: {ADMITTED_IMAGE}\n",
            f"      - image: {different_admitted_image()}\n",
        ),
        "Gateway deployment policy image",
    )
    expect_failure(
        "expected image differs from deployment and policy",
        baseline,
        "Deployment policy admitted image",
        "--phase",
        "deployment",
        "--expected-image",
        different_admitted_image(),
    )

    deployment_mutation_case(
        parent,
        "privileged-container",
        lambda root: replace_once(
            root / DEPLOYMENT,
            "          allowPrivilegeEscalation: false\n",
            "          allowPrivilegeEscalation: true\n",
        ),
        "Gateway securityContext",
    )
    deployment_mutation_case(
        parent,
        "wrong-secret-name",
        lambda root: replace_once(
            root / DEPLOYMENT,
            "          secretName: ibkr-paper-gateway-credentials\n",
            "          secretName: review-mutation\n",
        ),
        "Pod volumes",
    )
    deployment_mutation_case(
        parent,
        "wrong-secret-key",
        lambda root: replace_once(
            root / DEPLOYMENT,
            "          - key: TWS_USERID\n"
            "            path: TWS_USERID\n",
            "          - key: REVIEW_MUTATION\n"
            "            path: TWS_USERID\n",
        ),
        "Pod volumes",
    )
    deployment_mutation_case(
        parent,
        "wrong-secret-path",
        lambda root: replace_once(
            root / DEPLOYMENT,
            "          - key: TWS_PASSWORD\n"
            "            path: TWS_PASSWORD\n",
            "          - key: TWS_PASSWORD\n"
            "            path: REVIEW_MUTATION\n",
        ),
        "Pod volumes",
    )
    deployment_mutation_case(
        parent,
        "forbidden-env",
        lambda root: replace_once(
            root / DEPLOYMENT,
            "        imagePullPolicy: IfNotPresent\n",
            "        env:\n"
            "        - name: REVIEW_MUTATION\n"
            "          value: forbidden\n"
            "        imagePullPolicy: IfNotPresent\n",
        ),
        "Gateway container: forbidden fields present: env",
    )
    deployment_mutation_case(
        parent,
        "forbidden-args",
        lambda root: replace_once(
            root / DEPLOYMENT,
            "        imagePullPolicy: IfNotPresent\n",
            "        args:\n"
            "        - --review-mutation\n"
            "        imagePullPolicy: IfNotPresent\n",
        ),
        "Gateway container: forbidden fields present: args",
    )
    deployment_mutation_case(
        parent,
        "replica-count",
        lambda root: replace_once(
            root / DEPLOYMENT,
            "  replicas: 1\n",
            "  replicas: 2\n",
        ),
        "Deployment replicas",
    )
    deployment_mutation_case(
        parent,
        "second-container",
        lambda root: replace_once(
            root / DEPLOYMENT,
            "      dnsConfig:\n",
            "      - image: example.invalid/review-helper@sha256:"
            + "0" * 64
            + "\n"
            "        name: review-helper\n"
            "      dnsConfig:\n",
        ),
        "Pod container count",
    )
    deployment_mutation_case(
        parent,
        "service-account-token",
        lambda root: replace_once(
            root / DEPLOYMENT,
            "      automountServiceAccountToken: false\n",
            "      automountServiceAccountToken: true\n",
        ),
        "Pod automountServiceAccountToken",
    )
    deployment_mutation_case(
        parent,
        "host-network",
        lambda root: replace_once(
            root / DEPLOYMENT,
            "      automountServiceAccountToken: false\n",
            "      automountServiceAccountToken: false\n"
            "      hostNetwork: true\n",
        ),
        "Pod spec: forbidden fields present: hostNetwork",
    )
    deployment_mutation_case(
        parent,
        "container-ports",
        lambda root: replace_once(
            root / DEPLOYMENT,
            "        imagePullPolicy: IfNotPresent\n",
            "        imagePullPolicy: IfNotPresent\n"
            "        ports:\n"
            "        - containerPort: 4002\n",
        ),
        "Gateway container: forbidden fields present: ports",
    )
    deployment_mutation_case(
        parent,
        "wrong-container-uid",
        lambda root: replace_once(
            root / DEPLOYMENT,
            "          runAsUser: 10001\n",
            "          runAsUser: 10002\n",
        ),
        "Gateway securityContext",
    )
    deployment_mutation_case(
        parent,
        "wrong-container-gid",
        lambda root: replace_once(
            root / DEPLOYMENT,
            "          runAsGroup: 10001\n",
            "          runAsGroup: 10002\n",
        ),
        "Gateway securityContext",
    )
    deployment_mutation_case(
        parent,
        "wrong-fsgroup",
        lambda root: replace_once(
            root / DEPLOYMENT,
            "        fsGroup: 10001\n",
            "        fsGroup: 10002\n",
        ),
        "Pod securityContext",
    )
    deployment_mutation_case(
        parent,
        "wrong-pvc-shape",
        lambda root: replace_once(
            root / PVC,
            "      storage: 2Gi\n",
            "      storage: 3Gi\n",
        ),
        "PVC spec",
    )
    deployment_mutation_case(
        parent,
        "missing-ndots",
        lambda root: replace_once(
            root / DEPLOYMENT,
            "      dnsConfig:\n"
            "        options:\n"
            "        - name: ndots\n"
            "          value: \"1\"\n",
            "",
        ),
        "Pod dnsConfig",
    )
    deployment_mutation_case(
        parent,
        "extra-ibc-runtime-consumer",
        lambda root: replace_once(
            root / DEPLOYMENT,
            "      containers:\n",
            "      initContainers:\n"
            "      - image: example.invalid/review-helper@sha256:"
            + "0" * 64
            + "\n"
            "        name: review-helper\n"
            "        volumeMounts:\n"
            "        - mountPath: /run/ibc\n"
            "          name: ibc-runtime\n"
            "      containers:\n",
        ),
        "exclusive ibc-runtime mount",
    )


def main() -> int:
    source_phase = classify_source_set(REPO_ROOT)
    print(f"Detected {source_phase} IB Gateway source set")

    with tempfile.TemporaryDirectory(prefix="ibgateway-validator-tests-") as temp:
        parent = Path(temp)

        if source_phase == "foundation":
            baseline = clone_fixture(parent, "repository-foundation-baseline")
            expect_success("repository foundation baseline", baseline)
        else:
            baseline = clone_fixture(parent, "repository-deployment-baseline")
            expect_success("repository deployment baseline", baseline)

        run_common_foundation_tests(parent)
        if source_phase == "deployment":
            run_deployment_tests(parent)
        else:
            print("SKIP: deployment-only tests (complete deployment source set absent)")

    print("All applicable IB Gateway validator mutation tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
