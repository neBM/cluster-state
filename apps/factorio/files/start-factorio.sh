#!/usr/bin/env bash

set -euo pipefail

FACTORIO_BIN="${FACTORIO_BIN:-/opt/factorio/bin/x64/factorio}"
STATE_DIR="${FACTORIO_STATE_DIR:-/factorio}"
RUNTIME_DIR="${FACTORIO_RUNTIME_DIR:-/runtime}"
CONFIG_SOURCE_DIR="${FACTORIO_CONFIG_SOURCE_DIR:-/config}"
CURRENT_VERSION="${VERSION:?VERSION must be set}"
SAVES_DIR="${STATE_DIR}/saves"
PRE_UPGRADE_DIR="${STATE_DIR}/pre-upgrade"
VERSION_MARKER="${STATE_DIR}/.last-started-version"

mkdir -p "${STATE_DIR}" "${SAVES_DIR}" "${PRE_UPGRADE_DIR}" "${RUNTIME_DIR}"

for config_name in \
  config.ini \
  map-gen-settings.json \
  map-settings.json \
  mod-list.json \
  server-adminlist.json \
  server-settings.json \
  server-whitelist.json; do
  cp -- "${CONFIG_SOURCE_DIR}/${config_name}" "${RUNTIME_DIR}/${config_name}"
  chmod 0644 "${RUNTIME_DIR}/${config_name}"
done

shopt -s nullglob
stale_temp_save_candidates=("${SAVES_DIR}"/*.tmp.zip)
for stale_temp_save_candidate in "${stale_temp_save_candidates[@]}"; do
  if [[ -f "${stale_temp_save_candidate}" ]] && [[ ! -L "${stale_temp_save_candidate}" ]]; then
    rm -- "${stale_temp_save_candidate}"
  fi
done
save_candidates=("${SAVES_DIR}"/*.zip)
shopt -u nullglob

save_files=()
for save_candidate in "${save_candidates[@]}"; do
  if [[ "${save_candidate}" == *.tmp.zip ]]; then
    continue
  fi
  if [[ -f "${save_candidate}" ]] && [[ ! -L "${save_candidate}" ]]; then
    save_files+=("${save_candidate}")
  fi
done

has_saves=false
if ((${#save_files[@]})); then
  has_saves=true
fi

last_started_version=""
if [[ -f "${VERSION_MARKER}" ]]; then
  last_started_version="$(<"${VERSION_MARKER}")"
fi

if ${has_saves} && [[ -n "${last_started_version}" ]] && [[ "${last_started_version}" != "${CURRENT_VERSION}" ]]; then
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
    if [[ -f "${save_file}" ]]; then
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

if ! ${has_saves}; then
  final_save="${SAVES_DIR}/martins-server.zip"
  if [[ -e "${final_save}" ]] || [[ -L "${final_save}" ]]; then
    printf 'Cannot create initial save: final target already exists: %s\n' "${final_save}" >&2
    exit 1
  fi

  initial_save_temp="$(mktemp "${SAVES_DIR}/martins-server.XXXXXXXX.tmp.zip")"
  rm -- "${initial_save_temp}"
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
      --config "${RUNTIME_DIR}/config.ini" \
      --mod-directory "${RUNTIME_DIR}" \
      --map-gen-settings "${RUNTIME_DIR}/map-gen-settings.json" \
      --map-settings "${RUNTIME_DIR}/map-settings.json" \
      --create "${initial_save_temp}" &
    create_pid=$!
  fi

  if ((create_signal_status != 0)); then
    if [[ -n "${create_pid}" ]]; then
      kill -s "${create_signal_name}" "${create_pid}" 2>/dev/null || true
      wait "${create_pid}" 2>/dev/null || true
    fi
    rm -f -- "${initial_save_temp}" 2>/dev/null || true
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
    rm -f -- "${initial_save_temp}" 2>/dev/null || true
    trap - TERM INT
    exit "${create_signal_status}"
  fi

  if ((create_status != 0)); then
    rm -f -- "${initial_save_temp}" 2>/dev/null || true
    exit "${create_status}"
  fi

  if [[ ! -f "${initial_save_temp}" ]] || [[ -L "${initial_save_temp}" ]]; then
    rm -f -- "${initial_save_temp}" 2>/dev/null || true
    printf 'Initial save creation did not produce a regular temporary save\n' >&2
    exit 1
  fi
  if [[ -e "${final_save}" ]] || [[ -L "${final_save}" ]]; then
    rm -f -- "${initial_save_temp}" 2>/dev/null || true
    printf 'Cannot publish initial save: final target already exists: %s\n' "${final_save}" >&2
    exit 1
  fi
  if mv -T -n -- "${initial_save_temp}" "${final_save}"; then
    :
  else
    move_status=$?
    rm -f -- "${initial_save_temp}" 2>/dev/null || true
    exit "${move_status}"
  fi
  if [[ -e "${initial_save_temp}" ]] || [[ -L "${initial_save_temp}" ]]; then
    rm -f -- "${initial_save_temp}" 2>/dev/null || true
    printf 'Cannot publish initial save without overwriting the final target: %s\n' "${final_save}" >&2
    exit 1
  fi
fi

if [[ "${last_started_version}" != "${CURRENT_VERSION}" ]]; then
  printf '%s\n' "${CURRENT_VERSION}" >"${VERSION_MARKER}.tmp"
  mv -- "${VERSION_MARKER}.tmp" "${VERSION_MARKER}"
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
  --start-server-load-latest
