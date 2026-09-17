#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scoped_backup_script="${repo_root}/infrastructure/storage/restic-backup/files/backup-critical-pvc.sh"
maintenance_script="${repo_root}/infrastructure/storage/restic-backup/files/maintenance.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

fake_bin="${tmpdir}/bin"
mkdir -p "${fake_bin}"

cat >"${fake_bin}/restic" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

log_file="${RESTIC_FAKE_LOG:?}"
command="${1:?}"
printf '%s\n' "${command}" >>"${log_file}"

case "${command}" in
  snapshots)
    exit "${RESTIC_FAKE_SNAPSHOTS_EXIT:-0}"
    ;;
  init)
    exit "${RESTIC_FAKE_INIT_EXIT:-0}"
    ;;
  backup)
    exit "${RESTIC_FAKE_BACKUP_EXIT:-0}"
    ;;
  forget)
    exit "${RESTIC_FAKE_FORGET_EXIT:-0}"
    ;;
  check)
    exit "${RESTIC_FAKE_CHECK_EXIT:-0}"
    ;;
  *)
    printf 'unexpected restic command: %s\n' "${command}" >&2
    exit 99
    ;;
esac
EOF

chmod +x "${fake_bin}/restic"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local needle="$1"
  local file="$2"
  if ! grep -Fqx "${needle}" "${file}"; then
    printf 'expected to find "%s" in %s\n' "${needle}" "${file}" >&2
    cat "${file}" >&2
    exit 1
  fi
}

assert_not_contains() {
  local needle="$1"
  local file="$2"
  if grep -Fqx "${needle}" "${file}"; then
    printf 'did not expect "%s" in %s\n' "${needle}" "${file}" >&2
    cat "${file}" >&2
    exit 1
  fi
}

assert_contains_text() {
  local needle="$1"
  local file="$2"
  if ! grep -Fq "${needle}" "${file}"; then
    printf 'expected to find "%s" in %s\n' "${needle}" "${file}" >&2
    cat "${file}" >&2
    exit 1
  fi
}

run_scoped_backup() {
  local name="$1"
  shift

  run_script "${scoped_backup_script}" "${name}" "$@"
}

run_maintenance() {
  local name="$1"
  shift

  run_script "${maintenance_script}" "${name}" "$@"
}

run_script() {
  local script="$1"
  local name="$2"
  shift 2

  local case_dir="${tmpdir}/${name}"
  mkdir -p "${case_dir}"

  local log_file="${case_dir}/restic.log"
  local stdout_file="${case_dir}/stdout.log"
  local stderr_file="${case_dir}/stderr.log"

  local status=0
  if env \
    PATH="${fake_bin}:${PATH}" \
    RESTIC_FAKE_LOG="${log_file}" \
    "$@" \
    /bin/sh "${script}" >"${stdout_file}" 2>"${stderr_file}"; then
    status=0
  else
    status=$?
  fi

  printf '%s\n' "${status}" >"${case_dir}/status"
}

case_dir() {
  printf '%s/%s\n' "${tmpdir}" "$1"
}

configured_paths_file="${repo_root}/infrastructure/storage/restic-backup/files/critical-pvc-paths.txt"
assert_contains "/data/factorio-data-sw" "${configured_paths_file}"
configured_excludes_file="${repo_root}/infrastructure/storage/restic-backup/files/excludes.txt"
assert_contains "*.tmp.zip" "${configured_excludes_file}"

paths_file="${tmpdir}/critical-paths.txt"
mkdir -p "${tmpdir}/data/dovecot" "${tmpdir}/data/matrix-media"
printf '%s\n' "${tmpdir}/data/dovecot" "" "# ignored" "${tmpdir}/data/matrix-media" >"${paths_file}"
run_scoped_backup scoped_clean RESTIC_FAKE_BACKUP_EXIT=0 BACKUP_PATHS_FILE="${paths_file}"
scoped_clean_dir="$(case_dir scoped_clean)"
[ "$(cat "${scoped_clean_dir}/status")" -eq 0 ] || fail "scoped backup should succeed"
assert_contains snapshots "${scoped_clean_dir}/restic.log"
assert_contains backup "${scoped_clean_dir}/restic.log"
assert_not_contains forget "${scoped_clean_dir}/restic.log"
assert_not_contains check "${scoped_clean_dir}/restic.log"
assert_contains_text "Starting scoped critical PVC backup" "${scoped_clean_dir}/stdout.log"

run_scoped_backup scoped_warning RESTIC_FAKE_BACKUP_EXIT=3 BACKUP_PATHS_FILE="${paths_file}"
scoped_warning_dir="$(case_dir scoped_warning)"
[ "$(cat "${scoped_warning_dir}/status")" -eq 3 ] || fail "scoped backup exit 3 should fail the backup-only job"
assert_contains backup "${scoped_warning_dir}/restic.log"
assert_not_contains forget "${scoped_warning_dir}/restic.log"
assert_not_contains check "${scoped_warning_dir}/restic.log"

missing_paths_file="${tmpdir}/missing-paths.txt"
printf '%s\n' "${tmpdir}/data/does-not-exist" >"${missing_paths_file}"
run_scoped_backup scoped_missing BACKUP_PATHS_FILE="${missing_paths_file}"
scoped_missing_dir="$(case_dir scoped_missing)"
[ "$(cat "${scoped_missing_dir}/status")" -eq 66 ] || fail "scoped backup should fail before restic when a configured path is missing"
[ ! -f "${scoped_missing_dir}/restic.log" ] || fail "scoped backup should not call restic when a path is missing"

run_maintenance maintenance_clean RESTIC_FAKE_FORGET_EXIT=0 RESTIC_FAKE_CHECK_EXIT=0
maintenance_clean_dir="$(case_dir maintenance_clean)"
[ "$(cat "${maintenance_clean_dir}/status")" -eq 0 ] || fail "maintenance should succeed"
assert_contains forget "${maintenance_clean_dir}/restic.log"
assert_contains check "${maintenance_clean_dir}/restic.log"
assert_not_contains backup "${maintenance_clean_dir}/restic.log"

run_maintenance maintenance_forget_failure RESTIC_FAKE_FORGET_EXIT=1
maintenance_forget_dir="$(case_dir maintenance_forget_failure)"
[ "$(cat "${maintenance_forget_dir}/status")" -eq 1 ] || fail "maintenance forget failure should fail"
assert_contains forget "${maintenance_forget_dir}/restic.log"
assert_not_contains check "${maintenance_forget_dir}/restic.log"

printf 'restic backup script tests passed\n'

# Reuse the repository's pinned PyYAML/uv toolchain for offline rendered checks.
uv --no-config run --no-project --with PyYAML==6.0.3 python - "${repo_root}" <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

import yaml

root = Path(sys.argv[1])


def render(path):
    command = ["kustomize", "build"] if shutil.which("kustomize") else ["kubectl", "kustomize"]
    output = subprocess.check_output(command + [str(root / path)], text=True,
                                     env={**os.environ, "KUBECONFIG": "/dev/null"})
    return {(doc["kind"], doc["metadata"]["name"]): doc for doc in yaml.safe_load_all(output)}


restic = render("infrastructure/storage/restic-backup")
grafana = render("infrastructure/observability-ui/grafana")
policy = yaml.safe_load(restic["ConfigMap", "restic-backup-scripts"]["data"]["backup-policy.yaml"])
sources = """dovecot-mailboxes-sw factorio-data-sw gitlab-repositories-sw gitlab-shared-sw
    gitlab-uploads-sw glitchtip-uploads matrix-config-sw matrix-media-store-sw
    matrix-synapse-data-sw matrix-whatsapp-data-sw nextcloud-config nextcloud-custom-apps
    nextcloud-data vaultwarden-data-sw""".split()


class ResticManifests(unittest.TestCase):
    def test_existing_repository_is_statically_prebound_and_retained(self):
        self.assertIn(("PersistentVolume", "restic-repository"), list(restic))
        self.assertIn(("PersistentVolumeClaim", "restic-repository"), list(restic))
        pv = restic["PersistentVolume", "restic-repository"]["spec"]
        pvc = restic["PersistentVolumeClaim", "restic-repository"]
        self.assertEqual(pv["nfs"], {"server": "192.168.1.10", "path": "/volume1/csi/backups/restic", "readOnly": False})
        self.assertEqual(pv["mountOptions"], ["nfsvers=4.1", "hard", "timeo=600", "retrans=2"])
        self.assertEqual(pv["persistentVolumeReclaimPolicy"], "Retain")
        self.assertEqual(pv["claimRef"], {"name": "restic-repository", "namespace": "default"})
        self.assertEqual(pvc["metadata"]["namespace"], "default")
        self.assertEqual(pvc["spec"]["volumeName"], "restic-repository")
        self.assertNotIn("nodeAffinity", pv)
        for spec in (pv, pvc["spec"]):
            self.assertEqual(spec["storageClassName"], "")
            self.assertEqual(spec["accessModes"], ["ReadWriteMany"])
            self.assertEqual(spec["volumeMode"], "Filesystem")
        self.assertEqual(pv["capacity"], {"storage": "1Ti"})
        self.assertEqual(pvc["spec"]["resources"]["requests"], {"storage": "1Ti"})

    def test_jobs_share_writable_repository_without_hostname_pinning(self):
        for suffix, memory, limit, schedule, script in (
            ("critical-pvc-backup", "512Mi", "2Gi", "0 3 * * *", "backup-critical-pvc.sh"),
            ("repo-maintenance", "256Mi", "1Gi", "0 7 * * 0", "maintenance.sh"),
        ):
            with self.subTest(job=suffix):
                cronjob = restic["CronJob", "restic-" + suffix]["spec"]
                job = cronjob["jobTemplate"]["spec"]
                pod = job["template"]["spec"]
                container, = pod["containers"]
                volumes = {v["name"]: v for v in pod["volumes"]}
                self.assertEqual(volumes["repo"], {"name": "repo", "persistentVolumeClaim": {"claimName": "restic-repository", "readOnly": False}})
                self.assertFalse(any("hostPath" in v for v in pod["volumes"]))
                self.assertFalse(pod.get("nodeSelector"))
                self.assertNotIn("nodeName", pod)
                self.assertNotIn("nodeAffinity", pod.get("affinity", {}))
                self.assertEqual([m for m in container["volumeMounts"] if m["name"] == "repo"], [{"name": "repo", "mountPath": "/repo"}])
                self.assertEqual(container["resources"], {"requests": {"cpu": "100m", "memory": memory}, "limits": {"cpu": "500m", "memory": limit}})
                self.assertEqual(container["image"], "restic/restic:0.19.1")
                self.assertEqual(container["command"], ["/bin/sh", "/config/" + script])
                self.assertEqual(volumes["secrets"]["secret"]["secretName"], "restic-backup-secrets")
                self.assertEqual(volumes["secrets"]["secret"]["items"], [{"key": "RESTIC_PASSWORD", "path": "password"}])
                self.assertEqual((cronjob["schedule"], cronjob["timeZone"], cronjob["suspend"], cronjob["concurrencyPolicy"]), (schedule, "Europe/London", False, "Forbid"))
                self.assertEqual((job["activeDeadlineSeconds"], job["backoffLimit"]), (14400, 0))

    def test_source_scope_stays_readonly_and_out_of_maintenance(self):
        for suffix, expected in (("critical-pvc-backup", sources), ("repo-maintenance", [])):
            with self.subTest(job=suffix):
                pod = restic["CronJob", "restic-" + suffix]["spec"]["jobTemplate"]["spec"]["template"]["spec"]
                mounts = pod["containers"][0]["volumeMounts"]
                self.assertEqual([m for m in mounts if m["name"] not in {"repo", "scripts", "secrets"}],
                                 [{"name": s, "mountPath": "/data/" + s, "readOnly": True} for s in expected])
                self.assertEqual([v for v in pod["volumes"] if v["name"] not in {"repo", "scripts", "secrets"}],
                                 [{"name": s, "persistentVolumeClaim": {"claimName": s, "readOnly": True}} for s in expected])
        self.assertEqual([i["pvc"] for i in policy["jobs"][0]["includes"]], sources)

    def test_packaged_policy_describes_the_shared_repository(self):
        self.assertNotIn("hostPath", policy["repository"])
        self.assertEqual(policy["repository"]["persistentVolumeClaim"], "restic-repository")
        self.assertEqual(policy["repository"]["mountPath"], "/repo")
        self.assertEqual(policy["repository"]["nfs"], {"server": "192.168.1.10", "path": "/volume1/csi/backups/restic"})
        self.assertEqual(policy["repository"]["secretName"], "restic-backup-secrets")
        self.assertEqual(policy["repository"]["passwordFile"], "/secrets/password")

    def test_provisioning_deletes_only_the_obsolete_alert_uid(self):
        alerting, = [doc for (kind, name), doc in grafana.items() if kind == "ConfigMap" and name.startswith("grafana-alerting-")]
        rules = yaml.safe_load(alerting["data"]["rules.yaml"])
        self.assertEqual(rules["apiVersion"], 1)
        self.assertEqual(rules.get("deleteRules"), [{"orgId": 1, "uid": "restic-critical-pvc-backup-stale-api"}])
        uids = [rule["uid"] for group in rules["groups"] for rule in group["rules"]]
        self.assertEqual(uids.count("restic-backup-stale-api"), 1)
        self.assertNotIn("restic-critical-pvc-backup-stale-api", uids)
        volumes = grafana["Deployment", "grafana"]["spec"]["template"]["spec"]["volumes"]
        self.assertEqual(next(v for v in volumes if v["name"] == "alerting")["configMap"]["name"], alerting["metadata"]["name"])

    def test_grafana_rollout_does_not_require_a_surge_pod(self):
        deployment = grafana["Deployment", "grafana"]["spec"]
        self.assertEqual(deployment["replicas"], 1)
        self.assertEqual(deployment["strategy"], {"type": "Recreate"})


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
