#!/usr/bin/env python3
"""Real helper/local archives; backup-utility is a double, NOT native backup proof."""
import gzip
import hashlib
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / 'apps/gitlab-helm/files/nas-export.py'
DISABLED = 'external_diffs,terraform_state,pages,ci_secure_files,agent_plan_content,ci_catalog_bundles'


class ExportFixtures(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        if os.getuid() == 0:
            os.chown(self.root, 1000, 1000)
        self.recovery = self.root / 'recovery'
        self.recovery.mkdir()
        self.work = self.root / 'work'
        self.work.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.version = self.root / 'VERSION'
        self.version.write_text('19.5.0\n')
        self.fixture = self.root / 'fixture.tar'
        self.calls = self.root / 'calls'
        fake = self.bin / 'backup-utility'
        fake.write_text('''#!/usr/bin/env python3
import os, pathlib, shutil, sys, time
root = pathlib.Path(os.environ['BACKUP_WORK_DIR'])
with open(os.environ['FIXTURE_CALLS'], 'a') as f: f.write(' '.join(sys.argv[1:]) + '\\n')
if '--cleanup' in sys.argv:
    assert sys.argv[1:] == ['--cleanup', '--maximum-backups', '7']
    assert any((pathlib.Path(os.environ['RECOVERY_DIR']) / 'gitlab-exports').glob('*/archive.sha256'))
    sys.exit(int(os.environ.get('FIXTURE_CLEANUP_FAILURE', '0')))
assert sys.argv[1:] == ['--skip', os.environ['FIXTURE_DISABLED'], '--skip-cleanup']
if os.environ.get('FIXTURE_NATIVE_FAILURE'): sys.exit(7)
t = int(time.time())
name = time.strftime(str(t) + '_%Y_%m_%d_19.5.0_gitlab_backup.tar')
dest = root / 'backup_tars'
if dest.exists(): shutil.rmtree(dest)
dest.mkdir()
shutil.copyfile(os.environ['FIXTURE_ARCHIVE'], dest / name)
if os.environ.get('FIXTURE_STALE'): os.utime(dest / name, (1, 1))
if os.environ.get('FIXTURE_NAS_WRITE_FAILURE'): (pathlib.Path(os.environ['RECOVERY_DIR']) / 'gitlab-exports').chmod(0o500)
for component in ('registry', 'uploads', 'artifacts', 'lfs', 'packages'):
    if component == 'lfs' and os.environ.get('FIXTURE_SILENT_FAILURE'):
        print('\\x1b[31mUnable to check existence of bucket gitlab-lfs. Skipping backup of lfs ...\\x1b[0m')
        print('Bucket check command failed with exit code 1. Output: private diagnostic')
    else:
        print('\\x1b[34mDumping %s ...\\x1b[0m' % component)
        print('\\x1b[32m%s\\x1b[0m' % ('empty' if component == os.environ.get('FIXTURE_EMPTY') else 'done'))
print('[DONE] Backup can be found at s3://gitlab-backups/' + name)
''')
        fake.chmod(0o755)
        self.env = {**os.environ, 'PATH': str(self.bin) + ':' + os.environ['PATH'],
                    'RECOVERY_DIR': str(self.recovery), 'VERSION_FILE': str(self.version),
                    'BACKUP_WORK_DIR': str(self.work), 'FIXTURE_ARCHIVE': str(self.fixture),
                    'FIXTURE_CALLS': str(self.calls), 'FIXTURE_DISABLED': DISABLED}
        self.last_run = 0

    def add_archive(self, missing=None, directory=None, bad=None, empty=None):
        # Mirrors native get_skipped: pages occurs twice, enabled empty LFS is skipped.
        while int(time.time()) <= self.last_run:
            time.sleep(0.02)
        timestamp = int(time.time())
        backup_id = time.strftime(str(timestamp) + '_%Y_%m_%d_19.5.0')
        created = time.strftime('%Y-%m-%d %H:%M:%S %z')
        self.metadata = (f':backup_id: {backup_id}\n:db_version: 20261001000000\n'
                         f':backup_created_at: {created}\n:gitlab_version: 19.5.0\n'
                         ':tar_version: tar (GNU tar) 1.35\n:installation_type: gitlab-helm-chart\n'
                         ':skipped: builds,pages' + (',lfs' if empty == 'lfs' else '')
                         + ',external_diffs,terraform_state,pages,ci_secure_files,agent_plan_content,ci_catalog_bundles'
                         + '\n:repositories_server_side: false\n').encode()
        self.env.pop('FIXTURE_EMPTY', None)
        if empty:
            self.env['FIXTURE_EMPTY'] = empty
        with tarfile.open(self.fixture, 'w') as archive:
            def add(name, data):
                if name == missing:
                    return
                member = tarfile.TarInfo('./' + name)
                if name == directory:
                    member.type = tarfile.DIRTYPE
                    archive.addfile(member)
                else:
                    member.size = len(data)
                    archive.addfile(member, io.BytesIO(data))
            add('backup_information.yml', self.metadata)
            add('db/database.sql.gz', b'bad gzip' if bad == 'db' else gzip.compress(b'-- fixture SQL\n'))
            item = tarfile.TarInfo('./repositories')
            item.type = tarfile.DIRTYPE
            archive.addfile(item)  # Legitimately empty repositories; no bundle-count fiction.
            for component in ('registry', 'uploads', 'artifacts', 'lfs', 'packages'):
                if component == empty:
                    continue
                payload = self.gzip_tar()
                if bad == component:
                    payload = gzip.compress(b'not a tar')
                if bad == 'crc' and component == 'uploads':
                    payload = payload[:-8] + b'\0' * 8
                add(component + '.tar.gz', payload)
            if bad == 'unsafe':
                add('../escape', b'unsafe')

    @staticmethod
    def gzip_tar():
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode='w:gz') as inner:
            item = tarfile.TarInfo('./fixture')
            item.size = 7
            inner.addfile(item, io.BytesIO(b'fixture'))
        return buf.getvalue()

    def run_export(self):
        # Native filenames have one-second resolution; avoid deliberate collisions.
        while int(time.time()) <= self.last_run:
            time.sleep(0.02)
        self.last_run = int(time.time())
        if os.getuid() == 0:
            for p in self.root.rglob('*'):
                os.chown(p, 1000, 1000, follow_symlinks=False)
        def drop():
            os.setgroups([])
            os.setgid(1000)
            os.setuid(1000)
        return subprocess.run(['python3', str(SCRIPT)], env=self.env, capture_output=True,
                              text=True, timeout=20, preexec_fn=drop if os.getuid() == 0 else None)

    def completed(self):
        dest = self.recovery / 'gitlab-exports'
        return sorted(p for p in dest.iterdir() if not p.name.startswith('.')) if dest.exists() else []

    def test_empty_duplicate_native_metadata_and_private_retention(self):
        for _ in range(9):
            self.add_archive(empty='lfs')
            result = self.run_export()
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.completed()), 7)
        for directory in self.completed():
            self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
            files = list(directory.iterdir())
            self.assertEqual(len(files), 3)
            for p in files:
                self.assertEqual(p.stat().st_mode & 0o777, 0o600)
            archive = next(p for p in files if p.name.endswith('.tar'))
            self.assertEqual((directory / 'archive.sha256').read_text(), hashlib.sha256(archive.read_bytes()).hexdigest() + '  ' + archive.name + '\n')
            with tarfile.open(archive) as native:
                metadata = native.extractfile('./backup_information.yml')
                assert metadata is not None
                self.assertEqual((directory / 'backup_information.yml').read_bytes(), metadata.read())
        latest = self.completed()[-1]
        self.assertEqual(next(latest.glob('*.tar')).read_bytes(), self.fixture.read_bytes())
        for path in self.work.glob('.native-backup.*.log'):
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertIn('Producer exit status: 0', path.read_text())
        calls = self.calls.read_text().splitlines()
        self.assertEqual(calls, [f'--skip {DISABLED} --skip-cleanup', '--cleanup --maximum-backups 7'] * 9)
        unknown = self.recovery / 'gitlab-exports/unknown'
        unknown.mkdir()
        partial = self.recovery / 'gitlab-exports/.other.partial'
        partial.mkdir()
        self.assertEqual(self.run_export().returncode, 0)
        self.assertTrue(unknown.exists())
        self.assertTrue(partial.exists())

    def test_producer_and_payload_failures_preserve_previous(self):
        self.add_archive()
        self.assertEqual(self.run_export().returncode, 0)
        original = self.completed()
        cases = ('silent', 'nonzero', 'stale', 'invalid', 'nas_write', 'missing_db', 'missing_blob',
                 'directory_db', 'directory_blob', 'db_gzip', 'blob_tar', 'crc', 'unsafe')
        for case in cases:
            with self.subTest(case=case):
                for key in ('FIXTURE_SILENT_FAILURE', 'FIXTURE_NATIVE_FAILURE', 'FIXTURE_STALE', 'FIXTURE_NAS_WRITE_FAILURE'):
                    self.env.pop(key, None)
                self.add_archive(
                    missing={'missing_db': 'db/database.sql.gz', 'missing_blob': 'uploads.tar.gz'}.get(case),
                    directory={'directory_db': 'db/database.sql.gz', 'directory_blob': 'uploads.tar.gz'}.get(case),
                    bad={'db_gzip': 'db', 'blob_tar': 'uploads', 'crc': 'crc', 'unsafe': 'unsafe'}.get(case))
                if case == 'invalid':
                    self.fixture.write_bytes(b'not a tar')
                if case == 'nas_write':
                    self.env['FIXTURE_NAS_WRITE_FAILURE'] = '1'
                if case in ('silent', 'nonzero', 'stale'):
                    self.env[{'silent': 'FIXTURE_SILENT_FAILURE', 'nonzero': 'FIXTURE_NATIVE_FAILURE', 'stale': 'FIXTURE_STALE'}[case]] = '1'
                before = self.calls.read_text().count('--cleanup')
                result = self.run_export()
                if case == 'nas_write':
                    (self.recovery / 'gitlab-exports').chmod(0o700)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn('private diagnostic', result.stdout + result.stderr)
                self.assertEqual(self.completed(), original)
                self.assertEqual(self.calls.read_text().count('--cleanup'), before)

    def test_db_retention_only_after_qualified_publication(self):
        archives = self.recovery / 'db-archives'
        archives.mkdir(mode=0o700)
        for n in range(16):
            archive = archives / ('admission.' + f'{n:012d}')
            archive.mkdir(mode=0o700)
            dump = b'PGDMP fixture, NOT a database archive'
            (archive / 'database.dump').write_bytes(dump)
            (archive / 'database.sha256').write_text(hashlib.sha256(dump).hexdigest() + '  database.dump\n')
            (archive / 'archive.list').write_text('fixture pg_restore --list result\n')
            (archive / 'admission.txt').write_text(
                'previous_gitlab=19.5.0\nprevious_chart=10.5.0\ntarget_gitlab=19.5.0\ntarget_chart=10.5.0\n'
                + f'observed_at=2026-10-01T00:00:{n:02d}Z\nidentity=fixture\n')
            for p in archive.iterdir():
                p.chmod(0o600)
        unknown = archives / 'unknown'
        unknown.mkdir()
        partial = archives / '.admission.XXXXXXXXXXXX'
        partial.mkdir()
        self.add_archive(empty='lfs')
        self.env['FIXTURE_SILENT_FAILURE'] = '1'
        self.assertNotEqual(self.run_export().returncode, 0)
        self.assertEqual(len(list(archives.glob('admission.*'))), 16)
        self.env.pop('FIXTURE_SILENT_FAILURE')
        # NAS failure likewise cannot prune DB/native history.
        self.env['FIXTURE_NAS_WRITE_FAILURE'] = '1'
        self.assertNotEqual(self.run_export().returncode, 0)
        self.assertEqual(len(list(archives.glob('admission.*'))), 16)
        self.assertNotIn('--cleanup', self.calls.read_text())
        self.env.pop('FIXTURE_NAS_WRITE_FAILURE')
        (self.recovery / 'gitlab-exports').chmod(0o700)
        result = self.run_export()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(list(archives.glob('admission.*'))), 14)
        self.assertTrue(unknown.exists())
        self.assertTrue(partial.exists())
        self.assertFalse((archives / 'admission.000000000000').exists())
        self.assertTrue((archives / 'admission.000000000015').exists())

    def test_nas_and_cleanup_failures(self):
        self.add_archive()
        self.assertEqual(self.run_export().returncode, 0)
        original = self.completed()
        dest = self.recovery / 'gitlab-exports'
        dest.rename(self.recovery / 'previous')
        dest.symlink_to(self.work, target_is_directory=True)
        self.assertNotEqual(self.run_export().returncode, 0)
        dest.unlink()
        (self.recovery / 'previous').rename(dest)
        dest.chmod(0o755)
        self.assertNotEqual(self.run_export().returncode, 0)
        self.assertEqual(dest.stat().st_mode & 0o777, 0o755)  # No permission repair.
        dest.chmod(0o700)
        self.assertEqual(self.completed(), original)
        self.env['FIXTURE_CLEANUP_FAILURE'] = '1'
        self.assertNotEqual(self.run_export().returncode, 0)
        self.assertEqual(len(self.completed()), 2)  # Native cleanup failure keeps new NAS point.


if __name__ == '__main__':
    unittest.main()
