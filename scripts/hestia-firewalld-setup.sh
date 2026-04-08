#!/bin/bash
set -euo pipefail

# Hestia firewalld setup for Cilium CNI
#
# Hestia runs Fedora with firewalld active (heracles/nyx do not).
# firewalld's default FedoraServer zone only allows an explicit port list, so
# every new Cilium/Kubernetes port that pods need to reach on the node IP has
# to be either opened explicitly or — better — exempted via the trusted zone.
#
# This script puts all Cilium-managed interfaces into firewalld's trusted zone
# so pod→host traffic on the same node bypasses the FedoraServer filter chain.
# Pod network enforcement is handled by CiliumNetworkPolicy, not the host
# firewall.
#
# History:
#   - specs/003-nomad-to-kubernetes/findings.md documented 8472/udp (VXLAN) and
#     4240/tcp (cilium health) being opened when the cluster was first set up.
#   - 2026-04-08: hubble-relay was CrashLoopBackOff for weeks because port
#     4244/tcp (hubble-peer) was never added. Fixed by completing the trusted
#     zone approach (only cilium_host was in trusted — cilium_net, cilium_vxlan
#     and lxc+ were missing).
#   - 2026-04-08: the firewalld --reload triggered by this script wiped
#     Cilium's iptables CILIUM_POST_nat masquerade rules, silently breaking
#     hestia pod→LAN egress (lldap/overseerr/rspamd crashlooped until the
#     cilium-agent pod on hestia was restarted). Permanent fix: enabled
#     bpf.masquerade=true on the cilium helm release, so pod SNAT now lives
#     in eBPF tc hooks. firewalld reloads no longer touch pod egress.
#
# Usage: run on hestia (192.168.1.5) as a user with sudo.
#   ssh 192.168.1.5 'bash -s' < scripts/hestia-firewalld-setup.sh

if [[ "$(hostname -s | tr '[:upper:]' '[:lower:]')" != "hestia" ]]; then
  echo "ERROR: must be run on hestia, current host: $(hostname -s)" >&2
  exit 1
fi

if ! command -v firewall-cmd >/dev/null; then
  echo "ERROR: firewall-cmd not found — is firewalld installed?" >&2
  exit 1
fi

CILIUM_IFACES=(cilium_host cilium_net cilium_vxlan lxc+)

echo "=== Current trusted zone ==="
sudo firewall-cmd --permanent --zone=trusted --list-interfaces || true

for iface in "${CILIUM_IFACES[@]}"; do
  if sudo firewall-cmd --permanent --zone=trusted --query-interface="$iface" >/dev/null 2>&1; then
    echo "  [skip] $iface already in trusted zone"
  else
    echo "  [add]  $iface -> trusted"
    sudo firewall-cmd --permanent --zone=trusted --add-interface="$iface"
  fi
done

echo "=== Reloading firewalld ==="
sudo firewall-cmd --reload

echo "=== Trusted zone (runtime) ==="
sudo firewall-cmd --zone=trusted --list-all

echo ""
echo "Done. Verify from a pod on hestia:"
echo "  kubectl run -n kube-system nt --rm -i --restart=Never \\"
echo "    --image=busybox:latest \\"
echo "    --overrides='{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"hestia\"}}}' \\"
echo "    -- nc -zv -w5 192.168.1.5 4244"
