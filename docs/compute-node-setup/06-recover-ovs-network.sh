#!/bin/bash
# Recover management network on a compute node after eno1/br-ex migration issues.
# Run from physical console as root:
#   sudo bash 06-recover-ovs-network.sh eno1 192.168.30.14/24 192.168.30.1 192.168.10.1

set -euo pipefail

IFACE="${1:-eno1}"
MGMT_IP="${2:-}"
GATEWAY="${3:-}"
DNS="${4:-192.168.10.1}"

if [ -z "${MGMT_IP}" ] || [ -z "${GATEWAY}" ]; then
  echo "Usage: $0 <interface> <ip/mask> <gateway> [dns]"
  echo "Example: $0 eno1 192.168.30.14/24 192.168.30.1 192.168.10.1"
  exit 1
fi

echo "=== Emergency OVS network recovery ==="
echo "Interface: ${IFACE}"
echo "IP:        ${MGMT_IP}"
echo "Gateway:   ${GATEWAY}"
echo "DNS:       ${DNS}"
echo ""

systemctl enable openvswitch-switch >/dev/null 2>&1 || true
systemctl restart openvswitch-switch

ovs-vsctl --may-exist add-br br-ex
ovs-vsctl --may-exist add-port br-ex "${IFACE}"
ip link set br-ex up

# Recover runtime connectivity first
ip addr del "${MGMT_IP}" dev "${IFACE}" 2>/dev/null || true
ip addr add "${MGMT_IP}" dev br-ex 2>/dev/null || true
ip route replace default via "${GATEWAY}" dev br-ex

echo "Runtime connectivity restored (if VLAN/switch config is correct)."
echo "Writing persistent netplan via 05-setup-ovs-bridge.sh ..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${SCRIPT_DIR}/05-setup-ovs-bridge.sh" "${IFACE}" "${MGMT_IP}" "${GATEWAY}" "${DNS}"

echo ""
echo "Recovery complete. Validate from this node:"
echo "  ip addr show br-ex"
echo "  ovs-vsctl list-ports br-ex"
echo "  ping -c 3 ${GATEWAY}"
