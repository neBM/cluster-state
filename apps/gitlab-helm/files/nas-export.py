#!/usr/bin/env python3
"""Transfer-only CNG19.5 native backup admission. No restore, API or DB access.

CNG v19.5.0 scripts/bin/backup-utility write_backup_info/get_skipped and
scripts/lib/object_storage_backup.rb are the metadata authority. Empty and
inaccessible buckets BOTH become skipped: fail closed on that ambiguity.
"""
import contextlib
import datetime as dt
import fcntl
import gzip
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import time

NAME = re.compile(r'(\d{10})_\d{4}_\d{2}_\d{2}_(\d+\.\d+\.\d+)_gitlab_backup\.tar')
BLOBS = {'registry', 'uploads', 'artifacts', 'lfs', 'packages'}
REQUIRED = BLOBS | {'db', 'repositories'}
KNOWN = REQUIRED | {'builds', 'pages', 'external_diffs', 'terraform_state',
                    'ci_secure_files', 'agent_plan_content', 'ci_catalog_bundles'}
BLOCK = 1024 * 1024


def require(ok, reason):
    if not ok:
        raise ValueError(reason)


def private(path, directory=False):
    st = path.lstat()
    require((stat.S_ISDIR(st.st_mode) if directory else stat.S_ISREG(st.st_mode))
            and st.st_uid == 1000 and st.st_gid == 1000
            and stat.S_IMODE(st.st_mode) == (0o700 if directory else 0o600),
            'unsafe owned namespace permissions/type')


def namespace(path):
    if not path.exists() and not path.is_symlink():
        path.mkdir(mode=0o700)
    private(path, directory=True)
    return path


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def sync(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def command(config, *args):
    # Never echo client diagnostics/config (may contain credentials or private keys).
    result = subprocess.run(['s3cmd', '--config', str(config), *args],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            timeout=1800, check=False)
    require(result.returncode == 0, 'native s3cmd transfer/list failed')
    return result.stdout.decode('utf-8')


def consume(stream):
    while stream.read(BLOCK):
        pass


def safe_member(member):
    name = member.name
    require(not name.startswith('/') and '..' not in PurePosixPath(name).parts
            and '\\' not in name and not any(ord(c) < 32 for c in name)
            and (member.isfile() or member.isdir()), 'unsafe tar member')
    return name.removeprefix('./').rstrip('/')


def inspect_archive(path, name, version):
    # GNU tar header checks + complete payload reads; gzip CRCs for enabled blobs/DB.
    require(path.stat().st_size >= 1024 and path.stat().st_size % 512 == 0, 'truncated tar')
    with path.open('rb') as stream:
        stream.seek(-1024, os.SEEK_END)
        require(stream.read() == b'\0' * 1024, 'missing native tar end blocks')
    seen = set()
    metadata = None
    text = ''
    with tarfile.open(path, 'r:') as archive:
        for member in archive:
            key = safe_member(member)
            require(key not in seen, 'duplicate tar member')
            seen.add(key)
            if not member.isfile():
                continue
            stream = archive.extractfile(member)  # Read only; NEVER extract to disk.
            if stream is None:
                raise ValueError('unreadable regular member')
            if key == 'backup_information.yml':
                require(member.size <= 16384, 'oversized metadata')
                text = stream.read().decode('utf-8')
                metadata = {}
                for line in text.splitlines():
                    match = re.fullmatch(r':([a-z_]+): ?([^\r\n]*)', line)
                    if match is None or match[1] in metadata:
                        raise ValueError('malformed metadata')
                    metadata[match[1]] = match[2]
            elif key in {x + '.tar.gz' for x in BLOBS} or key.startswith('db/') and key.endswith('.sql.gz'):
                with gzip.GzipFile(fileobj=stream) as compressed:
                    consume(compressed)
            else:
                consume(stream)
    if metadata is None:
        raise ValueError('missing native metadata')
    require(set(metadata) == {'backup_id', 'db_version', 'backup_created_at', 'gitlab_version',
                             'tar_version', 'installation_type', 'skipped', 'repositories_server_side'},
            'unknown native metadata contract')
    backup_id = name.removesuffix('_gitlab_backup.tar')
    require(metadata['backup_id'] == backup_id and metadata['gitlab_version'] == version
            and metadata['installation_type'] == 'gitlab-helm-chart'
            and metadata['repositories_server_side'] == 'false'
            and re.fullmatch(r'\d{14}', metadata['db_version'])
            and metadata['tar_version'].startswith('tar (GNU tar) '), 'native version/component contract mismatch')
    created = dt.datetime.strptime(metadata['backup_created_at'], '%Y-%m-%d %H:%M:%S %z').timestamp()
    require(created == int(NAME.fullmatch(name)[1]) and -300 <= time.time() - created <= 26 * 3600,
            'stale/future or inconsistent native backup time')
    skipped = metadata['skipped'].split(',') if metadata['skipped'] else []
    require(len(skipped) == len(set(skipped)) and set(skipped) <= KNOWN, 'malformed skipped contract')
    require(not set(skipped) & REQUIRED,
            'required component skipped (native empty/inaccessible ambiguity; publication denied)')
    require({x + '.tar.gz' for x in BLOBS} <= seen, 'missing enabled blob archive')
    require('db/database.sql.gz' in seen, 'missing native main DB archive')
    # No invented repository bundle count: an empty installation may have none.
    return text


def completed(directory):
    """Recognize only this exporter's exact completed namespace. Unknown paths stay put."""
    found = []
    for path in directory.iterdir():
        name = path.name + '_gitlab_backup.tar'
        match = NAME.fullmatch(name)
        if not match or not path.is_dir() or path.is_symlink():
            continue
        private(path, directory=True)
        expected = {name, 'archive.sha256', 'backup_information.yml'}
        require({p.name for p in path.iterdir()} == expected, 'unexpected completed export contents')
        for file in path.iterdir():
            private(file)
        require((path / 'archive.sha256').read_text() == digest(path / name) + '  ' + name + '\n',
                'retained export readback failed')
        found.append((int(match[1]), path))
    return sorted(found)


def completed_db_archives(recovery):
    """Task2a's immutable completed four-file contract; no change to admission inputs."""
    directory = recovery / 'db-archives'
    if not directory.exists() and not directory.is_symlink():
        return []
    private(directory, directory=True)
    found = []
    for path in directory.iterdir():
        if not re.fullmatch(r'admission\.[a-zA-Z0-9]{12}', path.name):
            continue  # Unknown names and ALL .partial/.admission staging are untouched.
        private(path, directory=True)
        require({p.name for p in path.iterdir()} == {'database.dump', 'database.sha256', 'archive.list', 'admission.txt'},
                'unknown completed admission contents')
        for file in path.iterdir():
            private(file)
        require((path / 'database.sha256').read_text() == digest(path / 'database.dump') + '  database.dump\n'
                and (path / 'database.dump').stat().st_size > 0
                and (path / 'archive.list').stat().st_size > 0, 'retained admission readback failed')
        fields = (path / 'admission.txt').read_text().splitlines()
        require(len(fields) == 6 and fields[4].startswith('observed_at='), 'unknown admission metadata')
        observed = dt.datetime.strptime(fields[4], 'observed_at=%Y-%m-%dT%H:%M:%SZ')
        found.append((observed, path))
    return sorted(found)


def prune_owned(completions, keep):
    for _, old in completions[:-keep]:
        for path in old.iterdir():
            path.unlink()
        old.rmdir()


def main():
    os.umask(0o077)
    require((os.getuid(), os.getgid()) == (1000, 1000), 'requires UID/GID1000')
    recovery = Path(os.environ.get('RECOVERY_DIR', '/recovery'))
    require(recovery.is_dir() and not recovery.is_symlink(), 'recovery mount missing/unsafe')
    exports = namespace(recovery / 'gitlab-exports')
    # Directory flock also fences independently/manual-created Jobs on this claim.
    with contextlib.ExitStack() as cleanup:
        lock = os.open(exports, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        cleanup.callback(os.close, lock)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        config = Path(os.environ.get('S3_CONFIG', '/backup-config/config'))
        version = Path(os.environ.get('VERSION_FILE', '/srv/gitlab/VERSION')).read_text().strip()
        require(re.fullmatch(r'19\.5\.\d+', version), 'unsupported transfer metadata model')
        candidates = []
        for line in command(config, 'ls', 's3://gitlab-backups/').splitlines():
            fields = line.split()
            require(len(fields) == 4 and fields[2].isdigit() and fields[3].startswith('s3://gitlab-backups/'),
                    'malformed backup object listing')
            name = fields[3].removeprefix('s3://gitlab-backups/')
            match = NAME.fullmatch(name)
            if not match:
                require(not name.endswith('_gitlab_backup.tar'), 'unsafe/malformed native backup filename')
                continue  # Includes incomplete multipart/.partial and unrelated objects.
            candidates.append((int(match[1]), name, int(fields[2])))
        require(candidates, 'no completed native backup object')
        timestamp, name, size = max(candidates)
        require(-300 <= time.time() - timestamp <= 26 * 3600, 'latest backup is stale/future')
        selected = NAME.fullmatch(name)
        assert selected is not None  # Admitted above, not an external input assertion.
        require(selected[2] == version, 'backup/transfer utility version mismatch')
        target = exports / name.removesuffix('_gitlab_backup.tar')
        require(not target.exists() and not target.is_symlink(), 'publication collision')
        # Inspect all retained owned completions before mutation; never prune unknown/partial paths.
        retained = completed(exports)
        db_retained = completed_db_archives(recovery)
        stage = Path(tempfile.mkdtemp(prefix='.' + target.name + '.', suffix='.partial', dir=exports))
        try:
            archive = stage / name
            command(config, 'get', 's3://gitlab-backups/' + name, str(archive))
            private(archive)
            require(archive.stat().st_size == size and size > 0, 'download size/readback mismatch')
            metadata = inspect_archive(archive, name, version)
            checksum = digest(archive)
            (stage / 'backup_information.yml').write_text(metadata)
            (stage / 'archive.sha256').write_text(checksum + '  ' + name + '\n')
            for path in stage.iterdir():
                private(path)
                sync(path)
            require(digest(archive) == checksum, 'private archive readback failed')
            sync(stage)
            os.rename(stage, target)
            sync(exports)
            require(digest(target / name) == checksum, 'published archive readback failed')
            # New good point exists BEFORE any retention removal; retain seven total.
            prune_owned(sorted(retained + [(timestamp, target)]), 7)
            prune_owned(db_retained, 14)
            if db_retained:
                sync(recovery / 'db-archives')
            sync(exports)
        finally:
            if stage.exists():
                shutil.rmtree(stage)  # ONLY this invocation's private unpublished stage.
    print('NAS export published and read back; native restore and empty-bucket qualification remain required.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, EOFError, tarfile.TarError, subprocess.SubprocessError):
        # Deliberately do not dump native client output or private archive/metadata.
        print('NAS export denied: transfer, native contract, freshness, permissions or readback failed.', file=__import__('sys').stderr)
        raise SystemExit(1)
