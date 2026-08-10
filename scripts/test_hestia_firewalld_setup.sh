#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/scripts/hestia-firewalld-setup.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
fake_bin="${tmpdir}/bin"
log_file="${tmpdir}/firewall.log"
mkdir -p "${fake_bin}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cat >"${fake_bin}/hostname" <<'EOF'
#!/usr/bin/env bash
printf 'hestia\n'
EOF

cat >"${fake_bin}/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF

cat >"${fake_bin}/firewall-cmd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FIREWALL_TEST_LOG:?}"
case " $* " in
  *" --query-interface="*|*" --query-port="*) exit 1 ;;
esac
EOF

chmod +x "${fake_bin}/hostname" "${fake_bin}/sudo" "${fake_bin}/firewall-cmd"
env PATH="${fake_bin}:${PATH}" FIREWALL_TEST_LOG="${log_file}" /bin/bash "${script}" >/dev/null

assert_line() {
  local expected="$1"
  while IFS= read -r line; do
    [ "${line}" = "${expected}" ] && return 0
  done <"${log_file}"
  fail "missing firewall-cmd call: ${expected}"
}

assert_absent_text() {
  local forbidden="$1"
  while IFS= read -r line; do
    case "${line}" in
      *"${forbidden}"*) fail "forbidden firewall-cmd call contains ${forbidden}" ;;
    esac
  done <"${log_file}"
}

assert_line "--permanent --zone=FedoraServer --query-port=34197/udp"
assert_line "--permanent --zone=FedoraServer --add-port=34197/udp"
for iface in cilium_host cilium_net cilium_vxlan lxc+; do
  assert_line "--permanent --zone=trusted --query-interface=${iface}"
  assert_line "--permanent --zone=trusted --add-interface=${iface}"
done
assert_line "--reload"
assert_absent_text "34197/tcp"
assert_absent_text "27015"

printf 'Hestia firewalld setup tests passed\n'
