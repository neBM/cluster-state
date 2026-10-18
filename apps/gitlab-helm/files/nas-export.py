#!/usr/bin/env python3
"""Run native CNG backup, then publish that invocation's archive off-backend.

Depends on backup-utility/object_storage_backup.rb v19.5 producer output, NOT
remote metadata completeness. Requalify that output contract on native updates.
Native metadata stays opaque, including legitimate duplicate skipped entries.
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
DISABLED = 'external_diffs,terraform_state,pages,ci_secure_files,agent_plan_content,ci_catalog_bundles'
ANSI = re.compile(r'\x1b\[[0-9;]*m')
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


def native(args, log):
    # Private complete diagnostics, never forwarded to Job logs (may hold secrets).
    result = subprocess.run(['backup-utility', *args], stdout=log,
                            stderr=subprocess.STDOUT, timeout=9000, check=False)
    log.write(f'\nProducer exit status: {result.returncode}\n'.encode())
    log.flush()
    os.fsync(log.fileno())
    require(result.returncode == 0, 'native backup/cleanup failed')


def produce(work, version, log):
    started = time.time_ns()
    native(['--skip', DISABLED, '--skip-cleanup'], log)
    log.seek(0)
    output = ANSI.sub('', log.read().decode('utf-8'))
    require('Unable to check existence of bucket ' not in output,
            'native silent bucket-check failure')
    # The native helper prints these adjacent lines only after a successful sync.
    # Empty enabled buckets are supported without consulting mutable remote state.
    outcomes = re.findall(r'^Dumping (\w+) \.\.\.\n(empty|done)$', output, re.M)
    require(len(outcomes) == len(BLOBS) and {n for n, _ in outcomes} == BLOBS,
            'native enabled component output changed/incomplete')
    empty = {name for name, result in outcomes if result == 'empty'}
    published = re.findall(r'^\[DONE\] Backup can be found at s3://gitlab-backups/(\S+)$', output, re.M)
    require(len(published) == 1, 'native publication output changed/incomplete')
    name = published[0]
    match = NAME.fullmatch(name)
    require(match is not None and match[2] == version
            and started // 10**9 <= int(match[1]) <= time.time_ns() // 10**9,
            'archive does not belong to this native invocation')
    path = work / 'backup_tars' / name
    require(path.is_file() and not path.is_symlink() and path.stat().st_mtime_ns >= started,
            'missing/fresh native local archive required')
    return path, empty


def consume(stream):
    size = 0
    while data := stream.read(BLOCK):
        size += len(data)
    return size


def safe_member(member):
    name = member.name
    require(not name.startswith('/') and '..' not in PurePosixPath(name).parts
            and '\\' not in name and not any(ord(c) < 32 for c in name)
            and (member.isfile() or member.isdir()), 'unsafe tar member')
    return name.removeprefix('./').rstrip('/')


def inspect_archive(path, empty):
    # Read only, never extract. Native metadata is preserved, not reinterpreted.
    require(path.stat().st_size >= 1024 and path.stat().st_size % 512 == 0, 'truncated tar')
    with path.open('rb') as stream:
        stream.seek(-1024, os.SEEK_END)
        require(stream.read() == b'\0' * 1024, 'missing native tar end blocks')
    seen, files = set(), set()
    metadata = None

    with tarfile.open(path, 'r:') as archive:
        for member in archive:
            key = safe_member(member)
            require(key not in seen, 'duplicate tar member')
            seen.add(key)
            component = '/' not in key and key.endswith('.tar.gz')
            payload = component or key == 'db/database.sql.gz'
            if payload or key == 'backup_information.yml':
                require(member.isfile() and member.size > 0, 'native payload must be a nonempty regular file')
            if not member.isfile():
                continue
            files.add(key)
            stream = archive.extractfile(member)
            if stream is None:
                raise ValueError('unreadable regular member')
            if key == 'backup_information.yml':
                require(member.size <= 16384, 'oversized metadata')
                metadata = stream.read()
            elif component:
                with gzip.GzipFile(fileobj=stream) as compressed:
                    with tarfile.open(fileobj=compressed, mode='r|') as inner:
                        for item in inner:
                            safe_member(item)
                            if item.isfile():
                                consume(inner.extractfile(item))
                    consume(compressed)  # Includes gzip trailer/CRC, even beyond tar EOF.
            elif key.startswith('db/') and key.endswith('.sql.gz'):
                with gzip.GzipFile(fileobj=stream) as compressed:
                    require(consume(compressed) > 0, 'empty database payload')
            else:
                consume(stream)
    if metadata is None or 'db/database.sql.gz' not in files:
        raise ValueError('missing native metadata/main DB')
    require({x + '.tar.gz' for x in BLOBS - empty} <= files, 'missing enabled nonempty component')
    # Native DB/repositories are unskipped by our fixed invocation. No invented
    # repository bundle counts; an empty installation may contain no bundles.
    return metadata


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
        work = Path(os.environ.get('BACKUP_WORK_DIR', '/srv/gitlab/tmp'))
        version = Path(os.environ.get('VERSION_FILE', '/srv/gitlab/VERSION')).read_text().strip()
        require(re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version)
                is not None, 'native image requires a stable numeric version')
        # Local diagnostics survive failure/native cleanup; private, never a remote receipt.
        log = cleanup.enter_context(tempfile.NamedTemporaryFile(
            prefix='.native-backup.', suffix='.log', dir=work, delete=False))
        source, empty = produce(work, version, log)
        name = source.name
        match = NAME.fullmatch(name)
        assert match is not None  # Our produce() already admitted this value.
        timestamp = int(match[1])
        metadata = inspect_archive(source, empty)
        checksum = digest(source)
        target = exports / name.removesuffix('_gitlab_backup.tar')
        require(not target.exists() and not target.is_symlink(), 'publication collision')
        # Inspect all retained owned completions before mutation; never prune unknown/partial paths.
        retained = completed(exports)
        db_retained = completed_db_archives(recovery)
        stage = Path(tempfile.mkdtemp(prefix='.' + target.name + '.', suffix='.partial', dir=exports))
        try:
            archive = stage / name
            shutil.copyfile(source, archive)
            private(archive)
            require(digest(archive) == checksum, 'local/NAS archive mismatch')
            (stage / 'backup_information.yml').write_bytes(metadata)
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
            native(['--cleanup', '--maximum-backups', '7'], log)
        finally:
            if stage.exists():
                shutil.rmtree(stage)  # ONLY this invocation's private unpublished stage.
    print('Native backup and NAS publication/readback completed; retention applied.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, EOFError, tarfile.TarError, subprocess.SubprocessError):
        # Deliberately do not dump native client output or private archive/metadata.
        print('Native backup/NAS publication failed; inspect private local producer diagnostics.', file=__import__('sys').stderr)
        raise SystemExit(1)
