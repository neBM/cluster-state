#!/usr/bin/env python3
"""Focused stdlib retention fixtures; never call production main()/host cleanup."""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import textwrap
import tracemalloc
from types import SimpleNamespace
import unittest
import urllib.parse
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
CI = ROOT / 'infrastructure/shared-services/gitlab-runner/ci'
spec = importlib.util.spec_from_file_location('retention', CI / 'cache-retention.py')
assert spec is not None and spec.loader is not None
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
admission_spec = importlib.util.spec_from_file_location('admission', CI / 'maintenance-admission.py')
assert admission_spec is not None and admission_spec.loader is not None
a = importlib.util.module_from_spec(admission_spec)
admission_spec.loader.exec_module(a)


class FakeAPI:
    def __init__(self, state, snapshot, jobs):
        self.cm = {'kind': 'ConfigMap', 'metadata': {'name': 'hestia-ci-maintenance-state',
                   'namespace': 'ci-maintenance', 'uid': 'state-uid', 'resourceVersion': '1'},
                   'data': {'state.json': json.dumps(state)}}
        self.snapshot, self.jobs, self.fail_save = snapshot, jobs, False

    def request(self, method, path, body=None):
        if path == a.STATE:
            if method == 'PUT':
                if self.fail_save:
                    raise OSError('fixture state unavailable')
                if body['metadata']['resourceVersion'] != self.cm['metadata']['resourceVersion']:
                    raise a.Conflict('fixture CAS')
                self.cm = copy.deepcopy(body)
                self.cm['metadata']['resourceVersion'] = str(int(self.cm['metadata']['resourceVersion']) + 1)
            return copy.deepcopy(self.cm), {}
        if any(path.startswith(p) for p in (a.PODS, a.CONTROL_PODS, a.WORKER_PODS)):
            namespace = path.split('/')[4]
            return {'metadata': {}, 'items': copy.deepcopy([p for p in self.snapshot if p['metadata']['namespace'] == namespace])}, {}
        if '/jobs/' in path:
            return copy.deepcopy(self.jobs[path.rsplit('/', 1)[1]]), {}
        raise AssertionError((method, path))


class FakeGitLab:
    def __init__(self, paused=False):
        self.paused, self.puts, self.unknown = paused, [], False
        self.pages, self.queries = {}, []

    def request(self, method, path, body=None):
        if method == 'PUT':
            assert path == '/runners/2' and set(body) == {'paused'} and type(body['paused']) is bool
            self.puts.append(copy.deepcopy(body))
            self.paused = body['paused']
            if self.unknown:
                raise TimeoutError('fixture effect unknown')
            return {'id': 2, 'paused': self.paused}, {}
        if path == '/runners/2':
            return {'id': 2, 'paused': self.paused}, {}
        parsed = urllib.parse.urlsplit(path)
        query = urllib.parse.parse_qs(parsed.query)
        assert method == 'GET' and parsed.path == '/runners/2/jobs'
        assert set(query) == {'status', 'per_page', 'page'} and query['per_page'] == ['100']
        status, page = query['status'][0], query['page'][0]
        self.queries.append((status, page))
        return copy.deepcopy(self.pages.get(status, {'1': ([], {'X-Next-Page': ''})})[page])


class AdmissionTests(unittest.TestCase):
    def setUp(self):
        self.slot = 1793872020  # Replaced below with an exact UTC minute47.
        self.slot = self.slot // 3600 * 3600 + 47 * 60
        self.clock = self.slot + 10
        self.policy = 'f' * 64
        self.coordinator = self.pod('coord', 'hestia-ci-maintenance-admission')
        self.worker = self.pod('worker', 'hestia-ci-cache-retention')
        self.recovery = self.pod('recovery', 'hestia-ci-maintenance-recovery')
        snapshot = [self.coordinator, self.worker, self.recovery]
        stamp = a.dt.datetime.fromtimestamp(self.slot, a.dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        jobs = {p['metadata']['name'] + '-job': {'metadata': {
            'namespace': p['metadata']['namespace'], 'name': p['metadata']['name'] + '-job',
            'uid': p['metadata']['name'] + '-job-uid',
            'annotations': {'batch.kubernetes.io/cronjob-scheduled-timestamp': stamp},
            'ownerReferences': [{'kind': 'CronJob', 'name': p['metadata']['labels']['app'],
                                 'controller': True, 'uid': 'cron-uid'}]},
            'spec': {'template': {'spec': copy.deepcopy(p['spec'])}}} for p in snapshot}
        state = {'schema': 1, 'runner': 2, 'uid': 'state-uid', 'policy': self.policy,
                 'heartbeat': self.clock, 'phase': 'IDLE', 'operation': None}
        self.api = FakeAPI(state, snapshot, jobs)
        self.store = a.Store(self.api, self.policy)
        self.gl = FakeGitLab()
        self.me, self.who, self.rec = map(a.pod_identity, snapshot)

    def pod(self, name, app):
        labels = {'app': app}
        if name == 'worker':
            labels.update({'ci.brmartin.co.uk/job': 'true', 'ci.brmartin.co.uk/maintenance': 'true'})
        return {'metadata': {'namespace': 'ci-maintenance-worker' if name == 'worker' else 'ci-maintenance', 'uid': name + '-uid', 'name': name, 'labels': labels,
                'ownerReferences': [{'kind': 'Job', 'name': name + '-job', 'uid': name + '-job-uid', 'controller': True}]},
                'spec': {'containers': [{'name': 'main'}], 'nodeName': 'hestia',
                         'serviceAccountName': 'hestia-ci-maintenance-worker' if name == 'worker' else app,
                         'volumes': [{'name': 'policy', 'configMap': {'name': 'hestia-ci-cache-retention-fixture'}}]},
                'status': {'phase': 'Running', 'containerStatuses': [{'name': 'main', 'state': {'running': {}}}]}}

    def finish(self, name, phase='Succeeded'):
        pod = next(p for p in self.api.snapshot if p['metadata']['name'] == name)
        pod['status'] = {'phase': phase, 'containerStatuses': [{'name': 'main', 'state': {'terminated': {'exitCode': 0}}}]}

    def coordinate(self):
        a.coordinate(self.store, self.gl, self.me, now=lambda: self.clock,
                     sleep=lambda _: setattr(self, 'clock', self.clock + 1200))

    def recover(self):
        a.recover(self.store, self.gl, self.rec, now=lambda: self.clock)

    def state(self):
        return self.store.read()[1]

    def save(self, state):
        cm, _ = self.store.read()
        self.store.save(cm, state)

    def test_foreign_ci_cannot_claim_or_retire_worker(self):
        forged = copy.deepcopy(self.worker)
        forged['metadata']['namespace'] = 'ci'
        with self.assertRaises(a.Refuse):
            a.scheduled(self.api, forged, 'hestia-ci-cache-retention')
        with self.assertRaises(a.Refuse):
            a.WorkerFence(self.store, a.pod_identity(forged))
        self.assertFalse(a.terminal([forged], self.who))
        self.api.snapshot[1] = forged
        with self.assertRaises(a.Refuse):
            self.coordinate()
        self.assertIsNone(self.state()['operation']['worker'])

    def test_worker_job_generation_namespace_and_bundle_bound(self):
        for field in ('namespace', 'uid', 'name'):
            with self.subTest(field=field):
                saved = self.api.jobs['worker-job']['metadata'][field]
                self.api.jobs['worker-job']['metadata'][field] = 'foreign'
                with self.assertRaises(a.Refuse):
                    a.scheduled(self.api, self.worker, 'hestia-ci-cache-retention')
                self.api.jobs['worker-job']['metadata'][field] = saved
        self.api.jobs['worker-job']['spec']['template']['spec']['volumes'][0]['configMap']['name'] += '-foreign'
        with self.assertRaises(a.Refuse):
            a.scheduled(self.api, self.worker, 'hestia-ci-cache-retention')

    def test_true_baseline_and_persistence_failure_zero_puts(self):
        self.gl.paused = True
        self.coordinate()
        self.assertEqual(self.gl.puts, [])
        self.gl.paused, self.api.fail_save = False, True
        with self.assertRaises(OSError):
            self.coordinate()
        self.assertEqual(self.gl.puts, [])

    def test_normal_claim_terminal_restore_exact_puts(self):
        self.coordinate()
        fence = a.WorkerFence(self.store, self.who, now=lambda: self.clock)
        fence.claim(sleep=self.fail)
        fence.check()
        self.finish('coord')
        self.recover()
        self.assertEqual(self.gl.puts, [{'paused': True}])
        self.finish('worker')
        self.recover()
        self.assertEqual(self.gl.puts, [{'paused': True}, {'paused': False}])
        self.assertEqual(self.state()['phase'], 'DONE')
        self.assertEqual(self.state()['operation']['outcome'], 'cleanup-succeeded')
        with self.assertRaises(a.Refuse):
            fence.check()

    def test_failed_cleanup_restores_but_outcome_stays_failed(self):
        self.coordinate()
        a.WorkerFence(self.store, self.who, now=lambda: self.clock).claim(sleep=self.fail)
        self.finish('coord', 'Failed')
        self.finish('worker', 'Failed')
        self.recover()
        self.assertFalse(self.gl.paused)
        self.assertEqual(self.state()['operation']['outcome'], 'cleanup-failed')

    def test_pause_ack_coordinator_crash_independent_recovery(self):
        def crash(_):
            raise RuntimeError('fixture coordinator crashed after durable pause ack')
        self.gl.pages['running'] = {'1': ([{'id': 8, 'status': 'running'}], {'X-Next-Page': ''})}
        with self.assertRaises(RuntimeError):
            a.coordinate(self.store, self.gl, self.me, now=lambda: self.clock, sleep=crash)
        self.assertEqual(self.state()['phase'], 'DRAINING')
        self.finish('coord', 'Failed')
        self.recover()
        self.assertFalse(self.gl.paused)
        self.assertEqual(self.state()['phase'], 'DONE')

    def test_unknown_pause_and_restore_latch_no_extra_put(self):
        self.gl.unknown = True
        with self.assertRaises(a.Refuse):
            self.coordinate()
        self.assertEqual(self.state()['phase'], 'ALERT')
        self.finish('coord')
        with self.assertRaises(a.Refuse):
            self.recover()
        self.assertEqual(len(self.gl.puts), 1)
        self.setUp()
        self.coordinate()
        self.finish('coord')
        self.clock = self.slot + 1801
        self.gl.unknown = True
        with self.assertRaises(a.Refuse):
            self.recover()
        self.assertEqual(self.state()['phase'], 'ALERT')
        with self.assertRaises(a.Refuse):
            self.recover()
        self.assertEqual(len(self.gl.puts), 2)

    def test_pagination_malformed_and_accepted_running_fail_closed(self):
        self.gl.pages = {'running': {'1': ([], {'X-Next-Page': '2'}),
                                    '2': ([{'id': 22, 'status': 'running'}], {'X-Next-Page': ''})}}
        self.assertFalse(a.drained(self.gl))
        for page in (([], {}), ([{'id': 22, 'status': 'mystery'}], {'X-Next-Page': ''}),
                     ([], {'X-Next-Page': '1'})):
            self.gl.pages = {'running': {'1': page}}
            with self.assertRaises(a.Refuse):
                self.coordinate()
            self.assertNotIn(self.state()['phase'], {'ADMITTED', 'CLAIMED'})
            self.setUp()

    def test_status_filtered_idle_and_all_nonterminal_busy(self):
        expected = ('created', 'waiting_for_resource', 'preparing', 'waiting_for_callback',
                    'pending', 'manual', 'scheduled', 'running', 'canceling')
        self.assertTrue(a.drained(self.gl))
        self.assertEqual(self.gl.queries, [(status, '1') for status in expected])
        for status in expected:
            with self.subTest(status=status):
                gl = FakeGitLab()
                gl.pages[status] = {'1': ([{'id': 8, 'status': status}], {'x-next-page': '2'})}
                self.assertFalse(a.drained(gl))
                self.assertEqual(gl.queries[-1], (status, '1'))  # Busy needs no next page.

    def test_filtered_pagination_refuses_ignored_filter_bad_ids_and_bounds(self):
        bad_rows = [[{'id': 1, 'status': status}] for status in ('success', 'failed', 'canceled', 'skipped', 'running')]
        bad_rows += [[{'id': value, 'status': 'created'}] for value in (True, 0, -1, '8')]
        bad_rows += [[{'id': 1, 'status': 'created'}] * 2, [{}], {}]
        for rows in bad_rows:
            with self.subTest(rows=rows):
                self.gl.pages = {'created': {'1': (rows, {'X-Next-Page': ''})}}
                with self.assertRaises(a.Refuse):
                    a.drained(self.gl)
        for headers in ({}, {'x-next-page': None}, {'x-next-page': '0'},
                        {'x-next-page': '-1'}, {'x-next-page': '01'}, {'x-next-page': '1'}):
            self.gl.pages = {'created': {'1': ([], headers)}}
            with self.subTest(headers=headers), self.assertRaises(a.Refuse):
                a.drained(self.gl)
        self.gl.pages = {'created': {str(i): ([], {'x-next-page': str(i + 1)}) for i in range(1, 101)}}
        with self.assertRaisesRegex(a.Refuse, 'unbounded/incomplete'):
            a.drained(self.gl)
        self.gl.pages['created']['100'] = ([], {'x-next-page': ''})
        self.assertTrue(a.drained(self.gl))

    def test_hestia_local_drain_matches_worker_positive_remote_exemption(self):
        job = copy.deepcopy(self.worker)
        job['metadata'].update(namespace='ci', uid='ordinary-job', name='ordinary-job',
                               labels={'ci.brmartin.co.uk/job': 'true'})
        for node in ('heracles', 'nyx', 'hestia', 'unknown', ''):
            for phase in ('Running', 'Pending', 'Unknown', 'Succeeded', 'Failed'):
                for terminating in (False, True):
                    with self.subTest(node=node, phase=phase, terminating=terminating):
                        job['spec']['nodeName'], job['status']['phase'] = node, phase
                        job['metadata']['deletionTimestamp'] = 'fixture' if terminating else None
                        expected = not terminating and (phase in {'Succeeded', 'Failed'} or
                                   phase in {'Running', 'Pending'} and node in {'heracles', 'nyx'})
                        self.assertEqual(a.ci_drained([job]), expected)
                        payload = {'metadata': {}, 'items': [self.worker, job]}
                        if expected:
                            self.assertTrue(r.pod_gate(payload, self.who['uid']))
                        else:
                            with self.assertRaises(r.Refuse):
                                r.pod_gate(payload, self.who['uid'])
        job['spec'].pop('nodeName')
        job['status']['phase'], job['metadata']['deletionTimestamp'] = 'Pending', None
        self.assertFalse(a.ci_drained([job]))
        job['metadata'].pop('labels')
        with self.assertRaises(a.Refuse):
            a.ci_drained([job])
        self.api.snapshot.append(job)
        with self.assertRaises(a.Refuse):
            a.snapshot_all(self.api)

    def test_claim_cas_one_winner_and_seal_wins(self):
        self.coordinate()
        cm1, st1 = self.store.read()
        cm2, st2 = self.store.read()
        st1['phase'], st1['operation']['claimed'] = 'CLAIMED', True
        self.store.save(cm1, st1)
        st2['phase'] = 'CLOSING'
        with self.assertRaises(a.Conflict):
            self.store.save(cm2, st2)
        self.assertTrue(self.state()['operation']['claimed'])
        self.setUp()
        self.coordinate()
        cm1, st1 = self.store.read()
        cm2, st2 = self.store.read()
        st1['phase'] = 'CLOSING'
        self.store.save(cm1, st1)
        st2['phase'], st2['operation']['claimed'] = 'CLAIMED', True
        with self.assertRaises(a.Conflict):
            self.store.save(cm2, st2)
        with self.assertRaises(a.Refuse):
            a.WorkerFence(self.store, self.who, now=lambda: self.clock).claim(sleep=self.fail)

    def test_claimed_alive_missing_failuretarget_not_retirement(self):
        self.coordinate()
        fence = a.WorkerFence(self.store, self.who, now=lambda: self.clock)
        fence.claim(sleep=self.fail)
        self.finish('coord')
        self.clock = self.slot + 1801
        for phase in ('Running', 'Pending', 'Unknown'):
            self.api.snapshot[1]['status'].update(phase=phase, conditions=[{'type': 'FailureTarget', 'status': 'True'}])
            self.recover()
            self.assertEqual(len(self.gl.puts), 1)
        self.api.snapshot.pop(1)
        self.recover()
        self.assertEqual(len(self.gl.puts), 1)
        with self.assertRaises(a.Refuse):
            fence.check()
        self.clock = self.slot + 2700
        with self.assertRaises(a.Refuse):
            self.recover()
        self.assertEqual(self.state()['phase'], 'ALERT')

    def test_unclaimed_pending_sealed_does_not_block_restore(self):
        self.coordinate()
        self.finish('coord')
        self.api.snapshot[1]['status']['phase'] = 'Pending'
        self.clock = self.slot + 1801
        self.recover()
        self.assertEqual(self.state()['phase'], 'DONE')
        self.assertFalse(self.gl.paused)

    def test_stale_heartbeat_expiry_manual_late_schedule_zero_puts(self):
        for kind in ('heartbeat', 'token', 'manual', 'late'):
            with self.subTest(kind=kind):
                self.setUp()
                if kind == 'heartbeat':
                    state = self.state()
                    state['heartbeat'] = self.clock - 151
                    self.save(state)
                elif kind == 'manual':
                    self.api.jobs['coord-job']['metadata']['annotations'] = {}
                elif kind == 'late':
                    self.clock += 100
                with patch.object(a, 'TOKEN_EXPIRY', self.clock if kind == 'token' else a.TOKEN_EXPIRY):
                    with self.assertRaises(a.Refuse):
                        self.coordinate()
                self.assertEqual(self.gl.puts, [])

    def test_strict_types_uid_corruption_and_stale_holder(self):
        self.coordinate()
        state = self.state()
        state['operation']['baseline'] = 'false'
        with self.assertRaises(a.Refuse):
            self.save(state)
        self.api.cm['metadata']['uid'] = 'replacement'
        with self.assertRaises(a.Refuse):
            self.store.read()
        self.setUp()
        self.coordinate()
        self.finish('coord')
        self.clock = self.slot + 1801
        self.recover()
        self.assertEqual(self.state()['phase'], 'DONE')
        self.clock = self.slot + 3600 + 10
        stamp = a.dt.datetime.fromtimestamp(self.slot + 3600, a.dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        self.api.jobs['coord-job']['metadata']['annotations']['batch.kubernetes.io/cronjob-scheduled-timestamp'] = stamp
        state = self.state()
        state['heartbeat'] = self.clock
        self.save(state)
        with self.assertRaises(a.Refuse):
            self.coordinate()  # Previous restoration holder still Running.
        self.assertEqual(len(self.gl.puts), 2)


class AdmissionBootstrapTests(unittest.TestCase):
    def test_independent_recovery_entrypoint_exists(self):
        self.assertTrue((CI / 'maintenance-admission.py').is_file(),
                        'production independent admission/recovery is absent')


class RetentionFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='retention-test-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.builds, self.cache = self.base / 'builds', self.base / 'cache'
        self.builds.mkdir()
        self.cache.mkdir()
        self.roots = ((self.builds, 7), (self.cache, 30))
        self.now = 2_000_000_000

    def candidate(self, root, name, age):
        path = root / name
        (path / 'nested').mkdir(parents=True)
        file = path / 'nested/data'
        file.write_text(name)
        stamp = self.now - age * r.DAY
        os.utime(file, (stamp, stamp))
        return path

    def run_retention(self, **kwargs):
        with contextlib.redirect_stdout(io.StringIO()) as output, \
                patch.object(r, 'WORKSPACE_ROOT', self.builds), \
                patch.object(r, 'UV_ROOT', self.cache / 'uv'), \
                patch.object(r, 'ROOTS', self.roots):
            r.retain(self.roots, now=self.now, used=kwargs.pop('used', lambda _: 50),
                     available=kwargs.pop('available', lambda _: r.COLD_RESERVE),
                     opened=kwargs.pop('opened', set), mounts=kwargs.pop('mounts', set),
                     **kwargs)
        return output.getvalue()

class RetentionTests(RetentionFixture):
    def test_age_uses_newest_descendant_file_not_directory(self):
        stale = self.candidate(self.builds, 'stale', 8)
        fresh = self.candidate(self.cache, 'fresh', 40)
        new = fresh / 'nested/new'
        new.write_text('new')
        os.utime(new, (self.now, self.now))
        for path in (fresh, fresh / 'nested'):
            os.utime(path, (1, 1))
        self.run_retention(execute=True)
        self.assertFalse(stale.exists())  # Newly touched parent does not save old files.
        self.assertTrue(fresh.exists())   # Old parent does not expire a fresh descendant.
        self.assertTrue(self.builds.is_dir())
        self.assertTrue(self.cache.is_dir())

    def test_cache_30_day_boundary(self):
        old = self.candidate(self.cache, 'old', 30)
        fresh = self.candidate(self.cache, 'fresh', 29)
        owner = self.cache.stat().st_uid, self.cache.stat().st_gid
        self.run_retention(execute=True)
        self.assertFalse(old.exists())
        self.assertTrue(fresh.exists())
        self.assertEqual(owner, (self.cache.stat().st_uid, self.cache.stat().st_gid))

    def test_pressure_workspace_then_oldest_cache_until_65(self):
        work = self.candidate(self.builds, 'workspace', 1)
        old = self.candidate(self.cache, 'old', 2)
        new = self.candidate(self.cache, 'new', 1)
        def used(_):
            return 65 + 5 * int(work.exists()) + 5 * int(old.exists())
        self.run_retention(execute=True, used=used)
        self.assertFalse(work.exists())
        self.assertFalse(old.exists())
        self.assertTrue(new.exists())

    def test_at_67_triggers_pressure_cleanup_to_65(self):
        path = self.candidate(self.builds, 'young', 1)
        self.run_retention(execute=True, used=lambda _: 65 + 2 * path.exists())
        self.assertFalse(path.exists())

    def test_under_67_preserves_young_data(self):
        path = self.candidate(self.builds, 'young', 1)
        self.run_retention(execute=True, used=lambda _: 66.99)
        self.assertTrue(path.exists())

    def test_age_cleanup_precedes_capacity_backstop(self):
        old = self.candidate(self.cache, 'aged', 40)
        young = self.candidate(self.builds, 'young', 1)
        self.run_retention(execute=True, used=lambda _: 66 + 10 * old.exists())
        self.assertFalse(old.exists())
        self.assertTrue(young.exists())

    def test_dry_run_never_mutates(self):
        path = self.candidate(self.cache, 'old', 40)
        output = self.run_retention(execute=False, used=lambda _: 80)
        self.assertIn('WOULD DELETE', output)
        self.assertTrue(path.exists())

    def test_idle_workspace_unlinks_nested_symlink_only(self):
        outside = self.base / 'outside'
        outside.mkdir()
        sentinel = outside / 'sentinel'
        sentinel.write_text('preserve outside data')
        before = sentinel.stat()
        path = self.candidate(self.builds, 'old-workspace', 8)
        link = path / 'nested/link'
        link.symlink_to(outside, target_is_directory=True)
        stamp = self.now - 8 * r.DAY
        os.utime(link, (stamp, stamp), follow_symlinks=False)
        self.run_retention(execute=True)
        self.assertFalse(path.exists())
        self.assertFalse(link.is_symlink())
        self.assertEqual(sentinel.read_text(), 'preserve outside data')
        self.assertEqual(sentinel.stat(), before)

    def test_workspace_link_forms_never_open_or_follow_targets(self):
        outside = self.base / 'outside'
        outside.mkdir()
        sentinel = outside / 'sentinel'
        sentinel.write_text('preserve')
        target_before = sentinel.stat(), outside.stat()
        for form in ('absolute-file', 'relative-file', 'directory', 'dangling', 'cycle'):
            with self.subTest(form=form):
                path = self.candidate(self.builds, form, 8)
                link = path / 'nested/link'
                target = {'absolute-file': sentinel, 'relative-file': '../../../outside/sentinel',
                          'directory': outside, 'dangling': 'missing', 'cycle': 'link'}[form]
                link.symlink_to(target)
                stamp = self.now - 8 * r.DAY
                os.utime(link, (stamp, stamp), follow_symlinks=False)
                original_open, original_stat = r.os.open, r.os.stat
                def no_link_open(name, flags, *args, **kwargs):
                    self.assertNotEqual(str(name), 'link', 'symlink leaf was opened')
                    return original_open(name, flags, *args, **kwargs)
                def no_link_follow(name, *args, **kwargs):
                    if str(name) == 'link':
                        self.assertIs(kwargs.get('follow_symlinks'), False)
                    return original_stat(name, *args, **kwargs)
                with patch.object(r.os, 'open', no_link_open), \
                        patch.object(r.os, 'stat', no_link_follow):
                    self.run_retention(execute=True)
                self.assertFalse(path.exists())
                self.assertEqual((sentinel.stat(), outside.stat()), target_before)
        self.assertEqual(sentinel.read_text(), 'preserve')

    def test_workspace_link_own_freshness_and_default_helper_veto(self):
        path = self.candidate(self.builds, 'fresh-link', 8)
        link = path / 'nested/link'
        link.symlink_to('missing')
        os.utime(link, (self.now, self.now), follow_symlinks=False)
        self.run_retention(execute=True)
        self.assertTrue(link.is_symlink())
        device = path.stat().st_dev
        with self.assertRaises(r.Refuse):
            r.snapshot(path, device)
        generic = path / 'generic'
        generic.mkdir()
        (generic / 'link').symlink_to('missing')
        with self.assertRaises(r.Refuse):
            r.remove_tree(generic, device, set(), set(), r.identity(generic.stat()))
        (generic / 'link').unlink()
        generic.rmdir()
        # A backdated link mtime cannot hide a recent link creation/change.
        self.now = link.lstat().st_ctime + r.DAY
        old = self.now - 8 * r.DAY
        os.utime(path / 'nested/data', (old, old))
        os.utime(link, (old, old), follow_symlinks=False)
        _, latest = r.snapshot(path, device, workspace=True)
        self.assertEqual(latest, link.lstat().st_ctime)
        self.run_retention(execute=True)
        self.assertTrue(link.is_symlink())

    def test_workspace_root_candidate_and_cache_links_remain_protected(self):
        outside = self.base / 'outside'
        outside.mkdir()
        alias = self.base / 'root-alias'
        alias.symlink_to(self.builds, target_is_directory=True)
        with self.assertRaises(r.Refuse):
            r.retain(((alias, 7),), opened=set, mounts=set)
        candidate_alias = self.builds / 'alias'
        candidate_alias.symlink_to(outside, target_is_directory=True)
        for workspace in (False, True):
            with self.subTest(workspace=workspace), self.assertRaises(r.Refuse):
                r.snapshot(candidate_alias, self.builds.stat().st_dev, workspace=workspace)
            with self.subTest(workspace=workspace), self.assertRaises(r.Refuse):
                r.remove_tree(candidate_alias, self.builds.stat().st_dev, set(), set(),
                              r.identity(candidate_alias.lstat()), workspace=workspace)
        cached = self.candidate(self.cache, 'cache-link', 40)
        (cached / 'nested/link').symlink_to(outside)
        # Permission follows the fixed workspace identity, not age or input order.
        self.roots = ((self.cache, 7), (self.builds, 30))
        output = self.run_retention(execute=True)
        self.assertIn('PROTECTED', output)
        self.assertTrue(cached.exists())
        self.assertTrue(candidate_alias.is_symlink())
        self.assertTrue(outside.is_dir())

    def test_workspace_link_changes_between_proofs_refuse(self):
        for change in ('retarget', 'replace-directory', 'replace-candidate'):
            with self.subTest(change=change):
                path = self.candidate(self.builds, change, 8)
                link = path / 'nested/link'
                link.symlink_to('missing')
                old = self.now - 8 * r.DAY
                os.utime(link, (old, old), follow_symlinks=False)
                def gate():
                    if change == 'replace-candidate':
                        path.rename(path.with_name('moved'))
                        path.mkdir()
                    elif change == 'replace-directory':
                        (path / 'nested').rename(path / 'saved')
                        (path / 'nested').symlink_to(self.base)
                    else:
                        link.unlink()
                        link.symlink_to('different-missing')
                        os.utime(link, (old, old), follow_symlinks=False)
                with self.assertRaisesRegex(r.Refuse, 'changed/open/mounted'):
                    self.run_retention(execute=True, gate=gate)
                self.assertTrue(path.is_dir())
                # Each race gets its own workspace pair; no prior residual is consumed.
                self.builds = self.base / (change + '-next-builds')
                self.cache = self.base / (change + '-next-cache')
                self.builds.mkdir()
                self.cache.mkdir()
                self.roots = ((self.builds, 7), (self.cache, 30))

    def test_workspace_link_safety_fences_and_rechecks(self):
        path = self.candidate(self.builds, 'guarded', 8)
        link = path / 'nested/link'
        link.symlink_to('missing')
        old = self.now - 8 * r.DAY
        os.utime(link, (old, old), follow_symlinks=False)
        link_id = r.identity(link.lstat())
        for evidence in ('opened', 'mounts'):
            for pass_number in (1, 2):
                with self.subTest(evidence=evidence, pass_number=pass_number):
                    calls = 0
                    def scan():
                        nonlocal calls
                        calls += 1
                        return {link_id} if calls >= pass_number else set()
                    if pass_number == 1:
                        output = self.run_retention(execute=True, **{evidence: scan})
                        self.assertIn('PROTECTED', output)
                    else:
                        with self.assertRaisesRegex(r.Refuse, 'changed/open/mounted'):
                            self.run_retention(execute=True, **{evidence: scan})
                    self.assertTrue(link.is_symlink())
        with self.assertRaises(r.Refuse):
            r.snapshot(path, path.stat().st_dev ^ 1, workspace=True)
        original_stat = r.os.stat
        def other_device(name, *args, **kwargs):
            st = original_stat(name, *args, **kwargs)
            if str(name) == 'link':
                return SimpleNamespace(st_dev=st.st_dev ^ 1, st_ino=st.st_ino,
                                       st_mode=st.st_mode)
            return st
        with patch.object(r.os, 'stat', other_device):
            self.assertIn('PROTECTED', self.run_retention(execute=True))
        self.assertTrue(link.is_symlink())
        def denied_gate():
            raise r.Refuse('fixture API refusal')
        with self.assertRaisesRegex(r.Refuse, 'API refusal'):
            self.run_retention(execute=True, gate=denied_gate)
        self.assertTrue((path / 'nested/data').is_file())
        special = path / 'nested/special'
        os.mkfifo(special)
        self.assertIn('PROTECTED', self.run_retention(execute=True))
        self.assertTrue(link.is_symlink())
        with self.assertRaisesRegex(r.Refuse, 'cannot reach 65%'):
            self.run_retention(execute=True, used=lambda _: 80)

    def test_workspace_link_and_directory_replacement_during_deletion_refuse(self):
        outside = self.base / 'outside'
        outside.mkdir()
        sentinel = outside / 'sentinel'
        sentinel.write_text('preserve')
        for race in ('link', 'directory'):
            with self.subTest(race=race):
                path = self.candidate(self.builds, race + '-workspace', 8)
                link = path / 'nested/link'
                link.symlink_to(outside)
                proof, _ = r.snapshot(path, path.stat().st_dev, workspace=True)
                original = r.os.stat
                changed = False
                def metadata(name, *args, **kwargs):
                    nonlocal changed
                    st = original(name, *args, **kwargs)
                    if not changed and str(name) == ('link' if race == 'link' else 'nested'):
                        changed = True
                        if race == 'link':
                            link.unlink()
                            link.symlink_to('different-missing')
                        else:
                            (path / 'nested').rename(path / 'saved')
                            (path / 'nested').symlink_to(outside)
                    return st
                with patch.object(r.os, 'stat', metadata), self.assertRaises((r.Refuse, OSError)):
                    r.remove_tree(path, path.stat().st_dev, set(), set(), proof[1], workspace=True)
                self.assertTrue(changed)
                self.assertTrue(path.exists())
                self.assertEqual(sentinel.read_text(), 'preserve')

    def test_symlink_and_image_store_rejected_without_following(self):
        outside = self.base / 'outside'
        outside.mkdir()
        target = self.candidate(self.cache, 'unsafe', 40)
        (target / 'link').symlink_to(outside, target_is_directory=True)
        (self.cache / 'alias').symlink_to(outside, target_is_directory=True)
        store = self.candidate(self.cache, 'storage', 40)
        safe = self.candidate(self.cache, 'safe', 40)
        output = self.run_retention(execute=True)
        self.assertIn('PROTECTED', output)
        self.assertTrue(outside.exists())
        self.assertTrue(target.exists())
        self.assertTrue(store.exists())
        self.assertFalse(safe.exists())

    def test_cross_device_and_same_device_mount_rejected(self):
        path = self.candidate(self.cache, 'mounted', 40)
        with self.assertRaises(r.Refuse):
            r.snapshot(path, path.stat().st_dev + 1)
        self.run_retention(execute=True, mounts=lambda: {r.identity((path / 'nested').stat())})
        self.assertTrue(path.exists())

    def test_open_file_path_alias_and_cwd_inode_protection(self):
        path = self.candidate(self.cache, 'busy', 40)
        alias = self.base / 'different-path'
        os.link(path / 'nested/data', alias)
        proc = self.base / 'proc'
        proc.mkdir()
        (proc / str(os.getpid())).symlink_to('/proc/self', target_is_directory=True)
        with alias.open():
            self.run_retention(execute=True, opened=lambda: r.open_ids(proc))
        self.assertTrue(path.exists())
        previous = Path.cwd()
        try:
            os.chdir(path / 'nested')
            self.assertIn(r.identity(Path.cwd().stat()), r.open_ids(proc))
        finally:
            os.chdir(previous)

    def mount_owner(self, pid='self', mountpoint='/', device=None):
        proc = self.base / 'proc'
        owner = proc / pid
        (owner / 'ns').mkdir(parents=True, exist_ok=True)
        (owner / 'ns/mnt').touch()
        if not (owner / 'root').exists():
            (owner / 'root').symlink_to(self.base, target_is_directory=True)
        device = self.cache.stat().st_dev if device is None else device
        record = (f'1 0 {os.major(device)}:{os.minor(device)} / {mountpoint} '
                  'rw - xfs fixture rw\n')
        (owner / 'mountinfo').write_text(record)
        return proc, owner

    def test_unrelated_inaccessible_mount_is_not_statted(self):
        proc, owner = self.mount_owner(mountpoint='/unrelated',
                                      device=self.cache.stat().st_dev ^ 1)
        unrelated = owner / 'root/unrelated'
        original = Path.stat
        touched = []
        def metadata(path, *args, **kwargs):
            if path == unrelated:
                touched.append(path)
                raise PermissionError('fixture unrelated filesystem')
            return original(path, *args, **kwargs)
        with patch.object(Path, 'stat', metadata):
            try:
                mounted = r.mount_ids(self.cache.stat().st_dev, proc)
            except PermissionError as error:
                self.fail(f'provably unrelated mount root was accessed: {error}')
        self.assertEqual(mounted, set())
        self.assertEqual(touched, [])

    def test_unrelated_nsfs_opaque_root_is_not_resolved(self):
        proc, owner = self.mount_owner(mountpoint='/run/netns/fixture',
                                      device=os.makedev(0, 5))
        # Linux fs/namespace.c show_mountinfo() uses seq_dentry(); nsfs's
        # fs/nsfs.c ns_dname() emits an opaque namespace object, not a path.
        (owner / 'mountinfo').write_text(
            '1 0 0:5 net:[4026532000] /run/netns/fixture rw - nsfs nsfs rw\n')
        original = Path.stat
        def metadata(path, *args, **kwargs):
            if path == owner / 'root' or owner / 'root' in path.parents:
                self.fail(f'unrelated nsfs mount was resolved: {path}')
            return original(path, *args, **kwargs)
        with patch.object(Path, 'stat', metadata):
            self.assertEqual(r.mount_ids(os.makedev(8, 1), proc), set())

    def test_mountinfo_alias_resolves_to_inode_in_other_namespace(self):
        path = self.candidate(self.cache, 'mounted', 40)
        proc = self.base / 'proc'
        for pid in ('self', '1', '123'):
            self.mount_owner(pid, '/alias\\040mount' if pid == '123' else '/')
        (self.base / 'alias mount').symlink_to(path / 'nested', target_is_directory=True)
        self.assertIn(r.identity((path / 'nested').stat()), r.mount_ids(self.cache.stat().st_dev, proc))
        self.run_retention(execute=True, mounts=lambda: r.mount_ids(self.cache.stat().st_dev, proc))
        self.assertTrue(path.exists())

    def test_relevant_mount_access_and_metadata_fail_closed(self):
        self.mount_owner()
        proc, owner = self.mount_owner('123', mountpoint='/relevant')
        target = owner / 'root/relevant'
        original_stat, original_read = Path.stat, Path.read_text
        for denied in (target, owner / 'ns/mnt', owner / 'mountinfo'):
            with self.subTest(denied=denied):
                def metadata(path, *args, **kwargs):
                    if path == denied:
                        raise PermissionError('fixture relevant metadata')
                    return original_stat(path, *args, **kwargs)
                def read(path, *args, **kwargs):
                    if path == denied:
                        raise PermissionError('fixture mountinfo')
                    return original_read(path, *args, **kwargs)
                with patch.object(Path, 'stat', metadata), patch.object(Path, 'read_text', read):
                    with self.assertRaises(PermissionError):
                        r.mount_ids(self.cache.stat().st_dev, proc)
        # A missing relevant mount with a still-live namespace is not an exit race.
        with self.assertRaises(FileNotFoundError):
            r.mount_ids(self.cache.stat().st_dev, proc)

    def test_malformed_mountinfo_refuses_even_for_unrelated_device(self):
        proc, owner = self.mount_owner(device=self.cache.stat().st_dev ^ 1)
        valid = (owner / 'mountinfo').read_text()
        valid_device = valid.split()[2]
        malformed = ['', '1 0 0:1 / /', valid.replace(' - ', ' '),
                     valid.replace(' - ', ' - - '), valid + valid,
                     valid.replace(' / / ', ' / relative '),
                     valid.replace(' / / ', ' / /bad\\999 '),
                     valid.replace(' / / ', ' / /../escape ')]
        for device in ('unknown', '0', '0:1:2', '-1:2', '0:-1', '+0:1',
                       '00:1', '0:01', '０:1', '0:999999999999999999999'):
            malformed.append(valid.replace(valid_device, device, 1))
        for record in malformed:
            with self.subTest(record=record):
                (owner / 'mountinfo').write_text(record)
                with self.assertRaises(r.Refuse):
                    r.mount_ids(self.cache.stat().st_dev, proc)
        # Root path grammar is required on the cleanup device, not universally:
        # nsfs supplies opaque roots through the kernel's dentry-name callback.
        proc, owner = self.mount_owner()
        valid = (owner / 'mountinfo').read_text()
        for root in ('relative', r'/bad\999', '/../escape'):
            with self.subTest(root=root):
                (owner / 'mountinfo').write_text(valid.replace(' / / ', f' {root} / '))
                with self.assertRaises(r.Refuse):
                    r.mount_ids(self.cache.stat().st_dev, proc)

    def test_exited_process_mount_scan_races(self):
        proc, _ = self.mount_owner()
        _, owner = self.mount_owner('123')
        original_read, original_stat = Path.read_text, Path.stat
        expected = {r.identity(self.base.stat())}
        for phase in ('namespace', 'mountinfo', 'root'):
            with self.subTest(phase=phase):
                # Model a vanished process namespace, including ENOENT after read.
                def metadata(path, *args, **kwargs):
                    if path == owner / 'ns/mnt' and phase == 'namespace':
                        path.unlink()
                        raise FileNotFoundError('fixture exited namespace')
                    if path == owner / 'root' and phase == 'root':
                        (owner / 'ns/mnt').unlink()
                        raise ProcessLookupError('fixture exited process')
                    return original_stat(path, *args, **kwargs)
                def read(path, *args, **kwargs):
                    if path == owner / 'mountinfo' and phase == 'mountinfo':
                        (owner / 'ns/mnt').unlink()
                        raise FileNotFoundError('fixture exited process')
                    return original_read(path, *args, **kwargs)
                with patch.object(Path, 'stat', metadata), patch.object(Path, 'read_text', read):
                    self.assertEqual(r.mount_ids(self.cache.stat().st_dev, proc), expected)
                (owner / 'ns/mnt').touch()

    def test_default_scanner_uses_validated_fixture_filesystem(self):
        path = self.candidate(self.cache, 'old', 40)
        calls = []
        def scanner(device):
            calls.append(device)
            return set()
        with patch.object(r, 'mount_ids', scanner):
            self.run_retention(execute=True, mounts=None)
        self.assertEqual(calls, [self.cache.stat().st_dev] * 2)
        self.assertFalse(path.exists())
        (self.base / 'root-alias').symlink_to(self.cache, target_is_directory=True)
        with patch.object(r, 'mount_ids', self.fail), self.assertRaises(r.Refuse):
            r.retain(((self.base / 'root-alias', 30),), opened=set)
        original = Path.lstat
        def other_device(path, *args, **kwargs):
            st = original(path, *args, **kwargs)
            if path == self.cache:
                return SimpleNamespace(st_mode=st.st_mode, st_dev=st.st_dev ^ 1)
            return st
        with patch.object(Path, 'lstat', other_device), patch.object(r, 'mount_ids', self.fail):
            with self.assertRaisesRegex(r.Refuse, 'share the same filesystem'):
                self.run_retention(mounts=None)
        path = self.candidate(self.cache, 'replaced-root', 40)
        def gate():
            changed.start()
        changed = patch.object(Path, 'lstat', other_device)
        self.addCleanup(changed.stop)
        with self.assertRaisesRegex(r.Refuse, 'root filesystem changed'):
            self.run_retention(execute=True, gate=gate)
        changed.stop()
        self.assertTrue(path.exists())

    def test_incomplete_proc_scan_and_unreachable_target_fail_closed(self):
        path = self.candidate(self.cache, 'busy', 40)
        def denied():
            raise PermissionError('fixture unreadable proc')
        with self.assertRaises(PermissionError):
            self.run_retention(execute=True, opened=denied)
        with self.assertRaisesRegex(r.Refuse, 'cannot reach 65%'):
            self.run_retention(execute=True, used=lambda _: 80,
                               opened=lambda: {r.identity(path.stat())})
        self.assertTrue(path.exists())

    def test_recheck_before_delete_and_gate(self):
        path = self.candidate(self.cache, 'old', 40)
        calls = []
        def gate():
            calls.append(True)
            (path / 'new').write_text('race')
        with self.assertRaisesRegex(r.Refuse, 'changed/open/mounted'):
            self.run_retention(execute=True, gate=gate)
        self.assertEqual(calls, [True])
        self.assertTrue((path / 'nested/data').exists())

    def test_hardlinks_within_and_across_candidates(self):
        for cross_candidate in (False, True):
            with self.subTest(cross_candidate=cross_candidate):
                first = self.candidate(self.builds, 'first', 40)
                second = self.candidate(self.cache, 'second', 40)
                target = second / 'nested/link' if cross_candidate else first / 'nested/link'
                os.link(first / 'nested/data', target)
                self.run_retention(execute=True)
                self.assertFalse(first.exists())
                self.assertFalse(second.exists())

    def test_hardlink_mutations_still_rejected(self):
        for change in ('content', 'mtime', 'mode', 'inode'):
            with self.subTest(change=change):
                path = self.candidate(self.cache, change, 40)
                file = path / 'nested/data'
                os.link(file, path / 'nested/link')
                def gate():
                    if change == 'content':
                        file.write_text('changed content')
                    elif change == 'mtime':
                        os.utime(file, (self.now, self.now))
                    elif change == 'mode':
                        file.chmod(0o400)
                    else:
                        file.unlink()
                        file.write_text(change)
                with self.assertRaisesRegex(r.Refuse, 'changed/open/mounted'):
                    self.run_retention(execute=True, gate=gate)
                self.assertTrue(file.exists())
                # Do not let earlier subtests become candidates in the next one.
                for child in (path / 'nested').iterdir():
                    child.unlink()
                (path / 'nested').rmdir()
                path.rmdir()

    def test_proc_evidence_once_per_pass_and_rechecked(self):
        path = self.candidate(self.cache, 'old', 40)
        calls = {'open': 0, 'mount': 0}
        def opened():
            calls['open'] += 1
            return {r.identity((path / 'nested/data').stat())} if calls['open'] == 2 else set()
        def mounted():
            calls['mount'] += 1
            return set()
        with self.assertRaisesRegex(r.Refuse, 'changed/open/mounted'):
            self.run_retention(execute=True, opened=opened, mounts=mounted)
        self.assertEqual(calls, {'open': 2, 'mount': 2})
        self.assertTrue(path.exists())

    def test_streaming_synthetic_metadata_memory_and_order(self):
        # Fixed directory width, increasing total entries; no real bulk files or
        # recording mocks (their call history would itself grow with the tree).
        def measure(branches, reverse=False):
            visits = 0
            def metadata(name, *, dir_fd, follow_symlinks=False):
                nonlocal visits
                visits += 1
                parts = (*dir_fd, name)
                directory = len(parts) < 3
                inode = 1 if len(parts) == 1 else 2 + int(parts[1][1:]) * 513
                if not directory:
                    inode += 1 + int(parts[2][1:])
                return SimpleNamespace(st_dev=1, st_ino=inode, st_uid=0, st_gid=0,
                    st_mode=(stat.S_IFDIR if directory else stat.S_IFREG) | 0o700,
                    st_size=1, st_mtime=1 if directory else 2,
                    st_mtime_ns=1 if directory else 2, st_ctime_ns=3)
            def names(fd):
                result = ([f'd{i:04}' for i in range(branches)] if len(fd) == 1
                          else [f'f{i:04}' for i in range(512)])
                return result[::-1] if reverse else result
            with patch.object(r.os, 'open', lambda name, flags, *, dir_fd=None:
                              () if dir_fd is None else (*dir_fd, name)), \
                 patch.object(r.os, 'close', lambda fd: None), \
                 patch.object(r.os, 'stat', metadata), \
                 patch.object(r.os, 'fstat', lambda fd: metadata(fd[-1], dir_fd=fd[:-1])), \
                 patch.object(r.os, 'listdir', names):
                tracemalloc.start()
                try:
                    proof, latest = r.snapshot(Path('/synthetic/tree'), 1)
                    _, peak = tracemalloc.get_traced_memory()
                finally:
                    tracemalloc.stop()
            self.assertEqual(visits, 2 * (branches + 1) + branches * 512)
            self.assertEqual(latest, 2)
            self.assertEqual(len(proof[0]), 32)
            return proof, peak
        _, small = measure(8)
        proof, large = measure(128)
        reordered, _ = measure(128, reverse=True)
        self.assertEqual(proof, reordered)
        self.assertLess(large, small + 512 * 1024)
        self.assertLess(large, 2 * 1024 * 1024)
        print(f'streaming metadata peak bytes: 4096 files={small}, 65536 files={large}')

    def test_deletion_refuses_late_symlink_and_root_replacement(self):
        outside = self.base / 'outside'
        outside.write_text('preserve')
        for race in ('symlink', 'root'):
            path = self.candidate(self.cache, race, 40)
            proof, _ = r.snapshot(path, path.stat().st_dev)
            if race == 'symlink':
                (path / 'nested/data').unlink()
                (path / 'nested/data').symlink_to(outside)
            else:
                path.rename(path.with_name('moved'))
                path.mkdir()
            with self.assertRaises(r.Refuse):
                r.remove_tree(path, path.stat().st_dev, set(), set(), proof[1])
            self.assertEqual(outside.read_text(), 'preserve')


class UVTests(RetentionFixture):
    def uv(self, links=False):
        root = self.cache / 'uv'
        (root / 'archive-v0').mkdir(parents=True)
        (root / 'CACHEDIR.TAG').write_bytes(r.CACHE_TAG + b'\n')
        (root / '.lock').touch()
        payload = root / 'archive-v0/data'
        payload.write_text('cache')
        os.utime(payload, (1, 1))
        if links:
            (root / 'archive-v0/link').symlink_to(self.base / 'outside')
        return root

    def test_vendor_cache_buckets_and_retained_tool_directories(self):
        root = self.uv()
        buckets = ('archive-v0', 'builds-v0', 'environments-v2', 'interpreter-v4',
                   'sdists-v9', 'simple-v21', 'wheels-v6', 'python-v0', 'binaries-v0',
                   'osv-v0', 'flat-index-v2', 'git-v0', 'wheels-v5')
        with patch.object(r, 'UV_ROOT', root), patch.object(r, 'ROOTS', self.roots):
            for bucket in buckets:
                (root / bucket).mkdir(exist_ok=True)
            self.assertTrue(r.uv_proof(root, root.stat().st_dev, set(), set()))
            for name in ('tools', 'python', 'bun', 'cargo', 'unknown-v0', 'tools-v0'):
                with self.subTest(name=name):
                    (root / name).mkdir()
                    with self.assertRaisesRegex(r.Refuse, 'cache-only role'):
                        r.uv_proof(root, root.stat().st_dev, set(), set())
                    (root / name).rmdir()
            (root / 'git-v1').symlink_to(root / 'git-v0')
            with self.assertRaisesRegex(r.Refuse, 'cache-only role'):
                r.uv_proof(root, root.stat().st_dev, set(), set())
            (root / 'git-v1').unlink()
            os.mkfifo(root / 'python-v1')
            with self.assertRaisesRegex(r.Refuse, 'cache-only role'):
                r.uv_proof(root, root.stat().st_dev, set(), set())

    def test_uv_exclusion_age_pressure_and_skip_cases(self):
        root = self.uv()
        with patch.object(r, 'qualify_uv', self.fail), patch.object(r, 'owned_uv', self.fail):
            self.run_retention(execute=True)
            self.run_retention(execute=True, used=lambda _: 66.99)
            self.run_retention(execute=False, used=lambda _: 80)
            old = self.candidate(self.builds, 'aged', 8)
            self.run_retention(execute=True, used=lambda _: 65 + 15 * old.exists())
        self.assertTrue((root / 'archive-v0/data').exists())
        with patch.object(r, 'qualify_uv', return_value=None), \
                patch.object(r, 'remove_tree', self.fail), \
                patch.object(r, 'owned_uv', return_value=(0, b'')) as native:
            with self.assertRaisesRegex(r.Refuse, 'cannot reach 65%'):
                self.run_retention(execute=True, used=lambda _: 80)
            native.assert_called_once()

    def test_native_argv_success_and_protected_namespaces(self):
        root = self.uv(links=True)
        protected = [self.candidate(self.cache, name, 40) for name in
                     ('bun', 'cargo', 'tools', 'python')]
        def native(argv):
            self.assertEqual(argv, ['/usr/local/bin/uv', '--no-config', '--offline',
                                   '--no-python-downloads', 'cache', 'clean', '--cache-dir', str(root)])
            (root / 'archive-v0/data').unlink()  # Only the fake owner mutates UV.
            return 0, b''
        with patch.object(r, 'qualify_uv', return_value=None), patch.object(r, 'owned_uv', native):
            self.run_retention(execute=True, used=lambda _: 80 if (root / 'archive-v0/data').exists() else 65)
        self.assertTrue(all((p / 'nested/data').exists() for p in protected))

    def test_native_absent_failure_timeout_insufficient_and_reserve(self):
        with patch.object(r, 'qualify_uv', self.fail), patch.object(r, 'owned_uv', self.fail):
            with self.assertRaisesRegex(r.Refuse, 'cannot reach 65%'):
                self.run_retention(execute=True, used=lambda _: 80)
        root = self.uv()
        for outcome in ((9, b''), r.subprocess.TimeoutExpired('fixture', 1), (0, b'')):
            with self.subTest(outcome=outcome), patch.object(r, 'qualify_uv', return_value=None), \
                    patch.object(r, 'owned_uv', side_effect=outcome if isinstance(outcome, Exception) else None,
                                 return_value=outcome) as native:
                with self.assertRaises((r.Refuse, r.subprocess.TimeoutExpired)):
                    self.run_retention(execute=True, used=lambda _: 80)
                native.assert_called_once()
                self.assertTrue((root / 'archive-v0/data').exists())
        calls = 0
        def used(_):
            return 65 if calls else 80
        def native(_):
            nonlocal calls
            calls += 1
            return 0, b''
        with patch.object(r, 'qualify_uv', return_value=None), patch.object(r, 'owned_uv', native):
            with self.assertRaisesRegex(r.Refuse, 'cold reserve'):
                self.run_retention(execute=True, used=used, available=lambda _: r.COLD_RESERVE - 1)
        self.assertEqual(calls, 1)

    def test_uv_guard_refusals_and_revalidation(self):
        root = self.uv(links=True)
        for field in ('opened', 'mounts'):
            with self.subTest(field=field), patch.object(r, 'qualify_uv', self.fail):
                with self.assertRaisesRegex(r.Refuse, 'open/mounted'):
                    self.run_retention(execute=True, used=lambda _: 80,
                                       **{field: lambda: {r.identity((root / 'archive-v0/data').stat())}})
        with patch.object(r, 'qualify_uv', return_value=None), patch.object(r, 'owned_uv', self.fail):
            def gate():
                (root / 'archive-v0/data').write_text('changed')
            with self.assertRaisesRegex(r.Refuse, 'fingerprint changed'):
                self.run_retention(execute=True, used=lambda _: 80, gate=gate)
            def denied_gate():
                raise r.Refuse('stale claim')
            with self.assertRaisesRegex(r.Refuse, 'stale claim'):
                self.run_retention(execute=True, used=lambda _: 80, gate=denied_gate)
        for mutation in ('marker', 'tool', 'replacement', 'root-link'):
            with self.subTest(mutation=mutation), patch.object(r, 'owned_uv', self.fail):
                if mutation == 'marker':
                    (root / 'CACHEDIR.TAG').write_text('invalid')
                elif mutation == 'tool':
                    (root / 'CACHEDIR.TAG').write_bytes(r.CACHE_TAG)
                    (root / 'tools').mkdir()
                elif mutation == 'replacement':
                    (root / 'tools').rmdir()
                else:
                    root.rename(self.cache / 'saved')
                    root.symlink_to(self.cache / 'saved')
                def qualify():
                    root.rename(self.cache / 'replaced')
                    root.mkdir()
                with patch.object(r, 'qualify_uv', qualify if mutation == 'replacement' else self.fail):
                    with self.assertRaises((r.Refuse, OSError)):
                        self.run_retention(execute=True, used=lambda _: 80)
                if mutation == 'replacement':
                    root.rmdir()
                    (self.cache / 'replaced').rename(root)
        with self.assertRaisesRegex(r.Refuse, 'wrong UV'):
            r.uv_proof(root, root.lstat().st_dev, set(), set())

    def test_qualified_binary_and_version(self):
        binary = self.base / 'uv-binary'
        binary.write_bytes(b'fixture binary')
        with patch.object(r, 'UV_BINARY', binary), patch.object(r, 'owned_uv') as native:
            with self.assertRaisesRegex(r.Refuse, 'unsupported UV binary'):
                r.qualify_uv()
            native.assert_not_called()
            with patch.object(r, 'UV_SHA256', r.hashlib.sha256(binary.read_bytes()).hexdigest()):
                for rc, output in ((0, b'uv 0.11.26\n'), (0, b'uv 0.11.25\n'), (2, b'uv 0.11.26\n')):
                    native.return_value = rc, output
                    if rc == 0 and output == b'uv 0.11.26\n':
                        r.qualify_uv()
                    else:
                        with self.assertRaisesRegex(r.Refuse, 'unsupported UV version'):
                            r.qualify_uv()
                self.assertEqual(native.call_args.args[0], [str(binary), '--version'])

    def test_owned_child_timeout_reaped_and_environment_scrubbed(self):
        real_popen = r.subprocess.Popen
        children = []
        def launch(*args, **kwargs):
            self.assertEqual(kwargs['env'], r.UV_ENV)
            self.assertEqual(kwargs['cwd'], '/')
            self.assertEqual(kwargs['stdin'], r.subprocess.DEVNULL)
            self.assertIsNone(kwargs['stdout'])
            self.assertNotIn('stderr', kwargs)
            child = real_popen(*args, **kwargs)
            children.append(child)
            return child
        with patch.object(r.os, 'getpid', return_value=1), patch.object(r.subprocess, 'Popen', launch), \
                patch.dict(os.environ, {'UV_CONFIG_FILE': '/untrusted', 'HTTPS_PROXY': 'untrusted'}):
            with self.assertRaises(r.subprocess.TimeoutExpired):
                r.owned_uv(['/usr/bin/python3', '-B', '-c', 'import time; time.sleep(60)'], timeout=0.1)
        self.assertEqual(len(children), 1)
        self.assertIsNotNone(children[0].returncode)
        with self.assertRaises(ChildProcessError):
            os.waitpid(children[0].pid, os.WNOHANG)
        with patch.object(r.os, 'getpid', return_value=2), patch.object(r.subprocess, 'Popen', self.fail):
            with self.assertRaisesRegex(r.Refuse, 'private PID'):
                r.owned_uv(['never'])

    def test_native_fresh_open_mount_parent_link_and_device_guards(self):
        root = self.uv()
        with patch.object(r, 'UV_ROOT', root), patch.object(r, 'ROOTS', self.roots):
            with self.assertRaisesRegex(r.Refuse, 'filesystem changed'):
                r.uv_proof(root, root.stat().st_dev ^ 1, set(), set())
            with patch.object(r.os, 'statvfs', return_value=SimpleNamespace(f_flag=os.ST_RDONLY)):
                with self.assertRaisesRegex(r.Refuse, 'read-only'):
                    r.uv_proof(root, root.stat().st_dev, set(), set())
            alias = self.base / 'alias'
            alias.symlink_to(self.cache)
            with patch.object(r, 'UV_ROOT', alias / 'uv'), patch.object(r, 'ROOTS', ((self.builds, 7), (alias, 30))):
                with self.assertRaisesRegex(r.Refuse, 'ancestor'):
                    r.uv_proof(alias / 'uv', root.stat().st_dev, set(), set())
        for field in ('opened', 'mounts'):
            calls = 0
            def scan():
                nonlocal calls
                calls += 1
                return {r.identity(root.stat())} if calls > 1 else set()
            with self.subTest(field=field), patch.object(r, 'qualify_uv', return_value=None), \
                    patch.object(r, 'owned_uv', self.fail):
                with self.assertRaisesRegex(r.Refuse, 'open/mounted'):
                    self.run_retention(execute=True, used=lambda _: 80, **{field: scan})
            self.assertEqual(calls, 2)

    def test_owned_child_baseexception_and_unreaped_containment(self):
        primary = KeyboardInterrupt('fixture primary')
        class Child:
            stdout = None
            def __init__(self):
                self.trace = []
            def wait(self, *, timeout):
                self.trace.append(('wait', timeout))
                if len(self.trace) == 1:
                    raise primary
                raise r.subprocess.TimeoutExpired('fixture', timeout)
            def kill(self):
                self.trace.append(('kill',))
        child = Child()
        with patch.object(r.os, 'getpid', return_value=1), patch.object(r.subprocess, 'Popen', return_value=child):
            with self.assertRaises(KeyboardInterrupt) as caught:
                r.owned_uv(['fixture'])
        self.assertIs(caught.exception, primary)
        self.assertEqual(child.trace, [('wait', 330), ('kill',), ('wait', 5)])
        self.assertTrue(any('retirement UNPROVED' in note for note in primary.__notes__))


class GateTests(unittest.TestCase):
    def test_api_gate_reads_real_namespaces_and_rejects_ci_self(self):
        own = self.payload()
        own['items'][0]['metadata']['namespace'] = 'ci-maintenance-worker'
        env = {'NODE_NAME': 'hestia', 'POD_UID': 'self', 'POD_NAME': 'retention',
               'POD_NAMESPACE': 'ci-maintenance-worker', 'KUBERNETES_SERVICE_HOST': 'fixture',
               'KUBERNETES_SERVICE_PORT_HTTPS': '443'}
        urls = []
        lists = {'ci': {'metadata': {}, 'items': []}, 'ci-maintenance-worker': own}
        def response(request, **kwargs):
            urls.append(request.full_url)
            return io.StringIO(json.dumps(lists[request.full_url.split('/')[6]]))
        with patch.dict(r.os.environ, env), patch.object(r.ssl, 'create_default_context'), \
                patch.object(Path, 'read_text', return_value='fixture-token'), \
                patch.object(r.urllib.request, 'urlopen', response):
            r.api_gate()
            self.assertEqual(urls, ['https://fixture:443/api/v1/namespaces/ci/pods?limit=500',
                                    'https://fixture:443/api/v1/namespaces/ci-maintenance-worker/pods?limit=500'])
            lists['ci'] = copy.deepcopy(own)
            lists['ci']['items'][0]['metadata']['namespace'] = 'ci'
            lists['ci-maintenance-worker'] = {'metadata': {}, 'items': []}
            with self.assertRaises(r.Refuse):
                r.api_gate()

    def test_cross_namespace_complete_or_refuse(self):
        own = self.payload()
        own['items'][0]['metadata']['namespace'] = 'ci-maintenance-worker'
        empty = {'metadata': {}, 'items': []}
        lists = {'ci': copy.deepcopy(empty), 'ci-maintenance-worker': own}
        self.assertTrue(r.pod_gate(r.combined_pods(lists.__getitem__), 'self'))
        for namespace in lists:
            for bad in (None, {'metadata': {'continue': 'more'}, 'items': []},
                        {'metadata': {}, 'items': [None]}, {'metadata': {}, 'items': None}):
                changed = copy.deepcopy(lists)
                changed[namespace] = bad
                with self.subTest(namespace=namespace, bad=bad), self.assertRaises(r.Refuse):
                    r.pod_gate(r.combined_pods(changed.__getitem__), 'self')
        duplicate = copy.deepcopy(own['items'][0])
        duplicate['metadata']['namespace'] = 'ci'
        lists['ci']['items'] = [duplicate]
        with self.assertRaises(r.Refuse):
            r.pod_gate(r.combined_pods(lists.__getitem__), 'self')
        lists['ci']['items'][0]['metadata']['namespace'] = 'foreign'
        with self.assertRaises(r.Refuse):
            r.combined_pods(lists.__getitem__)

    def payload(self, phase='Running'):
        return {'metadata': {}, 'items': [{
            'metadata': {'uid': 'self', 'name': 'retention', 'labels': {
                'ci.brmartin.co.uk/job': 'true', 'ci.brmartin.co.uk/maintenance': 'true'}},
            'spec': {'nodeName': 'hestia'}, 'status': {'phase': phase}}]}

    def gate_results(self, case):
        # Execute the actual embedded GC gate, replacing only its input I/O.
        source = (CI / 'cronjob-ci-hestia-ci-store-gc.yaml').read_text()
        code = textwrap.dedent(source.split("python3 - <<'PY' || gate_rc=$?\n", 1)[1].split('\n              PY', 1)[0])
        class OriginalOS:
            environ = {'POD_UID': 'self'}
        namespace = {'json': json, 'os': OriginalOS, 'fixture': case}
        rewritten = code.replace('import json\n', '').replace('import os\n', '')
        rewritten = rewritten.replace('with open("/tmp/pods.json", "rb") as stream:\n    payload = json.load(stream)', 'payload = fixture')
        embedded = 0
        with contextlib.redirect_stdout(io.StringIO()):
            try:
                exec(rewritten, namespace)
            except SystemExit as error:
                embedded = 75 if error.code == 75 else 1
        try:
            retention = 0 if r.pod_gate(case, 'self') else 75
        except r.Refuse:
            retention = 1
        return embedded, retention

    def test_remote_active_ci_is_node_local(self):
        for node in ('heracles', 'nyx'):
            for phase in ('Running', 'Pending'):
                case = self.payload()
                remote = copy.deepcopy(case['items'][0])
                remote['metadata'].update(uid='remote', name='runner-remote')
                remote['metadata']['labels'].pop('ci.brmartin.co.uk/maintenance')
                remote['spec']['nodeName'] = node
                remote['status']['phase'] = phase
                case['items'].append(remote)
                with self.subTest(node=node, phase=phase):
                    self.assertEqual(self.gate_results(case), (0, 0))

    def test_gate_matches_existing_gc_fence(self):
        cases = [self.payload(), self.payload('Pending')]
        for phase in ('Running', 'Pending'):
            item = copy.deepcopy(self.payload()['items'][0])
            item['metadata']['uid'] = 'other'
            item['status']['phase'] = phase
            cases.append({'metadata': {}, 'items': [*self.payload()['items'], item]})
        for field, value in [('uid', 'absent'), ('deletionTimestamp', 'now'), ('labels', {})]:
            value_case = self.payload()
            value_case['items'][0]['metadata'][field] = value
            cases.append(value_case)
        paged = self.payload()
        paged['metadata']['continue'] = 'more'
        cases.extend([paged, {'metadata': {}, 'items': []}, {'items': None}])
        wrong_node = self.payload()
        wrong_node['items'][0]['spec']['nodeName'] = 'nyx'
        cases.append(wrong_node)
        for case in cases:
            with self.subTest(payload=case):
                embedded, retention = self.gate_results(case)
                self.assertEqual(embedded, retention)

    def test_node_local_safety_matrix(self):
        for node in ('hestia', 'heracles', 'nyx', '', 'unknown'):
            for phase in ('Running', 'Pending', 'Unknown', '', 'Failed', 'Succeeded'):
                for terminating in (False, True):
                    case = self.payload()
                    other = copy.deepcopy(case['items'][0])
                    other['metadata'].update(uid='other', name='runner-other')
                    other['spec']['nodeName'] = node
                    other['status']['phase'] = phase
                    if terminating:
                        other['metadata']['deletionTimestamp'] = 'now'
                    case['items'].append(other)
                    allowed = not terminating and (phase in ('Failed', 'Succeeded') or
                        phase in ('Running', 'Pending') and node in ('heracles', 'nyx'))
                    expected = 0 if allowed else 1
                    with self.subTest(node=node, phase=phase, terminating=terminating):
                        self.assertEqual(self.gate_results(case), (expected, expected))
        for mutation in ('uid', 'name', 'labels', 'spec', 'status', 'item', 'duplicate'):
            for remote in (False, True):
                case = self.payload()
                item = copy.deepcopy(case['items'][0])
                if remote:
                    item['metadata'].update(uid='remote', name='runner-remote')
                    item['spec']['nodeName'] = 'heracles'
                if mutation in ('uid', 'name', 'labels'):
                    item['metadata'][mutation] = '' if mutation != 'labels' else None
                elif mutation in ('spec', 'status'):
                    item[mutation] = None
                elif mutation == 'item':
                    item = None
                case['items'] = [case['items'][0], item] if remote else [item]
                if mutation == 'duplicate':
                    case['items'].append(copy.deepcopy(item))
                with self.subTest(mutation=mutation, remote=remote):
                    self.assertEqual(self.gate_results(case), (1, 1))
        for malformed in (None, {}, {'items': None}, {'metadata': {}, 'items': [None]},
                          {'metadata': {'continue': 'more'}, 'items': []}):
            with self.subTest(malformed=malformed):
                self.assertEqual(self.gate_results(malformed), (1, 1))
        # Preserve otherwise valid non-CI observations, even unknown phases.
        case = self.payload()
        other = copy.deepcopy(case['items'][0])
        other['metadata'].update(uid='non-ci', labels={})
        other['status']['phase'] = 'Unknown'
        case['items'].append(other)
        self.assertEqual(self.gate_results(case), (0, 0))

    def test_local_conflict_during_pending_retry_is_fatal(self):
        conflict = self.payload('Pending')
        other = copy.deepcopy(conflict['items'][0])
        other['metadata']['uid'] = 'arriving'
        other['status']['phase'] = 'Running'
        conflict['items'].append(other)
        self.assertEqual(self.gate_results(conflict), (1, 1))
        payloads = iter([self.payload('Pending'), conflict, self.payload()])
        sleeps = []
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(r.Refuse):
            r.wait_for_gate(lambda: next(payloads), 'self', sleeps.append)
        self.assertEqual(sleeps, [2])
        self.assertEqual(next(payloads), self.payload())

    def test_pending_retry_bounded_and_rejections_not_retried(self):
        with contextlib.redirect_stdout(io.StringIO()):
            payloads = iter([self.payload('Pending'), self.payload()])
            sleeps = []
            r.wait_for_gate(lambda: next(payloads), 'self', sleeps.append)
            self.assertEqual(sleeps, [2])
            sleeps.clear()
            with self.assertRaisesRegex(r.Refuse, 'did not become Running'):
                r.wait_for_gate(lambda: self.payload('Pending'), 'self', sleeps.append)
            self.assertEqual(len(sleeps), 14)
            with self.assertRaises(r.Refuse):
                r.wait_for_gate(lambda: {'items': []}, 'self', self.fail)


if __name__ == '__main__':
    unittest.main(verbosity=2)
