#!/usr/bin/env python3
"""Bounded CI retention. No path overrides: fixtures inject paths into retain()."""
import hashlib
import json
import os
from pathlib import Path
import ssl
import stat
import sys
import time
import urllib.request

ROOTS = ((Path('/var/lib/ci-builds-nocow'), 7),
         (Path('/var/lib/ci-cache-nocow'), 30))
DAY = 86400


class Refuse(RuntimeError):
    pass


def pod_gate(payload, self_uid):
    # Same identity/completeness fence as hestia-ci-store-gc; only Pending retries.
    if type(payload) is not dict or type(payload.get('items')) is not list:
        raise Refuse('invalid Pod list')
    metadata = payload.get('metadata')
    if type(metadata) is not dict or metadata.get('continue', '') != '':
        raise Refuse('incomplete Pod list')
    seen = False
    pending = False
    for pod in payload['items']:
        if type(pod) is not dict:
            raise Refuse('invalid Pod item')
        meta, spec, status = (pod.get(k) for k in ('metadata', 'spec', 'status'))
        if type(meta) is not dict or type(spec) is not dict or type(status) is not dict:
            raise Refuse('incomplete Pod identity')
        uid, name, labels = (meta.get(k) for k in ('uid', 'name', 'labels'))
        phase, node = status.get('phase'), spec.get('nodeName', '')
        if any(type(v) is not str for v in (uid, name, phase, node)) or type(labels) is not dict:
            raise Refuse('invalid Pod identity types')
        if uid == self_uid:
            if (seen or labels.get('ci.brmartin.co.uk/maintenance') != 'true'
                    or labels.get('ci.brmartin.co.uk/job') != 'true'
                    or node != 'hestia' or phase not in {'Running', 'Pending'}
                    or meta.get('deletionTimestamp')):
                raise Refuse('inconsistent maintenance Pod identity')
            seen, pending = True, phase == 'Pending'
        elif labels.get('ci.brmartin.co.uk/job') == 'true' and phase in {'Running', 'Pending'}:
            raise Refuse(f'active CI Pod: {name} ({phase})')
    if not seen:
        raise Refuse('maintenance Pod absent')
    return not pending


def wait_for_gate(fetch, uid, sleep=time.sleep):
    for attempt in range(15):
        if pod_gate(fetch(), uid):
            return
        if attempt != 14:
            print('maintenance Pod still Pending; waiting for Running', flush=True)
            sleep(2)
    raise Refuse('maintenance Pod did not become Running')


def api_gate():
    if os.environ.get('NODE_NAME') != 'hestia' or not os.environ.get('POD_UID'):
        raise Refuse('missing/wrong downward API identity')
    sa = Path('/var/run/secrets/kubernetes.io/serviceaccount')
    context = ssl.create_default_context(cafile=str(sa / 'ca.crt'))
    url = ('https://' + os.environ['KUBERNETES_SERVICE_HOST'] + ':'
           + os.environ['KUBERNETES_SERVICE_PORT_HTTPS'] + '/api/v1/namespaces/ci/pods?limit=500')

    def fetch():
        request = urllib.request.Request(url, headers={
            'Authorization': 'Bearer ' + (sa / 'token').read_text().strip()})
        with urllib.request.urlopen(request, context=context, timeout=15) as response:
            return json.load(response)

    wait_for_gate(fetch, os.environ['POD_UID'])


def identity(st):
    return st.st_dev, st.st_ino


def check_entry(st, device, busy, mounted):
    if identity(st) in busy or identity(st) in mounted:
        raise Refuse('open/mounted entry')
    if st.st_dev != device or not (stat.S_ISDIR(st.st_mode) or stat.S_ISREG(st.st_mode)):
        raise Refuse('non-ordinary or cross-device entry')


def snapshot(path, device, mounted=frozenset(), busy=frozenset()):
    """Stream ordered metadata; retain only directory names on the active DFS path."""
    digest = hashlib.sha256()
    latest_file, latest_directory = None, float('-inf')
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    parent = os.open(path.parent, flags)
    root_id = None

    def visit(parent, name, relative):
        nonlocal latest_file, latest_directory, root_id
        st = os.stat(name, dir_fd=parent, follow_symlinks=False)
        check_entry(st, device, busy, mounted)
        if relative == Path('.'):
            root_id = identity(st)
        # unlink() changes surviving hardlinks' ctime (even across candidates).
        # File identity/mode/size/mtime remain invariant; do not fingerprint ctime
        # or nlink for regular files, including the final surviving link.
        value = (identity(st), st.st_mode, st.st_uid, st.st_gid, st.st_size, st.st_mtime_ns,
                 st.st_ctime_ns if stat.S_ISDIR(st.st_mode) else None)
        digest.update(repr((str(relative), value)).encode())
        if stat.S_ISDIR(st.st_mode):
            latest_directory = max(latest_directory, st.st_mtime)
            fd = os.open(name, flags, dir_fd=parent)
            try:
                if identity(os.fstat(fd)) != identity(st):
                    raise Refuse('directory replaced during snapshot')
                for child in sorted(os.listdir(fd)):
                    visit(fd, child, relative / child)
            finally:
                os.close(fd)
        else:
            latest_file = st.st_mtime if latest_file is None else max(latest_file, st.st_mtime)
    try:
        visit(parent, path.name, Path('.'))
    finally:
        os.close(parent)
    # Empty trees still need a conservative age; populated trees use FILE age.
    return (digest.digest(), root_id), latest_directory if latest_file is None else latest_file


def mount_ids(proc=Path('/proc')):
    """Inspect all visible mount namespaces, including same-device bind aliases."""
    result = set()
    seen = set()
    owners = [proc / 'self', *(p for p in proc.iterdir() if p.name.isdecimal())]
    for owner in owners:
        try:
            namespace = identity((owner / 'ns/mnt').stat())
            if namespace in seen:
                continue
            for line in (owner / 'mountinfo').read_text().splitlines():
                mountpoint = line.split()[4]
                for encoded, decoded in (('\\040', ' '), ('\\011', '\t'), ('\\012', '\n'), ('\\134', '\\')):
                    mountpoint = mountpoint.replace(encoded, decoded)
                try:
                    result.add(identity((owner / 'root' / mountpoint.lstrip('/')).stat()))
                except (FileNotFoundError, ProcessLookupError):
                    pass
            seen.add(namespace)
        except (FileNotFoundError, ProcessLookupError):
            pass  # Exited process; permission/parse failures still fail closed.
    return result


def open_ids(proc=Path('/proc')):
    """stat() resolves bind/path aliases to device+inode, not pathname strings."""
    result = set()
    for process in proc.iterdir():
        if not process.name.isdecimal():
            continue
        try:
            references = [process / 'cwd', *list((process / 'fd').iterdir())]
            for reference in references:
                try:
                    result.add(identity(reference.stat()))
                except (FileNotFoundError, ProcessLookupError):
                    pass
        except (FileNotFoundError, ProcessLookupError):
            pass
        # PermissionError deliberately propagates: an incomplete scan is unsafe.
    return result


def usage(root):
    fs = os.statvfs(root)
    return 100 * (fs.f_blocks - fs.f_bavail) / fs.f_blocks


def remove_tree(path, device, busy, mounted, expected_root):
    """FD-relative, no-follow deletion, with only active ancestors retained."""
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    with_fd = os.open(path.parent, flags)

    def remove(parent, name, expected=None):
        st = os.stat(name, dir_fd=parent, follow_symlinks=False)
        check_entry(st, device, busy, mounted)
        if expected is not None and identity(st) != expected:
            raise Refuse('candidate replaced before deletion')
        if stat.S_ISDIR(st.st_mode):
            fd = os.open(name, flags, dir_fd=parent)
            try:
                if identity(os.fstat(fd)) != identity(st):
                    raise Refuse('directory replaced during deletion')
                with os.scandir(fd) as children:
                    for child in children:
                        remove(fd, child.name)
            finally:
                os.close(fd)
            current = os.stat(name, dir_fd=parent, follow_symlinks=False)
            check_entry(current, device, busy, mounted)
            if identity(current) != identity(st) or current.st_mode != st.st_mode:
                raise Refuse('directory replaced during deletion')
            os.rmdir(name, dir_fd=parent)
        else:
            current = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if any(getattr(current, key) != getattr(st, key) for key in
                   ('st_dev', 'st_ino', 'st_mode', 'st_uid', 'st_gid', 'st_size',
                    'st_mtime_ns', 'st_ctime_ns')):
                raise Refuse('file changed during deletion')
            os.unlink(name, dir_fd=parent)
    try:
        remove(with_fd, path.name, expected_root)
    finally:
        os.close(with_fd)


def retain(roots, *, execute=False, now=None, used=usage,
           opened=open_ids, mounts=mount_ids, gate=lambda: None):
    now = time.time() if now is None else now
    candidates = []
    devices = set()
    mounted, busy = mounts(), opened()
    for root, days in roots:
        st = root.lstat()
        if not stat.S_ISDIR(st.st_mode):
            raise Refuse(f'root is not an ordinary directory: {root}')
        devices.add(st.st_dev)
        for path in sorted(root.iterdir()):
            try:
                if not stat.S_ISDIR(path.lstat().st_mode):
                    raise Refuse(f'candidate is not an ordinary directory: {path}')
                if path.name in {'storage', 'docker', 'containerd', 'containers', 'libpod'}:
                    raise Refuse(f'image/runtime store name: {path}')
                proof, latest = snapshot(path, st.st_dev, mounted, busy)
            except Refuse as error:
                print(f'PROTECTED {error}', flush=True)
                continue
            candidates.append((root, days, path, proof, latest))
    if len(devices) != 1:
        raise Refuse('retention roots must share the same filesystem')
    safe = candidates
    # Workspaces first, oldest namespace first within each group.
    safe.sort(key=lambda c: (next(i for i, r in enumerate(roots) if r[0] == c[0]), c[4], str(c[2])))
    def delete(candidate, reason):
        root, days, path, proof, latest = candidate
        print(f'{"DELETE" if execute else "WOULD DELETE"} {path} reason={reason} latest_file_mtime={latest}', flush=True)
        if execute:
            gate()
            mounted, busy = mounts(), opened()
            device = root.stat().st_dev
            try:
                current, _ = snapshot(path, device, mounted, busy)
            except Refuse as error:
                raise Refuse(f'candidate changed/open/mounted: {path}: {error}') from error
            if current != proof:
                raise Refuse(f'candidate changed/open/mounted: {path}')
            remove_tree(path, device, busy, mounted, current[1])

    remaining = []
    for candidate in safe:
        if candidate[4] <= now - candidate[1] * DAY:
            delete(candidate, 'age')
        else:
            remaining.append(candidate)
    # Age expiry first; only a still-pressured filesystem needs the backstop.
    pressure = used(roots[0][0]) >= 75
    for candidate in remaining:
        if pressure and used(candidate[0]) > 65:
            delete(candidate, 'capacity')
    final = used(roots[0][0])
    print(f'filesystem used={final:.2f}% pressure_triggered={pressure} execute={execute}', flush=True)
    if execute and pressure and final > 65:
        raise Refuse('cannot reach 65% within approved idle directories; no scope widening')


def main():
    if sys.argv[1:] not in ([], ['--execute']):
        raise Refuse('usage: cache-retention.py [--execute] (default: dry run)')
    api_gate()  # Required even for dry run; no force/bypass or path overrides.
    retain(ROOTS, execute=sys.argv[1:] == ['--execute'], gate=api_gate)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'REFUSED: {error}', file=sys.stderr, flush=True)
        sys.exit(1)
