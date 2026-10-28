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


def fingerprint(entries):
    digest = hashlib.sha256()
    for path, value in entries.items():
        digest.update(repr((str(path), value)).encode())
    return digest.digest()


def snapshot(path, device, mounted=frozenset()):
    """Reject the whole candidate on symlinks, devices or cross-filesystem entries."""
    entries = {}
    files, directories = [], []

    def visit(item):
        st = item.lstat()
        if identity(st) in mounted:
            raise Refuse(f'mounted entry: {item}')
        if st.st_dev != device or not (stat.S_ISDIR(st.st_mode) or stat.S_ISREG(st.st_mode)):
            raise Refuse(f'non-ordinary or cross-device entry: {item}')
        entries[item.relative_to(path)] = (identity(st), st.st_mode, st.st_size, st.st_mtime_ns, st.st_ctime_ns)
        if stat.S_ISDIR(st.st_mode):
            directories.append(st.st_mtime)
            for child in sorted(item.iterdir()):
                visit(child)
        else:
            files.append(st.st_mtime)
    visit(path)
    # Empty trees still need a conservative age; populated trees use FILE age.
    return entries, max(files or directories)


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


def remove_tree(path, expected):
    """FD-relative, no-follow traversal; preserve every parent and its ownership."""
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    with_fd = os.open(path.parent, flags)

    def remove(parent, name, relative):
        st = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if (identity(st), st.st_mode, st.st_size, st.st_mtime_ns, st.st_ctime_ns) != expected[relative]:
            raise Refuse(f'candidate changed before deletion: {path / relative}')
        if stat.S_ISDIR(st.st_mode):
            fd = os.open(name, flags, dir_fd=parent)
            try:
                if identity(os.fstat(fd)) != identity(st):
                    raise Refuse('directory replaced during deletion')
                for child in os.listdir(fd):
                    remove(fd, child, relative / child)
            finally:
                os.close(fd)
            os.rmdir(name, dir_fd=parent)
        else:
            os.unlink(name, dir_fd=parent)
    try:
        remove(with_fd, path.name, Path('.'))
    finally:
        os.close(with_fd)


def retain(roots, *, execute=False, now=None, used=usage,
           opened=open_ids, mounts=mount_ids, gate=lambda: None):
    now = time.time() if now is None else now
    candidates = []
    devices = set()
    mounted = mounts()
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
                entries, latest = snapshot(path, st.st_dev, mounted)
            except Refuse as error:
                print(f'PROTECTED {error}', flush=True)
                continue
            # Retain only inode identities + digest across namespaces, not every stat.
            proof = (fingerprint(entries), {entry[0] for entry in entries.values()})
            candidates.append((root, days, path, proof, latest))
            del entries
    if len(devices) != 1:
        raise Refuse('retention roots must share the same filesystem')
    busy = opened()
    safe = []
    for candidate in candidates:
        root, days, path, proof, latest = candidate
        ids = proof[1]
        if ids & (busy | mounted):
            print(f'PROTECTED open/mounted: {path}', flush=True)
        else:
            safe.append(candidate)
    # Workspaces first, oldest namespace first within each group.
    safe.sort(key=lambda c: (next(i for i, r in enumerate(roots) if r[0] == c[0]), c[4], str(c[2])))
    def delete(candidate, reason):
        root, days, path, proof, latest = candidate
        print(f'{"DELETE" if execute else "WOULD DELETE"} {path} reason={reason} latest_file_mtime={latest}', flush=True)
        if execute:
            gate()
            current, _ = snapshot(path, root.stat().st_dev, mounts())
            ids = {entry[0] for entry in current.values()}
            if fingerprint(current) != proof[0] or ids & (opened() | mounts()):
                raise Refuse(f'candidate changed/open/mounted: {path}')
            remove_tree(path, current)

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
