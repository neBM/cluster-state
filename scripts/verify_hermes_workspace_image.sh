#!/usr/bin/env bash

set -euo pipefail

if (( $# != 3 )); then
  printf 'usage: %s IMAGE ARCH OCI_REVISION\n' "$0" >&2
  exit 2
fi

image="$1"
expected_arch="$2"
expected_revision="$3"

case "${expected_arch}" in
  amd64 | arm64)
    ;;
  *)
    printf 'unsupported architecture: %s\n' "${expected_arch}" >&2
    exit 2
    ;;
esac

container=""
rootfs=""
cleanup() {
  set +e
  if [[ -n "${rootfs}" && -n "${container}" ]]; then
    buildah umount "${container}" >/dev/null
  fi
  if [[ -n "${container}" ]]; then
    buildah rm "${container}" >/dev/null
  fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

test "$(buildah inspect --type image --format '{{.Docker.OS}}' "${image}")" = linux
test "$(buildah inspect --type image --format '{{.Docker.Architecture}}' "${image}")" = "${expected_arch}"
test "$(buildah inspect --type image --format '{{index .Docker.Config.Labels "org.opencontainers.image.revision"}}' "${image}")" = "${expected_revision}"
test "$(buildah inspect --type image --format '{{.Docker.Config.User}}' "${image}")" = 0:0
test "$(buildah inspect --type image --format '{{.Docker.Config.WorkingDir}}' "${image}")" = /workspace
test "$(buildah inspect --type image --format '{{len .Docker.Config.Entrypoint}}' "${image}")" -eq 1
test "$(buildah inspect --type image --format '{{index .Docker.Config.Entrypoint 0}}' "${image}")" = /usr/local/sbin/hermes-workspace-entrypoint
test "$(buildah inspect --type image --format '{{len .Docker.Config.ExposedPorts}}' "${image}")" -eq 1
# shellcheck disable=SC2016  # Go-template variables are intentionally literal.
test "$(buildah inspect --type image --format '{{range $port, $_ := .Docker.Config.ExposedPorts}}{{$port}}{{end}}' "${image}")" = 2222/tcp
test "$(buildah inspect --type image --format '{{len .Docker.Config.Healthcheck.Test}}' "${image}")" -eq 2
test "$(buildah inspect --type image --format '{{index .Docker.Config.Healthcheck.Test 0}}' "${image}")" = CMD
test "$(buildah inspect --type image --format '{{index .Docker.Config.Healthcheck.Test 1}}' "${image}")" = /usr/local/bin/hermes-workspace-healthcheck

container="$(buildah from "${image}")"
rootfs="$(buildah mount "${container}")"

host_keys="$(find "${rootfs}/etc/ssh" -maxdepth 1 -name 'ssh_host_*' -print -quit)"
test -z "${host_keys}"
test -x "${rootfs}/usr/bin/ssh"
test -x "${rootfs}/usr/bin/ssh-keygen"
test -x "${rootfs}/usr/sbin/sshd"
test -f "${rootfs}/etc/ssh/sshd_config"
test -x "${rootfs}/usr/local/sbin/hermes-workspace-entrypoint"
test -x "${rootfs}/usr/local/bin/hermes-workspace-healthcheck"
test ! -e "${rootfs}/usr/bin/ssh-keygen.distrib"
test ! -e "${rootfs}/usr/local/sbin/ssh-keygen"

diversion="$(buildah run "${container}" -- dpkg-divert --list /usr/bin/ssh-keygen)"
test -z "${diversion}"
test "$(buildah run "${container}" -- dpkg-query --search /usr/bin/ssh)" = "openssh-client: /usr/bin/ssh"
test "$(buildah run "${container}" -- dpkg-query --search /usr/bin/ssh-keygen)" = "openssh-client: /usr/bin/ssh-keygen"
test "$(buildah run "${container}" -- dpkg-query --search /usr/sbin/sshd)" = "openssh-server: /usr/sbin/sshd"
key_types="$(buildah run "${container}" -- /usr/bin/ssh -Q key)"
test -n "${key_types}"
if buildah run "${container}" -- /usr/bin/ssh-keygen -l -f /etc/ssh/sshd_config >/dev/null 2>&1; then
  printf 'ssh-keygen unexpectedly accepted a non-key file\n' >&2
  exit 1
fi

# Variables in this command are intentionally expanded by the image's shell.
# shellcheck disable=SC2016
buildah run "${container}" -- /bin/sh -ceu '
  for tool in bash cc c++ gcc g++ curl diff find git gzip jq make patch ps python3 shellcheck tar unzip lsblk ssh ssh-keygen sshd uv uvx glab kubectl; do
    command -v "${tool}" >/dev/null
  done
  test -s /etc/ssl/certs/ca-certificates.crt
'
buildah run "${container}" -- /usr/local/bin/uv --version
buildah run "${container}" -- /usr/local/bin/uvx --version
buildah run "${container}" -- /usr/local/bin/glab --version
buildah run "${container}" -- /usr/local/bin/kubectl version --client
