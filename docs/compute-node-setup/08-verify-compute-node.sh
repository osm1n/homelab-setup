#!/usr/bin/env bash
# Verify Ubuntu compute node baseline after bootstrap/reboot.
# Run as root on the compute node.
#
# Example:
#   sudo bash 08-verify-compute-node.sh \
#     --node-name hpg9-compute-2 \
#     --iface eno1 \
#     --mgmt-ip 192.168.30.13/24 \
#     --kube-api 192.168.30.100

set -euo pipefail

NODE_NAME="$(hostname -s)"
IFACE="eno1"
MGMT_IP=""
KUBE_API="192.168.30.100"

PASS=0
WARN=0
FAIL=0

usage() {
  cat <<'EOF'
Usage:
  sudo bash 08-verify-compute-node.sh [options]

Options:
  --node-name <name>        Kubernetes node name (default: hostname -s)
  --iface <name>            Physical interface expected under br-ex (default: eno1)
  --mgmt-ip <cidr>          Expected management CIDR on br-ex (recommended)
  --kube-api <ip>           Expected kube API endpoint in kubelet configs (default: 192.168.30.100)
  -h, --help                Show help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --node-name) NODE_NAME="$2"; shift 2 ;;
    --iface) IFACE="$2"; shift 2 ;;
    --mgmt-ip) MGMT_IP="$2"; shift 2 ;;
    --kube-api) KUBE_API="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

ok() { PASS=$((PASS + 1)); echo "PASS: $*"; }
warn() { WARN=$((WARN + 1)); echo "WARN: $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

expect_active() {
  local svc="$1"
  if systemctl is-active --quiet "$svc"; then
    ok "service active: $svc"
  else
    bad "service not active: $svc"
  fi
}

expect_enabled() {
  local svc="$1"
  if systemctl is-enabled --quiet "$svc"; then
    ok "service enabled: $svc"
  else
    bad "service not enabled: $svc"
  fi
}

echo "=== Verify Compute Node Baseline ==="
echo "node_name: ${NODE_NAME}"
echo "iface:     ${IFACE}"
echo "kube_api:  ${KUBE_API}"
if [ -n "${MGMT_IP}" ]; then
  echo "mgmt_ip:   ${MGMT_IP}"
fi
echo

if ip -4 addr show br-ex >/dev/null 2>&1; then
  ok "br-ex interface exists"
else
  bad "br-ex interface missing"
fi

if [ -n "${MGMT_IP}" ]; then
  if ip -4 addr show br-ex | grep -q "inet ${MGMT_IP%/*}/"; then
    ok "br-ex has expected management IP ${MGMT_IP}"
  else
    bad "br-ex missing expected management IP ${MGMT_IP}"
  fi
else
  if ip -4 addr show br-ex | grep -q "inet "; then
    ok "br-ex has an IPv4 address"
  else
    bad "br-ex has no IPv4 address"
  fi
fi

if ip -4 addr show "${IFACE}" | grep -q "inet "; then
  bad "${IFACE} still has IPv4 address (should be moved to br-ex)"
else
  ok "${IFACE} has no host IPv4 address"
fi

default_count="$(ip -4 route | awk '/^default/{c++} END {print c+0}')"
if [ "${default_count}" -eq 1 ] && ip -4 route | grep -q '^default .* dev br-ex'; then
  ok "single default route via br-ex"
else
  bad "default route is not clean (count=${default_count})"
fi

if [ -f /etc/netplan/60-ovs-bridge.yaml ]; then
  ok "netplan file exists: /etc/netplan/60-ovs-bridge.yaml"
  perms="$(stat -c '%a' /etc/netplan/60-ovs-bridge.yaml)"
  if [ "${perms}" = "600" ]; then
    ok "netplan permissions are 600"
  else
    warn "netplan permissions are ${perms}, expected 600"
  fi
else
  bad "netplan file missing: /etc/netplan/60-ovs-bridge.yaml"
fi

expect_active openvswitch-switch
expect_enabled openvswitch-switch
expect_active kubelet
expect_enabled kubelet
expect_active containerd
expect_enabled containerd
expect_active libvirtd
expect_enabled libvirtd
expect_active ssh
expect_enabled ssh

if command -v ovs-vsctl >/dev/null 2>&1; then
  if ovs-vsctl list-ports br-ex 2>/dev/null | grep -qx "${IFACE}"; then
    ok "OVS br-ex contains ${IFACE}"
  else
    bad "OVS br-ex missing ${IFACE}"
  fi
else
  bad "ovs-vsctl is not available"
fi

for f in /etc/kubernetes/bootstrap-kubelet.conf /etc/kubernetes/kubelet.conf; do
  if [ -f "$f" ]; then
    if grep -q "server: https://${KUBE_API}:6443" "$f"; then
      ok "$(basename "$f") points to ${KUBE_API}:6443"
    elif grep -q "server: https://127.0.0.1:6443" "$f"; then
      warn "$(basename "$f") still points to 127.0.0.1:6443"
    else
      warn "$(basename "$f") has unexpected server endpoint"
    fi
  else
    warn "missing kube config file: $f"
  fi
done

if [ -S /run/libvirt/libvirt-sock ] && [ -S /run/libvirt/libvirt-sock-ro ]; then
  ok "libvirt sockets exist"
  sock_perm="$(stat -c '%a' /run/libvirt/libvirt-sock)"
  if [ "${sock_perm}" = "777" ]; then
    ok "libvirt-sock permissions are 777"
  else
    warn "libvirt-sock permissions are ${sock_perm}, expected 777"
  fi
else
  bad "libvirt socket files missing in /run/libvirt"
fi

if command -v kubectl >/dev/null 2>&1; then
  if kubectl get node "${NODE_NAME}" >/dev/null 2>&1; then
    if kubectl get node "${NODE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q True; then
      ok "kubernetes node is Ready: ${NODE_NAME}"
    else
      bad "kubernetes node is not Ready: ${NODE_NAME}"
    fi

    labels="$(kubectl get node "${NODE_NAME}" --show-labels 2>/dev/null || true)"
    echo "${labels}" | grep -q 'openvswitch=enabled' && ok "label present: openvswitch=enabled" || bad "missing label: openvswitch=enabled"
    echo "${labels}" | grep -q 'openstack-nova-compute=enabled' && ok "label present: openstack-nova-compute=enabled" || bad "missing label: openstack-nova-compute=enabled"
    echo "${labels}" | grep -q 'openstack-compute-node=enabled' && ok "label present: openstack-compute-node=enabled" || bad "missing label: openstack-compute-node=enabled"

    pods="$(kubectl -n openstack get pods --field-selector spec.nodeName=${NODE_NAME} -o wide 2>/dev/null || true)"
    echo "${pods}" | grep -q 'nova-compute' && ok "nova-compute pod scheduled on node" || warn "nova-compute pod not found on node"
    echo "${pods}" | grep -q 'neutron-ovs-agent' && ok "neutron-ovs-agent pod scheduled on node" || warn "neutron-ovs-agent pod not found on node"
  else
    warn "kubectl cannot find node ${NODE_NAME} from this host context"
  fi
else
  warn "kubectl not installed on this host; skipped cluster checks"
fi

echo
echo "Summary: PASS=${PASS} WARN=${WARN} FAIL=${FAIL}"
if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
