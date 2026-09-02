#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML==6.0.3"]
# ///

from __future__ import annotations

import unittest

from validate_versioned_migration_jobs import (
    parse_gitlab_release_versions,
    validate_gitlab_version_drift,
)


class GitLabVersionInvariantTests(unittest.TestCase):
    def test_parses_quoted_and_unquoted_release_versions(self) -> None:
        app_version, migration_version = parse_gitlab_release_versions(
            """
            apiVersion: kustomize.config.k8s.io/v1beta1
            kind: Kustomization
            configMapGenerator:
            - name: gitlab-release
              literals:
              - "appVersion=v19.2.4"
              - migrationVersion=v19.3.0
              - migrationRunSuffix=r1
            """
        )

        self.assertEqual(app_version, "v19.2.4")
        self.assertEqual(migration_version, "v19.3.0")

    def test_decoy_generator_cannot_mask_effective_release_drift(self) -> None:
        versions = parse_gitlab_release_versions(
            """
            apiVersion: kustomize.config.k8s.io/v1beta1
            kind: Kustomization
            configMapGenerator:
            - name: gitlab-release
              literals:
              - "appVersion=v19.1.0"
              - migrationVersion=v19.3.0
            - name: unrelated-release
              literals:
              - appVersion=v19.3.0
            """
        )

        self.assertEqual(versions, ("v19.1.0", "v19.3.0"))
        with self.assertRaisesRegex(ValueError, "more than one minor release ahead"):
            validate_gitlab_version_drift(*versions)

    def test_rejects_duplicate_gitlab_release_generators(self) -> None:
        with self.assertRaisesRegex(
            ValueError,
            "expected exactly one configMapGenerator named 'gitlab-release', found 2",
        ):
            parse_gitlab_release_versions(
                """
                configMapGenerator:
                - name: gitlab-release
                  literals:
                  - appVersion=v19.3.0
                - name: gitlab-release
                  literals:
                  - migrationVersion=v19.3.0
                """
            )

    def test_rejects_duplicate_release_literals(self) -> None:
        with self.assertRaisesRegex(
            ValueError, "expected exactly one appVersion literal, found 2"
        ):
            parse_gitlab_release_versions(
                """
                configMapGenerator:
                - name: gitlab-release
                  literals:
                  - appVersion=v19.3.0
                  - "appVersion=v19.2.4"
                  - migrationVersion=v19.3.0
                """
            )

    def test_rejects_duplicate_yaml_configuration_keys(self) -> None:
        with self.assertRaisesRegex(
            ValueError, "duplicate mapping key 'configMapGenerator'"
        ):
            parse_gitlab_release_versions(
                """
                configMapGenerator:
                - name: gitlab-release
                  literals:
                  - appVersion=v19.3.0
                  - migrationVersion=v19.3.0
                configMapGenerator:
                - name: unrelated-release
                  literals:
                  - appVersion=v19.1.0
                """
            )

    def test_rejects_malformed_versions(self) -> None:
        for version in ("19.3.0", "v19.3", "v19.three.0"):
            with self.subTest(version=version):
                with self.assertRaisesRegex(ValueError, "invalid GitLab version"):
                    validate_gitlab_version_drift(version, "v19.3.0")

    def test_rejects_migration_more_than_one_minor_ahead(self) -> None:
        with self.assertRaisesRegex(ValueError, "more than one minor release ahead"):
            validate_gitlab_version_drift("v19.1.0", "v19.3.0")

    def test_rejects_migration_patch_behind_application(self) -> None:
        with self.assertRaisesRegex(ValueError, "behind appVersion"):
            validate_gitlab_version_drift("v19.3.1", "v19.3.0")

    def test_allows_equal_or_one_minor_ahead(self) -> None:
        for app_version, migration_version in (
            ("v19.3.0", "v19.3.0"),
            ("v19.2.4", "v19.3.0"),
            ("v18.11.4", "v19.0.1"),
        ):
            with self.subTest(
                app_version=app_version,
                migration_version=migration_version,
            ):
                validate_gitlab_version_drift(app_version, migration_version)


if __name__ == "__main__":
    unittest.main()
