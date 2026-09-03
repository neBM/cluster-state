#!/usr/bin/env bash
set -Eeuo pipefail; umask 077
SOURCE_HOME="/home/ben/.hermes"; SOURCE_UNIT="hermes-gateway.service"
KUBECONFIG="/home/ben/.kube/config"; DROPIN="/home/ben/.config/systemd/user/hermes-gateway.service.d/20-authority-fence.conf"
TOKEN="$SOURCE_HOME/gateway-authority.enabled"; RESULT="$SOURCE_HOME/k8s-cutover-result.json"
PROC_CGROUP="/proc/$$/cgroup"; SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
HELPER="$SCRIPT_DIR/hermes-agent-migration.sh"; REVISION="${1:-}"; PHASE=started
usage() { printf 'Usage: %s main@sha1:<40 lowercase hex>\n' "$0" >&2; }
[ "$#" -eq 1 ] || { usage; exit 64; }; [[ "$REVISION" =~ ^main@sha1:[0-9a-f]{40}$ ]] || { usage; exit 64; }
die() { printf 'ERROR: %s\n' "$*" >&2; return 1; }; need() { command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"; }
for command in busctl flock kubectl python3 systemctl systemd-analyze timeout sleep; do need "$command"; done
[ -d "$SOURCE_HOME" ] && [ -r "$KUBECONFIG" ] && [ -x "$HELPER" ] || die "source, fixed kubeconfig, or helper is unavailable"
exec 9<"$SOURCE_HOME"; flock -n 9 || die "another cutover launcher holds the source lock"
k() { timeout --foreground 20s kubectl --kubeconfig "$KUBECONFIG" --request-timeout=15s "$@"; }
sprop() { timeout --foreground 10s systemctl --user show "$SOURCE_UNIT" -p "$1" --value; }
result_io() {
  python3 - "$RESULT" "$1" "${2:-}" "${3:-}" "${4:-}" "$REVISION" <<'PY'
import json,os,re,stat,sys
path,action,state,phase,fence,revision=sys.argv[1:]; states={"started","synced","activation-attempted","success","failure"}; phases={"started","synced","activation-attempted","success"}; fences={"not-fenced","verified-fenced","fence-unknown"}
def pairs(items): value=dict(items); len(items)==len(value) or (_ for _ in ()).throw(ValueError("duplicate result key")); return value
def read():
    fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW); info=os.fstat(fd); raw=os.read(fd,4097); os.close(fd)
    (stat.S_ISREG(info.st_mode) and info.st_uid==os.getuid() and stat.S_IMODE(info.st_mode)==0o600 and len(raw)<=4096) or (_ for _ in ()).throw(RuntimeError("result metadata differs"))
    value=json.loads(raw,object_pairs_hook=pairs,parse_constant=lambda item: (_ for _ in ()).throw(ValueError(item)))
    (type(value) is dict and set(value)=={"state","lastPhase","revision","fence"} and value["state"] in states and value["lastPhase"] in phases and value["fence"] in fences and re.fullmatch(r"main@sha1:[0-9a-f]{40}",value["revision"]) is not None) or (_ for _ in ()).throw(RuntimeError("result schema differs"))
    return value
if action=="check":
    if not os.path.lexists(path): raise SystemExit(0)
    value=read(); raise SystemExit("prior result forbids rerun" if value["state"] in {"activation-attempted","success"} or value["lastPhase"] in {"activation-attempted","success"} else 0)
expected={"state":state,"lastPhase":phase,"revision":revision,"fence":fence}
if action!="write" or state not in states or phase not in phases or fence not in fences: raise SystemExit("invalid result write")
temporary=f"{path}.{os.getpid()}.tmp"; fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_CLOEXEC|os.O_NOFOLLOW,0o600)
data=(json.dumps(expected,sort_keys=True,separators=(",",":"))+"\n").encode(); written=os.write(fd,data); os.fsync(fd); os.close(fd)
if written!=len(data): raise RuntimeError("short result write")
os.replace(temporary,path); dfd=os.open(os.path.dirname(path),os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|os.O_NOFOLLOW); os.fsync(dfd); os.close(dfd)
if read()!=expected: raise RuntimeError("result readback differs")
PY
}
token_file() {
  python3 - "$DROPIN" "$TOKEN" "$1" <<'PY'
import os,stat,sys
dropin,token,action=sys.argv[1:]; expected=b"[Unit]\nConditionPathExists=/home/ben/.hermes/gateway-authority.enabled\n[Service]\nKillMode=control-group\nTimeoutStopSec=90s\nSendSIGKILL=yes\n"
def read(path):
    fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW); info=os.fstat(fd); data=os.read(fd,len(expected)+1); os.close(fd); return info,data
if action=="check":
    for path,content,label in ((dropin,expected,"drop-in"),(token,b"","token")):
        info,data=read(path); (stat.S_ISREG(info.st_mode) and info.st_uid==os.getuid() and stat.S_IMODE(info.st_mode)==0o600 and data==content) or (_ for _ in ()).throw(SystemExit(f"authority {label} differs"))
elif action=="remove":
    if os.path.lexists(token): os.unlink(token)
    fd=os.open(os.path.dirname(token),os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|os.O_NOFOLLOW); os.fsync(fd); os.close(fd)
elif action=="absent" and os.path.lexists(token): raise SystemExit("authority token remains present")
elif action not in {"absent"}: raise SystemExit("invalid token action")
PY
}
fenced() { token_file absent >/dev/null 2>&1 && [ "$(sprop ActiveState)" = inactive ] && [ "$(sprop MainPID)" = 0 ]; }
failure() { local status="${1:-1}" fence=fence-unknown; trap - ERR EXIT INT TERM; set +e; token_file remove >/dev/null 2>&1; timeout --foreground 100s systemctl --user stop "$SOURCE_UNIT" >/dev/null 2>&1; fenced && fence=verified-fenced; result_io write failure "$PHASE" "$fence" >/dev/null 2>&1; printf 'ERROR: cutover failed at %s; source status: %s\n' "$PHASE" "$fence" >&2; [ "$status" -ne 0 ] || status=1; exit "$status"; }
gate() {
  local self_cgroup="" source_cgroup dropins timespan conditions
  [ "$(sprop ActiveState)" = active ] || die "source service is not active"; [ "$(sprop NeedDaemonReload)" = no ] || die "source unit needs daemon-reload"; dropins="$(sprop DropInPaths)"; [[ " $dropins " == *" $DROPIN "* ]] || die "authority drop-in is not loaded"; token_file check
  [ "$(sprop KillMode)" = control-group ] && [ "$(sprop SendSIGKILL)" = yes ] || die "effective source kill properties differ"
  timespan="$(timeout --foreground 10s systemd-analyze timespan "$(sprop TimeoutStopUSec)")"
  [[ "$timespan" =~ (^|$'\n')[[:space:]]*μs:[[:space:]]*90000000($|$'\n') ]] || die "effective source stop timeout differs"
  conditions="$(timeout --foreground 10s busctl --user --json=short get-property org.freedesktop.systemd1 /org/freedesktop/systemd1/unit/hermes_2dgateway_2eservice org.freedesktop.systemd1.Unit Conditions)"
  python3 - "$TOKEN" 3<<<"$conditions" <<'PY'
import json,os,sys; raw=os.read(3,1048577); (raw.strip() and len(raw)<=1048576) or (_ for _ in ()).throw(SystemExit("effective Conditions is blank or oversized")); value=json.loads(raw,object_pairs_hook=lambda items: dict(items) if len(items)==len(dict(items)) else (_ for _ in ()).throw(ValueError("duplicate Conditions key")),parse_constant=lambda item: (_ for _ in ()).throw(ValueError(item)))
token=sys.argv[1]; data=value.get("data") if type(value) is dict and set(value)=={"type","data"} and value.get("type")=="a(sbbsi)" else None; valid=type(data) is list and all(type(item) is list and len(item)==5 and type(item[0]) is str and type(item[1]) is bool and type(item[2]) is bool and type(item[3]) is str and type(item[4]) is int for item in data); (valid and any(item[0]=="ConditionPathExists" and item[1] is False and item[2] is False and item[3]==token for item in data)) or (_ for _ in ()).throw(SystemExit("effective authority condition differs"))
PY
  while IFS=: read -r hierarchy _ path; do if [ "$hierarchy" = 0 ]; then self_cgroup="$path"; fi; done <"$PROC_CGROUP"; source_cgroup="$(sprop ControlGroup)"
  [ -n "$self_cgroup" ] && [ -n "$source_cgroup" ] && [ "$self_cgroup" != "$source_cgroup" ] || die "launcher and source cgroups are not distinct"
  [ "$(k get namespace kube-system -o jsonpath='{.metadata.uid}')" = 16710d5a-45ec-4b64-a101-b1a4db28a6e7 ] || die "kube-system UID differs"
  [ "$(k -n flux-system get kustomization apps -o jsonpath='{.spec.suspend}')" = true ] || die "apps is not suspended"; [ "$(k -n flux-system get kustomization cluster-state -o jsonpath='{.spec.suspend}')" = true ] || die "parent is not suspended"
  [ "$(k -n flux-system get gitrepository cluster-state -o 'jsonpath={.spec.suspend}{"|"}{.status.artifact.revision}')" = "true|$REVISION" ] || die "source is not suspended at the requested revision"
}
pod_boundary() {
  local value; value="$(k -n default get pods --chunk-size=0 -o json)"
  python3 - 3<<<"$value" <<'PY'
import json,os
raw=os.read(3,1048577); (raw.strip() and len(raw)<=1048576) or (_ for _ in ()).throw(SystemExit("Pod collection is blank or oversized")); obj=json.loads(raw)
if type(obj) is not dict: raise SystemExit("Pod collection is malformed")
metadata=obj.get("metadata"); items=obj.get("items")
if obj.get("apiVersion")!="v1" or obj.get("kind") not in {"List","PodList"} or type(metadata) is not dict or metadata.get("continue") not in {None,""} or type(items) is not list: raise SystemExit("Pod collection is malformed or continued")
for pod in items:
    meta=pod.get("metadata") if type(pod) is dict else None; spec=pod.get("spec") if type(pod) is dict else None
    if type(pod) is not dict or pod.get("apiVersion")!="v1" or pod.get("kind")!="Pod" or type(meta) is not dict or type(spec) is not dict or type(meta.get("name")) is not str or not meta["name"] or meta.get("namespace")!="default": raise SystemExit("Pod item is malformed")
    labels=meta.get("labels",{}); volumes=spec.get("volumes",[])
    if type(labels) is not dict or type(volumes) is not list or any(type(volume) is not dict for volume in volumes): raise SystemExit("Pod labels or volumes are malformed")
    name=meta["name"]
    if labels.get("app.kubernetes.io/name") in {"hermes-agent","hermes-agent-migration"} or name=="hermes-agent" or name.startswith("hermes-agent-"): raise SystemExit("target or migration Pod exists")
    pvcs=[volume.get("persistentVolumeClaim") for volume in volumes]
    if any(pvc is not None and type(pvc) is not dict for pvc in pvcs): raise SystemExit("Pod PVC is malformed")
    if any(type(pvc) is dict and pvc.get("claimName")=="hermes-agent-state" for pvc in pvcs): raise SystemExit("Pod mounts hermes-agent-state")
PY
}
ready() {
  python3 - "$ACTIVATION_TOKEN" "$REVISION" 3<<<"$1" <<'PY'
import json,os,sys
obj=json.loads(os.read(3,1048577)); token,revision=sys.argv[1:]
meta=obj.get("metadata") if type(obj) is dict else None; spec=obj.get("spec") if type(obj) is dict else None; status=obj.get("status") if type(obj) is dict else None
if type(obj) is not dict or obj.get("apiVersion")!="kustomize.toolkit.fluxcd.io/v1" or obj.get("kind")!="Kustomization" or type(meta) is not dict or meta.get("name")!="apps" or meta.get("namespace")!="flux-system" or type(spec) is not dict or spec.get("suspend") is not False or type(status) is not dict: raise SystemExit("apps response is malformed")
generation=meta.get("generation"); annotations=meta.get("annotations"); conditions=status.get("conditions")
if type(generation) is not int or type(annotations) is not dict or type(conditions) is not list or any(type(item) is not dict for item in conditions): raise SystemExit("apps readiness fields are malformed")
if annotations.get("reconcile.fluxcd.io/requestedAt")!=token or status.get("lastHandledReconcileAt")!=token or status.get("lastAppliedRevision")!=revision or status.get("observedGeneration")!=generation or not any(item.get("type")=="Ready" and item.get("status")=="True" for item in conditions): raise SystemExit(75)
PY
}
result_io check; gate; result_io write started started not-fenced
trap 'failure $?' ERR EXIT; trap 'failure 130' INT; trap 'failure 143' TERM
token_file remove; token_file absent
HERMES_MIGRATION_KUBECONFIG="$KUBECONFIG" "$HELPER" final-sync
fenced || die "source did not remain fenced after final sync"; result_io write synced synced verified-fenced; PHASE=synced; pod_boundary
ACTIVATION_TOKEN="activate-$(python3 -c 'import secrets; print(secrets.token_hex(16))')"; [[ "$ACTIVATION_TOKEN" =~ ^activate-[0-9a-f]{32}$ ]] || die "activation token generation failed"
result_io write activation-attempted activation-attempted verified-fenced; PHASE=activation-attempted
PATCH="$(printf '{"metadata":{"annotations":{"reconcile.fluxcd.io/requestedAt":"%s"}},"spec":{"suspend":false}}' "$ACTIVATION_TOKEN")"; k -n flux-system patch kustomization apps --type=merge -p "$PATCH" >/dev/null
ready_state=0; deadline=$((SECONDS + 640))
while (( SECONDS < deadline )); do value="$(k -n flux-system get kustomization apps -o json)"; if ready "$value"; then ready_state=1; break; else status=$?; [ "$status" -eq 75 ] || exit "$status"; fi; (( SECONDS < deadline )) && sleep 10; done
[ "$ready_state" -eq 1 ] || die "apps did not reconcile within 11 minutes"
[ "$(k -n flux-system get gitrepository cluster-state -o 'jsonpath={.spec.suspend}{"|"}{.status.artifact.revision}')" = "true|$REVISION" ] || die "source suspension or artifact changed"
HERMES_MIGRATION_KUBECONFIG="$KUBECONFIG" "$HELPER" verify-target
token_file absent; fenced || die "source fence proof failed after target verification"; result_io write success success verified-fenced; PHASE=success
trap - ERR EXIT INT TERM; printf 'cutover success: target verified at %s; source is verified-fenced\n' "$REVISION"
