#!/usr/bin/env python3
"""Bounded CI retention. No path overrides: fixtures inject paths into retain()."""
import hashlib
import json
import os
from pathlib import Path
import re
import ssl
import stat
import signal
import subprocess
import threading
import sys
import time
import urllib.request

# Only this fixed root admits nested unlink-only links; never infer from age/order.
WORKSPACE_ROOT = Path('/var/lib/ci-builds-nocow')
ROOTS = ((WORKSPACE_ROOT, 7),
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
    uids = set()
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
        if not uid or not name or uid in uids:
            raise Refuse('empty or duplicate Pod identity')
        uids.add(uid)
        if uid == self_uid:
            if (seen or labels.get('ci.brmartin.co.uk/maintenance') != 'true'
                    or labels.get('ci.brmartin.co.uk/job') != 'true'
                    or node != 'hestia' or phase not in {'Running', 'Pending'}
                    or meta.get('deletionTimestamp')):
                raise Refuse('inconsistent maintenance Pod identity')
            seen, pending = True, phase == 'Pending'
        elif labels.get('ci.brmartin.co.uk/job') == 'true':
            if meta.get('deletionTimestamp') or phase not in {'Running', 'Pending', 'Failed', 'Succeeded'}:
                raise Refuse(f'terminating or unknown-phase CI Pod: {name}')
            # Current CI hostPaths are node-local; Kubedock copies do not share them.
            # Only positively assigned, known remote nodes qualify for exemption.
            if phase in {'Running', 'Pending'} and node not in {'heracles', 'nyx'}:
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


def combined_pods(fetch):
    items = []
    for namespace in ('ci', 'ci-maintenance-worker'):
        payload = fetch(namespace)
        if (type(payload) is not dict or type(payload.get('items')) is not list
                or type(payload.get('metadata')) is not dict
                or payload['metadata'].get('continue', '') != ''):
            raise Refuse('incomplete namespace Pod list')
        seen = set()
        for pod in payload['items']:
            if (type(pod) is not dict or type(pod.get('metadata')) is not dict
                    or pod['metadata'].get('namespace') != namespace
                    or any(type(pod.get(k)) is not dict for k in ('spec', 'status'))):
                raise Refuse('wrong namespace or malformed Pod')
            meta = pod['metadata']
            if (any(type(meta.get(k)) is not str or not meta[k] for k in ('uid', 'name'))
                    or meta['uid'] in seen or type(meta.get('labels')) is not dict
                    or type(pod['status'].get('phase')) is not str
                    or type(pod['spec'].get('nodeName', '')) is not str):
                raise Refuse('invalid namespace Pod identity')
            seen.add(meta['uid'])
        items.extend(payload['items'])
    # pod_gate rejects duplicate UIDs across either list before allowing cleanup.
    return {'metadata': {}, 'items': items}


def api_gate():
    if (os.environ.get('NODE_NAME') != 'hestia' or not os.environ.get('POD_UID')
            or os.environ.get('POD_NAMESPACE') != 'ci-maintenance-worker'):
        raise Refuse('missing/wrong downward API identity')
    sa = Path('/var/run/secrets/kubernetes.io/serviceaccount')
    context = ssl.create_default_context(cafile=str(sa / 'ca.crt'))
    url = ('https://' + os.environ['KUBERNETES_SERVICE_HOST'] + ':'
           + os.environ['KUBERNETES_SERVICE_PORT_HTTPS'])

    def fetch(namespace):
        request = urllib.request.Request(url + '/api/v1/namespaces/' + namespace + '/pods?limit=500', headers={
            'Authorization': 'Bearer ' + (sa / 'token').read_text().strip()})
        with urllib.request.urlopen(request, context=context, timeout=15) as response:
            return json.load(response)

    def snapshot():
        payload = combined_pods(fetch)
        matches = [p for p in payload['items'] if p['metadata'].get('uid') == os.environ['POD_UID']]
        if (len(matches) != 1 or matches[0]['metadata']['namespace'] != 'ci-maintenance-worker'
                or matches[0]['metadata'].get('name') != os.environ.get('POD_NAME')):
            raise Refuse('wrong worker Pod identity')
        return payload

    wait_for_gate(snapshot, os.environ['POD_UID'])


def identity(st):
    return st.st_dev, st.st_ino


def check_entry(st, device, busy, mounted, *, symlink_leaf=False):
    if identity(st) in busy or identity(st) in mounted:
        raise Refuse('open/mounted entry')
    if st.st_dev != device or not (stat.S_ISDIR(st.st_mode) or stat.S_ISREG(st.st_mode)
                                 or symlink_leaf and stat.S_ISLNK(st.st_mode)):
        raise Refuse('non-ordinary or cross-device entry')


def snapshot(path, device, mounted=frozenset(), busy=frozenset(), *, workspace=False, native_uv=False):
    """Stream ordered metadata; retain only directory names on the active DFS path."""
    if native_uv and path != UV_ROOT:
        raise Refuse('wrong UV proof root')
    digest = hashlib.sha256()
    latest_file, latest_directory = None, float('-inf')
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    parent = os.open(path.parent, flags)
    root_id = None

    def visit(parent, name, relative):
        nonlocal latest_file, latest_directory, root_id
        st = os.stat(name, dir_fd=parent, follow_symlinks=False)
        check_entry(st, device, busy, mounted, symlink_leaf=(workspace or native_uv) and relative != Path('.'))
        if relative == Path('.'):
            root_id = identity(st)
        # unlink() changes surviving hardlinks' ctime (even across candidates).
        # File identity/mode/size/mtime remain invariant; do not fingerprint ctime
        # or nlink for regular files, including the final surviving link.
        value = (identity(st), st.st_mode, st.st_uid, st.st_gid, st.st_size, st.st_mtime_ns,
                 st.st_ctime_ns if not stat.S_ISREG(st.st_mode) else None)
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
            # A link is an unlink-only leaf: inspect its own metadata, never its
            # target. Its ctime also prevents backdated/recreated links aging out.
            latest = max(st.st_mtime, st.st_ctime) if stat.S_ISLNK(st.st_mode) else st.st_mtime
            latest_file = latest if latest_file is None else max(latest_file, latest)
    try:
        visit(parent, path.name, Path('.'))
    finally:
        os.close(parent)
    # Empty trees still need a conservative age; populated trees use FILE age.
    return (digest.digest(), root_id), latest_directory if latest_file is None else latest_file


def mount_ids(device, proc=Path('/proc')):
    """Resolve only cleanup-filesystem mounts, across all visible namespaces."""
    result = set()
    seen = set()
    owners = [proc / 'self', *(p for p in proc.iterdir() if p.name.isdecimal())]
    for owner in owners:
        try:
            namespace = identity((owner / 'ns/mnt').stat())
            if namespace in seen:
                continue
            lines = (owner / 'mountinfo').read_text().splitlines()
            if not lines:
                raise Refuse('empty mountinfo')
            mount_numbers = set()
            for line in lines:
                fields = line.split()
                if (len(fields) < 10 or fields[-4] != '-' or '-' in fields[:-4]
                        or not re.fullmatch(r'[1-9][0-9]*', fields[0])
                        or not re.fullmatch(r'0|[1-9][0-9]*', fields[1])
                        or fields[0] in mount_numbers):
                    raise Refuse('malformed or ambiguous mountinfo record')
                mount_numbers.add(fields[0])
                if not re.fullmatch(r'(0|[1-9][0-9]*):(0|[1-9][0-9]*)', fields[2]):
                    raise Refuse('invalid mountinfo device')
                major, minor = map(int, fields[2].split(':'))
                try:
                    mount_device = os.makedev(major, minor)
                    if (os.major(mount_device), os.minor(mount_device)) != (major, minor):
                        raise ValueError('device does not round trip')
                except (ValueError, OverflowError) as error:
                    raise Refuse('invalid mountinfo device') from error
                # Mountpoints are paths, but unrelated roots may be opaque
                # kernel objects (e.g. nsfs). Require path roots only on target.
                for value in (fields[3:5] if mount_device == device else fields[4:5]):
                    if (not value.startswith('/') or '\x00' in value
                            or re.search(r'\\(?!040|011|012|134)', value)
                            or any(part in {'.', '..'} for part in value.split('/'))):
                        raise Refuse('invalid mountinfo path')
                # Only a validated kernel device identity can exclude a mount.
                # Cross-device tree entries are independently rejected by snapshot.
                if mount_device != device:
                    continue
                mountpoint = fields[4]
                for encoded, decoded in (('\\040', ' '), ('\\011', '\t'), ('\\012', '\n'), ('\\134', '\\')):
                    mountpoint = mountpoint.replace(encoded, decoded)
                st = (owner / 'root' / mountpoint.lstrip('/')).stat()
                if st.st_dev != device:
                    raise Refuse('relevant mount device changed')
                result.add(identity(st))
            seen.add(namespace)
        except (FileNotFoundError, ProcessLookupError):
            # A vanished process/namespace is a race, not negative mount evidence.
            # Missing metadata or relevant roots in a live namespace still refuse.
            if owner.name == 'self':
                raise
            try:
                (owner / 'ns/mnt').stat()
            except (FileNotFoundError, ProcessLookupError):
                continue
            raise
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


def remove_tree(path, device, busy, mounted, expected_root, *, workspace=False):
    """FD-relative, no-follow deletion, with only active ancestors retained."""
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    with_fd = os.open(path.parent, flags)

    def remove(parent, name, expected=None):
        st = os.stat(name, dir_fd=parent, follow_symlinks=False)
        check_entry(st, device, busy, mounted, symlink_leaf=workspace and expected is None)
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


UV_ROOT = Path('/var/lib/ci-cache-nocow/uv')
HOST_PROC = Path('/host/proc')
UV_BINARY = Path('/usr/local/bin/uv')
UV_SHA256 = '0c7b00d4f2c10d0bf66b26e4f432388d7782e1071d913f921eae0b8e35cb3c80'
UV_ENV = {'PATH': '/usr/local/bin:/usr/bin:/bin', 'HOME': '/', 'LANG': 'C.UTF-8'}
COLD_RESERVE = 38_857_516_474
CACHE_TAG = b'Signature: 8a477f597d28d172789f06886806bc55'


def free_bytes(root):
    fs = os.statvfs(root)
    return fs.f_bavail * fs.f_frsize


def owned_uv(argv, *, timeout=330, version=False):
    """Own one direct child; no raw PID/PGID authority after Popen reaps it.

    Production admits only private-namespace PID1. Kernel namespace teardown is
    the ultimate containment if bounded kill/reap cannot retire a stuck child.
    The immutable UV clean does not launch helpers. Never infer retirement from
    a Job deadline or an init-only exit in a host PID namespace.
    """
    if (os.getpid() != 1 or threading.current_thread() is not threading.main_thread()
            or signal.getsignal(signal.SIGCHLD) != signal.SIG_DFL):
        raise Refuse('native UV requires direct Python private PID namespace init')
    child = None
    try:
        child = subprocess.Popen(argv, env=UV_ENV.copy(), cwd='/',
                                 stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE if version else None)
        rc = child.wait(timeout=timeout)
        if version:
            assert child.stdout is not None
        output = child.stdout.read(257) if child.stdout is not None else b''
        if len(output) > 256:
            raise Refuse('unsupported UV version output')
        return rc, output
    except BaseException as primary:
        if child is not None:
            # Popen pins its unreaped direct child and internally checks returncode;
            # do not use os.kill()/killpg() after poll()/wait(). Sole reaper is PID1.
            try:
                child.kill()
            except BaseException as error:
                primary.add_note('UV child kill failed: ' + type(error).__name__)
            try:
                child.wait(timeout=5)
            except BaseException as error:
                primary.add_note('UV child retirement UNPROVED: ' + type(error).__name__)
        raise
    finally:
        if child is not None and child.stdout is not None:
            child.stdout.close()


def qualify_uv():
    digest = hashlib.sha256()
    with UV_BINARY.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    if digest.hexdigest() != UV_SHA256:
        raise Refuse('unsupported UV binary')
    rc, output = owned_uv([str(UV_BINARY), '--version'], timeout=10, version=True)
    if rc != 0 or not re.fullmatch(rb'uv 0\.11\.26(?: \([^\r\n]*\))?\n', output):
        raise Refuse('unsupported UV version')


def uv_proof(root, device, mounted, busy):
    """Fixed cache-only role, no-follow ancestors and streamed link-leaf proof.

    Link permission is proof-only here; generic remove_tree remains default deny.
    Native UV is path based: maintained scheduler/claimed-pause writer exclusion,
    not descriptor-relative deletion or malicious-host-root race resistance.
    """
    if root != UV_ROOT or root.parent != ROOTS[1][0]:
        raise Refuse('wrong UV cache role')
    ancestors = []
    for path in reversed((root.parent, *root.parent.parents)):
        st = path.lstat()
        if not stat.S_ISDIR(st.st_mode):
            raise Refuse('UV ancestor is not an ordinary directory')
        ancestors.append((str(path), identity(st), st.st_mode, st.st_uid, st.st_gid))
    parent = root.parent.lstat()
    if parent.st_dev != device:
        raise Refuse('UV parent filesystem changed')
    if os.statvfs(root.parent).f_flag & os.ST_RDONLY:
        raise Refuse('UV filesystem is read-only')
    st = root.lstat()
    check_entry(st, device, busy, mounted)
    if not stat.S_ISDIR(st.st_mode):
        raise Refuse('UV root is not an ordinary directory')
    # Cache generations coexist normally; bucket numbers do not identify producers.
    for path in root.iterdir():
        mode = path.lstat().st_mode
        if stat.S_ISDIR(mode):
            if not re.fullmatch(r'(archive|builds|environments|interpreter|sdists|simple|wheels)-v[0-9]+', path.name):
                raise Refuse('UV cache-only role not established')
        elif path.name not in {'.gitignore', '.lock', 'CACHEDIR.TAG'} or not stat.S_ISREG(mode):
            raise Refuse('UV cache-only role not established')
    fd = os.open(root / 'CACHEDIR.TAG', os.O_RDONLY | os.O_NOFOLLOW)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode) or os.read(fd, len(CACHE_TAG)) != CACHE_TAG:
            raise Refuse('invalid UV cache marker')
    finally:
        os.close(fd)
    proof, _ = snapshot(root, device, mounted, busy, native_uv=True)
    return ancestors, proof


def clean_uv(root, device, mounted, busy, *, mounts, opened, gate):
    try:
        root.lstat()
    except FileNotFoundError:
        print('UV native outcome=absent', flush=True)
        return
    proof = uv_proof(root, device, mounted, busy)
    qualify_uv()
    gate()  # WorkerFence.check + complete API gate, after executable qualification.
    current = uv_proof(root, device, mounts(), opened())
    if current != proof:
        raise Refuse('UV root/fingerprint changed')
    gate()  # Long metadata scans cannot spend the admission lease unchecked.
    # No other writers can enter until the claimed worker's containers terminate.
    rc, _ = owned_uv([str(UV_BINARY), '--no-config', '--offline', '--no-python-downloads',
                      'cache', 'clean', '--cache-dir', str(root)])
    print(f'UV native outcome=completed exit={rc}', flush=True)
    if rc != 0:
        raise Refuse(f'UV native clean failed exit={rc}')
    # UV may remove its root: do not recreate internals or require the old inode.


def retain(roots, *, execute=False, now=None, used=usage, available=free_bytes,
           opened=open_ids, mounts=None, gate=lambda: None):
    now = time.time() if now is None else now
    candidates = []
    root_stats = [root.lstat() for root, _ in roots]
    for (root, _), st in zip(roots, root_stats):
        if not stat.S_ISDIR(st.st_mode):
            raise Refuse(f'root is not an ordinary directory: {root}')
    devices = {st.st_dev for st in root_stats}
    if len(devices) != 1:
        raise Refuse('retention roots must share the same filesystem')
    device = devices.pop()
    if mounts is None:
        mounts = lambda: mount_ids(device)
    mounted, busy = mounts(), opened()
    for (root, days), st in zip(roots, root_stats):
        for path in sorted(root.iterdir()):
            if path == UV_ROOT:
                continue  # UV owns this class, even without links; never Python age/capacity deletion.
            if root == UV_ROOT.parent and path.name in {'bun', 'cargo', 'tools', 'python', 'managed-python', 'uv-tools', 'uv-python'}:
                continue  # Retained tool/runtime namespaces are not newly reclaimable.
            try:
                if not stat.S_ISDIR(path.lstat().st_mode):
                    raise Refuse(f'candidate is not an ordinary directory: {path}')
                if path.name in {'storage', 'docker', 'containerd', 'containers', 'libpod'}:
                    raise Refuse(f'image/runtime store name: {path}')
                proof, latest = snapshot(path, st.st_dev, mounted, busy,
                                         workspace=root == WORKSPACE_ROOT)
            except Refuse as error:
                print(f'PROTECTED {error}', flush=True)
                continue
            candidates.append((root, days, path, proof, latest))
    safe = candidates
    # Workspaces first, oldest namespace first within each group.
    safe.sort(key=lambda c: (next(i for i, r in enumerate(roots) if r[0] == c[0]), c[4], str(c[2])))
    def delete(candidate, reason):
        root, days, path, proof, latest = candidate
        print(f'{"DELETE" if execute else "WOULD DELETE"} {path} reason={reason} latest_file_mtime={latest}', flush=True)
        if execute:
            gate()
            current_root = root.lstat()
            if not stat.S_ISDIR(current_root.st_mode) or current_root.st_dev != device:
                raise Refuse('retention root filesystem changed')
            mounted, busy = mounts(), opened()
            try:
                current, _ = snapshot(path, device, mounted, busy,
                                      workspace=root == WORKSPACE_ROOT)
            except Refuse as error:
                raise Refuse(f'candidate changed/open/mounted: {path}: {error}') from error
            if current != proof:
                raise Refuse(f'candidate changed/open/mounted: {path}')
            gate()  # Metadata scanning may take time: recheck admission at unlink boundary.
            remove_tree(path, device, busy, mounted, current[1],
                        workspace=root == WORKSPACE_ROOT)

    remaining = []
    for candidate in safe:
        if candidate[4] <= now - candidate[1] * DAY:
            delete(candidate, 'age')
        else:
            remaining.append(candidate)
    # Age expiry first; only a still-pressured filesystem needs the backstop.
    pressure = used(roots[0][0]) >= 67
    for candidate in remaining:
        if pressure and used(candidate[0]) > 65:
            delete(candidate, 'capacity')
    final = used(roots[0][0])
    if execute and pressure and final > 65:
        for (root, _), st in zip(roots, root_stats):
            if root == UV_ROOT.parent and identity(root.lstat()) != identity(st):
                raise Refuse('UV parent replaced')
        clean_uv(UV_ROOT, device, mounted, busy, mounts=mounts, opened=opened, gate=gate)
        final = used(roots[0][0])  # Actual filesystem use, not UV's hardlink-overcounted report.
    print(f'filesystem used={final:.2f}% pressure_triggered={pressure} execute={execute}', flush=True)
    if execute and pressure and final > 65:
        raise Refuse('cannot reach 65% within approved idle directories; no scope widening')
    if execute and pressure and available(roots[0][0]) < COLD_RESERVE:
        raise Refuse('cold reserve not reached; no scope widening')


def main():
    if sys.argv[1:] not in ([], ['--execute']):
        raise Refuse('usage: cache-retention.py [--execute] (default: dry run)')
    # Import the same immutable policy bundle as the separate controls. No GitLab
    # credential or GitLab client is constructed in this privileged Pod.
    import importlib.util
    spec = importlib.util.spec_from_file_location('maintenance', Path(__file__).with_name('maintenance-admission.py'))
    assert spec is not None and spec.loader is not None
    admission = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(admission)
    store = admission.kube_store()
    fence = admission.WorkerFence(store, admission.self_identity(store.api))
    fence.claim()  # CAS ownership before even scanning host roots.
    def gate():
        fence.check()
        api_gate()  # Preserve all previous complete Pod-list checks.
    gate()
    # Replace hostPID observation with the same host /proc mounted read-only.
    # Python stays private PID1 so all-container termination includes UV retirement.
    retain(ROOTS, execute=sys.argv[1:] == ['--execute'], gate=gate,
           opened=lambda: open_ids(HOST_PROC),
           mounts=lambda: mount_ids(ROOTS[0][0].lstat().st_dev, HOST_PROC))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'REFUSED: {error}', file=sys.stderr, flush=True)
        sys.exit(1)
