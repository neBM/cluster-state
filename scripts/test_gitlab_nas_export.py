#!/usr/bin/env python3
"""Local real-script/archive/permissions fixtures; s3cmd is a command double, NOT S3 proof."""
import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / 'apps/gitlab-helm/files/nas-export.py'


class ExportFixtures(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        if os.getuid() == 0:
            os.chown(self.root, 1000, 1000)
        self.recovery = self.root / 'recovery'
        self.recovery.mkdir()
        self.remote = self.root / 'remote'
        self.remote.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.version = self.root / 'VERSION'
        self.version.write_text('19.5.0\n')
        self.config = self.root / 'config'
        self.config.write_text('fixture config; not credentials\n')
        fake = self.bin / 's3cmd'
        fake.write_text('''#!/usr/bin/env python3
import os, pathlib, shutil, sys
r = pathlib.Path(os.environ['FIXTURE_REMOTE'])
if os.environ.get('FIXTURE_S3_FAILURE'): sys.exit(1)
if 'ls' in sys.argv:
    for p in sorted(r.iterdir()):
        print('2026-01-01 01:00 %d s3://gitlab-backups/%s' % (p.stat().st_size, p.name))
elif 'get' in sys.argv:
    shutil.copyfile(r / sys.argv[-2].rsplit('/', 1)[-1], sys.argv[-1])
else: sys.exit(2)
''')
        fake.chmod(0o755)
        self.env = {**os.environ, 'PATH': str(self.bin) + ':' + os.environ['PATH'],
                    'RECOVERY_DIR': str(self.recovery), 'VERSION_FILE': str(self.version),
                    'S3_CONFIG': str(self.config), 'FIXTURE_REMOTE': str(self.remote)}
        self.timestamp = int(time.time()) - 60

    def add_archive(self, timestamp=None, skipped='builds,pages,external_diffs,terraform_state,ci_secure_files,agent_plan_content,ci_catalog_bundles', missing=None, metadata=None, unsafe=False):
        timestamp = timestamp or self.timestamp
        date = time.strftime('%Y_%m_%d', time.localtime(timestamp))
        backup_id = f'{timestamp}_{date}_19.5.0'
        name = backup_id + '_gitlab_backup.tar'
        info = (f':backup_id: {backup_id}\n:db_version: 20261001000000\n'
                f':backup_created_at: {time.strftime("%Y-%m-%d %H:%M:%S %z", time.localtime(timestamp))}\n'
                ':gitlab_version: 19.5.0\n:tar_version: tar (GNU tar) 1.35\n'
                f':installation_type: gitlab-helm-chart\n:skipped: {skipped}\n:repositories_server_side: false\n')
        with tarfile.open(self.remote / name, 'w') as archive:
            def add(n, data):
                member = tarfile.TarInfo('./' + n)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
            add('backup_information.yml', (metadata if metadata is not None else info).encode())
            add('db/database.sql.gz', self.gzip_tar(sql=True))
            # Native repositories may be empty: no invented bundle-per-project requirement.
            member = tarfile.TarInfo('./repositories')
            member.type = tarfile.DIRTYPE
            archive.addfile(member)
            for component in ('registry', 'uploads', 'artifacts', 'lfs', 'packages'):
                if component != missing:
                    add(component + '.tar.gz', self.gzip_tar())
            if unsafe:
                add('../escape', b'unsafe')
        return name

    @staticmethod
    def gzip_tar(sql=False):
        import gzip
        if sql:
            return gzip.compress(b'-- fixture database SQL\n')
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode='w:gz') as inner:
            item = tarfile.TarInfo('./fixture')
            item.size = 7
            inner.addfile(item, io.BytesIO(b'fixture'))
        return buf.getvalue()

    def run_export(self):
        self.assertTrue(SCRIPT.is_file(), 'NAS exporter script is missing')
        if os.getuid() == 0:
            for p in self.root.rglob('*'):
                os.chown(p, 1000, 1000)
        def drop():
            os.setgroups([])
            os.setgid(1000)
            os.setuid(1000)
        return subprocess.run(['python3', str(SCRIPT)], env=self.env, capture_output=True,
                              text=True, timeout=20, preexec_fn=drop if os.getuid() == 0 else None)

    def completed(self):
        dest = self.recovery / 'gitlab-exports'
        return sorted(p for p in dest.iterdir() if not p.name.startswith('.')) if dest.exists() else []

    def test_private_publication_and_retention(self):
        for n in range(9):
            self.add_archive(self.timestamp - (9 - n) * 10)
            result = self.run_export()
            self.assertEqual(result.returncode, 0, result.stderr)
            # The fixture has only the last completed remote object, not a simulated native backup.
            for p in self.remote.iterdir():
                p.unlink()
        self.assertEqual(len(self.completed()), 7)
        for directory in self.completed():
            self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
            files = list(directory.iterdir())
            self.assertEqual(len(files), 3)
            for p in files:
                self.assertEqual(p.stat().st_mode & 0o777, 0o600)
            archive = next(p for p in files if p.name.endswith('.tar'))
            self.assertEqual((directory / 'archive.sha256').read_text(), hashlib.sha256(archive.read_bytes()).hexdigest() + '  ' + archive.name + '\n')
        unknown = self.recovery / 'gitlab-exports/unknown'
        unknown.mkdir()
        partial = self.recovery / 'gitlab-exports/.other.partial'
        partial.mkdir()
        self.add_archive(self.timestamp + 1)
        self.assertEqual(self.run_export().returncode, 0)
        self.assertTrue(unknown.exists())
        self.assertTrue(partial.exists())

    def test_fail_closed_fixtures_preserve_previous(self):
        self.add_archive(self.timestamp - 1)
        self.assertEqual(self.run_export().returncode, 0)
        original = self.completed()
        for p in self.remote.iterdir():
            p.unlink()
        cases = ('missing', 'stale', 'partial', 'unreadable', 'skipped', 'missing_component', 'unsafe', 'malformed', 's3_failure')
        for case in cases:
            with self.subTest(case=case):
                for p in self.remote.iterdir():
                    p.unlink()
                self.env.pop('FIXTURE_S3_FAILURE', None)
                if case == 'stale':
                    self.add_archive(int(time.time()) - 26 * 3600 - 1)
                elif case == 'partial':
                    (self.remote / 'backup.tar.partial').write_bytes(b'partial')
                elif case == 'unreadable':
                    name = self.add_archive()
                    (self.remote / name).write_bytes(b'not a tar')
                elif case == 'skipped':
                    self.add_archive(skipped='builds,uploads')
                elif case == 'missing_component':
                    self.add_archive(missing='uploads')
                elif case == 'unsafe':
                    self.add_archive(unsafe=True)
                elif case == 'malformed':
                    self.add_archive(metadata=':skipped: []\n')
                elif case == 's3_failure':
                    self.env['FIXTURE_S3_FAILURE'] = '1'
                result = self.run_export()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.completed(), original)

    def test_db_retention_only_after_qualified_export(self):
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
        self.assertNotEqual(self.run_export().returncode, 0)
        self.assertEqual(len(list(archives.glob('admission.*'))), 16)
        self.add_archive()
        result = self.run_export()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(list(archives.glob('admission.*'))), 14)
        self.assertTrue(unknown.exists())
        self.assertTrue(partial.exists())
        self.assertFalse((archives / 'admission.000000000000').exists())
        self.assertTrue((archives / 'admission.000000000015').exists())

    def test_nas_fixtures(self):
        self.add_archive()
        self.recovery.rmdir()
        self.assertNotEqual(self.run_export().returncode, 0)
        self.recovery.mkdir()
        dest = self.recovery / 'gitlab-exports'
        dest.symlink_to(self.remote, target_is_directory=True)
        self.assertNotEqual(self.run_export().returncode, 0)
        dest.unlink()
        dest.mkdir(mode=0o755)
        self.assertNotEqual(self.run_export().returncode, 0)
        self.assertEqual(dest.stat().st_mode & 0o777, 0o755)
        dest.rmdir()
        self.recovery.chmod(0o500)
        self.assertNotEqual(self.run_export().returncode, 0)
        self.recovery.chmod(0o700)


if __name__ == '__main__':
    unittest.main()
