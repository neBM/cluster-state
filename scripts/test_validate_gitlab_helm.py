#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML==6.0.3"]
# ///
"""Mutate the real candidate source and one real Helm render, never fake readiness."""
import copy
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parent.parent


class CandidateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.validator_path = ROOT / "scripts/validate_gitlab_helm.py"

    def setUp(self):
        self.assertTrue(self.validator_path.is_file(), "native GitLab Helm validator is missing")
        spec = importlib.util.spec_from_file_location("validator", self.validator_path)
        assert spec is not None and spec.loader is not None
        self.v = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.v)
        self.release = yaml.safe_load((ROOT / "apps/gitlab-helm/helmrelease.yaml").read_text())

    def test_actual_source(self):
        self.assertEqual(self.v.validate_source(ROOT), [])

    def test_source_drift(self):
        changes = [
            ("edition", lambda r: r["spec"]["values"]["global"].update(edition="ee")),
            ("version", lambda r: r["spec"]["chart"]["spec"].update(version="10.4.0")),
            ("activation", lambda r: r["spec"].update(suspend=False)),
            ("workers", lambda r: r["spec"]["values"]["gitlab"]["sidekiq"].update(concurrency=20)),
            ("duplicate controller", lambda r: r["spec"]["values"]["global"]["gatewayApi"].update(enabled=True)),
            ("independent app pin", lambda r: r["spec"]["values"]["global"].update(gitlabVersion="19.4.0")),
        ]
        for name, mutate in changes:
            with self.subTest(name=name):
                release = copy.deepcopy(self.release)
                mutate(release)
                self.assertTrue(self.v.validate_release(release), name)

    def test_root_graph_activation(self):
        with tempfile.TemporaryDirectory() as tmp:
            import shutil
            root = Path(tmp)
            for directory in ("apps", "clusters"):
                shutil.copytree(ROOT / directory, root / directory)
            path = root / "apps/kustomization.yaml"
            data = yaml.safe_load(path.read_text())
            data["resources"].append("gitlab-helm")
            path.write_text(yaml.safe_dump(data))
            self.assertTrue(self.v.validate_source(root))

    def test_internal_alias_contract(self):
        source = yaml.safe_load((ROOT / "apps/gitlab/service-default-gitlab-registry-internal.yaml").read_text())
        self.assertEqual(self.v.validate_internal_alias(source), [])
        for field, value in (("port", 5000), ("targetPort", 443)):
            changed = copy.deepcopy(source)
            changed["spec"]["ports"][0][field] = value
            self.assertTrue(self.v.validate_internal_alias(changed))

    def test_real_render_mutations(self):
        path = os.environ.get("GITLAB_HELM_RENDERED")
        self.assertIsNotNone(path, "run via validate_gitlab_helm.sh for a real chart render")
        assert path is not None
        docs = list(yaml.safe_load_all(Path(path).read_text()))
        self.assertEqual(self.v.validate_render(docs), [])
        workloads = [d for d in docs if d and d.get("kind") in ("Deployment", "StatefulSet")]
        for workload in workloads:
            if workload["metadata"]["labels"].get("app") not in {"gitaly", "kas", "registry", "sidekiq", "webservice", "toolbox"}:
                continue
            with self.subTest(name=workload["metadata"]["name"], field="replicas"):
                changed = copy.deepcopy(docs)
                next(d for d in changed if d == workload)["spec"]["replicas"] = 2
                self.assertTrue(self.v.validate_render(changed))
            for container in workload["spec"]["template"]["spec"]["containers"]:
                for field in ("requests", "limits"):
                    if field not in container.get("resources", {}):
                        continue
                    with self.subTest(container=container["name"], field=field):
                        changed = copy.deepcopy(docs)
                        target = next(d for d in changed if d == workload)
                        target_container = next(c for c in target["spec"]["template"]["spec"]["containers"] if c["name"] == container["name"])
                        target_container["resources"][field]["memory"] = "1Mi"
                        self.assertTrue(self.v.validate_render(changed))
        for app, env_name in (("webservice", "WORKER_PROCESSES"), ("webservice", "PUMA_THREADS_MIN"), ("webservice", "PUMA_THREADS_MAX"), ("sidekiq", "SIDEKIQ_CONCURRENCY")):
            changed = copy.deepcopy(docs)
            target = next(d for d in changed if d and d.get("kind") == "Deployment" and d["metadata"]["labels"].get("app") == app)
            env = next(c for c in target["spec"]["template"]["spec"]["containers"] if c["name"] == app)["env"]
            next(e for e in env if e["name"] == env_name)["value"] = "99"
            self.assertTrue(self.v.validate_render(changed))
        for version in ("-ee:v19.5.0", "-ce:v19.4.0"):
            changed = copy.deepcopy(docs)
            target = next(d for d in changed if d and d.get("kind") == "Deployment" and d["metadata"]["labels"].get("app") == "webservice")
            container = target["spec"]["template"]["spec"]["containers"][0]
            container["image"] = "registry.gitlab.com/gitlab-org/build/cng/gitlab-webservice" + version
            self.assertTrue(self.v.validate_render(changed))
        changed = copy.deepcopy(docs)
        workload = copy.deepcopy(workloads[0])
        workload["metadata"]["name"] = "duplicate-ingress"
        changed.append(workload)
        self.assertTrue(self.v.validate_render(changed))


if __name__ == "__main__":
    unittest.main()
