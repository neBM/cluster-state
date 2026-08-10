#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
startup_script="${repo_root}/apps/factorio/files/start-factorio.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -x "${startup_script}" ] || fail "Factorio startup wrapper is missing or not executable"

tmpdir="$(mktemp -d)"
wrapper_pid=""
child_pid=""
signal_release_file=""

process_state() {
  local pid="$1"
  local stat_line
  local stat_fields

  [ -r "/proc/${pid}/stat" ] || return 1
  stat_line="$(<"/proc/${pid}/stat")"
  stat_fields="${stat_line##*) }"
  printf '%s\n' "${stat_fields%% *}"
}

process_is_running() {
  local state
  state="$(process_state "$1")" || return 1
  [ "${state}" != "Z" ] && [ "${state}" != "X" ]
}

wait_for_process_stop() {
  local pid="$1"
  local attempts="${2:-500}"
  local attempt

  for ((attempt = 0; attempt < attempts; attempt++)); do
    if ! process_is_running "${pid}"; then
      return 0
    fi
    sleep 0.01
  done
  return 1
}

wait_for_process_absence() {
  local pid="$1"
  local attempts="${2:-500}"
  local attempt

  for ((attempt = 0; attempt < attempts; attempt++)); do
    if [ ! -e "/proc/${pid}" ]; then
      return 0
    fi
    sleep 0.01
  done
  return 1
}

cleanup() {
  if [ -n "${signal_release_file}" ]; then
    : >"${signal_release_file}" 2>/dev/null || true
  fi

  if [ -n "${child_pid}" ] && process_is_running "${child_pid}"; then
    kill -TERM "${child_pid}" 2>/dev/null || true
  fi
  if [ -n "${wrapper_pid}" ] && process_is_running "${wrapper_pid}"; then
    kill -TERM "${wrapper_pid}" 2>/dev/null || true
  fi

  if [ -n "${wrapper_pid}" ]; then
    if ! wait_for_process_stop "${wrapper_pid}" 200; then
      kill -KILL "${wrapper_pid}" 2>/dev/null || true
      wait_for_process_stop "${wrapper_pid}" 200 || true
    fi
    wait "${wrapper_pid}" 2>/dev/null || true
  fi

  if [ -n "${child_pid}" ] && [ -e "/proc/${child_pid}" ]; then
    kill -KILL "${child_pid}" 2>/dev/null || true
    wait_for_process_absence "${child_pid}" 200 || true
  fi

  rm -rf "${tmpdir}"
}
trap cleanup EXIT

config_dir="${repo_root}/apps/factorio/files"
fake_factorio="${tmpdir}/factorio"

cat >"${fake_factorio}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >>"${FACTORIO_TEST_LOG:?}"
printf '\n' >>"${FACTORIO_TEST_LOG}"

create_target=""
create_next=false
for argument in "$@"; do
  if ${create_next}; then
    create_target="${argument}"
    create_next=false
  elif [ "${argument}" = "--create" ]; then
    create_next=true
  fi
done

[ -n "${create_target}" ] || exit 0

case "${FACTORIO_TEST_MODE:-success}" in
  success)
    printf 'fresh-save\n' >"${create_target}"
    ;;
  fail-partial)
    printf 'partial-save\n' >"${create_target}"
    exit "${FACTORIO_TEST_CREATE_STATUS:?}"
    ;;
  block-create)
    printf 'partial-save\n' >"${create_target}"
    exec 9<>"${FACTORIO_TEST_BLOCK_FIFO:?}"

    handle_term() {
      printf 'received\n' >"${FACTORIO_TEST_TERM_FILE}.tmp.$$"
      mv -- "${FACTORIO_TEST_TERM_FILE}.tmp.$$" "${FACTORIO_TEST_TERM_FILE}"
      while [ ! -e "${FACTORIO_TEST_RELEASE_FILE}" ]; do
        IFS= read -r -t 0.05 _ <&9 || true
      done
      exit 143
    }
    trap handle_term TERM

    printf '%s %s\n' "$$" "${PPID}" >"${FACTORIO_TEST_PID_FILE}.tmp.$$"
    mv -- "${FACTORIO_TEST_PID_FILE}.tmp.$$" "${FACTORIO_TEST_PID_FILE}"
    printf 'ready\n' >"${FACTORIO_TEST_READY_FILE}.tmp.$$"
    mv -- "${FACTORIO_TEST_READY_FILE}.tmp.$$" "${FACTORIO_TEST_READY_FILE}"

    while :; do
      IFS= read -r -t 1 _ <&9 || true
    done
    ;;
  *)
    printf 'unknown FACTORIO_TEST_MODE: %s\n' "${FACTORIO_TEST_MODE}" >&2
    exit 2
    ;;
esac
EOF
chmod +x "${fake_factorio}"

state_dir=""
runtime_dir=""
log_file=""
factorio_mode="success"
create_status="42"
ready_file=""
term_file=""
pid_file=""
release_file=""
block_fifo=""
startup_bash_env=""
boundary_marker=""

reset_fixture() {
  local name="$1"
  local scenario_dir="${tmpdir}/${name}"

  wrapper_pid=""
  child_pid=""
  signal_release_file=""
  state_dir="${scenario_dir}/state"
  runtime_dir="${scenario_dir}/runtime"
  log_file="${scenario_dir}/factorio.log"
  factorio_mode="success"
  create_status="42"
  ready_file="${scenario_dir}/create.ready"
  term_file="${scenario_dir}/create.term"
  pid_file="${scenario_dir}/create.pid"
  release_file="${scenario_dir}/create.release"
  block_fifo="${scenario_dir}/create.block"
  startup_bash_env=""
  boundary_marker=""
  mkdir -p "${state_dir}/saves" "${runtime_dir}"
  : >"${log_file}"
}

run_startup() {
  env \
    VERSION="$1" \
    FACTORIO_BIN="${fake_factorio}" \
    FACTORIO_STATE_DIR="${state_dir}" \
    FACTORIO_RUNTIME_DIR="${runtime_dir}" \
    FACTORIO_CONFIG_SOURCE_DIR="${config_dir}" \
    FACTORIO_TEST_LOG="${log_file}" \
    FACTORIO_TEST_MODE="${factorio_mode}" \
    FACTORIO_TEST_CREATE_STATUS="${create_status}" \
    FACTORIO_TEST_READY_FILE="${ready_file}" \
    FACTORIO_TEST_TERM_FILE="${term_file}" \
    FACTORIO_TEST_PID_FILE="${pid_file}" \
    FACTORIO_TEST_RELEASE_FILE="${release_file}" \
    FACTORIO_TEST_BLOCK_FIFO="${block_fifo}" \
    BASH_ENV="${startup_bash_env}" \
    FACTORIO_TEST_DEBUG_OWNER_BASHPID="" \
    FACTORIO_TEST_BOUNDARY_MARKER="${boundary_marker}" \
    "${startup_script}"
}

start_startup() {
  env \
    VERSION="$1" \
    FACTORIO_BIN="${fake_factorio}" \
    FACTORIO_STATE_DIR="${state_dir}" \
    FACTORIO_RUNTIME_DIR="${runtime_dir}" \
    FACTORIO_CONFIG_SOURCE_DIR="${config_dir}" \
    FACTORIO_TEST_LOG="${log_file}" \
    FACTORIO_TEST_MODE="${factorio_mode}" \
    FACTORIO_TEST_CREATE_STATUS="${create_status}" \
    FACTORIO_TEST_READY_FILE="${ready_file}" \
    FACTORIO_TEST_TERM_FILE="${term_file}" \
    FACTORIO_TEST_PID_FILE="${pid_file}" \
    FACTORIO_TEST_RELEASE_FILE="${release_file}" \
    FACTORIO_TEST_BLOCK_FIFO="${block_fifo}" \
    "${startup_script}" &
  wrapper_pid=$!
}

wait_for_file() {
  local path="$1"
  local attempts="${2:-500}"
  local attempt

  for ((attempt = 0; attempt < attempts; attempt++)); do
    if [ -f "${path}" ]; then
      return 0
    fi
    sleep 0.01
  done
  return 1
}

line_count() {
  local count=0
  while IFS= read -r _; do
    count=$((count + 1))
  done <"$1"
  printf '%s\n' "${count}"
}

assert_log_contains() {
  local needle="$1"
  local content
  content="$(<"${log_file}")"
  case "${content}" in
    *"${needle}"*) ;;
    *) fail "Factorio invocation missing ${needle}" ;;
  esac
}

assert_no_create_residue() {
  local temp_saves

  [ ! -e "${state_dir}/saves/martins-server.zip" ] && [ ! -L "${state_dir}/saves/martins-server.zip" ] ||
    fail "failed or interrupted create left the final save"
  shopt -s nullglob
  temp_saves=("${state_dir}/saves/"*.tmp.zip)
  shopt -u nullglob
  [ "${#temp_saves[@]}" -eq 0 ] || fail "failed or interrupted create left a temporary save"
}

assert_only_atomic_final() {
  local save_entries

  shopt -s nullglob
  save_entries=("${state_dir}/saves/"*)
  shopt -u nullglob
  [ "${#save_entries[@]}" -eq 1 ] || fail "successful create did not leave exactly one save entry"
  [ "${save_entries[0]}" = "${state_dir}/saves/martins-server.zip" ] || fail "successful create left a non-final save entry"
  [ -f "${save_entries[0]}" ] && [ ! -L "${save_entries[0]}" ] || fail "final save is not a regular non-symlink file"
}

test_partial_create_failure_and_restart() {
  local status

  reset_fixture partial
  factorio_mode="fail-partial"
  create_status="42"
  if run_startup 2.0.77; then
    status=0
  else
    status=$?
  fi
  [ "${status}" -eq 42 ] || fail "create failure status was ${status}, expected exact child status 42"
  assert_no_create_residue

  factorio_mode="success"
  : >"${log_file}"
  run_startup 2.0.77
  assert_only_atomic_final
  [ "$(line_count "${log_file}")" -eq 2 ] || fail "restart after create failure did not create and load a fresh save"
}

test_term_forwarding_reaping_and_restart() {
  local child_parent_pid
  local status
  local stopped_wrapper_pid

  reset_fixture term
  factorio_mode="block-create"
  mkfifo "${block_fifo}"
  signal_release_file="${release_file}"
  start_startup 2.0.77

  wait_for_file "${ready_file}" || fail "blocked create child did not publish readiness"
  read -r child_pid child_parent_pid <"${pid_file}" || fail "blocked create child PID file was incomplete"
  [[ "${child_pid}" =~ ^[0-9]+$ ]] || fail "blocked create child PID was invalid"
  [ "${child_parent_pid}" = "${wrapper_pid}" ] || fail "blocked create was not a direct child of the wrapper"

  kill -TERM "${wrapper_pid}"
  wait_for_file "${term_file}" || fail "TERM sent to wrapper was not forwarded to the blocked create child"
  process_is_running "${wrapper_pid}" || fail "wrapper exited before reaping the TERM-blocked create child"

  : >"${release_file}"
  wait_for_process_stop "${wrapper_pid}" || fail "wrapper did not exit after the create child handled TERM"
  stopped_wrapper_pid="${wrapper_pid}"
  if wait "${stopped_wrapper_pid}"; then
    status=0
  else
    status=$?
  fi
  wrapper_pid=""
  [ "${status}" -eq 143 ] || fail "TERM-interrupted wrapper exited ${status}, expected 143"
  wait_for_process_absence "${child_pid}" || fail "TERM-interrupted create child was not reaped"
  child_pid=""
  signal_release_file=""
  assert_no_create_residue

  factorio_mode="success"
  : >"${log_file}"
  run_startup 2.0.77
  assert_only_atomic_final
  [ "$(line_count "${log_file}")" -eq 2 ] || fail "restart after TERM did not create and load a fresh save"
}

test_term_at_create_completion_boundary_and_restart() {
  local boundary_evidence
  local publication
  local status

  reset_fixture term-boundary
  startup_bash_env="${tmpdir}/term-boundary-bash-env.sh"
  boundary_marker="${tmpdir}/term-boundary.marker"
  cat >"${startup_bash_env}" <<'EOF'
if [[ -z "${FACTORIO_TEST_DEBUG_OWNER_BASHPID:-}" ]]; then
  export FACTORIO_TEST_DEBUG_OWNER_BASHPID="${BASHPID}"
  trap '
    if [[ "${BASH_COMMAND}" == "trap - TERM INT" ]] && [[ ! -e "${FACTORIO_TEST_BOUNDARY_MARKER:?}" ]]; then
      printf "owner=%s command=trap - TERM INT\n" "${BASHPID}" >"${FACTORIO_TEST_BOUNDARY_MARKER}"
      kill -TERM "${BASHPID}"
    fi
  ' DEBUG
fi
EOF

  if run_startup 2.0.77; then
    status=0
  else
    status=$?
  fi

  [ -f "${boundary_marker}" ] || fail "completion-boundary TERM injection did not reach trap clearing"
  boundary_evidence="$(<"${boundary_marker}")"
  [[ "${boundary_evidence}" =~ ^owner=[0-9]+\ command=trap\ -\ TERM\ INT$ ]] ||
    fail "completion-boundary TERM injection marker was malformed: ${boundary_evidence}"

  publication="absent"
  if [ -e "${state_dir}/saves/martins-server.zip" ] || [ -L "${state_dir}/saves/martins-server.zip" ]; then
    publication="present"
  fi
  [ "${status}" -eq 143 ] ||
    fail "completion-boundary TERM exited ${status} with final save ${publication}; expected 143 with final save absent; ${boundary_evidence}"
  assert_no_create_residue

  startup_bash_env=""
  boundary_marker=""
  : >"${log_file}"
  run_startup 2.0.77
  assert_only_atomic_final
  [ "$(line_count "${log_file}")" -eq 2 ] || fail "restart after completion-boundary TERM did not create and load a fresh save"
}

test_nonregular_zip_entries_are_not_saves() {
  local symlink_target

  reset_fixture nonregular
  mkdir "${state_dir}/saves/directory.zip"
  symlink_target="${tmpdir}/nonregular-target"
  printf 'preserve-target\n' >"${symlink_target}"
  ln -s "${symlink_target}" "${state_dir}/saves/symlink.zip"

  run_startup 2.0.77
  [ -f "${state_dir}/saves/martins-server.zip" ] && [ ! -L "${state_dir}/saves/martins-server.zip" ] ||
    fail "directory or symlink *.zip entry suppressed initial save creation"
  [ -d "${state_dir}/saves/directory.zip" ] || fail "non-save *.zip directory was not preserved"
  [ -L "${state_dir}/saves/symlink.zip" ] || fail "non-save *.zip symlink was not preserved"
  [ "$(<"${symlink_target}")" = "preserve-target" ] || fail "non-save symlink target was modified"
  [ "$(line_count "${log_file}")" -eq 2 ] || fail "non-regular *.zip entries were treated as existing saves"
}

test_successful_create_is_atomic() {
  local first_invocation

  reset_fixture atomic
  run_startup 2.0.77
  IFS= read -r first_invocation <"${log_file}" || fail "fresh create invocation was not logged"
  case "${first_invocation}" in
    *"--create ${state_dir}/saves/"*.tmp.zip\ *) ;;
    *) fail "fresh create did not target a direct-child *.tmp.zip file" ;;
  esac
  case "${first_invocation}" in
    *"--create ${state_dir}/saves/martins-server.zip"*) fail "fresh create wrote directly to the final save" ;;
  esac
  assert_only_atomic_final
  [ "$(<"${state_dir}/saves/martins-server.zip")" = "fresh-save" ] || fail "atomically published save content was incorrect"
}

test_existing_same_version_and_pre_upgrade_behavior() {
  local first_invocation
  local before_backup
  local backup_glob
  local backup_dirs

  reset_fixture existing
  printf 'incomplete-save\n' >"${state_dir}/saves/orphan.tmp.zip"
  printf 'preserve-me\n' >"${state_dir}/saves/not-a-save.tmp"

  run_startup 2.0.77
  [ ! -e "${state_dir}/saves/orphan.tmp.zip" ] || fail "stale temporary save was not removed before save discovery"
  [ "$(<"${state_dir}/saves/not-a-save.tmp")" = "preserve-me" ] || fail "startup cleanup removed a non-*.tmp.zip file"
  [ "$(line_count "${log_file}")" -eq 2 ] || fail "fresh startup must create and then load one save"
  [ "$(<"${state_dir}/.last-started-version")" = "2.0.77" ] || fail "fresh startup version marker missing"
  [ -f "${state_dir}/saves/martins-server.zip" ] || fail "default Freeplay save was not created"
  IFS= read -r first_invocation <"${log_file}" || fail "fresh create invocation was not logged"
  case "${first_invocation}" in
    *"--map-gen-settings ${runtime_dir}/map-gen-settings.json"*) ;;
    *) fail "fresh create invocation missing explicit map-gen settings" ;;
  esac
  case "${first_invocation}" in
    *"--map-settings ${runtime_dir}/map-settings.json"*) ;;
    *) fail "fresh create invocation missing explicit map settings" ;;
  esac
  assert_log_contains "--create"
  assert_log_contains "--start-server-load-latest"
  assert_log_contains "--use-server-whitelist"
  assert_log_contains "--server-adminlist"
  assert_log_contains "--mod-directory"
  case "$(<"${log_file}")" in
    *rcon* | *RCON*) fail "RCON appeared in Factorio invocation" ;;
  esac
  for config in config.ini map-gen-settings.json map-settings.json mod-list.json server-adminlist.json server-settings.json server-whitelist.json; do
    [ -f "${runtime_dir}/${config}" ] || fail "runtime config ${config} was not copied"
  done

  : >"${log_file}"
  run_startup 2.0.77
  [ "$(line_count "${log_file}")" -eq 1 ] || fail "same-version restart must only load the existing save"
  backup_glob=("${state_dir}"/pre-upgrade/*)
  [ ! -e "${backup_glob[0]}" ] || fail "same-version restart created an upgrade backup"

  printf 'save-before-upgrade\n' >"${state_dir}/saves/martins-server.zip"
  : >"${log_file}"
  run_startup 2.0.78
  [ "$(line_count "${log_file}")" -eq 1 ] || fail "upgrade startup must not regenerate the world"
  [ "$(<"${state_dir}/.last-started-version")" = "2.0.78" ] || fail "upgrade version marker was not advanced"
  backup_dirs=("${state_dir}"/pre-upgrade/from-2.0.77-to-2.0.78-*)
  [ "${#backup_dirs[@]}" -eq 1 ] && [ -d "${backup_dirs[0]}" ] || fail "version-bound pre-upgrade backup missing"
  [ "$(<"${backup_dirs[0]}/martins-server.zip")" = "save-before-upgrade" ] || fail "pre-upgrade save copy is incorrect"
  [ -f "${backup_dirs[0]}/backup-metadata.txt" ] || fail "pre-upgrade metadata missing"

  before_backup="${backup_dirs[0]}"
  : >"${log_file}"
  run_startup 2.0.78
  backup_dirs=("${state_dir}"/pre-upgrade/from-2.0.77-to-2.0.78-*)
  [ "${#backup_dirs[@]}" -eq 1 ] && [ "${backup_dirs[0]}" = "${before_backup}" ] || fail "same-version restart duplicated the upgrade backup"
}

run_case() {
  local name="$1"
  local test_function="$2"

  "${test_function}"
  printf 'PASS: %s\n' "${name}"
}

case "${1:-all}" in
  partial)
    run_case "partial create failure cleanup and restart" test_partial_create_failure_and_restart
    ;;
  term)
    run_case "TERM forwarding, reaping, cleanup, and restart" test_term_forwarding_reaping_and_restart
    ;;
  boundary)
    run_case "TERM at create completion boundary is observed" test_term_at_create_completion_boundary_and_restart
    ;;
  nonregular)
    run_case "non-regular zip entries are not saves" test_nonregular_zip_entries_are_not_saves
    ;;
  atomic)
    run_case "successful initial create is atomic" test_successful_create_is_atomic
    ;;
  existing)
    run_case "same-version and pre-upgrade behavior" test_existing_same_version_and_pre_upgrade_behavior
    ;;
  all)
    run_case "partial create failure cleanup and restart" test_partial_create_failure_and_restart
    run_case "TERM forwarding, reaping, cleanup, and restart" test_term_forwarding_reaping_and_restart
    run_case "TERM at create completion boundary is observed" test_term_at_create_completion_boundary_and_restart
    run_case "non-regular zip entries are not saves" test_nonregular_zip_entries_are_not_saves
    run_case "successful initial create is atomic" test_successful_create_is_atomic
    run_case "same-version and pre-upgrade behavior" test_existing_same_version_and_pre_upgrade_behavior
    ;;
  *)
    fail "unknown startup test case: $1"
    ;;
esac

printf 'Factorio startup wrapper tests passed\n'
