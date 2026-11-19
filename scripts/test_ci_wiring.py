#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML==6.0.3"]
# ///
"""Focused source-effects regression for this repository's local CI DAG.

This deliberately models only the direct conditions/globs used here, not the
GitLab compiler. Unsupported rule syntax fails rather than silently guessing.
"""
from __future__ import annotations

import copy
import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
MODULES = ("rpi5-dra-driver", "seaweedfs-cosi-driver", "cosi-provisioner-sidecar", "seaweedfs-csi-driver")
SUITES = {
    "safety": ("validate:application-safety", "apps/new-consumer/deployment.yaml"),
    "gitlab": ("validate:gitlab", "apps/gitlab-helm/files/upgrade-admission.sh"),
    "runner": ("validate:runner", "infrastructure/shared-services/gitlab-runner/ci/retention.py"),
    "migrations": ("validate:migrations", "apps/feedback/migrations/001_initial.sql"),
    "ibgateway": ("validate:ibgateway", "apps/autonomous-investing/broker-observer-deployment-policy.yaml"),
    "workspace": ("validate:workspace-contracts", "apps/hermes-workspace/deployment.yaml"),
    "mail": ("validate:mail", "apps/mail/deployment-default-sogo.yaml"),
    "matrix": ("validate:matrix", "apps/matrix/configmap-default-synapse-config.yaml"),
    "temporal": ("validate:temporal", "apps/temporal/server/configmap.yaml"),
    "factorio": ("validate:factorio", "apps/factorio/files/scenario-control.lua"),
    "restic": ("validate:restic", "infrastructure/storage/restic-backup/files/maintenance.sh"),
    "iris": ("validate:iris", "apps/iris/deployment-default-iris.yaml"),
    "firewall": ("validate:firewall", "scripts/hestia-firewalld-setup.sh"),
}
# Transitive GitLab tests stay owned by the native chart launcher.
TRANSITIVE = ("test_validate_gitlab_helm.py", "test_gitlab_upgrade_admission.py", "test_gitlab_nas_export.py")
RELEASES = {
    **{f"package:{module}": {f"compile:{module}", f"test:{module}", "validate:driver-sources", "validate:manifests"}
       for module in MODULES[:3]},
    "package:feedback-migrations": {"compile:feedback-migrations", "validate:migrations", "validate:application-safety", "validate:manifests"},
    "publish:hermes-workspace:index": {"package:hermes-workspace:amd64", "package:hermes-workspace:arm64", "validate:workspace-contracts", "validate:application-safety", "validate:manifests"},
}


def effective(ci: dict, name: str) -> dict:
    job = ci[name]
    assert isinstance(job, dict), f"{name}: job must be a mapping"
    parent = job.get("extends")
    assert parent is None or isinstance(parent, str), "unsupported extends shape"
    return {**(effective(ci, parent) if parent else {}), **job}


def matches(pattern: str, path: str) -> bool:
    # The repository uses literal paths and GitLab's recursive **/* glob only.
    if pattern.endswith("/**/*"):
        return path.startswith(pattern[:-4])
    assert not any(c in pattern for c in "*?{["), f"unsupported change glob: {pattern}"
    return pattern == path


def condition(expr: str, source: str, branch: str, protected: bool) -> bool:
    values = {"CI_PIPELINE_SOURCE": source, "CI_COMMIT_BRANCH": branch,
              "CI_DEFAULT_BRANCH": "main", "CI_COMMIT_REF_PROTECTED": str(protected).lower()}
    def atom(text: str) -> bool:
        found = re.fullmatch(r'\$(\w+) == (?:"([^"]*)"|\$(\w+))', text.strip())
        assert found, f"unsupported condition: {text}"
        left, literal, variable = found.groups()
        return values[left] == (values[variable] if variable else literal)
    return any(all(atom(part) for part in clause.split(" && ")) for clause in expr.split(" || "))


def selected(ci: dict, path: str, source: str = "merge_request_event", branch: str = "", protected: bool = False) -> set[str]:
    result = set()
    for name in ci:
        if name.startswith(".") or not isinstance(ci[name], dict) or "script" not in effective(ci, name):
            continue
        for rule in effective(ci, name).get("rules", []):
            assert isinstance(rule, dict), f"{name}: nested rule sequence"
            assert set(rule) <= {"if", "changes"}, f"{name}: unsupported rule keys"
            paths = rule["changes"]
            assert len(paths) == len(set(paths)), f"{name}: duplicate change paths"
            if condition(rule["if"], source, branch, protected) and any(matches(p, path) for p in paths):
                result.add(name)
                break
    return result


def verify(ci: dict) -> None:
    barrier = effective(ci, "gate:release")
    assert "needs" not in barrier, "release barrier must wait for all selected prior-stage jobs"
    stages = ci["stages"]
    assert barrier["stage"] == "release-gate"
    assert all(stages.index(stage) < stages.index("release-gate") for stage in ("compile", "package", "validate"))
    assert stages.index("release-gate") < stages.index("publish")
    for name in ci:
        if isinstance(ci[name], dict) and "script" in effective(ci, name):
            job = effective(ci, name)
            assert job.get("allow_failure", False) is False, f"{name}: required job cannot allow failure"
            assert job.get("when", "on_success") == "on_success", f"{name}: required job must gate on success"
    generic = effective(ci, "validate:manifests")
    assert generic["script"] == ["./scripts/validate_kustomize.sh"]
    assert not generic.get("before_script"), "Helm/chart bootstrap must not run globally"
    assert {n["job"] for n in generic["needs"] if not n.get("optional", False)} >= {"validate:ci-wiring"}
    wiring = effective(ci, "validate:ci-wiring")
    assert wiring["script"] == [
        "uv --no-config run --script scripts/test_ci_wiring.py",
        "uv --no-config run --locked --script scripts/test_render_schema.py",
    ], "CI wiring must run the locked native render/schema regression"
    assert not wiring.get("before_script"), "render/schema regressions must not bootstrap Helm"
    helm = "\n".join(effective(ci, "validate:gitlab")["before_script"])
    assert "helm-v4.2.4-linux-${helm_arch}.tar.gz" in helm and "sha256sum -c" in helm
    for module in MODULES:
        job = effective(ci, f"test:{module}")
        assert job["variables"]["DRIVER_MODULE"] == module
        assert job["script"] == ['cd "drivers/${DRIVER_MODULE}"', "unset FILER_ADDR", "go test ./..."]
    for mode in (("merge_request_event", "", False), ("push", "main", True)):
        for dependency in ("scripts/validate_kustomize.sh", "scripts/validate_render_schema.py",
                           "scripts/validate_render_schema.py.lock", "scripts/test_render_schema.py",
                           "scripts/test_render_schema.py.lock", ".gitlab-ci.yml"):
            assert {"validate:ci-wiring", "validate:manifests"} <= selected(ci, dependency, *mode), \
                f"render/schema regression missing shared dependency {dependency}"
        for suite, (job, path) in SUITES.items():
            assert job in selected(ci, path, *mode), f"{job}: missing domain trigger"
            assert effective(ci, job)["script"] == [f"./scripts/validate_contracts.sh {suite}"]
            for dependency in ("scripts/validate_contracts.sh", "scripts/fixtures/new-case.json", "scripts/test_sogo_manifest.py.lock", ".gitlab-ci.yml"):
                assert job in selected(ci, dependency, *mode), f"{job}: missing shared dependency {dependency}"
        for module in MODULES:
            assert f"test:{module}" in selected(ci, f"drivers/{module}/go.mod", *mode)
        # A newly discovered shared DB consumer always receives the global budget
        # check, but does not pay for unrelated IB/Temporal/Factorio mutations.
        unrelated = selected(ci, "apps/new-consumer/deployment.yaml", *mode)
        assert "validate:application-safety" in unrelated
        assert not {"validate:ibgateway", "validate:temporal", "validate:factorio"} & unrelated
        # Complete CI edits keep every existing main build/publication lane.
        all_jobs = selected(ci, ".gitlab-ci.yml", *mode)
        if mode[1] == "main":
            assert set(RELEASES) <= all_jobs
            assert {"package:hermes-workspace:amd64", "package:hermes-workspace:arm64"} <= all_jobs
        for name in all_jobs:
            for need in effective(ci, name).get("needs", []):
                assert need.get("optional", False) is False, f"{name}: optional safety gate"
                assert need["job"] in all_jobs, f"{name}: unreachable need {need['job']}"
    for name, gates in RELEASES.items():
        job = effective(ci, name)
        assert job["stage"] == "publish", f"{name}: premature release stage"
        needs = {need["job"] for need in job["needs"] if not need.get("optional", False)}
        required = gates | {"gate:release"}
        assert required <= needs, f"{name}: missing release test/safety gates {required - needs}"
        for path in (".gitlab-ci.yml", "apps/hermes-workspace/image/Dockerfile", "drivers/rpi5-dra-driver/go.mod"):
            assert name not in selected(ci, path), f"{name}: MR publication"
            assert name not in selected(ci, path, "push", "", True), f"{name}: tag publication"
            assert name not in selected(ci, path, "push", "main", False), f"{name}: unprotected publication"
    # Every actual producer selection must have its complete needs graph present,
    # including image-only and migration-only changes (not just CI-file edits).
    paths = {path for _, path in SUITES.values()} | {"apps/hermes-workspace/image/Dockerfile", "scripts/verify_hermes_workspace_image.sh"}
    paths |= {f"drivers/{module}/go.mod" for module in MODULES}
    for path in paths:
        jobs = selected(ci, path, "push", "main", True)
        for name in jobs:
            for need in effective(ci, name).get("needs", []):
                assert need["job"] in jobs, f"{path}: {name} missing {need['job']}"


def main() -> None:
    ci = yaml.safe_load((ROOT / ".gitlab-ci.yml").read_text())
    verify(ci)
    # Safety oracle controls: a harmless dependency superset is allowed; a missing
    # release gate or an MR-authorized publisher must be rejected.
    superset = copy.deepcopy(ci)
    superset["validate:matrix"]["rules"][0]["changes"].append("docs/matrix.md")
    verify(superset)
    for name in RELEASES:
        mutant = copy.deepcopy(ci)
        mutant[name]["needs"] = [need for need in mutant[name]["needs"] if need["job"] != "validate:manifests"]
        try:
            verify(mutant)
        except AssertionError:
            pass
        else:
            raise AssertionError(f"{name}: removed release gate escaped regression")
        mutant = copy.deepcopy(ci)
        mutant[name]["rules"][0]["if"] = '$CI_PIPELINE_SOURCE == "merge_request_event"'
        try:
            verify(mutant)
        except AssertionError:
            pass
        else:
            raise AssertionError(f"{name}: MR publication escaped regression")
    launcher = (ROOT / "scripts/validate_contracts.sh").read_text()
    assert 'uv --no-config run --locked --script "${repo_root}/scripts/test_sogo_manifest.py"' in launcher
    native = (ROOT / "scripts/validate_gitlab_helm.sh").read_text()
    for script in TRANSITIVE:
        assert script in native, f"native GitLab launcher lost {script}"
    for source, branch, protected in (("merge_request_event", "", False), ("push", "main", True), ("push", "", True)):
        jobs = sorted(selected(ci, ".gitlab-ci.yml", source, branch, protected))
        print(f"{source} branch={branch or '<none/tag>'} protected={protected}: {len(jobs)} jobs")
        print("  " + ", ".join(jobs))
    print("Focused CI wiring and release-gate regressions passed")


if __name__ == "__main__":
    main()
