#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["PyYAML==6.0.3"]
# ///
"""Mutate the real candidate source and one real Helm render, never fake readiness."""
import copy
import importlib.util
import os
import subprocess
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

    def _render_preparation(self, path):
        # Same native fallback as validate_kustomize.sh; no API access.
        command = ['kustomize', 'build'] if self.v.shutil.which('kustomize') else ['kubectl', 'kustomize']
        rendered = subprocess.check_output(command + [str(ROOT / path)], text=True)
        return [doc for doc in yaml.safe_load_all(rendered) if doc]

    def test_native_redis_preparation(self):
        """Source-only guards: never start Redis to prepare a blank WFFC volume."""
        docs = self._render_preparation('apps/gitlab-redis')
        self.assertCountEqual([d['kind'] for d in docs],
                              ['PersistentVolumeClaim', 'ConfigMap', 'CiliumNetworkPolicy',
                               'Service', 'StatefulSet', 'Job'])
        objects = {d['kind']: d for d in docs}
        claim = objects['PersistentVolumeClaim']
        self.assertEqual(claim['spec'], {'accessModes': ['ReadWriteOnce'],
                         'storageClassName': 'local-path-retain',
                         'resources': {'requests': {'storage': '1Gi'}}})
        self.assertEqual(claim['metadata']['annotations']['kustomize.toolkit.fluxcd.io/prune'], 'Disabled')
        self.assertEqual(claim['metadata']['annotations'].get('volumeType'), 'local')
        config = objects['ConfigMap']
        self.assertIs(config['immutable'], True)
        self.assertEqual(set(config['data']), {'redis.conf'})
        for directive in ('bind 127.0.0.1', 'databases 16', 'maxmemory 0',
                          'maxmemory-policy noeviction', 'appendonly yes', 'appendfsync always',
                          'no-appendfsync-on-rewrite no', 'aof-load-truncated no',
                          'auto-aof-rewrite-min-size 64mb'):
            self.assertIn(directive, config['data']['redis.conf'].splitlines())
        stateful = objects['StatefulSet']['spec']
        self.assertEqual(stateful['replicas'], 0)
        self.assertEqual(stateful['updateStrategy'], {'type': 'OnDelete'})
        service = objects['Service']['spec']
        self.assertEqual(service['clusterIP'], 'None')
        self.assertIs(service['publishNotReadyAddresses'], False)
        self.assertEqual(service['selector'], {'app': 'gitlab-redis-durable', 'role': 'durable'})
        policy = objects['CiliumNetworkPolicy']['spec']
        self.assertEqual(policy['endpointSelector']['matchLabels'], {'app': 'gitlab-redis-durable'})
        self.assertEqual(policy['enableDefaultDeny'], {'ingress': True, 'egress': True})
        self.assertEqual(policy['ingress'], [])
        self.assertEqual(policy['egress'], [])
        self.assertEqual(policy['ingressDeny'], [{'fromEntities': ['world', 'host', 'remote-node']}])
        job = objects['Job']['spec']
        self.assertEqual((job['parallelism'], job['completions'], job['backoffLimit'], job['activeDeadlineSeconds']),
                         (1, 1, 0, 300))
        self.assertNotIn('suspend', job)  # Ordinary finite completion, not a suspended health bypass.
        prepare = job['template']['spec']
        self.assertEqual(prepare['restartPolicy'], 'Never')
        self.assertEqual(prepare['activeDeadlineSeconds'], 300)
        self.assertEqual(prepare['volumes'], [{'name': 'data', 'persistentVolumeClaim':
                         {'claimName': claim['metadata']['name']}}])
        self.assertEqual(prepare['containers'][0]['volumeMounts'], [{'name': 'data', 'mountPath': '/data'}])
        prod_selector = yaml.safe_load((ROOT / 'apps/gitlab/service-default-gitlab-redis.yaml').read_text())['spec']['selector']
        for workload in (stateful, job):
            labels = workload['template']['metadata']['labels']
            self.assertFalse(all(labels.get(k) == v for k, v in prod_selector.items()))
            self.assertEqual(labels['app'], 'gitlab-redis-durable')
            pod = workload['template']['spec']
            self.assertIs(pod['automountServiceAccountToken'], False)
            self.assertIs(pod['enableServiceLinks'], False)
            self.assertEqual(pod['terminationGracePeriodSeconds'], 60)
            self.assertEqual(pod['securityContext'], {'runAsNonRoot': True, 'runAsUser': 999,
                             'runAsGroup': 1000, 'fsGroup': 1000, 'fsGroupChangePolicy': 'OnRootMismatch',
                             'seccompProfile': {'type': 'RuntimeDefault'}})
            self.assertNotIn('initContainers', pod)
            self.assertEqual(len(pod['containers']), 1)
            container = pod['containers'][0]
            self.assertEqual(container['image'], 'docker.io/library/redis@sha256:9d317178eceac8454a2284a9e6df2466b93c745529947f0cd42a0fa9609d7005')
            self.assertEqual(container['resources'], {'requests': {'cpu': '50m', 'memory': '32Mi'}, 'limits': {'memory': '256Mi'}})
            self.assertEqual(container['securityContext'], {'allowPrivilegeEscalation': False,
                             'readOnlyRootFilesystem': True, 'capabilities': {'drop': ['ALL']}})
            self.assertNotIn('env', container)
            self.assertNotIn('envFrom', container)
        redis = stateful['template']['spec']['containers'][0]
        self.assertEqual(redis['args'], ['umask 077\ntest -s /data/appendonlydir/appendonly.aof.manifest\n'
                         'exec /usr/local/bin/docker-entrypoint.sh redis-server /etc/redis/redis.conf\n'])
        initializer = prepare['containers'][0]
        self.assertEqual(initializer['command'], ['/bin/sh', '-ec'])
        self.assertNotIn('ports', initializer)
        shell = initializer['args'][0]
        subprocess.run(['/bin/sh', '-n'], input=shell, text=True, check=True)
        self.assertNotRegex(shell, r'\b(redis-server|redis-cli|curl|wget|chown)\b')
        self.assertIn('sync "$probe"', shell)
        self.assertNotRegex(shell, r'(?m)^\s*sync(?:\s+-[^\n]*)?\s*$')

    def test_redis_volume_type_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for directory in ("apps", "clusters", "infrastructure/observability-ui/grafana", "infrastructure/storage/gitlab-recovery"):
                self.v.shutil.copytree(ROOT / directory, root / directory)
            path = root / "apps/gitlab-redis/persistentvolumeclaim.yaml"
            claim = yaml.safe_load(path.read_text())
            for volume_type in (None, 'hostPath'):
                with self.subTest(volume_type=volume_type):
                    annotations = claim['metadata']['annotations']
                    annotations.pop('volumeType', None)
                    if volume_type is not None:
                        annotations['volumeType'] = volume_type
                    path.write_text(yaml.safe_dump(claim))
                    errors = self.v.validate_source(root)
                    self.assertTrue(any('volumeType' in error for error in errors), errors)

    def test_inactive_preparation_leaves(self):
        for name in ('gitlab-helm', 'gitlab-redis'):
            leaf = yaml.safe_load((ROOT / f'clusters/k3s-homelab/flux-system/kustomization-{name}.yaml').read_text())
            self.assertEqual(leaf['spec']['sourceRef'], {'kind': 'GitRepository', 'name': 'cluster-state'})
            self.assertIs(leaf['spec']['suspend'], True)
            self.assertIs(leaf['spec']['wait'], True)
            self.assertIs(leaf['spec']['prune'], False)
            self.assertEqual(leaf['spec']['path'], f'./apps/{name}')
            self.assertIn({'name': 'storage-classes'}, leaf['spec']['dependsOn'])
            self.assertNotIn('healthCheckExprs', leaf['spec'])
        for entrypoint in ('apps', 'clusters/k3s-homelab'):
            for doc in self._render_preparation(entrypoint):
                self.assertFalse(doc.get('metadata', {}).get('name', '').startswith('gitlab-redis-durable'))
                self.assertFalse(doc.get('kind') == 'Kustomization' and doc['metadata']['name'] == 'gitlab-redis')

    def test_recovery_destination(self):
        patches = self.release['spec']['postRenderers'][0]['kustomize']['patches']
        claims = [op['value']['persistentVolumeClaim']['claimName']
                  for patch in patches for op in yaml.safe_load(patch['patch'])
                  if isinstance(op.get('value'), dict) and 'persistentVolumeClaim' in op['value']]
        self.assertEqual(claims, ['gitlab-helm-recovery-windsor-sync'] * 2)

    def test_recovery_storage_mutations(self):
        storage = self.v.kustomize(ROOT, 'infrastructure/storage/gitlab-recovery')
        leaf = yaml.safe_load((ROOT / 'clusters/k3s-homelab/flux-system/kustomization-gitlab-recovery-storage.yaml').read_text())
        prepared = self.v.kustomize(ROOT, 'apps/gitlab-helm')
        self.assertEqual(self.v.validate_recovery_storage(storage, leaf, prepared), [])
        for field, value in (
            ('server', 'example.invalid'), ('share', '/not-a-private-config-reference'),
            ('onDelete', 'delete'),
            ('subDir', '${pvc.metadata.namespace}/${pvc.metadata.name}-${pv.metadata.name}'),
        ):
            changed = copy.deepcopy(storage)
            changed[0]['parameters'][field] = value
            self.assertTrue(self.v.validate_recovery_storage(changed, leaf, prepared), field)
        for field, value in (('allowVolumeExpansion', 0), ('reclaimPolicy', 'Delete'), ('volumeBindingMode', 'WaitForFirstConsumer')):
            changed = copy.deepcopy(storage)
            changed[0][field] = value
            self.assertTrue(self.v.validate_recovery_storage(changed, leaf, prepared), field)
        for field, value in (
            ('sourceRef', {'kind': 'GitRepository', 'name': 'flux-system'}),
            ('dependsOn', []), ('postBuild', {}), ('prune', 1), ('wait', 1),
            ('postBuild', {'substituteFrom': [{'kind': 'Secret', 'name': 'gitlab-recovery-nfs-config', 'optional': 0}]}),
        ):
            changed = copy.deepcopy(leaf)
            changed['spec'][field] = value
            self.assertTrue(self.v.validate_recovery_storage(storage, changed, prepared), field)
        for claim in [d for d in prepared if d['kind'] == 'PersistentVolumeClaim']:
            changed = copy.deepcopy(prepared)
            changed.remove(claim)
            self.assertTrue(self.v.validate_recovery_storage(storage, leaf, changed), claim['metadata']['name'])
            changed = copy.deepcopy(prepared)
            next(d for d in changed if d == claim)['metadata']['annotations'] = {}
            self.assertTrue(self.v.validate_recovery_storage(storage, leaf, changed))

    def test_backup_monitoring_source(self):
        document = yaml.safe_load((ROOT / "infrastructure/observability-ui/grafana/_grafana_alert_rules.yaml").read_text())
        rules = [r for g in document["groups"] if g["name"] == "backup-health" for r in g["rules"]]
        native = [r for r in rules if r["uid"].startswith("gitlab-native-backup-")]
        self.assertEqual(len(native), 2, "native backup failure and stale/missing alerts are required")
        self.assertEqual(self.v.validate_backup_alerts(document), [])

    def test_backup_monitoring_mutations(self):
        """Synthetic rule mutations: source-contract checks, NOT PromQL execution."""
        document = yaml.safe_load((ROOT / "infrastructure/observability-ui/grafana/_grafana_alert_rules.yaml").read_text())
        rules = [r for g in document["groups"] if g["name"] == "backup-health" for r in g["rules"]]
        native = [r for r in rules if r["uid"].startswith("gitlab-native-backup-")]
        self.assertEqual(len(native), 2, "native monitoring rules missing")
        for rule in native:
            for name, old, new in (
                ("suspension gate", "== 0", "== 1"),
                ("other owner", 'owner_name="gitlab-helm-toolbox-backup"', 'owner_name="unrelated-backup"'),
                ("other namespace", 'namespace="default"', 'namespace="unrelated"'),
                ("non-controller owner", 'owner_is_controller="true"', 'owner_is_controller="false"'),
                ("completion extends bound", "kube_job_status_start_time", "kube_job_status_completion_time"),
                ("missing first success hidden", "or on(namespace)", "and on(namespace)"),
                ("not a completed Job", "kube_job_complete", "kube_job_status_active"),
            ):
                with self.subTest(uid=rule["uid"], mutation=name):
                    changed = copy.deepcopy(document)
                    target = next(r for g in changed["groups"] for r in g["rules"] if r["uid"] == rule["uid"])
                    expression = target["data"][0]["model"]["expr"]
                    self.assertIn(old, expression, name)
                    target["data"][0]["model"]["expr"] = expression.replace(old, new)
                    self.assertTrue(self.v.validate_backup_alerts(changed), name)
            changed = copy.deepcopy(document)
            target = next(r for g in changed["groups"] for r in g["rules"] if r["uid"] == rule["uid"])
            target["data"][1]["model"]["conditions"][0]["evaluator"]["params"] = [93601]
            self.assertTrue(self.v.validate_backup_alerts(changed), "wrong firing bound")
        changed = copy.deepcopy(document)
        target = next(r for g in changed["groups"] for r in g["rules"] if r["uid"] == "gitlab-native-backup-failed-api")
        expression = target["data"][0]["model"]["expr"]
        self.assertIn("> on(namespace)", expression)
        target["data"][0]["model"]["expr"] = expression.replace("> on(namespace)", "or on(namespace)")
        self.assertTrue(self.v.validate_backup_alerts(changed), "later-success failure suppression drift")

    def test_source_drift(self):
        changes = [
            ("edition", lambda r: r["spec"]["values"]["global"].update(edition="ee")),
            ("version", lambda r: r["spec"]["chart"]["spec"].update(version="10.4.0")),
            ("activation", lambda r: r["spec"].update(suspend=False)),
            ("integer suspend alias", lambda r: r["spec"].update(suspend=1)),
            ("boolean retries alias", lambda r: r["spec"]["upgrade"]["remediation"].update(retries=False)),
            ("boolean workerProcesses alias", lambda r: r["spec"]["values"]["gitlab"]["webservice"].update(workerProcesses=True)),
            ("workers", lambda r: r["spec"]["values"]["gitlab"]["sidekiq"].update(concurrency=20)),
            ("duplicate controller", lambda r: r["spec"]["values"]["global"]["gatewayApi"].update(enabled=True)),
            ("independent app pin", lambda r: r["spec"]["values"]["global"].update(gitlabVersion="19.4.0")),
            ("hook strategy", lambda r: r["spec"].update(postRenderStrategy="separate")),
            ("hook selector", lambda r: r["spec"]["postRenderers"][0]["kustomize"]["patches"][0]["target"].update(name="wrong")),
            ("no patch", lambda r: r["spec"].update(postRenderers=[])),
            ("fsGroup NAS mutation", lambda r: r["spec"]["values"]["upgradeCheck"]["securityContext"].update(fsGroup=1000)),
            ("backup active", lambda r: r["spec"]["values"]["gitlab"]["toolbox"]["backups"]["cron"].update(suspend=False)),
            ("backup unbounded", lambda r: r["spec"]["values"]["gitlab"]["toolbox"]["backups"]["cron"].update(backoffLimit=6)),
            ("wrong registry bucket", lambda r: r["spec"]["values"]["global"]["registry"].update(bucket="registry")),
            ("optional blobs", lambda r: r["spec"]["values"]["global"]["appConfig"]["terraformState"].update(enabled=True)),
            ("internal S3 redirect", lambda r: r["spec"]["values"]["registry"]["storage"]["redirect"].update(disable=False)),
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
            for directory in ("apps", "clusters", "infrastructure/observability-ui/grafana", "infrastructure/storage/gitlab-recovery"):
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


    def test_backup_and_export_contract_mutations(self):
        path = os.environ.get("GITLAB_HELM_RENDERED")
        self.assertIsNotNone(path, "real native Helm render required")
        assert path is not None
        docs = [d for d in yaml.safe_load_all(Path(path).read_text()) if d]
        self.assertEqual(self.v.validate_backup_render(docs), [])
        for key, value in (("suspend", False), ("schedule", "0 0 * * *"), ("timeZone", "UTC")):
            changed = copy.deepcopy(docs)
            next(d for d in changed if d["kind"] == "CronJob")["spec"][key] = value
            self.assertTrue(self.v.validate_backup_render(changed))
        changed = copy.deepcopy(docs)
        cron = next(d for d in changed if d["kind"] == "CronJob")
        cron["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]["args"] = ["replacement"]
        self.assertTrue(self.v.validate_backup_render(changed))
        self.assertFalse(any(d['kind'] == 'CronJob' for d in self.v.kustomize(ROOT, 'apps/gitlab-helm')))
        self.assertEqual(self.v.validate_backup_input(docs), [])
        native = self.v.backup_crons(docs)[0]
        for name, mutate in (
            ('unmatched', lambda ds: ds.remove(next(d for d in ds if d == native))),
            ('duplicate', lambda ds: ds.append(copy.deepcopy(native))),
            ('command shape', lambda ds: self.v.backup_crons(ds)[0]['spec']['jobTemplate']['spec']['template']['spec']['containers'][0].update(args=['wrong'])),
        ):
            with self.subTest(name=name):
                changed = copy.deepcopy(docs)
                mutate(changed)
                with self.assertRaises(ValueError):
                    self.v.apply_postrender(changed, self.release)
        with self.assertRaises(subprocess.CalledProcessError):
            self.v.apply_postrender(changed, self.release, check_input=False)
        patched = self.v.apply_postrender(docs, self.release)
        self.assertEqual(self.v.validate_backup_postrender(docs, patched), [])
        subprocess.run(['bash', '-n', '-c', self.v.SITE_BACKUP_ARGS[2]], check=True)
        for name, mutate in (
            ('NAS ownership repair', lambda s: s['securityContext'].update(fsGroup=1000)),
            ('API token', lambda s: s.update(automountServiceAccountToken=True)),
            ('configure changed', lambda s: s['initContainers'][0].update(name='wrong')),
            ('native env changed', lambda s: s['containers'][0]['env'].pop()),
            ('native image changed', lambda s: s['containers'][0].update(image='wrong')),
            ('missing NAS mount', lambda s: s['containers'][0]['volumeMounts'].pop()),
            ('old async destination', lambda s: next(v for v in s['volumes'] if v['name'] == 'backup-recovery')['persistentVolumeClaim'].update(claimName='gitlab-helm-recovery-windsor')),
        ):
            with self.subTest(name=name):
                changed = copy.deepcopy(patched)
                mutate(self.v.backup_crons(changed)[0]['spec']['jobTemplate']['spec']['template']['spec'])
                self.assertTrue(self.v.validate_postrender(docs, changed, self.release))
        unmatched = copy.deepcopy(self.release)
        unmatched['spec']['postRenderers'][0]['kustomize']['patches'][1]['target']['name'] = '^unmatched$'
        self.assertTrue(self.v.validate_postrender(docs, self.v.apply_postrender(docs, unmatched), unmatched))

    def test_native_postrender_shape_denials(self):
        path = os.environ.get("GITLAB_HELM_RENDERED")
        self.assertIsNotNone(path, "real Helm render required")
        assert path is not None
        docs = [d for d in yaml.safe_load_all(Path(path).read_text()) if d]
        self.assertEqual(self.v.validate_hook_input(docs), [])
        hook = next(d for d in docs if d.get("kind") == "Job" and d["metadata"]["name"] == self.v.HOOK_NAME)
        for name, mutate in (
            ("unmatched", lambda ds: ds.remove(next(d for d in ds if d == hook))),
            ("duplicate", lambda ds: ds.append(copy.deepcopy(hook))),
            ("reshaped env", lambda ds: next(d for d in ds if d == hook)["spec"]["template"]["spec"]["containers"][0]["env"].reverse()),
            ("unexpected init", lambda ds: next(d for d in ds if d == hook)["spec"]["template"]["spec"].update(initContainers=[{"name": "other"}])),
        ):
            with self.subTest(name=name):
                changed = copy.deepcopy(docs)
                mutate(changed)
                self.assertTrue(self.v.validate_hook_input(changed))
                with self.assertRaises(ValueError):
                    self.v.apply_postrender(changed, self.release)
        # Exercise the REAL Kustomize JSON6902 test, not just our shape oracle.
        broken = copy.deepcopy(docs)
        next(d for d in broken if d == hook)["spec"]["template"]["spec"]["containers"][0]["env"].reverse()
        with self.assertRaises(subprocess.CalledProcessError):
            self.v.apply_postrender(broken, self.release, check_input=False)
        unmatched = copy.deepcopy(self.release)
        unmatched["spec"]["postRenderers"][0]["kustomize"]["patches"][0]["target"]["name"] = "^unmatched$"
        no_op = self.v.apply_postrender(docs, unmatched)
        self.assertTrue(self.v.validate_postrender(docs, no_op, unmatched), "silent Kustomize no-op must fail CI")
        patched = self.v.apply_postrender(docs, self.release)
        self.assertEqual(self.v.validate_postrender(docs, patched, self.release), [])
        changed = copy.deepcopy(patched)
        admission = next(d for d in changed if d.get("kind") == "Job" and d["metadata"]["name"] == self.v.HOOK_NAME)["spec"]["template"]["spec"]["initContainers"][0]
        admission["env"][0]["value"] = "v19.4.0"
        self.assertTrue(self.v.validate_postrender(docs, changed, self.release))
        changed = copy.deepcopy(patched)
        volumes = self.v.hook_jobs(changed)[0]['spec']['template']['spec']['volumes']
        next(v for v in volumes if v['name'] == 'admission-recovery')['persistentVolumeClaim']['claimName'] = 'gitlab-helm-recovery-windsor'
        self.assertTrue(self.v.validate_postrender(docs, changed, self.release))


class LegacyS3ConfigTests(unittest.TestCase):
    """Native Kustomize propagation only; real CNG ERB rendering is a runtime gate."""

    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("validator", ROOT / "scripts/validate_gitlab_helm.py")
        assert spec is not None and spec.loader is not None
        validator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(validator)
        cls.docs = validator.kustomize(ROOT, "apps")

    def test_required_native_connection_consumers(self):
        active = {"gitlab-webservice", "gitlab-sidekiq", "gitlab-workhorse"}
        projected = {d["metadata"]["name"] for d in self.docs if d["kind"] in ("Deployment", "Job")
                     and any(v["name"] == "objectstore-connection"
                             for v in d["spec"]["template"]["spec"].get("volumes", []))}
        self.assertEqual(projected, active)
        # Keep existing tuning/path checks on the historical Job, without new S3 input.
        workloads = {
            "gitlab-webservice": ("75m", "2100Mi", "3Gi"),
            "gitlab-sidekiq": ("150m", "1600Mi", "2Gi"),
            "gitlab-workhorse": ("100m", "32Mi", "256Mi"),
            "gitlab-migrations-v19.5.0-r1": ("75m", "2100Mi", "3Gi"),
        }
        for name, (cpu, memory, limit) in workloads.items():
            with self.subTest(consumer=name):
                matches = [d for d in self.docs if d["kind"] in ("Deployment", "Job")
                           and d["metadata"]["name"] == name]
                self.assertEqual(len(matches), 1)
                workload = matches[0]
                pod = workload["spec"]["template"]["spec"]
                container = pod["containers"][0]
                volumes = {v["name"]: v for v in pod["volumes"]}
                mounts = {m["name"]: m for m in container["volumeMounts"]}
                if name in active:
                    self.assertEqual(volumes["objectstore-connection"], {
                        "name": "objectstore-connection", "secret": {
                            "secretName": "gitlab-helm-objectstore", "optional": False,
                            "defaultMode": 420, "items": [{"key": "connection", "path": "connection"}],
                        },
                    })
                    self.assertEqual(mounts["objectstore-connection"], {
                        "name": "objectstore-connection", "mountPath": "/etc/gitlab/objectstore", "readOnly": True,
                    })
                else:
                    self.assertNotIn("objectstore-connection", volumes)
                    self.assertNotIn("objectstore-connection", mounts)
                    self.assertFalse(any(v.get("secret", {}).get("secretName") == "gitlab-helm-objectstore"
                                         for v in volumes.values()))
                    self.assertFalse(any(m["mountPath"].startswith("/etc/gitlab/objectstore")
                                         for m in mounts.values()))
                self.assertEqual(len(mounts), len(container["volumeMounts"]))
                self.assertEqual(len(volumes), len(pod["volumes"]))
                for volume, path, claim in (
                    ("uploads", "/srv/gitlab/public/uploads", "gitlab-uploads-sw"),
                    ("shared", "/srv/gitlab/shared", "gitlab-shared-sw"),
                ):
                    self.assertEqual(mounts[volume]["mountPath"], path)
                    self.assertEqual(volumes[volume]["persistentVolumeClaim"]["claimName"], claim)
                env = {e["name"]: e for e in container["env"]}
                self.assertEqual(env["CONFIG_TEMPLATE_DIRECTORY"]["value"], "/var/opt/gitlab/config/templates")
                self.assertEqual(env["CONFIG_DIRECTORY"]["value"], "/srv/gitlab/config")
                self.assertFalse(any(e.startswith(("AWS_", "S3_")) for e in env))
                tuning = {"gitlab-webservice": {"WORKER_PROCESSES": "1", "PUMA_THREADS_MIN": "1", "PUMA_THREADS_MAX": "4"},
                          "gitlab-sidekiq": {"SIDEKIQ_CONCURRENCY": "5"}}.get(name, {})
                for key, value in tuning.items():
                    self.assertEqual(env[key]["value"], value)
                self.assertEqual(container["resources"], {
                    "requests": {"cpu": cpu, "memory": memory}, "limits": {"memory": limit},
                })
                self.assertTrue(container["image"].split("@", 1)[0].endswith(":v19.5.0"))
                if workload["kind"] == "Deployment":
                    self.assertEqual(workload["spec"]["replicas"], 1)

    def test_uploads_native_parent_root_and_consumed_rollout(self):
        configs = {d["metadata"]["name"]: d["data"] for d in self.docs if d["kind"] == "ConfigMap"}
        uploads = yaml.safe_load(configs["gitlab-config-templates"]["gitlab.yml.erb"])["production"]["uploads"]
        self.assertNotIn("base_dir", uploads, "retain the native uploads layout default")
        # GitLab 19.5 config/initializers/1_settings.rb defaults base_dir to
        # uploads/-/system; AvatarUploader appends model/mount/id and filename.
        native_base_dir = Path("uploads/-/system")
        avatar_suffix = Path("user/avatar/42/avatar.png")
        resolved = Path(uploads["storage_path"]) / native_base_dir / avatar_suffix
        marker = "gitlab.brmartin.co.uk/uploads-layout"
        consumers = {"gitlab-webservice", "gitlab-sidekiq"}
        marked = {d["metadata"]["name"] for d in self.docs if d["kind"] in ("Deployment", "Job")
                  and marker in d["spec"]["template"].get("metadata", {}).get("annotations", {})}
        for name in sorted(consumers):
            with self.subTest(consumer=name):
                deployment = next(d for d in self.docs if d["kind"] == "Deployment" and d["metadata"]["name"] == name)
                template = deployment["spec"]["template"]
                mount = next(m for m in template["spec"]["containers"][0]["volumeMounts"] if m["name"] == "uploads")
                physical = Path(mount["mountPath"]) / "-/system" / avatar_suffix
                self.assertEqual(resolved, physical, "native uploader root must resolve to the existing PVC bytes")
                self.assertNotIn("/uploads/uploads/", str(resolved))
                self.assertEqual(template["metadata"]["annotations"].get(marker), "native-parent-root")
        self.assertEqual(marked, consumers, "roll only active Rails consumers, not Workhorse or the schema Job")

    def test_erb_templates_and_bounded_types(self):
        configs = {d["metadata"]["name"]: d["data"] for d in self.docs if d["kind"] == "ConfigMap"}
        rails = configs["gitlab-config-templates"]
        workhorse = configs["workhorse-config"]
        self.assertNotIn("gitlab.yml", rails, "CNG plain-copy loop would clobber rendered YAML")
        self.assertNotIn("workhorse-config.toml", workhorse, "CNG plain-copy loop would clobber rendered TOML")
        # Parsing the unrendered YAML scalar checks source shape, NOT ERB execution.
        production = yaml.safe_load(rails["gitlab.yml.erb"])["production"]
        store = production["object_store"]
        self.assertIs(store["enabled"], True)
        self.assertIs(store["proxy_download"], True)
        self.assertEqual(store["connection"], "<%= YAML.safe_load(File.read('/etc/gitlab/objectstore/connection')).to_json %>")
        expected: dict[str, dict[str, object]] = {
            kind: {"bucket": f"gitlab-{kind}"} for kind in ("artifacts", "lfs", "uploads", "packages")
        }
        expected.update({kind: {"enabled": False} for kind in (
            "external_diffs", "dependency_proxy", "terraform_state", "pages",
            "ci_secure_files", "agent_plan_content", "ci_catalog_bundles",
        )})
        self.assertEqual(store["objects"], expected)
        self.assertEqual(production["artifacts"]["path"], "/srv/gitlab/shared/artifacts")
        self.assertEqual(production["lfs"]["storage_path"], "/srv/gitlab/shared/lfs-objects")
        self.assertEqual(production["uploads"]["storage_path"], "/srv/gitlab/public")
        self.assertEqual(rails["database.yml"].count("pool: 10"), 2)
        template = workhorse["workhorse-config.toml.erb"]
        self.assertTrue(template.startswith("<% c = YAML.safe_load(File.read('/etc/gitlab/objectstore/connection')) %>"))
        for text in ('[redis]', 'URL = "redis://gitlab-redis:6379"', '[[listeners]]',
                     'network = "tcp"', 'addr = "0.0.0.0:8181"', '[object_storage]', '[object_storage.s3]'):
            self.assertIn(text, template)
        for key in ("provider", "aws_access_key_id", "aws_secret_access_key"):
            self.assertIn(f"{key} = <%= c.fetch('{key}').to_json %>", template)
        # Endpoint/region/path_style/signature stay in native Rails/request config.
        self.assertNotIn("c.fetch('endpoint')", template)
        self.assertNotIn("c.fetch('path_style')", template)

    def test_historical_job_keeps_ordinary_lifecycle(self):
        policy = "kustomize.toolkit.fluxcd.io/ssa"
        annotated = [d for d in self.docs if policy in d.get("metadata", {}).get("annotations", {})]
        self.assertEqual(annotated, [], "no create-only/apply-skipping exception")
        jobs = [d for d in self.docs if d["kind"] == "Job"
                and d["metadata"].get("labels", {}).get("app") == "gitlab"
                and d["metadata"].get("labels", {}).get("component") == "migrations"]
        self.assertEqual([d["metadata"]["name"] for d in jobs], ["gitlab-migrations-v19.5.0-r1"])
        job = jobs[0]
        for metadata in (job["metadata"], job["spec"]["template"]["metadata"]):
            for annotation in (policy, "kustomize.toolkit.fluxcd.io/force",
                               "kustomize.toolkit.fluxcd.io/healthcheck",
                               "kustomize.toolkit.fluxcd.io/reconcile"):
                self.assertNotIn(annotation, metadata.get("annotations", {}))
        self.assertEqual(job["spec"]["backoffLimit"], 6)
        self.assertEqual(job["spec"]["template"]["spec"]["restartPolicy"], "OnFailure")
        self.assertEqual(job["spec"]["template"]["spec"]["containers"][0]["args"], ["/scripts/db-migrate"])
        self.assertNotIn("ttlSecondsAfterFinished", job["spec"])
        owner = yaml.safe_load((ROOT / "clusters/k3s-homelab/flux-system/kustomization-apps.yaml").read_text())
        self.assertIs(owner["spec"]["wait"], True)
        self.assertNotIn("force", owner["spec"])
        # Official Helm Jobs also keep their ordinary completion waits.
        for path in (ROOT / "apps/gitlab-helm").rglob("*.yaml"):
            self.assertNotIn(f"{policy}: IfNotPresent", path.read_text(), str(path))


if __name__ == "__main__":
    unittest.main()
