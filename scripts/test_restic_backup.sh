#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backup_script="${repo_root}/infrastructure/storage/restic-backup/files/backup.sh"
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

run_backup() {
  local name="$1"
  shift

  run_script "${backup_script}" "${name}" "$@"
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

run_backup warning_exit_3 RESTIC_FAKE_BACKUP_EXIT=3
warning_dir="$(case_dir warning_exit_3)"
[ "$(cat "${warning_dir}/status")" -eq 0 ] || fail "backup exit 3 should be treated as non-fatal"
assert_contains backup "${warning_dir}/restic.log"
assert_contains forget "${warning_dir}/restic.log"
assert_contains check "${warning_dir}/restic.log"
assert_contains_text "WARNING: restic backup completed with unreadable source files; continuing after exit code 3." "${warning_dir}/stdout.log"

run_backup fatal_exit_2 RESTIC_FAKE_BACKUP_EXIT=2
fatal_dir="$(case_dir fatal_exit_2)"
[ "$(cat "${fatal_dir}/status")" -eq 2 ] || fail "backup exit 2 should fail the script"
assert_contains backup "${fatal_dir}/restic.log"
assert_not_contains forget "${fatal_dir}/restic.log"
assert_not_contains check "${fatal_dir}/restic.log"

run_backup clean_exit_0 RESTIC_FAKE_BACKUP_EXIT=0
clean_dir="$(case_dir clean_exit_0)"
[ "$(cat "${clean_dir}/status")" -eq 0 ] || fail "backup exit 0 should succeed"
assert_contains backup "${clean_dir}/restic.log"
assert_contains forget "${clean_dir}/restic.log"
assert_contains check "${clean_dir}/restic.log"

run_backup forget_exit_1 RESTIC_FAKE_BACKUP_EXIT=0 RESTIC_FAKE_FORGET_EXIT=1
forget_dir="$(case_dir forget_exit_1)"
[ "$(cat "${forget_dir}/status")" -eq 1 ] || fail "forget exit 1 should fail the script"
assert_contains backup "${forget_dir}/restic.log"
assert_contains forget "${forget_dir}/restic.log"
assert_not_contains check "${forget_dir}/restic.log"

run_backup check_exit_1 RESTIC_FAKE_BACKUP_EXIT=0 RESTIC_FAKE_CHECK_EXIT=1
check_dir="$(case_dir check_exit_1)"
[ "$(cat "${check_dir}/status")" -eq 1 ] || fail "check exit 1 should fail the script"
assert_contains backup "${check_dir}/restic.log"
assert_contains forget "${check_dir}/restic.log"
assert_contains check "${check_dir}/restic.log"

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
