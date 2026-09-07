#!/usr/bin/env bash

set -euo pipefail
umask 077

host_key=/run/secrets/hermes-workspace/ssh_host_ed25519_key
authorized_keys=/run/secrets/hermes-workspace/authorized_keys
secret_root=/run/secrets/hermes-workspace

fail() {
  printf 'hermes-workspace: %s\n' "$*" >&2
  exit 1
}

require_read_only_secret_file() {
  local path="$1"
  local label="$2"
  local resolved options owner group mode numeric_mode

  [[ -f "$path" ]] || fail "$label is missing or is not a regular file: $path"
  resolved="$(readlink -f -- "$path")"
  [[ "$resolved" == "$secret_root"/* ]] || fail "$label resolves outside $secret_root"

  options="$(findmnt --target "$path" --noheadings --output OPTIONS)"
  [[ ",$options," == *,ro,* ]] || fail "$label must be supplied by a read-only mount"

  IFS=: read -r owner group mode < <(stat -Lc '%u:%g:%a' -- "$path")
  [[ "$owner" == 0 && "$group" == 0 ]] || fail "$label must be owned by root:root"
  numeric_mode=$((8#$mode))
  (( (numeric_mode & 022) == 0 )) || fail "$label must not be writable by group or other"
  (( (numeric_mode & 0111) == 0 )) || fail "$label must not be executable"
}

validate_workspace() {
  local owner group mode numeric_mode

  [[ -d /workspace && ! -L /workspace ]] || fail "/workspace must be a directory, not a symlink"
  IFS=: read -r owner group mode < <(stat -Lc '%u:%g:%a' -- /workspace)
  if (( owner != 10000 || group != 10000 )); then
    fail "/workspace must be owned by UID/GID 10000:10000"
  fi
  numeric_mode=$((8#$mode))
  (( (numeric_mode & 077) == 0 )) || fail "/workspace must not grant group or other access"
  (( (numeric_mode & 0700) == 0700 )) || fail "/workspace owner requires rwx permissions"
  runuser -u workspace -- test -w /workspace || fail "/workspace is not writable by UID 10000"
}

validate_writable_runtime_paths() {
  local owner group mode numeric_mode

  [[ -d /run && -w /run ]] || fail "/run must be a writable runtime volume"
  IFS=: read -r owner group mode < <(stat -Lc '%u:%g:%a' -- /run)
  numeric_mode=$((8#$mode))
  if [[ "$owner" != 0 || "$group" != 0 ]] || (( (numeric_mode & 022) != 0 )); then
    fail "/run must be root-owned and not group/other writable"
  fi
  install -d -o 0 -g 0 -m 0755 /run/sshd

  [[ -d /tmp && ! -L /tmp ]] || fail "/tmp must be a writable directory, not a symlink"
  IFS=: read -r owner group mode < <(stat -Lc '%u:%g:%a' -- /tmp)
  [[ "$owner" == 0 && "$group" == 0 && "$mode" == 1777 ]] \
    || fail "/tmp must be root:root mode 1777"
  runuser -u workspace -- test -w /tmp || fail "/tmp is not writable by UID 10000"
}

validate_authorized_keys() {
  local line key_count=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    printf '%s\n' "$line" | ssh-keygen -l -f /dev/stdin >/dev/null 2>&1 \
      || fail "authorized_keys contains an invalid public key"
    ((key_count += 1))
  done < "$authorized_keys"
  (( key_count == 0 )) && fail "authorized_keys contains no public keys"
}

(($# == 0)) || fail "entrypoint arguments are not supported"
[[ "$(id -u)" == 0 ]] || fail "sshd must start as root so it can drop sessions to UID 10000"
[[ "$(id -u workspace)" == 10000 && "$(id -g workspace)" == 10000 ]] \
  || fail "workspace account identity is not UID/GID 10000:10000"
shadow_entry="$(getent shadow workspace)" || fail "workspace shadow entry is missing"
IFS=: read -r _ shadow_password _ <<< "$shadow_entry"
[[ "$shadow_password" == '*' ]] || fail "workspace account must have no usable password"

validate_writable_runtime_paths
validate_workspace
require_read_only_secret_file "$host_key" "SSH host key"
require_read_only_secret_file "$authorized_keys" "authorized_keys"

IFS=: read -r _host_owner _host_group host_mode < <(stat -Lc '%u:%g:%a' -- "$host_key")
[[ "$host_mode" == 400 || "$host_mode" == 600 ]] \
  || fail "SSH host key must be mode 0400 or 0600"
validate_authorized_keys

/usr/sbin/sshd -t -f /etc/ssh/sshd_config
exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config
