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
from unittest.mock import patch

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
                     valid.replace(' / / ', ' relative / '),
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


class GateTests(unittest.TestCase):
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
