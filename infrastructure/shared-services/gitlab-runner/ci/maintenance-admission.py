#!/usr/bin/env python3
"""Runner2-only admission and independent recovery; no filesystem authority.

State is explicitly bootstrapped by the operator, never inferred or recreated.
Ambiguous remote writes latch ALERT: a GET is not proof a late PUT cannot commit.
"""
import copy
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

STATE = '/api/v1/namespaces/ci-maintenance/configmaps/hestia-ci-maintenance-state'
PODS = '/api/v1/namespaces/ci/pods'
CONTROL_PODS = '/api/v1/namespaces/ci-maintenance/pods'
WORKER_NAMESPACE = 'ci-maintenance-worker'
WORKER_PODS = '/api/v1/namespaces/ci-maintenance-worker/pods'
GITLAB = 'https://git.brmartin.co.uk/api/v4'
TOKEN = Path('/credential/token')
TOKEN_EXPIRY = int(dt.datetime(2027, 11, 5, tzinfo=dt.timezone.utc).timestamp())
PHASES = {'IDLE', 'PAUSE_INTENT', 'DRAINING', 'ADMITTED', 'CLAIMED',
          'CLOSING', 'RESTORING', 'DONE', 'ALERT'}
# GitLab 19.5 HasStatus: all AVAILABLE_STATUSES except completed statuses.
# Observe pre-execution first, then running (including native prepare), then canceling.
ACTIVE = ('created', 'waiting_for_resource', 'preparing', 'waiting_for_callback',
          'pending', 'manual', 'scheduled', 'running', 'canceling')


class Refuse(RuntimeError):
    pass


class Conflict(Refuse):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise Refuse('redirect refused')


def require(condition, reason):
    if not condition:
        raise Refuse(reason)


def text(value):
    return type(value) is str and bool(value) and len(value) <= 256


def identity(value):
    require(type(value) is dict and set(value) == {'namespace', 'name', 'uid', 'job', 'job_uid'}
            and all(text(v) for v in value.values()), 'invalid owner identity')
    require(value['namespace'] in {WORKER_NAMESPACE, 'ci-maintenance'}, 'invalid owner namespace')
    return value


def policy_hash():
    directory = Path(__file__).resolve().parent
    return hashlib.sha256(b'runner2-admission-v1\0' +
                          (directory / 'maintenance-admission.py').read_bytes() +
                          (directory / 'cache-retention.py').read_bytes()).hexdigest()


def validate(state, uid, policy):
    require(type(state) is dict and set(state) == {
        'schema', 'uid', 'policy', 'runner', 'heartbeat', 'phase', 'operation'}, 'invalid state fields')
    require(type(state['schema']) is int and state['schema'] == 1
            and type(state['runner']) is int and state['runner'] == 2
            and state['uid'] == uid and text(uid) and state['policy'] == policy
            and type(state['heartbeat']) is int and state['heartbeat'] >= 0
            and state['phase'] in PHASES, 'invalid state identity or policy')
    op = state['operation']
    if op is None:
        require(state['phase'] == 'IDLE', 'missing operation')
        return state
    require(type(op) is dict and set(op) == {
        'id', 'slot', 'coordinator', 'worker', 'claimed', 'holder', 'baseline',
        'restore_required', 'write', 'drain_by', 'cleanup_by', 'recover_by',
        'outcome', 'restored'}, 'invalid operation fields')
    identity(op['coordinator'])
    for field in ('worker', 'holder'):
        if op[field] is not None:
            identity(op[field])
    require(op['coordinator']['namespace'] == 'ci-maintenance'
            and (op['worker'] is None or op['worker']['namespace'] == WORKER_NAMESPACE)
            and (op['holder'] is None or op['holder']['namespace'] == 'ci-maintenance'), 'wrong effect-owner namespace')
    require(all(type(op[k]) is bool for k in ('claimed', 'baseline', 'restore_required', 'restored'))
            and op['baseline'] is False and op['restore_required'] is True
            and all(type(op[k]) is int for k in ('slot', 'drain_by', 'cleanup_by', 'recover_by'))
            and op['slot'] % 3600 == 47 * 60
            and op['drain_by'] == op['slot'] + 1200
            and op['cleanup_by'] == op['slot'] + 1800
            and op['recover_by'] == op['slot'] + 2700
            and op['write'] in {'none', 'pause', 'restore', 'unknown'}
            and text(op['outcome']), 'invalid operation values')
    expected = hashlib.sha256(f"{op['slot']}:{op['coordinator']['uid']}:{policy}".encode()).hexdigest()
    require(op['id'] == expected, 'invalid operation generation')
    require(not op['claimed'] or op['worker'] is not None, 'missing claimant')
    require(state['phase'] not in {'ADMITTED', 'CLAIMED'} or
            op['worker'] is not None and op['write'] == 'none', 'invalid admission')
    require(state['phase'] != 'CLAIMED' or op['claimed'], 'missing claim latch')
    require(state['phase'] != 'DONE' or op['restored'] and op['write'] == 'none', 'invalid restoration')
    return state


class HTTP:
    def __init__(self, base, token, ca=None):
        self.base, self.token = base, token
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), NoRedirect(),
            urllib.request.HTTPSHandler(context=ssl.create_default_context(cafile=ca)))

    def request(self, method, path, body=None):
        require(path.startswith('/') and not path.startswith('//'), 'invalid API path')
        if self.base == GITLAB:
            require(method == 'GET' and (path == '/runners/2' or path.startswith('/runners/2/jobs?'))
                    or method == 'PUT' and path == '/runners/2'
                    and type(body) is dict and set(body) == {'paused'}
                    and type(body['paused']) is bool, 'GitLab authority refused')
        headers = {'Authorization': 'Bearer ' + self.token} if self.base != GITLAB else {'PRIVATE-TOKEN': self.token}
        headers['Content-Type'] = 'application/json'
        data = None if body is None else json.dumps(body).encode()
        try:
            with self.opener.open(urllib.request.Request(self.base + path, data=data,
                                                       headers=headers, method=method), timeout=5) as response:
                payload = response.read(2_000_001)
                require(len(payload) <= 2_000_000, 'oversize API response')
                return json.loads(payload), dict(response.headers.items())
        except urllib.error.HTTPError as error:
            if error.code == 409:
                raise Conflict('state conflict; reread required') from None
            raise Refuse('API HTTP failure') from None


class Store:
    def __init__(self, api, policy):
        self.api, self.policy, self.uid = api, policy, None

    def read(self):
        cm, _ = self.api.request('GET', STATE)
        require(type(cm) is dict and cm.get('kind') == 'ConfigMap', 'invalid state object')
        meta = cm.get('metadata', {})
        require(meta.get('name') == 'hestia-ci-maintenance-state' and meta.get('namespace') == 'ci-maintenance'
                and text(meta.get('uid')) and text(meta.get('resourceVersion'))
                and not meta.get('deletionTimestamp'), 'invalid state metadata')
        if self.uid is None:
            self.uid = meta['uid']
        require(self.uid == meta['uid'], 'state object replaced')
        state = json.loads(cm['data']['state.json'])
        validate(state, self.uid, self.policy)
        return cm, state

    def save(self, cm, state):
        validate(state, self.uid, self.policy)
        desired = copy.deepcopy(cm)
        desired['data'] = {'state.json': json.dumps(state, sort_keys=True, separators=(',', ':'))}
        # PUT retains the exact UID/resourceVersion; a 409 never retries an overwrite.
        self.api.request('PUT', STATE, desired)
        _, observed = self.read()
        require(observed == state, 'CAS readback not confirmed')
        return observed


def pods(api, namespace='ci'):
    require(namespace in {'ci', 'ci-maintenance', WORKER_NAMESPACE}, 'invalid observation namespace')
    value, _ = api.request('GET', '/api/v1/namespaces/' + namespace + '/pods?limit=500')
    require(type(value) is dict and type(value.get('items')) is list
            and type(value.get('metadata')) is dict and value['metadata'].get('continue', '') == '',
            'incomplete Pod snapshot')
    seen = set()
    for pod in value['items']:
        require(type(pod) is dict and all(type(pod.get(k)) is dict for k in ('metadata', 'spec', 'status')),
                'malformed Pod')
        meta = pod['metadata']
        require(meta.get('namespace') == namespace and text(meta.get('uid')) and text(meta.get('name')) and meta['uid'] not in seen
                and type(meta.get('labels')) is dict and text(pod['status'].get('phase'))
                and type(pod['spec'].get('nodeName', '')) is str,
                'malformed Pod identity')
        seen.add(meta['uid'])
    return value['items']


def snapshot_all(api):
    snapshot = pods(api) + pods(api, 'ci-maintenance') + pods(api, WORKER_NAMESPACE)
    require(len({p['metadata']['uid'] for p in snapshot}) == len(snapshot), 'duplicate snapshot UID')
    return snapshot


def owner_ref(pod):
    refs = pod['metadata'].get('ownerReferences', [])
    require(type(refs) is list, 'invalid owner references')
    owners = [v for v in refs if type(v) is dict and v.get('controller') is True]
    require(len(owners) == 1 and owners[0].get('kind') == 'Job'
            and text(owners[0].get('name')) and text(owners[0].get('uid')), 'missing native Job owner')
    return owners[0]


def pod_identity(pod):
    owner = owner_ref(pod)
    return {'namespace': pod['metadata']['namespace'], 'name': pod['metadata']['name'], 'uid': pod['metadata']['uid'],
            'job': owner['name'], 'job_uid': owner['uid']}


def bundle(pod):
    volumes = [v for v in pod['spec'].get('volumes', []) if v.get('name') == 'policy']
    require(len(volumes) == 1, 'missing policy bundle')
    name = volumes[0].get('configMap', {}).get('name')
    require(text(name) and name.startswith('hestia-ci-cache-retention-'), 'wrong policy bundle')
    return name


def scheduled(api, pod, cron):
    ident = pod_identity(pod)
    namespace = WORKER_NAMESPACE if cron == 'hestia-ci-cache-retention' else 'ci-maintenance'
    require(ident['namespace'] == namespace, 'wrong scheduled namespace')
    job, _ = api.request('GET', '/apis/batch/v1/namespaces/' + ident['namespace'] + '/jobs/' + urllib.parse.quote(ident['job'], safe=''))
    require(job.get('metadata', {}).get('uid') == ident['job_uid']
            and job['metadata'].get('namespace') == namespace
            and job['metadata'].get('name') == ident['job'], 'Job generation changed')
    template = job.get('spec', {}).get('template', {})
    sa = 'hestia-ci-maintenance-worker' if namespace == WORKER_NAMESPACE else cron
    require(pod['spec'].get('serviceAccountName') == sa
            and template.get('spec', {}).get('serviceAccountName') == sa
            and bundle(template) == bundle(pod), 'Job policy or service account changed')
    refs = job['metadata'].get('ownerReferences', [])
    require(len(refs) == 1 and refs[0].get('kind') == 'CronJob' and refs[0].get('name') == cron
            and refs[0].get('controller') is True and text(refs[0].get('uid')), 'not a scheduled native Job')
    annotation = job['metadata'].get('annotations', {}).get('batch.kubernetes.io/cronjob-scheduled-timestamp')
    require(type(annotation) is str and re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:47:00Z', annotation) is not None,
            'missing exact UTC schedule')
    return int(dt.datetime.strptime(annotation, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc).timestamp())


def terminal(snapshot, ident):
    matches = [p for p in snapshot if p['metadata']['namespace'] == ident['namespace'] and p['metadata']['name'] == ident['name']
               and p['metadata']['uid'] == ident['uid']]
    if len(matches) != 1:
        return False  # 404 is not retirement proof.
    pod = matches[0]
    if pod_identity(pod) != ident or pod['status']['phase'] not in {'Succeeded', 'Failed'}:
        return False
    for spec_key, status_key in (('containers', 'containerStatuses'), ('initContainers', 'initContainerStatuses'),
                                 ('ephemeralContainers', 'ephemeralContainerStatuses')):
        names = [c['name'] for c in pod['spec'].get(spec_key, [])]
        statuses = pod['status'].get(status_key, [])
        if (len(statuses) != len(names) or {s.get('name') for s in statuses} != set(names)
                or any(type(s.get('state', {}).get('terminated')) is not dict for s in statuses)):
            return False
    return bool(pod['spec'].get('containers'))


def runner(api):
    value, _ = api.request('GET', '/runners/2')
    require(type(value) is dict and type(value.get('id')) is int and value['id'] == 2
            and type(value.get('paused')) is bool, 'invalid Runner2 readback')
    return value['paused']


def drained(api):
    # Supported scalar status filter avoids completed history. Idle requires every
    # filter's complete bounded pagination; foreign statuses mean ignored filtering.
    for status in ACTIVE:
        page, seen_pages, seen_jobs = '1', set(), set()
        while True:
            require(page not in seen_pages and len(seen_pages) < 100, 'unbounded/incomplete jobs pagination')
            seen_pages.add(page)
            values, headers = api.request('GET', '/runners/2/jobs?status=' + status + '&per_page=100&page=' + page)
            require(type(values) is list, 'invalid jobs page')
            for value in values:
                require(type(value) is dict and type(value.get('id')) is int and value['id'] > 0
                        and value['id'] not in seen_jobs and type(value.get('status')) is str
                        and value['status'] == status, 'invalid accepted-job evidence or ignored status filter')
                seen_jobs.add(value['id'])
            headers = {k.lower(): v for k, v in headers.items()}
            require('x-next-page' in headers and type(headers['x-next-page']) is str, 'missing pagination evidence')
            page = headers['x-next-page']
            require(page == '' or re.fullmatch(r'[1-9][0-9]*', page) is not None, 'invalid next page')
            require(page not in seen_pages, 'repeated jobs page')
            if values:
                return False  # Proven busy needs no further history or filters.
            if page == '':
                break
    return True


def ci_drained(snapshot):
    for pod in snapshot:
        labels = pod['metadata'].get('labels')
        require(type(labels) is dict, 'missing Pod labels')
        if labels.get('ci.brmartin.co.uk/job') == 'true' and labels.get('ci.brmartin.co.uk/maintenance') != 'true':
            phase = pod['status']['phase']
            if pod['metadata'].get('deletionTimestamp') or phase not in {'Running', 'Pending', 'Succeeded', 'Failed'}:
                return False
            # Same positive node-local hostPath exemption as cache-retention pod_gate.
            if phase in {'Running', 'Pending'} and pod['spec'].get('nodeName') not in {'heracles', 'nyx'}:
                return False
    return True


def new_operation(slot, coord, policy):
    return {'id': hashlib.sha256(f"{slot}:{coord['uid']}:{policy}".encode()).hexdigest(),
            'slot': slot, 'coordinator': coord, 'worker': None, 'claimed': False,
            'holder': None, 'baseline': False, 'restore_required': True, 'write': 'pause',
            'drain_by': slot + 1200, 'cleanup_by': slot + 1800, 'recover_by': slot + 2700,
            'outcome': 'pause-intent', 'restored': False}


def alert(store, cm, state, reason):
    state['phase'] = 'ALERT'
    if state['operation'] is not None:
        state['operation']['outcome'] = reason
    store.save(cm, state)
    raise Refuse(reason)


def coordinate(store, gitlab, me, now=time.time, sleep=time.sleep):
    snapshot = snapshot_all(store.api)
    own = next((p for p in snapshot if p['metadata']['uid'] == me['uid']), None)
    require(own is not None and pod_identity(own) == me, 'coordinator absent')
    slot = scheduled(store.api, own, 'hestia-ci-maintenance-admission')
    require(0 <= now() - slot <= 90, 'late/old schedule refused')
    cm, state = store.read()
    require(state['phase'] in {'IDLE', 'DONE'}, 'operation not closed')
    require(0 <= now() - state['heartbeat'] <= 150 and now() + 2700 < TOKEN_EXPIRY,
            'stale recovery heartbeat or expiring token')
    if state['operation'] is not None:
        old = state['operation']
        require(old['slot'] < slot and old['holder'] is not None and terminal(snapshot, old['holder']),
                'previous restoration holder not retired')
    baseline = runner(gitlab)
    # Capture locally before fallible persistence. True baseline has ZERO writes.
    restore_required = not baseline
    if not restore_required:
        return
    state['operation'] = new_operation(slot, me, store.policy)
    state['phase'] = 'PAUSE_INTENT'
    store.save(cm, state)  # Must be durable/read back before the only pause attempt.
    try:
        gitlab.request('PUT', '/runners/2', {'paused': True})
        require(runner(gitlab) is True, 'pause readback failed')
    except Exception:
        cm, state = store.read()
        state['operation']['write'] = 'unknown'
        alert(store, cm, state, 'unknown-pause-write')
    cm, state = store.read()
    require(state['phase'] == 'PAUSE_INTENT' and state['operation']['coordinator'] == me,
            'pause ownership lost')
    state['operation']['write'] = 'none'
    state['phase'] = 'DRAINING'
    store.save(cm, state)
    while now() < slot + 1200:
        cm, state = store.read()
        require(state['phase'] == 'DRAINING' and state['operation']['coordinator'] == me,
                'drain ownership sealed')
        snapshot = snapshot_all(store.api)
        if runner(gitlab) and drained(gitlab) and ci_drained(snapshot):
            workers = [p for p in snapshot if p['metadata']['namespace'] == WORKER_NAMESPACE
                       and p['metadata'].get('labels', {}).get('app') == 'hestia-ci-cache-retention'
                       and bundle(p) == bundle(own)
                       and p['status']['phase'] in {'Pending', 'Running'} and not p['metadata'].get('deletionTimestamp')
                       and scheduled(store.api, p, 'hestia-ci-cache-retention') == slot]
            require(len(workers) <= 1, 'ambiguous worker generation')
            if workers:
                state['operation']['worker'] = pod_identity(workers[0])
                state['operation']['outcome'] = 'admitted'
                state['phase'] = 'ADMITTED'
                store.save(cm, state)
                return
        sleep(5)
    cm, state = store.read()
    require(state['phase'] == 'DRAINING', 'drain already closed')
    state['phase'], state['operation']['outcome'] = 'CLOSING', 'drain-timeout'
    store.save(cm, state)
    raise Refuse('natural drain deadline; accepted jobs unchanged')


def recover(store, gitlab, me, now=time.time):
    cm, state = store.read()
    if state['phase'] == 'ALERT':
        raise Refuse('latched ALERT; operator reconciliation required')
    try:
        require(now() + 60 < TOKEN_EXPIRY, 'token expired/expiring')
        runner(gitlab)  # Heartbeat certifies token/API readiness, not merely execution.
    except Exception:
        if state['operation'] is not None and state['phase'] != 'DONE':
            alert(store, cm, state, 'recovery-api-or-credential-unavailable')
        raise
    state['heartbeat'] = int(now())
    store.save(cm, state)
    cm, state = store.read()
    if state['phase'] in {'IDLE', 'DONE'}:
        return
    op = state['operation']
    snapshot = snapshot_all(store.api)
    if now() >= op['recover_by']:
        alert(store, cm, state, 'recovery-horizon-exceeded')
    if state['phase'] in {'PAUSE_INTENT', 'DRAINING'}:
        if now() < op['drain_by'] and not terminal(snapshot, op['coordinator']):
            return
    elif state['phase'] in {'ADMITTED', 'CLAIMED'}:
        if now() < op['cleanup_by'] and not (op['claimed'] and terminal(snapshot, op['worker'])):
            return
    if state['phase'] != 'RESTORING':
        # CAS seal races the only ADMITTED->CLAIMED CAS. Never erase claim latch.
        state['phase'] = 'CLOSING'
        store.save(cm, state)
        cm, state = store.read()
        op = state['operation']
    if not terminal(snapshot, op['coordinator']):
        return
    if op['claimed'] and not terminal(snapshot, op['worker']):
        return
    if op['holder'] is not None and not terminal(snapshot, op['holder']):
        return
    if op['write'] != 'none':
        alert(store, cm, state, 'unresolved-remote-write')
    if op['claimed']:
        worker = next(p for p in snapshot if p['metadata']['uid'] == op['worker']['uid'])
        op['outcome'] = 'cleanup-succeeded' if worker['status']['phase'] == 'Succeeded' else 'cleanup-failed'
    elif op['outcome'] == 'admitted':
        op['outcome'] = 'worker-unclaimed'
    elif op['outcome'] == 'pause-intent':
        op['outcome'] = 'coordinator-failed'
    state['phase'], op['holder'], op['write'] = 'RESTORING', me, 'restore'
    store.save(cm, state)
    try:
        gitlab.request('PUT', '/runners/2', {'paused': op['baseline']})
        require(runner(gitlab) is op['baseline'], 'restore readback failed')
    except Exception:
        cm, state = store.read()
        state['operation']['write'] = 'unknown'
        alert(store, cm, state, 'unknown-restore-write')
    cm, state = store.read()
    require(state['phase'] == 'RESTORING' and state['operation']['holder'] == me, 'restoration ownership lost')
    state['phase'] = 'DONE'
    state['operation']['write'], state['operation']['restored'] = 'none', True
    store.save(cm, state)


class WorkerFence:
    def __init__(self, store, me, now=time.time):
        require(me['namespace'] == WORKER_NAMESPACE, 'wrong worker namespace')
        self.store, self.me, self.now, self.operation = store, me, now, None

    def claim(self, sleep=time.sleep):
        end = self.now() + 1200
        while self.now() < end:
            cm, state = self.store.read()
            op = state['operation']
            if op is not None and op['worker'] == self.me:
                require(self.now() < op['cleanup_by'], 'worker deadline expired')
                if state['phase'] == 'ADMITTED':
                    state['phase'], op['claimed'] = 'CLAIMED', True
                    self.store.save(cm, state)
                    self.operation = op['id']
                    self.check()
                    return
                require(state['phase'] in {'PAUSE_INTENT', 'DRAINING'}, 'worker claim sealed')
            require(state['phase'] not in {'ALERT', 'CLOSING', 'RESTORING'}, 'admission closed')
            sleep(2)
        raise Refuse('worker admission deadline')

    def check(self):
        _, state = self.store.read()
        op = state['operation']
        require(state['phase'] == 'CLAIMED' and op['id'] == self.operation
                and op['worker'] == self.me and op['claimed'] is True
                and op['write'] == 'none' and self.now() < op['cleanup_by'], 'worker fence revoked')


def kube_store():
    sa = Path('/var/run/secrets/kubernetes.io/serviceaccount')
    base = 'https://' + os.environ['KUBERNETES_SERVICE_HOST'] + ':' + os.environ['KUBERNETES_SERVICE_PORT_HTTPS']
    return Store(HTTP(base, (sa / 'token').read_text().strip(), str(sa / 'ca.crt')), policy_hash())


def self_identity(api):
    namespace = os.environ['POD_NAMESPACE']
    require(namespace in {WORKER_NAMESPACE, 'ci-maintenance'}, 'wrong self namespace')
    matches = [p for p in pods(api, namespace) if p['metadata']['uid'] == os.environ['POD_UID']
               and p['metadata']['name'] == os.environ['POD_NAME']]
    require(len(matches) == 1 and not matches[0]['metadata'].get('deletionTimestamp'), 'self Pod identity missing')
    return pod_identity(matches[0])


def main():
    require(sys.argv[1:] in (['coordinate'], ['recover']), 'expected coordinate or recover')
    require(os.environ.get('POD_NAMESPACE') == 'ci-maintenance', 'control namespace refused')
    # Independent execution wall bound; Job deadline is a second, native bound.
    def expired(*_):
        raise Refuse('execution deadline')
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(45 if sys.argv[1] == 'recover' else 1370)
    store = kube_store()
    me = self_identity(store.api)
    gitlab = HTTP(GITLAB, TOKEN.read_text().strip())
    if sys.argv[1] == 'recover':
        recover(store, gitlab, me)
    else:
        coordinate(store, gitlab, me)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Never log response bodies, headers, tokens, URLs or untrusted data.
        print('MAINTENANCE REFUSED: ' + (str(error) if isinstance(error, Refuse) else type(error).__name__),
              file=sys.stderr, flush=True)
        sys.exit(1)
