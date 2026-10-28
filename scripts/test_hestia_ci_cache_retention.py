#!/usr/bin/env python3
"""Focused stdlib retention fixtures; never call production main()/host cleanup."""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parent.parent
CI = ROOT / 'infrastructure/shared-services/gitlab-runner/ci'
spec = importlib.util.spec_from_file_location('retention', CI / 'cache-retention.py')
assert spec is not None and spec.loader is not None
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


class RetentionTests(unittest.TestCase):
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
        with contextlib.redirect_stdout(io.StringIO()) as output:
            r.retain(self.roots, now=self.now, used=kwargs.pop('used', lambda _: 50),
                     opened=kwargs.pop('opened', set), mounts=kwargs.pop('mounts', set),
                     **kwargs)
        return output.getvalue()

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

    def test_under_75_preserves_young_data(self):
        path = self.candidate(self.builds, 'young', 1)
        self.run_retention(execute=True, used=lambda _: 74.99)
        self.assertTrue(path.exists())

    def test_age_cleanup_precedes_capacity_backstop(self):
        old = self.candidate(self.cache, 'aged', 40)
        young = self.candidate(self.builds, 'young', 1)
        self.run_retention(execute=True, used=lambda _: 70 + 10 * old.exists())
        self.assertFalse(old.exists())
        self.assertTrue(young.exists())

    def test_dry_run_never_mutates(self):
        path = self.candidate(self.cache, 'old', 40)
        output = self.run_retention(execute=False, used=lambda _: 80)
        self.assertIn('WOULD DELETE', output)
        self.assertTrue(path.exists())

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

    def test_mountinfo_alias_resolves_to_inode_in_other_namespace(self):
        path = self.candidate(self.cache, 'mounted', 40)
        proc = self.base / 'proc'
        for pid in ('self', '1', '123'):
            owner = proc / pid
            (owner / 'ns').mkdir(parents=True)
            (owner / 'ns/mnt').touch()
            (owner / 'root').symlink_to(self.base, target_is_directory=True)
            (owner / 'mountinfo').write_text('1 0 0:1 / /alias rw - xfs fixture rw\n' if pid == '123' else '')
        (self.base / 'alias').symlink_to(path / 'nested', target_is_directory=True)
        self.assertIn(r.identity((path / 'nested').stat()), r.mount_ids(proc))
        self.run_retention(execute=True, mounts=lambda: r.mount_ids(proc))
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


class GateTests(unittest.TestCase):
    def payload(self, phase='Running'):
        return {'metadata': {}, 'items': [{
            'metadata': {'uid': 'self', 'name': 'retention', 'labels': {
                'ci.brmartin.co.uk/job': 'true', 'ci.brmartin.co.uk/maintenance': 'true'}},
            'spec': {'nodeName': 'hestia'}, 'status': {'phase': phase}}]}

    def test_gate_matches_existing_gc_fence(self):
        # Reuse the original production gate as the reference, without its huge harness.
        source = (CI / 'cronjob-ci-hestia-ci-store-gc.yaml').read_text()
        code = textwrap.dedent(source.split("python3 - <<'PY' || gate_rc=$?\n", 1)[1].split('\n              PY', 1)[0])
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
                # Redirect original /tmp JSON read and environment only, not gate logic.
                class OriginalOS:
                    environ = {'POD_UID': 'self'}
                namespace = {'json': json, 'os': OriginalOS}
                rewritten = code.replace('import json\n', '').replace('import os\n', '')
                rewritten = rewritten.replace('with open("/tmp/pods.json", "rb") as stream:\n    payload = json.load(stream)', 'payload = fixture')
                namespace['fixture'] = case
                expected = 0
                with contextlib.redirect_stdout(io.StringIO()):
                    try:
                        exec(rewritten, namespace)
                    except SystemExit as error:
                        expected = 75 if error.code == 75 else 1
                try:
                    actual = 0 if r.pod_gate(case, 'self') else 75
                except r.Refuse:
                    actual = 1
                self.assertEqual(expected, actual)

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
