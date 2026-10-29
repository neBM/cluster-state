#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML==6.0.3"]
# ///
"""Exercise rendered architecture admission and the production config generator."""

import copy
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

from validate_gitlab_runner_templates import cpu_millicores, validate_pool_contract

ROOT = Path(__file__).resolve().parent.parent
RUNNERS = ROOT / "infrastructure/shared-services/gitlab-runner"
LANES = ("amd64", "any", "arm64", "services")


class RunnerConfigTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        renderer = ["kustomize", "build"] if shutil.which("kustomize") else ["kubectl", "kustomize"]
        cls.objects = list(yaml.safe_load_all(subprocess.check_output([*renderer, str(RUNNERS)], text=True)))
        cls.managers = [obj for obj in cls.objects if obj["kind"] == "Deployment"]
        cls.fixture = json.loads((ROOT / "scripts/fixtures/gitlab-runner-architecture-pools.json").read_text())
        cls.configs = {}
        cls.requests = {}

    def test_architecture_admission_and_generator(self):
        self.assertEqual(sorted(m["metadata"]["name"] for m in self.managers),
                         ["gitlab-runner-amd64", "gitlab-runner-arm64"])
        maps = {obj["metadata"]["name"]: obj["data"] for obj in self.objects if obj["kind"] == "ConfigMap"}
        pins = {image["name"]: image for image in yaml.safe_load((RUNNERS / "kustomization.yaml").read_text())["images"]}
        system_ids = []
        for manager in self.managers:
            arch = manager["spec"]["template"]["metadata"]["labels"]["pool"]
            self.assertEqual(manager["spec"]["replicas"], 1)
            self.assertEqual(manager["spec"]["strategy"], {"type": "Recreate"})
            pod = manager["spec"]["template"]["spec"]
            self.assertNotIn("nodeSelector", pod)
            self.assertEqual(pod["serviceAccountName"], "gitlab-runner")
            self.assertEqual(len(pod["containers"]), 1)
            self.assertEqual(pod["containers"][0]["args"], ["run", "--config", "/config/config.toml"])
            self.requests[arch] = pod["containers"][0]["resources"]["requests"]
            init, = pod["initContainers"]
            for name, container in (("busybox", init), ("gitlab/gitlab-runner", pod["containers"][0])):
                pin = pins[name]
                self.assertRegex(pin["digest"], r"^sha256:[0-9a-f]{64}$")
                self.assertEqual(container["image"], f'{pin.get("newName", name)}:{pin["newTag"]}@{pin["digest"]}')
            refs = {e["name"]: e["valueFrom"]["secretKeyRef"] for e in init["env"] if "valueFrom" in e}
            self.assertEqual(refs, {f"RUNNER_TOKEN_{lane.upper()}": {
                "name": "gitlab-runner-secrets", "key": f"runner_token_{lane}", "optional": False
            } for lane in LANES})
            tokens = {f"RUNNER_TOKEN_{lane.upper()}": f'synthetic-{lane}-&|\\"$`' for lane in LANES}
            environment = {**os.environ, **tokens, **{e["name"]: e["value"] for e in init["env"] if "value" in e}}
            access, secret = "synthetic-access-&|$", "synthetic-secret-&|$"
            bucket = {"bucketName": "gitlab-runner-cache", "endpoint": "http://s3.example:8333",
                      "accessKeyID": access, "accessSecretKey": secret}
            volumes = {v["name"]: v for v in pod["volumes"]}
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
                    for e in init["env"]:
                        launch += ["-e", e["name"]]
                    command = [*launch, "docker.io/library/" + init["image"], *command]
                else:
                    paths["/template"] = root / "template"
                    pattern = "(?:" + "|".join(re.escape(p) for p in sorted(paths, key=len, reverse=True)) + r")(?![\w.-])"
                    command[-1] = re.sub(pattern, lambda m: str(paths[m[0]]), command[-1])
                try:
                    result = subprocess.run(command, env=environment, capture_output=True, timeout=60)
                    self.assertEqual(result.returncode, 0, "config generator failed (output withheld)")
                    self.assertEqual(result.stdout + result.stderr, b"", "generator must not log credentials")
                    config_path = paths["/config"] / "config.toml"
                    actual = tomllib.loads(config_path.read_text())
                    self.configs[arch] = actual
                    self.assertEqual(actual["check_interval"], 1)
                    self.assertEqual(actual["shutdown_timeout"], 0)  # admitted idle cutover, not an active-job drain claim
                    self.assertEqual(actual["session_server"], {"session_timeout": 1800})
                    for lane, runner in zip(environment["RUNNER_LANES"].split(), actual["runners"], strict=True):
                        template_dir = paths[f"/template/{lane}"]
                        # Exact rendered fragment map consumed by this production manager.
                        expected = tomllib.loads("".join(p.read_text() for p in sorted(template_dir.glob("[2-9][0-9]-*.toml"))))["runners"][0]
                        expected.update(name=f"k8s-{lane}", token=tokens[f"RUNNER_TOKEN_{lane.upper()}"])
                        expected["cache"]["s3"].update(ServerAddress="s3.example:8333", BucketName=bucket["bucketName"], AccessKey=access, SecretKey=secret)
                        self.assertEqual(runner, expected, f"{arch}/{lane}: generation changed lane semantics")
                        self.assertEqual(runner["request_concurrency"], 4)
                        # Runner chooses its version-coupled, selector-aware native helper.
                        self.assertNotIn("helper_image", runner["kubernetes"], f"{arch}/{lane}")
                        self.assertEqual(runner["kubernetes"].get("image_pull_secrets", []),
                                         ["gitlab-runner-helper-pull"] if lane in ("any", "services") else [])
                        services = runner["kubernetes"].get("services", [])
                        self.assertEqual(services, [] if lane == "any" else [{
                            "name": "joyrex2001/kubedock:0.20.3", "alias": "kubedock",
                            "command": ["server", "--port-forward"]
                        }])
                    self.assertEqual(stat.S_IMODE(config_path.stat().st_mode), 0o600)
                    system_id = paths["/config"] / ".runner_system_id"
                    self.assertEqual(stat.S_IMODE(system_id.stat().st_mode), 0o600)
                    self.assertEqual(system_id.read_text(), (paths["/system-id"] / "system_id").read_text())
                    system_ids.append(system_id.read_text())
                    self.assertEqual(sorted(p.name for p in paths["/config"].iterdir()), [".runner_system_id", "config.toml"])
                    for invalid in ("token", "cosi", "pool"):
                        invalid_env = environment.copy()
                        if invalid == "token":
                            invalid_env[f"RUNNER_TOKEN_{environment['RUNNER_LANES'].split()[0].upper()}"] = ""
                        elif invalid == "cosi":
                            (paths["/cosi/gitlab-runner-cache"] / "BucketInfo").write_text("{}")
                        else:
                            (paths["/cosi/gitlab-runner-cache"] / "BucketInfo").write_text(json.dumps(bucket))
                            # Reject the former two-slot ARM pool, not only three.
                            invalid_env["RUNNER_CONCURRENT"] = "2"
                        result = subprocess.run(command, env=invalid_env, capture_output=True, timeout=60)
                        self.assertNotEqual(result.returncode, 0)
                        for value in [*tokens.values(), access, secret]:
                            self.assertNotIn(value.encode(), result.stdout + result.stderr)
                finally:
                    if container:
                        subprocess.run(["podman", "rm", "--force", "--ignore", name], check=True, capture_output=True)
        self.assertEqual(len(set(system_ids)), 2)
        self.assertEqual(validate_pool_contract(self.configs, self.requests, self.fixture), [])
        self.assertEqual({arch: c["concurrent"] for arch, c in self.configs.items()},
                         {"amd64": 1, "arm64": 1})
        self.assertEqual(sum(c["concurrent"] for c in self.configs.values()), 2)
        # Nyx has abundant CPU but only 7.8Mi memory after GitLab reservations.
        # Both dimensions must fit on the same node; it is not a second ARM slot.
        measured = copy.deepcopy(self.fixture)
        measured["pools"]["arm64"].update(
            headroom_cpu_m=[1240, 2530],
            headroom_memory_mi=[4690.796875, 7.83203125])
        self.assertEqual(validate_pool_contract(self.configs, self.requests, measured), [])
        fake_two_slots = copy.deepcopy(self.configs)
        fake_two_slots["arm64"]["concurrent"] = 2
        fake_two_slots["arm64"]["runners"][1]["limit"] = 2
        self.assertIn("arm64: acquisition bound must equal 1 usable slots",
                      validate_pool_contract(fake_two_slots, self.requests, measured))
        # CPU on Nyx and memory on Heracles cannot be combined into one slot.
        measured["pools"]["arm64"]["headroom_cpu_m"][0] = 100
        self.assertIn("arm64: acquisition bound must equal 0 usable slots",
                      validate_pool_contract(self.configs, self.requests, measured))
        # Focused counterexamples: over-acquisition, architecture escape, and the
        # actual native + helper + Kubedock + two database sidecars CPU envelope.
        for case in ("second-arm-slot", "second-amd-slot", "old-all-lane-manager", "generic-architecture", "unaccounted-services", "oversized-sidecars", "oversized-amd-service"):
            with self.subTest(case=case):
                bad = copy.deepcopy(self.configs)
                if case == "second-arm-slot":
                    bad["arm64"]["concurrent"] = 2
                elif case == "second-amd-slot":
                    bad["amd64"]["concurrent"] = 2
                elif case == "old-all-lane-manager":
                    bad["any"] = copy.deepcopy(bad["arm64"])
                elif case == "generic-architecture":
                    del bad["amd64"]["runners"][1]["kubernetes"]["node_selector"]
                elif case == "unaccounted-services":
                    bad["amd64"]["runners"][0]["kubernetes"]["service_cpu_request"] = "0"
                elif case == "oversized-sidecars":
                    # Exceed the target budget, including its larger raw headroom.
                    bad["amd64"]["runners"][0]["kubernetes"]["service_cpu_request"] = "400m"
                else:
                    bad["amd64"]["runners"][2]["kubernetes"]["cpu_request"] = "1500m"
                self.assertTrue(validate_pool_contract(bad, self.requests, self.fixture))


if __name__ == "__main__":
    unittest.main()
