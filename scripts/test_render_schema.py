#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML==6.0.3"]
# ///
"""Focused offline graph/selection/schema controls; no application suites."""

import contextlib
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import yaml

import validate_render_schema as validator


def flux_child(path):
    return yaml.safe_dump({
        "apiVersion": "kustomize.toolkit.fluxcd.io/v1", "kind": "Kustomization",
        "metadata": {"name": "child", "namespace": "flux-system"},
        "spec": {"path": path, "sourceRef": {"kind": "GitRepository", "name": "cluster-state"}},
    })


VALID = """apiVersion: v1
kind: ConfigMap
metadata:
  name: control
  namespace: default
data:
  value: valid
"""


class GraphSelection(unittest.TestCase):
    def test_defaults_follow_children_deduplicate_cycles_and_keep_candidates(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for path in ("bootstrap", "leaf-nfs", "inactive"):
                (root / path).mkdir()
            outputs = {"bootstrap": flux_child("./leaf-nfs"),
                       "leaf-nfs": flux_child("./bootstrap"), "inactive": VALID}
            with patch.object(validator, "ROOT", root), \
                    patch.object(validator, "BOOTSTRAP", "bootstrap"), \
                    patch.object(validator, "EXTRA_PATHS", ("inactive",)), \
                    patch.object(validator, "render", side_effect=outputs.__getitem__) as render:
                self.assertEqual([path for path, _ in validator.rendered_paths([])],
                                 ["bootstrap", "inactive", "leaf-nfs"])
                self.assertEqual(render.call_count, 3)

    def test_requested_paths_do_not_expand_flux_children_or_add_defaults(self):
        with patch.object(validator, "render", return_value=flux_child("missing-child")) as render:
            paths = list(validator.rendered_paths([validator.BOOTSTRAP]))
        self.assertEqual([path for path, _ in paths], [validator.BOOTSTRAP])
        render.assert_called_once_with(validator.BOOTSTRAP)

    def test_missing_or_outside_repository_path_is_rejected(self):
        for path in ("../", "does-not-exist"):
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, "repository Kustomize"):
                validator.local_path(path)

    def test_external_flux_source_does_not_silently_claim_coverage(self):
        document = yaml.safe_load(flux_child("apps"))
        document["spec"]["sourceRef"]["name"] = "another-repository"
        with self.assertRaisesRegex(ValueError, "external Flux sourceRef"):
            list(validator.children([document]))

    def test_empty_render_is_not_success(self):
        with patch.object(validator, "render", return_value=""), \
                self.assertRaisesRegex(ValueError, "no resources"):
            list(validator.rendered_paths([validator.BOOTSTRAP]))

    def test_tool_version_must_match(self):
        with patch.dict(os.environ, {"FLUX_SCHEMA_BIN": "other-flux-schema"}), \
                patch.object(subprocess, "check_output", return_value="0.1.0"), \
                self.assertRaisesRegex(ValueError, "0.17.0 required"):
            validator.schema_tool(Path("unused"))


class RealRenderSchema(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tools = tempfile.TemporaryDirectory(prefix="schema-control-tools-")
        cls.addClassCleanup(cls.tools.cleanup)
        cls.tool = validator.schema_tool(Path(cls.tools.name))

    def check_manifest(self, manifest):
        with tempfile.TemporaryDirectory(prefix="schema-control-") as temporary:
            root = Path(temporary)
            entrypoint = root / "fixture"
            entrypoint.mkdir()
            (entrypoint / "resource.yaml").write_text(manifest)
            (entrypoint / "kustomization.yaml").write_text(
                "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources: [resource.yaml]\n")
            with patch.object(validator, "ROOT", root), \
                    patch.dict(os.environ, {"FLUX_SCHEMA_BIN": self.tool}), \
                    contextlib.redirect_stdout(io.StringIO()):
                validator.validate(["fixture"])

    def test_valid_actual_render(self):
        self.check_manifest(VALID)

    def test_invalid_builtin_schema_is_rejected(self):
        # Rendering succeeds: the failure must come from the schema check.
        invalid = """apiVersion: apps/v1
kind: Deployment
metadata: {name: invalid, namespace: default}
spec:
  replicas: not-an-integer
  selector: {matchLabels: {app: invalid}}
  template:
    metadata: {labels: {app: invalid}}
    spec:
      containers: [{name: main, image: example.invalid/main:control}]
"""
        with self.assertRaises(subprocess.CalledProcessError):
            self.check_manifest(invalid)

    def test_missing_schema_is_rejected(self):
        unknown = VALID.replace("apiVersion: v1", "apiVersion: unknown.invalid/v1").replace(
            "kind: ConfigMap", "kind: UnknownControl")
        with self.assertRaises(subprocess.CalledProcessError):
            self.check_manifest(unknown)

    def test_missing_namespace_contract_is_preserved(self):
        with self.assertRaisesRegex(ValueError, "metadata.namespace is missing"):
            self.check_manifest(VALID.replace("  namespace: default\n", ""))


if __name__ == "__main__":
    unittest.main(verbosity=2)
