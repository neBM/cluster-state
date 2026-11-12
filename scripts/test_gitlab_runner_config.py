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

from validate_gitlab_runner_templates import cpu_millicores, validate_pool_contract, validate_storage_contract

ROOT = Path(__file__).resolve().parent.parent
RUNNERS = ROOT / "infrastructure/shared-services/gitlab-runner"
LANES = ("amd64", "arm64")


class RunnerConfigTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        renderer = ["kustomize", "build"] if shutil.which("kustomize") else ["kubectl", "kustomize"]
        cls.objects = list(yaml.safe_load_all(subprocess.check_output([*renderer, str(RUNNERS)], text=True)))
        cls.managers = [obj for obj in cls.objects if obj["kind"] == "Deployment"]
        cls.fixture = json.loads((ROOT / "scripts/fixtures/gitlab-runner-architecture-pools.json").read_text())
        cls.configs = {}
        cls.requests = {}

    def test_maintenance_keeps_hestia_scheduler_lock(self):
        jobs = {o['metadata']['name']: o for o in self.objects if o['kind'] == 'CronJob'}
        self.assertEqual(jobs['hestia-ci-cache-retention']['spec']['schedule'], '47 * * * *')
        for name in ('hestia-ci-store-gc', 'hestia-ci-cache-retention'):
            with self.subTest(job=name):
                template = jobs[name]['spec']['jobTemplate']['spec']['template']
                self.assertEqual(template['metadata']['labels']['ci.brmartin.co.uk/job'], 'true')
                self.assertEqual(template['metadata']['labels']['ci.brmartin.co.uk/maintenance'], 'true')
                pod = template['spec']
                self.assertEqual(pod['nodeSelector']['kubernetes.io/hostname'], 'hestia')
                self.assertEqual(pod['affinity']['podAntiAffinity'], {
                    'requiredDuringSchedulingIgnoredDuringExecution': [{
                        'labelSelector': {'matchLabels': {'ci.brmartin.co.uk/job': 'true'}},
                        'topologyKey': 'kubernetes.io/hostname',
                        'namespaces': ['ci', 'ci-maintenance-worker'],
                    }],
                })

    def test_store_gc_covers_overlay_and_vfs(self):
        job, = [o for o in self.objects if o['kind'] == 'CronJob'
                and o['metadata']['name'] == 'hestia-ci-store-gc']
        container, = job['spec']['jobTemplate']['spec']['template']['spec']['containers']
        script, = container['args']
        self.assertIn('for storage_driver in overlay vfs; do', script)
        self.assertIn('echo "CI store GC driver=${storage_driver}"', script)
        self.assertIn('--storage-driver=overlay', script)
        self.assertIn('--storage-driver=vfs', script)
        self.assertIn('--transient-store', script)
        self.assertIn('--runroot=/run/ci-containers-prune/vfs', script)
        self.assertIn('--tmpdir=/tmp/libpod-vfs', script)
        self.assertEqual(script.count('python3 -B /policy/maintenance-admission.py gc-claim'), 1)
        self.assertLess(script.index('gc-claim'), script.index('for storage_driver'))
        self.assertIn('container prune --force --filter until=168h', script)
        self.assertIn('ps -a --external --filter until=168h --format json', script)
        self.assertIn('image prune --all --force --filter until=168h', script)

    def test_maintenance_namespace_and_least_privilege(self):
        # Dedicated namespace keeps the existing CI job SA's Secret/ConfigMap
        # CRUD authority away from the administrator credential/restoration latch.
        jobs = {o['metadata']['name']: o for o in self.objects if o['kind'] == 'CronJob'}
        state, = [o for o in self.objects if o['kind'] == 'ConfigMap' and o['metadata']['name'] == 'hestia-ci-maintenance-state']
        self.assertEqual(state['metadata']['namespace'], 'ci-maintenance')
        self.assertNotIn('data', state)
        self.assertEqual(state['metadata']['annotations']['kustomize.toolkit.fluxcd.io/ssa'], 'Merge')
        self.assertEqual(jobs['hestia-ci-store-gc-admission']['spec']['schedule'], '16 4 * * *')
        for name, bound in (('hestia-ci-maintenance-admission', 1380),
                            ('hestia-ci-store-gc-admission', 1380), ('hestia-ci-maintenance-recovery', 50)):
            job = jobs[name]
            self.assertEqual(job['metadata']['namespace'], 'ci-maintenance')
            self.assertEqual(job['spec']['jobTemplate']['spec']['activeDeadlineSeconds'], bound)
            template = job['spec']['jobTemplate']['spec']['template']
            self.assertNotIn('ci.brmartin.co.uk/job', template['metadata']['labels'])
            self.assertNotIn('ci.brmartin.co.uk/maintenance', template['metadata']['labels'])
            pod = template['spec']
            self.assertNotIn('hostPID', pod)
            self.assertTrue(pod['securityContext']['runAsNonRoot'])
            self.assertTrue(all('hostPath' not in v for v in pod['volumes']))
            container, = pod['containers']
            self.assertEqual(container['securityContext']['capabilities']['drop'], ['ALL'])
            self.assertTrue(container['securityContext']['readOnlyRootFilesystem'])
            self.assertFalse(container['securityContext']['allowPrivilegeEscalation'])
            self.assertIn({'name': 'credential', 'mountPath': '/credential', 'readOnly': True}, container['volumeMounts'])
            policy, = [v for v in pod['volumes'] if v['name'] == 'policy']
            self.assertTrue(any(o['kind'] == 'ConfigMap' and o['metadata']['namespace'] == 'ci-maintenance'
                                and o['metadata']['name'] == policy['configMap']['name'] for o in self.objects))
        worker = jobs['hestia-ci-cache-retention']['spec']['jobTemplate']['spec']['template']['spec']
        self.assertFalse(worker['hostPID'])
        self.assertFalse(worker['shareProcessNamespace'])
        container, = worker['containers']
        self.assertEqual(container['image'], 'ghcr.io/astral-sh/uv@sha256:d21c2dd538d409d050027f67cd09f0b84882cf59072cf77720b15e21f3fe6af5')
        self.assertEqual(container['command'], ['/usr/local/bin/python3', '-B', '/policy/cache-retention.py'])
        self.assertEqual(container['args'], ['--execute'])
        self.assertEqual(container['resources'], {'requests': {'cpu': '10m', 'memory': '64Mi'}, 'limits': {'cpu': '500m', 'memory': '512Mi'}})
        self.assertIn({'name': 'host-proc', 'mountPath': '/host/proc', 'readOnly': True}, container['volumeMounts'])
        self.assertEqual([v for v in worker['volumes'] if 'hostPath' in v], [
            {'name': 'host-proc', 'hostPath': {'path': '/proc', 'type': 'Directory'}},
            {'name': 'builds', 'hostPath': {'path': '/var/lib/ci-builds-nocow', 'type': 'Directory'}},
            {'name': 'cache', 'hostPath': {'path': '/var/lib/ci-cache-nocow', 'type': 'Directory'}}])
        self.assertEqual(jobs['hestia-ci-cache-retention']['metadata']['namespace'], 'ci-maintenance-worker')
        namespaces = {o['metadata']['name']: o for o in self.objects if o['kind'] == 'Namespace'}
        self.assertEqual(namespaces['ci-maintenance-worker']['metadata']['labels']['pod-security.kubernetes.io/enforce'], 'privileged')
        accounts = {(o['metadata']['namespace'], o['metadata']['name']) for o in self.objects if o['kind'] == 'ServiceAccount'}
        self.assertIn(('ci-maintenance-worker', 'hestia-ci-maintenance-worker'), accounts)
        self.assertNotIn(('ci', 'hestia-ci-maintenance-worker'), accounts)
        policy, = [v for v in worker['volumes'] if v['name'] == 'policy']
        for control in ('hestia-ci-maintenance-admission', 'hestia-ci-store-gc-admission', 'hestia-ci-maintenance-recovery'):
            control_pod = jobs[control]['spec']['jobTemplate']['spec']['template']['spec']
            control_policy, = [v for v in control_pod['volumes'] if v['name'] == 'policy']
            self.assertEqual(policy['configMap']['name'], control_policy['configMap']['name'])
        gc_control = copy.deepcopy(jobs['hestia-ci-store-gc-admission']['spec'])
        gc_control['schedule'] = '47 * * * *'
        gc_control['jobTemplate']['spec']['template']['metadata']['labels'] = {'app': 'hestia-ci-maintenance-admission'}
        self.assertEqual(gc_control, jobs['hestia-ci-maintenance-admission']['spec'])
        self.assertTrue(any(o['kind'] == 'ConfigMap' and o['metadata']['namespace'] == 'ci-maintenance-worker'
                            and o['metadata']['name'] == policy['configMap']['name'] for o in self.objects))
        self.assertFalse(any('secret' in v for v in worker['volumes']))
        self.assertEqual(worker['serviceAccountName'], 'hestia-ci-maintenance-worker')
        for role in [o for o in self.objects if o['kind'] == 'Role' and o['metadata']['name'].startswith('hestia-ci-maintenance')]:
            for rule in role['rules']:
                self.assertNotIn('secrets', rule['resources'])
                self.assertTrue(set(rule['verbs']) <= {'get', 'list', 'update'})
                if 'configmaps' in rule['resources']:
                    self.assertEqual(role['metadata']['namespace'], 'ci-maintenance')
                    self.assertEqual(rule['resourceNames'], ['hestia-ci-maintenance-state'])
        for binding in [o for o in self.objects if o['kind'] == 'RoleBinding' and o['metadata']['namespace'] == 'ci-maintenance']:
            self.assertTrue(all(s['namespace'] == 'ci-maintenance' or
                                s['namespace'] == 'ci-maintenance-worker' and s['name'] in {'hestia-ci-maintenance-worker', 'hestia-ci-store-gc'}
                                for s in binding['subjects']))
        state_binding, = [o for o in self.objects if o['kind'] == 'RoleBinding' and o['metadata']['name'] == 'hestia-ci-maintenance-state']
        self.assertIn({'kind': 'ServiceAccount', 'name': 'hestia-ci-maintenance-worker', 'namespace': 'ci-maintenance-worker'}, state_binding['subjects'])
        roles = {(o['metadata']['namespace'], o['metadata']['name']): o for o in self.objects if o['kind'] == 'Role'}
        for binding in [o for o in self.objects if o['kind'] == 'RoleBinding' and o['metadata']['namespace'] in ('ci-maintenance', 'ci-maintenance-worker')]:
            self.assertTrue(all(s.get('namespace') != 'ci' for s in binding['subjects']))
        observer = roles['ci-maintenance-worker', 'hestia-ci-maintenance-observer']
        bindings = [o for o in self.objects if o['kind'] == 'RoleBinding']
        for identity, namespaces in ((('ci-maintenance-worker', 'hestia-ci-maintenance-worker'), ('ci', 'ci-maintenance-worker')),
                                     (('ci-maintenance', 'hestia-ci-maintenance-admission'), ('ci', 'ci-maintenance', 'ci-maintenance-worker')),
                                     (('ci-maintenance', 'hestia-ci-maintenance-recovery'), ('ci', 'ci-maintenance', 'ci-maintenance-worker'))):
            for namespace in namespaces:
                granted = [roles[namespace, b['roleRef']['name']] for b in bindings
                           if b['metadata']['namespace'] == namespace and any(
                               (s.get('namespace'), s.get('name')) == identity for s in b['subjects'])]
                self.assertTrue(any('pods' in rule['resources'] and 'list' in rule['verbs']
                                    for role in granted for rule in role['rules']), (identity, namespace))
        self.assertEqual(observer['rules'], [{'apiGroups': [''], 'resources': ['pods'], 'verbs': ['list']},
                                             {'apiGroups': ['batch'], 'resources': ['jobs'], 'verbs': ['get']}])
    def test_internal_metrics_service_and_policy(self):
        service, = [o for o in self.objects if o["kind"] == "Service"]
        policy, = [o for o in self.objects if o["kind"] == "CiliumNetworkPolicy"]
        self.assertEqual(service["metadata"]["namespace"], "default")
        self.assertEqual(service["metadata"]["annotations"], {
            "prometheus.io/scrape": "true", "prometheus.io/path": "/metrics",
            "prometheus.io/port": "9252",
        })
        self.assertEqual(service["spec"], {
            "type": "ClusterIP", "selector": {"app": "gitlab-runner"},
            "ports": [{"name": "metrics", "port": 9252, "targetPort": "metrics", "protocol": "TCP"}],
        })
        self.assertEqual(policy["metadata"]["namespace"], "default")
        self.assertEqual(policy["spec"], {
            "endpointSelector": {"matchLabels": service["spec"]["selector"]},
            "enableDefaultDeny": {"ingress": True, "egress": False},
            "ingress": [{"fromEndpoints": [{"matchLabels": {
                "k8s:io.kubernetes.pod.namespace": "default",
                "app.kubernetes.io/instance": "victoriametrics",
                "app.kubernetes.io/name": "victoriametrics",
            }}], "toPorts": [{"ports": [{"port": "9252", "protocol": "TCP"}]}]}],
            "ingressDeny": [{"fromEntities": ["world", "host", "remote-node"]}],
        })
        for manager in self.managers:
            template = manager["spec"]["template"]
            self.assertTrue(all(template["metadata"]["labels"].get(k) == v
                                for k, v in service["spec"]["selector"].items()))
            self.assertNotIn("prometheus.io/scrape", template["metadata"].get("annotations", {}))
            self.assertFalse(template["spec"].get("hostNetwork", False))
            self.assertEqual(template["spec"]["containers"][0]["ports"],
                             [{"name": "metrics", "containerPort": 9252, "protocol": "TCP"}])
        templates = (o for o in self.objects if o["kind"] == "ConfigMap"
                     and "20-runner-header.toml" in o.get("data", {}))
        for config in templates:
            runner, = tomllib.loads("".join(value for key, value in sorted(config["data"].items())))["runners"]
            self.assertNotEqual(runner["kubernetes"]["pod_labels"].get("app"), "gitlab-runner")

    def test_storage_contract_rejects_shared_graphroot_and_duplicate_mounts(self):
        templates = [o for o in self.objects if o["kind"] == "ConfigMap"
                     and "20-runner-header.toml" in o.get("data", {})]
        self.assertEqual(len(templates), len(LANES))
        for template in templates:
            runner, = tomllib.loads("".join(value for key, value in sorted(template["data"].items())))["runners"]
            self.assertEqual(validate_storage_contract(runner), [])
            for case in ("graphroot-hostpath", "tmpfs", "ephemeral-workspace", "ephemeral-cache",
                         "duplicate-repo", "duplicate-builds-mount", "different-builds-dir"):
                with self.subTest(template=template["metadata"]["name"], case=case):
                    bad = copy.deepcopy(runner)
                    volumes = bad["kubernetes"]["volumes"]
                    if case == "graphroot-hostpath":
                        volume, = volumes.pop("empty_dir")
                        volume.pop("medium")
                        volume.update(host_path="/var/lib/ci-containers-nocow", read_only=False)
                        volumes["host_path"].append(volume)
                    elif case == "tmpfs":
                        volumes["empty_dir"][0]["medium"] = "Memory"
                    elif case in ("ephemeral-workspace", "ephemeral-cache"):
                        index = 0 if case == "ephemeral-workspace" else 1
                        volume = volumes["host_path"].pop(index)
                        volumes["empty_dir"].append({"name": volume["name"], "mount_path": volume["mount_path"], "medium": ""})
                    elif case == "duplicate-repo":
                        volumes["pvc"] = [{"name": "repo", "mount_path": "/extra"}]
                    elif case == "duplicate-builds-mount":
                        volumes["empty_dir"].append({"name": "extra", "mount_path": "/builds", "medium": ""})
                    else:
                        bad["builds_dir"] = "/other-builds"
                    self.assertTrue(validate_storage_contract(bad))

    def test_architecture_admission_and_generator(self):
        self.assertEqual(sorted(m["metadata"]["name"] for m in self.managers),
                         ["gitlab-runner"])
        maps = {obj["metadata"]["name"]: obj.get("data", {}) for obj in self.objects if obj["kind"] == "ConfigMap"}
        pins = {image["name"]: image for image in yaml.safe_load((RUNNERS / "kustomization.yaml").read_text())["images"]}
        system_ids = []
        for manager in self.managers:
            arch = "architecture"
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
                    self.assertEqual(actual["listen_address"], ":9252")
                    self.assertEqual(actual["session_server"], {"session_timeout": 1800})
                    for lane, runner in zip(environment["RUNNER_LANES"].split(), actual["runners"], strict=True):
                        template_dir = paths[f"/template/{lane}"]
                        # Exact rendered fragment map consumed by this production manager.
                        expected = tomllib.loads("".join(p.read_text() for p in sorted(template_dir.glob("[2-9][0-9]-*.toml"))))["runners"][0]
                        expected.update(name=f"k8s-{lane}", token=tokens[f"RUNNER_TOKEN_{lane.upper()}"])
                        expected["cache"]["s3"].update(ServerAddress="s3.example:8333", BucketName=bucket["bucketName"], AccessKey=access, SecretKey=secret)
                        self.assertEqual(runner, expected, f"{arch}/{lane}: generation changed lane semantics")
                        self.assertEqual(runner["request_concurrency"], 4)
                        self.assertEqual(runner["feature_flags"], {"FF_EXPORT_HIGH_CARDINALITY_METRICS": True})
                        # Runner chooses its version-coupled, selector-aware native helper.
                        self.assertNotIn("helper_image", runner["kubernetes"], f"{arch}/{lane}")
                        k = runner["kubernetes"]
                        self.assertEqual(k['affinity']['pod_anti_affinity']['required_during_scheduling_ignored_during_execution'][0]['namespaces'], ['ci', 'ci-maintenance-worker'])
                        self.assertTrue(k["privileged"])
                        self.assertFalse(k["enable_service_links"])
                        self.assertEqual(k["cpu_request"], "250m" if lane == "amd64" else "500m")
                        self.assertEqual(k["helper_cpu_request"], "50m")
                        self.assertEqual(k["service_cpu_request"], "25m")
                        self.assertEqual(k["service_account"], "gitlab-runner")
                        self.assertEqual(k["namespace"], "ci")
                        self.assertEqual(k["pull_policy"], ["if-not-present"])
                        self.assertEqual(k["allowed_pull_policies"], ["always", "if-not-present", "never"])
                        self.assertEqual(validate_storage_contract(runner), [], f"{arch}/{lane}")
                        self.assertTrue({"DOCKER_HOST=tcp://kubedock:2475", "TESTCONTAINERS_RYUK_DISABLED=true",
                                         "TESTCONTAINERS_CHECKS_DISABLE=true"}.issubset(runner["environment"]))
                        self.assertEqual(runner["kubernetes"].get("image_pull_secrets", []),
                                         ["gitlab-runner-helper-pull"])
                        services = runner["kubernetes"].get("services", [])
                        self.assertEqual(services, [{
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
                            # Reject independent manager bounds in the unified pool.
                            invalid_env["RUNNER_CONCURRENT"] = "2"
                        result = subprocess.run(command, env=invalid_env, capture_output=True, timeout=60)
                        self.assertNotEqual(result.returncode, 0)
                        for value in [*tokens.values(), access, secret]:
                            self.assertNotIn(value.encode(), result.stdout + result.stderr)
                finally:
                    if container:
                        subprocess.run(["podman", "rm", "--force", "--ignore", name], check=True, capture_output=True)
        self.assertEqual(len(set(system_ids)), 1)
        self.assertEqual(validate_pool_contract(self.configs, self.requests, self.fixture), [])
        self.assertEqual({arch: c["concurrent"] for arch, c in self.configs.items()},
                         {"architecture": 3})
        self.assertEqual([r["limit"] for r in self.configs["architecture"]["runners"]], [1, 2])
        # Synthetic resource-fit counterexample: CPU and memory must fit on the
        # same node. This does not dynamically lower production pool limits.
        constrained = copy.deepcopy(self.fixture)
        constrained["pools"]["arm64"].update(
            headroom_cpu_m=[100, 1000], headroom_memory_mi=[2048, 8])
        self.assertIn("arm64: fixture fits only 0 of 2 configured slots",
                      validate_pool_contract(self.configs, self.requests, constrained))
        for case in ("global-bound", "arm-bound", "amd-bound", "extra-manager", "extra-registration",
                     "architecture-escape", "unaccounted-services", "oversized-sidecars", "oversized-build"):
            with self.subTest(case=case):
                bad = copy.deepcopy(self.configs)
                config = bad["architecture"]
                amd, arm = config["runners"]
                if case == "global-bound":
                    config["concurrent"] = 4
                elif case == "arm-bound":
                    arm["limit"] = 3
                elif case == "amd-bound":
                    amd["limit"] = 2
                elif case == "extra-manager":
                    bad["any"] = copy.deepcopy(config)
                elif case == "extra-registration":
                    config["runners"].append(copy.deepcopy(amd))
                elif case == "architecture-escape":
                    del arm["kubernetes"]["node_selector"]
                elif case == "unaccounted-services":
                    amd["kubernetes"]["service_cpu_request"] = "0"
                elif case == "oversized-sidecars":
                    amd["kubernetes"]["service_cpu_request"] = "400m"
                else:
                    amd["kubernetes"]["cpu_request"] = "1500m"
                self.assertTrue(validate_pool_contract(bad, self.requests, self.fixture))


if __name__ == "__main__":
    unittest.main()
