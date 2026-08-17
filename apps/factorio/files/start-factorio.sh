#!/usr/bin/env bash

set -euo pipefail

FACTORIO_BIN="${FACTORIO_BIN:-/opt/factorio/bin/x64/factorio}"
STATE_DIR="${FACTORIO_STATE_DIR:-/factorio}"
RUNTIME_DIR="${FACTORIO_RUNTIME_DIR:-/runtime}"
CONFIG_SOURCE_DIR="${FACTORIO_CONFIG_SOURCE_DIR:-/config}"
CURRENT_VERSION="${VERSION:?VERSION must be set}"
SAVES_DIR="${STATE_DIR}/saves"
SCENARIOS_DIR="${STATE_DIR}/scenarios"
PRE_UPGRADE_DIR="${STATE_DIR}/pre-upgrade"
VERSION_MARKER="${STATE_DIR}/.last-started-version"
WORLD_MARKER="${STATE_DIR}/.friendly-factories-world"
FINAL_SAVE_NAME="friendly-factories.zip"
FINAL_SAVE="${SAVES_DIR}/${FINAL_SAVE_NAME}"
SCENARIO_NAME="friendly-factories"
CREATION_ROOT_PREFIX=".friendly-factories-create."
LEGACY_SAVE_NAME="martins-server.zip"
LEGACY_VERSION="2.0.77"

required_config_sources=(
  config.ini
  map-gen-settings.json
  map-settings.json
  mod-list.json
  scenario-control.lua
  scenario-description.json
  server-adminlist.json
  server-settings.json
  server-whitelist.json
)
declare -A resolved_config_sources=()

if ! canonical_config_source_dir="$(realpath -e -- "${CONFIG_SOURCE_DIR}")" \
  || [[ ! -d "${canonical_config_source_dir}" ]]; then
  printf 'Config source directory is missing or not a directory: %s\n' "${CONFIG_SOURCE_DIR}" >&2
  exit 1
fi
for config_source_name in "${required_config_sources[@]}"; do
  config_source="${CONFIG_SOURCE_DIR}/${config_source_name}"
  if ! resolved_config_source="$(realpath -e -- "${config_source}")" \
    || [[ ! -f "${resolved_config_source}" ]]; then
    printf 'Config source is missing or not a regular file: %s\n' "${config_source}" >&2
    exit 1
  fi
  if [[ "${canonical_config_source_dir}" != / ]] \
    && [[ "${resolved_config_source}" != "${canonical_config_source_dir}/"* ]]; then
    printf 'Config source escapes config source directory: %s\n' "${config_source}" >&2
    exit 1
  fi
  resolved_config_sources["${config_source_name}"]="${resolved_config_source}"
done

mkdir -p "${STATE_DIR}" "${SAVES_DIR}" "${SCENARIOS_DIR}" "${PRE_UPGRADE_DIR}" "${RUNTIME_DIR}"

for config_name in \
  config.ini \
  map-gen-settings.json \
  map-settings.json \
  mod-list.json \
  server-adminlist.json \
  server-settings.json \
  server-whitelist.json; do
  cp -- "${resolved_config_sources[${config_name}]}" "${RUNTIME_DIR}/${config_name}"
  chmod 0644 "${RUNTIME_DIR}/${config_name}"
done

shopt -s nullglob
stale_temp_save_candidates=("${SAVES_DIR}"/*.tmp.zip)
stale_creation_root_candidates=("${STATE_DIR}/${CREATION_ROOT_PREFIX}"*)
stale_world_marker_candidates=("${WORLD_MARKER}.tmp-"*)
stale_version_marker_candidates=("${VERSION_MARKER}.tmp-"*)
shopt -u nullglob
if [[ -e "${VERSION_MARKER}.tmp" ]] || [[ -L "${VERSION_MARKER}.tmp" ]]; then
  stale_version_marker_candidates+=("${VERSION_MARKER}.tmp")
fi
for stale_temp_save_candidate in "${stale_temp_save_candidates[@]}"; do
  if [[ -f "${stale_temp_save_candidate}" ]] && [[ ! -L "${stale_temp_save_candidate}" ]]; then
    rm -- "${stale_temp_save_candidate}"
  fi
done
for stale_creation_root_candidate in "${stale_creation_root_candidates[@]}"; do
  if [[ ! -d "${stale_creation_root_candidate}" ]] || [[ -L "${stale_creation_root_candidate}" ]]; then
    printf 'Refusing to remove non-directory isolated creation state: %s\n' "${stale_creation_root_candidate}" >&2
    exit 1
  fi
  rm -rf -- "${stale_creation_root_candidate}"
done
for stale_world_marker_candidate in "${stale_world_marker_candidates[@]}"; do
  if [[ ! -f "${stale_world_marker_candidate}" ]] || [[ -L "${stale_world_marker_candidate}" ]]; then
    printf 'Refusing malformed stale world marker temporary: %s\n' "${stale_world_marker_candidate}" >&2
    exit 1
  fi
  rm -- "${stale_world_marker_candidate}"
done
for stale_version_marker_candidate in "${stale_version_marker_candidates[@]}"; do
  if [[ ! -f "${stale_version_marker_candidate}" ]] || [[ -L "${stale_version_marker_candidate}" ]]; then
    printf 'Refusing malformed stale version marker temporary: %s\n' "${stale_version_marker_candidate}" >&2
    exit 1
  fi
  rm -- "${stale_version_marker_candidate}"
done

shopt -s nullglob
save_candidates=("${SAVES_DIR}"/*.zip)
shopt -u nullglob
save_files=()
primary_save_files=()
autosave_files=()
for save_candidate in "${save_candidates[@]}"; do
  if [[ "${save_candidate}" == *.tmp.zip ]]; then
    continue
  fi
  if [[ -f "${save_candidate}" ]] && [[ ! -L "${save_candidate}" ]]; then
    save_files+=("${save_candidate}")
    save_basename="${save_candidate##*/}"
    if [[ "${save_basename}" =~ ^_autosave[0-9]+\.zip$ ]]; then
      autosave_files+=("${save_candidate}")
    else
      primary_save_files+=("${save_candidate}")
    fi
  fi
done

last_started_version=""
if [[ -f "${VERSION_MARKER}" ]] && [[ ! -L "${VERSION_MARKER}" ]]; then
  last_started_version="$(<"${VERSION_MARKER}")"
fi

world_marker_present=false
if [[ -e "${WORLD_MARKER}" ]] || [[ -L "${WORLD_MARKER}" ]]; then
  if [[ ! -f "${WORLD_MARKER}" ]] || [[ -L "${WORLD_MARKER}" ]]; then
    printf 'Friendly factories world marker is not a regular file: %s\n' "${WORLD_MARKER}" >&2
    exit 1
  fi
  if [[ "$(<"${WORLD_MARKER}")" != "${FINAL_SAVE_NAME}" ]]; then
    printf 'Friendly factories world marker has unexpected content\n' >&2
    exit 1
  fi
  world_marker_present=true
fi

create_scenario=false
has_existing_scenario=false
if ${world_marker_present}; then
  if ((${#primary_save_files[@]} != 1)) || [[ "${primary_save_files[0]:-}" != "${FINAL_SAVE}" ]]; then
    printf 'Refusing startup: migrated state must contain exactly %s plus optional Factorio autosaves\n' "${FINAL_SAVE_NAME}" >&2
    exit 1
  fi
  has_existing_scenario=true
else
  if ((${#autosave_files[@]})); then
    printf 'Refusing one-time replacement: unmarked state contains autosaves\n' >&2
    exit 1
  fi
  case "${#primary_save_files[@]}" in
    0)
      create_scenario=true
      ;;
    1)
      if [[ "${primary_save_files[0]}" == "${FINAL_SAVE}" ]]; then
        has_existing_scenario=true
      elif [[ "${primary_save_files[0]##*/}" == "${LEGACY_SAVE_NAME}" ]] \
        && [[ "${last_started_version}" == "${LEGACY_VERSION}" ]] \
        && [[ "${CURRENT_VERSION}" == "${LEGACY_VERSION}" ]]; then
        printf 'Replacing explicitly approved unused legacy world %s at Factorio %s\n' "${LEGACY_SAVE_NAME}" "${LEGACY_VERSION}"
        rm -- "${primary_save_files[0]}"
        save_files=()
        primary_save_files=()
        create_scenario=true
      else
        printf 'Refusing one-time replacement: unexpected unmarked primary save %s or version %s\n' \
          "${primary_save_files[0]##*/}" "${last_started_version:-missing}" >&2
        exit 1
      fi
      ;;
    *)
      printf 'Refusing one-time replacement: found %s unmarked primary saves\n' "${#primary_save_files[@]}" >&2
      exit 1
      ;;
  esac
fi

if ${has_existing_scenario} && [[ -n "${last_started_version}" ]] && [[ "${last_started_version}" != "${CURRENT_VERSION}" ]]; then
  safe_previous_version="${last_started_version//[^[:alnum:]._-]/_}"
  safe_current_version="${CURRENT_VERSION//[^[:alnum:]._-]/_}"
  backup_timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_name="from-${safe_previous_version}-to-${safe_current_version}-${backup_timestamp}"
  backup_dir="${PRE_UPGRADE_DIR}/${backup_name}"
  backup_staging_dir="${PRE_UPGRADE_DIR}/.${backup_name}.tmp-$$"

  if [[ -e "${backup_dir}" ]]; then
    backup_dir="${backup_dir}-$$"
  fi
  mkdir "${backup_staging_dir}"
  for save_file in "${save_files[@]}"; do
    if [[ -f "${save_file}" ]] && [[ ! -L "${save_file}" ]]; then
      cp -- "${save_file}" "${backup_staging_dir}/"
    fi
  done
  {
    printf 'previous-version=%s\n' "${last_started_version}"
    printf 'new-version=%s\n' "${CURRENT_VERSION}"
    printf 'created-utc=%s\n' "${backup_timestamp}"
  } >"${backup_staging_dir}/backup-metadata.txt"
  mv -- "${backup_staging_dir}" "${backup_dir}"
fi

if ${create_scenario}; then
  if [[ -e "${FINAL_SAVE}" ]] || [[ -L "${FINAL_SAVE}" ]]; then
    printf 'Cannot create initial scenario: final target already exists: %s\n' "${FINAL_SAVE}" >&2
    exit 1
  fi

  expected_config_lines=(
    '[path]'
    'read-data=/opt/factorio/data'
    'write-data=/factorio'
    ''
    '[other]'
    'autosave-interval=10'
    'autosave-slots=12'
    'check-updates=false'
    'enable-experimental-updates=false'
    'enable-new-mods=false'
  )
  source_config_lines=()
  mapfile -t source_config_lines <"${resolved_config_sources[config.ini]}"
  if ((${#source_config_lines[@]} != ${#expected_config_lines[@]})); then
    printf 'Factorio config source does not have the expected exact shape\n' >&2
    exit 1
  fi
  for ((config_index = 0; config_index < ${#expected_config_lines[@]}; config_index++)); do
    if [[ "${source_config_lines[config_index]}" != "${expected_config_lines[config_index]}" ]]; then
      printf 'Factorio config source does not have the expected exact shape\n' >&2
      exit 1
    fi
  done

  creation_root=""
  cleanup_create_artifacts() {
    if [[ -n "${creation_root}" ]]; then
      rm -rf -- "${creation_root}" 2>/dev/null || true
    fi
  }
  trap cleanup_create_artifacts EXIT

  creation_root="$(mktemp -d "${STATE_DIR}/${CREATION_ROOT_PREFIX}XXXXXXXX")"
  creation_saves_dir="${creation_root}/saves"
  scenario_dir="${creation_root}/scenarios/${SCENARIO_NAME}"
  conversion_config="${creation_root}/config.ini"
  initial_save_temp="${creation_saves_dir}/${FINAL_SAVE_NAME}"
  mkdir -p "${creation_saves_dir}" "${scenario_dir}"
  cp -- "${resolved_config_sources[scenario-control.lua]}" "${scenario_dir}/control.lua"
  cp -- "${resolved_config_sources[scenario-description.json]}" "${scenario_dir}/description.json"
  chmod 0644 "${scenario_dir}/control.lua" "${scenario_dir}/description.json"
  {
    printf '[path]\n'
    printf 'read-data=/opt/factorio/data\n'
    printf 'write-data=%s\n' "${creation_root}"
    printf '\n[other]\n'
    printf 'autosave-interval=10\n'
    printf 'autosave-slots=12\n'
    printf 'check-updates=false\n'
    printf 'enable-experimental-updates=false\n'
    printf 'enable-new-mods=false\n'
  } >"${conversion_config}"
  chmod 0600 "${conversion_config}"

  create_pid=""
  create_signal_name=""
  create_signal_status=0

  forward_create_signal() {
    if ((create_signal_status == 0)); then
      create_signal_name="$1"
      create_signal_status="$2"
    fi
    if [[ -n "${create_pid}" ]]; then
      kill -s "${create_signal_name}" "${create_pid}" 2>/dev/null || true
    fi
  }

  trap 'forward_create_signal TERM 143' TERM
  trap 'forward_create_signal INT 130' INT

  if ((create_signal_status == 0)); then
    "${FACTORIO_BIN}" \
      --config "${conversion_config}" \
      --mod-directory "${RUNTIME_DIR}" \
      --map-gen-settings "${RUNTIME_DIR}/map-gen-settings.json" \
      --map-settings "${RUNTIME_DIR}/map-settings.json" \
      --scenario2map "${SCENARIO_NAME}" &
    create_pid=$!
  fi

  if ((create_signal_status != 0)); then
    if [[ -n "${create_pid}" ]]; then
      kill -s "${create_signal_name}" "${create_pid}" 2>/dev/null || true
      wait "${create_pid}" 2>/dev/null || true
    fi
    cleanup_create_artifacts
    trap - TERM INT
    exit "${create_signal_status}"
  fi

  if wait "${create_pid}"; then
    create_status=0
  else
    create_status=$?
  fi

  if ((create_signal_status == 0)); then
    trap - TERM INT
  fi

  if ((create_signal_status != 0)); then
    wait "${create_pid}" 2>/dev/null || true
    cleanup_create_artifacts
    trap - TERM INT
    exit "${create_signal_status}"
  fi

  if ((create_status != 0)); then
    cleanup_create_artifacts
    exit "${create_status}"
  fi

  if [[ ! -f "${initial_save_temp}" ]] || [[ -L "${initial_save_temp}" ]]; then
    cleanup_create_artifacts
    printf 'Scenario conversion did not produce a regular temporary save\n' >&2
    exit 1
  fi
  if [[ -e "${FINAL_SAVE}" ]] || [[ -L "${FINAL_SAVE}" ]]; then
    cleanup_create_artifacts
    printf 'Cannot publish initial scenario: final target already exists: %s\n' "${FINAL_SAVE}" >&2
    exit 1
  fi
  if mv -T -n -- "${initial_save_temp}" "${FINAL_SAVE}"; then
    :
  else
    move_status=$?
    cleanup_create_artifacts
    exit "${move_status}"
  fi
  if [[ -e "${initial_save_temp}" ]] || [[ -L "${initial_save_temp}" ]]; then
    cleanup_create_artifacts
    printf 'Cannot publish initial scenario without overwriting the final target: %s\n' "${FINAL_SAVE}" >&2
    exit 1
  fi
  cleanup_create_artifacts
  trap - EXIT
  has_existing_scenario=true
fi

if [[ ! -f "${FINAL_SAVE}" ]] || [[ -L "${FINAL_SAVE}" ]]; then
  printf 'Deterministic scenario save is missing or not regular: %s\n' "${FINAL_SAVE}" >&2
  exit 1
fi

if ! ${world_marker_present}; then
  world_marker_temp=""
  cleanup_world_marker_temp() {
    if [[ -n "${world_marker_temp}" ]]; then
      rm -f -- "${world_marker_temp}" 2>/dev/null || true
    fi
  }
  trap cleanup_world_marker_temp EXIT

  world_marker_temp="$(umask 077 && mktemp "${WORLD_MARKER}.tmp-XXXXXXXX")"
  if [[ ! -f "${world_marker_temp}" ]] || [[ -L "${world_marker_temp}" ]]; then
    printf 'Cannot publish friendly factories world marker: temporary is not a regular file\n' >&2
    exit 1
  fi
  if ! printf '%s\n' "${FINAL_SAVE_NAME}" >"${world_marker_temp}"; then
    printf 'Cannot write friendly factories world marker temporary\n' >&2
    exit 1
  fi
  if [[ ! -f "${world_marker_temp}" ]] || [[ -L "${world_marker_temp}" ]] \
    || [[ "$(<"${world_marker_temp}")" != "${FINAL_SAVE_NAME}" ]] \
    || [[ "$(wc -c <"${world_marker_temp}")" -ne "$(printf '%s\n' "${FINAL_SAVE_NAME}" | wc -c)" ]]; then
    printf 'Cannot publish friendly factories world marker: temporary content is invalid\n' >&2
    exit 1
  fi
  if mv -T -n -- "${world_marker_temp}" "${WORLD_MARKER}"; then
    :
  else
    move_status=$?
    exit "${move_status}"
  fi
  if [[ -e "${world_marker_temp}" ]] || [[ -L "${world_marker_temp}" ]]; then
    printf 'Cannot publish friendly factories world marker without overwriting the final target\n' >&2
    exit 1
  fi
  world_marker_temp=""
  if [[ ! -f "${WORLD_MARKER}" ]] || [[ -L "${WORLD_MARKER}" ]] \
    || [[ "$(<"${WORLD_MARKER}")" != "${FINAL_SAVE_NAME}" ]] \
    || [[ "$(wc -c <"${WORLD_MARKER}")" -ne "$(printf '%s\n' "${FINAL_SAVE_NAME}" | wc -c)" ]]; then
    printf 'Cannot publish friendly factories world marker: final content is invalid\n' >&2
    exit 1
  fi
  trap - EXIT
fi

if [[ "${last_started_version}" != "${CURRENT_VERSION}" ]]; then
  version_marker_temp=""
  cleanup_version_marker_temp() {
    if [[ -n "${version_marker_temp}" ]]; then
      rm -f -- "${version_marker_temp}" 2>/dev/null || true
    fi
  }
  trap cleanup_version_marker_temp EXIT

  version_marker_temp="$(umask 077 && mktemp "${VERSION_MARKER}.tmp-XXXXXXXX")"
  if [[ ! -f "${version_marker_temp}" ]] || [[ -L "${version_marker_temp}" ]]; then
    printf 'Cannot publish Factorio version marker: temporary is not a regular file\n' >&2
    exit 1
  fi
  if ! printf '%s\n' "${CURRENT_VERSION}" >"${version_marker_temp}"; then
    printf 'Cannot write Factorio version marker temporary\n' >&2
    exit 1
  fi
  if [[ ! -f "${version_marker_temp}" ]] || [[ -L "${version_marker_temp}" ]] \
    || [[ "$(<"${version_marker_temp}")" != "${CURRENT_VERSION}" ]] \
    || [[ "$(wc -c <"${version_marker_temp}")" -ne "$(printf '%s\n' "${CURRENT_VERSION}" | wc -c)" ]]; then
    printf 'Cannot publish Factorio version marker: temporary content is invalid\n' >&2
    exit 1
  fi
  mv -T -- "${version_marker_temp}" "${VERSION_MARKER}"
  version_marker_temp=""
  if [[ ! -f "${VERSION_MARKER}" ]] || [[ -L "${VERSION_MARKER}" ]] \
    || [[ "$(<"${VERSION_MARKER}")" != "${CURRENT_VERSION}" ]] \
    || [[ "$(wc -c <"${VERSION_MARKER}")" -ne "$(printf '%s\n' "${CURRENT_VERSION}" | wc -c)" ]]; then
    printf 'Cannot publish Factorio version marker: final content is invalid\n' >&2
    exit 1
  fi
  trap - EXIT
fi

exec "${FACTORIO_BIN}" \
  --config "${RUNTIME_DIR}/config.ini" \
  --mod-directory "${RUNTIME_DIR}" \
  --server-settings "${RUNTIME_DIR}/server-settings.json" \
  --server-whitelist "${RUNTIME_DIR}/server-whitelist.json" \
  --use-server-whitelist \
  --server-adminlist "${RUNTIME_DIR}/server-adminlist.json" \
  --server-id "${STATE_DIR}/server-id.json" \
  --port 34197 \
  --start-server "${FINAL_SAVE}"
