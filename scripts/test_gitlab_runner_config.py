#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML==6.0.3"]
# ///
"""Exercise rendered Runner admission and the production config generator."""

import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
import tomllib
import unittest
import uuid
from pathlib import Path

import yaml

from validate_gitlab_runner_templates import load_template

ROOT = Path(__file__).resolve().parent.parent
RUNNERS = ROOT / "infrastructure/shared-services/gitlab-runner"
LANES = ("amd64", "any", "arm64", "services")


class RunnerConfigTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        renderer = ["kustomize", "build"] if shutil.which("kustomize") else ["kubectl", "kustomize"]
        rendered = subprocess.check_output([*renderer, str(RUNNERS)], text=True)
        cls.objects = list(yaml.safe_load_all(rendered))
        cls.managers = [obj for obj in cls.objects if obj["kind"] == "Deployment"]

    def test_single_admission_manager(self):
        self.assertEqual(len(self.managers), 1, "all registrations must share one admission process")
        manager = self.managers[0]
        self.assertEqual(manager["metadata"]["name"], "gitlab-runner-any")
        self.assertEqual(manager["spec"]["replicas"], 1)
        self.assertEqual(manager["spec"]["strategy"], {"type": "Recreate"})
        pod = manager["spec"]["template"]["spec"]
        self.assertNotIn("nodeSelector", pod)
        self.assertEqual(len(pod["containers"]), 1)
        self.assertEqual(pod["containers"][0]["args"], ["run", "--config", "/config/config.toml"])

    def test_generated_global_bound_and_preserved_lanes(self):
        self.assertEqual(len(self.managers), 1)
        pod = self.managers[0]["spec"]["template"]["spec"]
        init, = pod["initContainers"]
        self.assertEqual(init["image"], "busybox:1.38")
        self.assertEqual(pod["containers"][0]["image"], "gitlab/gitlab-runner:v19.4.0")
        refs = {entry["name"]: entry["valueFrom"]["secretKeyRef"] for entry in init["env"]}
        self.assertEqual(refs, {
            f"RUNNER_TOKEN_{lane.upper()}": {
                "name": "gitlab-runner-secrets", "key": f"runner_token_{lane}", "optional": False
            } for lane in LANES
        })
        # Synthetic credentials include both shell/sed and TOML metacharacters.
        tokens = {f"RUNNER_TOKEN_{lane.upper()}": f'synthetic-{lane}-&|\\"$`' for lane in LANES}
        access, secret = "synthetic-access-&|$", "synthetic-secret-&|$"
        bucket = {"bucketName": "gitlab-runner-cache", "endpoint": "http://s3.example:8333",
                  "accessKeyID": access, "accessSecretKey": secret}
        maps = {obj["metadata"]["name"]: obj["data"] for obj in self.objects if obj["kind"] == "ConfigMap"}
        system_ids = [name for name in maps if name.startswith("gitlab-runner-system-id")]
        self.assertEqual(system_ids, ["gitlab-runner-system-id-any"])
        volumes = {volume["name"]: volume for volume in pod["volumes"]}
        with tempfile.TemporaryDirectory(prefix="runner-config-") as temporary:
            root = Path(temporary)
            paths = {}
            for mount in init["volumeMounts"]:
                volume = volumes[mount["name"]]
                directory = root / mount["mountPath"].lstrip("/")
                directory.mkdir(parents=True)
                paths[mount["mountPath"]] = directory
                if "configMap" in volume:
                    for key, value in maps[volume["configMap"]["name"]].items():
                        (directory / key).write_text(value)
                if "secret" in volume:
                    self.assertEqual(volume["secret"]["secretName"], "gitlab-runner-cache-cosi-s3")
                    (directory / "BucketInfo").write_text(json.dumps(bucket, indent=2))
            command = [*init["command"], *init["args"]]
            container = os.environ.get("RUNNER_CONFIG_CONTAINER") == "1"
            name = f"runner-config-{uuid.uuid4().hex}"
            if container:
                launch = ["podman", "run", "--rm", "--name", name, "--network=none", "--read-only",
                          "--cap-drop=all", "--security-opt=no-new-privileges", "--userns=keep-id",
                          "--user", f"{os.getuid()}:{os.getgid()}"]
                for mount in init["volumeMounts"]:
                    mode = "ro,Z" if mount.get("readOnly") else "rw,Z"
                    launch += ["-v", f'{paths[mount["mountPath"]]}:{mount["mountPath"]}:{mode}']
                for key in tokens:
                    launch += ["-e", key]
                command = [*launch, "docker.io/library/" + init["image"], *command]
            else:
                # Default native gate needs no container daemon; only fixture paths change.
                paths["/template"] = root / "template"
                pattern = "(?:" + "|".join(re.escape(path) for path in sorted(paths, key=len, reverse=True)) + r")(?![\w.-])"
                command[-1] = re.sub(pattern, lambda match: str(paths[match[0]]), command[-1])
            try:
                result = subprocess.run(command, env={**os.environ, **tokens}, capture_output=True, timeout=60)
                self.assertEqual(result.returncode, 0, "config generator failed (output withheld)")
                self.assertEqual(result.stdout + result.stderr, b"", "generator must not log credentials")
                config_path = paths["/config"] / "config.toml"
                actual = tomllib.loads(config_path.read_text())
                self.assertEqual(actual["concurrent"], 1)
                self.assertEqual(actual["check_interval"], 1)
                self.assertEqual(actual["shutdown_timeout"], 0)
                self.assertEqual(actual["session_server"], {"session_timeout": 1800})
                self.assertEqual(len(actual["runners"]), 4)
                for lane, runner in zip(LANES, actual["runners"], strict=True):
                    expected = tomllib.loads(load_template(RUNNERS / "runner-base", RUNNERS / "runners" / lane))["runners"][0]
                    expected.update(name=f"k8s-{lane}", token=tokens[f"RUNNER_TOKEN_{lane.upper()}"])
                    expected["cache"]["s3"].update(ServerAddress="s3.example:8333", BucketName=bucket["bucketName"], AccessKey=access, SecretKey=secret)
                    self.assertEqual(runner, expected, f"{lane} configuration changed during generation")
                    self.assertEqual(runner["limit"], 1)
                    self.assertEqual(runner["request_concurrency"], 4)
                self.assertEqual(stat.S_IMODE(config_path.stat().st_mode), 0o600)
                system_id = paths["/config"] / ".runner_system_id"
                self.assertEqual(stat.S_IMODE(system_id.stat().st_mode), 0o600)
                self.assertEqual(system_id.read_text(), maps[system_ids[0]]["system_id"])
                self.assertEqual(sorted(p.name for p in paths["/config"].iterdir()), [".runner_system_id", "config.toml"])
                # Missing credentials must fail without disclosing any synthetic values.
                for invalid in ("token", "cosi"):
                    environment = {**os.environ, **tokens}
                    if invalid == "token":
                        environment["RUNNER_TOKEN_AMD64"] = ""
                    else:
                        (paths["/cosi/gitlab-runner-cache"] / "BucketInfo").write_text("{}")
                    result = subprocess.run(command, env=environment, capture_output=True, timeout=60)
                    self.assertNotEqual(result.returncode, 0)
                    output = result.stdout + result.stderr
                    for value in [*tokens.values(), access, secret]:
                        self.assertNotIn(value.encode(), output)
            finally:
                if container:
                    subprocess.run(["podman", "rm", "--force", "--ignore", name], check=True, capture_output=True)


if __name__ == "__main__":
    unittest.main()
