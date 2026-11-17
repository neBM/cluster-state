#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML==6.0.3"]
# ///

from __future__ import annotations

import unittest

import yaml

from validate_versioned_migration_jobs import (
    parse_gitlab_release_versions,
    validate_feedback_migration_release,
    validate_gitlab_version_drift,
    validate_job_name_matches_image,
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


class MigrationImageReferenceTests(unittest.TestCase):
    def test_accepts_tag_with_optional_digest_and_registry_port(self) -> None:
        for repository in (
            "registry.example/namespace/migrations",
            "registry.example:443/namespace/migrations",
            "localhost/namespace/migrations",
            "localhost:5000/namespace/migrations",
            "registry-1.a:443/name_space/repo__name/migrations--job",
        ):
            for suffix in ("", "@sha256:" + "a" * 64):
                with self.subTest(repository=repository, suffix=suffix):
                    validate_job_name_matches_image(
                        "feedback-migrations-v3-r1", f"{repository}:v3{suffix}"
                    )

    def test_rejects_malformed_or_mismatched_release_references(self) -> None:
        for image in (
            "registry..example:443/ns/migrations:v3",
            "registry-.example:443/ns/migrations:v3",
            "registry.-example:443/ns/migrations:v3",
            "registry.example.:443/ns/migrations:v3",
            "registry.example:443/namespace/migrations",
            "registry.example:443/namespace/migrations@sha256:" + "a" * 64,
            "registry.example:443/namespace/migrations:v2@sha256:" + "a" * 64,
            "registry.example:443/namespace/migrations:v3@sha256:abc",
            "registry.example:443/namespace/migrations:v3@sha256:" + "g" * 64,
            "registry.example:443/namespace/migrations:v3@sha512:" + "a" * 64,
            "registry.example:443/namespace/migrations:v3@sha256:" + "a" * 64 + "@extra",
            "registry.example:443/namespace/migrations:v3:extra",
            "registry.example:443/namespace/migrations:",
        ):
            with self.subTest(image=image), self.assertRaises(SystemExit):
                validate_job_name_matches_image("feedback-migrations-v3-r1", image)


class FeedbackMigrationReleaseTests(unittest.TestCase):
    repository = "registry.example:443/namespace/feedback-migrations"

    def setUp(self) -> None:
        self.source = "  - migrationVersion=v3\n"
        self.release = {
            "migrationVersion": "v3",
            "migrationRunSuffix": "r1",
            "migrationImage": f"{self.repository}:v3",
        }
        self.job = {
            "kind": "Job",
            "metadata": {"name": "feedback-migrations-v3-r1"},
            "spec": {"template": {"spec": {"containers": [
                {"name": "migrations", "image": self.release["migrationImage"]}
            ]}}},
        }

    def validate(self, latest_migration: int = 3, repository: str | None = None) -> None:
        rendered = yaml.safe_dump_all([
            {"kind": "ConfigMap", "metadata": {"name": "feedback-release"}, "data": self.release},
            self.job,
        ])
        validate_feedback_migration_release(
            self.source, rendered, latest_migration, repository or self.repository
        )

    def test_allows_whole_tag_or_digest_image_with_port(self) -> None:
        for suffix in ("", "@sha256:" + "a" * 64):
            with self.subTest(suffix=suffix):
                image = f"{self.repository}:v3{suffix}"
                self.release["migrationImage"] = image
                self.job["spec"]["template"]["spec"]["containers"][0]["image"] = image
                self.validate()

    def test_rejects_version_not_matching_highest_sql(self) -> None:
        with self.assertRaisesRegex(ValueError, "highest SQL migration v4"):
            self.validate(latest_migration=4)

    def test_rejects_literal_unreadable_by_native_producer(self) -> None:
        self.source = '  - "migrationVersion=v3"\n'
        with self.assertRaisesRegex(ValueError, "native image producer"):
            self.validate()

    def test_rejects_image_version_even_if_job_name_contains_both_versions(self) -> None:
        self.release["migrationImage"] = f"{self.repository}:v2"
        self.job["metadata"]["name"] = "feedback-migrations-v2-v3-r1"
        with self.assertRaisesRegex(ValueError, "repository and migrationVersion"):
            self.validate()

    def test_rejects_repository_not_published_by_native_producer(self) -> None:
        with self.assertRaisesRegex(ValueError, "native producer repository"):
            self.validate(repository="registry.example:443/different/migrations")

    def test_rejects_job_identity_drift(self) -> None:
        self.job["metadata"]["name"] = "feedback-migrations-v3-r2"
        with self.assertRaisesRegex(ValueError, "Job identity"):
            self.validate()

    def test_rejects_job_image_not_bound_to_whole_release_reference(self) -> None:
        self.release["migrationImage"] += "@sha256:" + "a" * 64
        with self.assertRaisesRegex(ValueError, "whole migrationImage"):
            self.validate()

    def test_requires_full_migration_image_field(self) -> None:
        del self.release["migrationImage"]
        with self.assertRaisesRegex(ValueError, "requires migrationImage"):
            self.validate()


if __name__ == "__main__":
    unittest.main()
