#!/bin/bash
# Ubuntu Compute Node Preparation Script
# Run as root: sudo bash 02-prepare-node.sh

set -euo pipefail

echo "=== Preparing Ubuntu node for OpenStack Compute ==="

# Update system
apt-get update && apt-get upgrade -y

# Disable swap (required for Kubernetes)
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# Load required kernel modules
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# Sysctl settings for Kubernetes
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

# Install containerd
apt-get install -y apt-transport-https ca-certificates curl gnupg

# Add Docker repository (for containerd)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update
apt-get install -y containerd.io

# Configure containerd
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# Install Kubernetes components (matching cluster minor)
KUBE_VERSION="${KUBE_VERSION:-1.34}"

curl -fsSL https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list

apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

systemctl enable kubelet

# Install libvirt and QEMU for Nova compute
apt-get install -y \
    qemu-kvm \
    libvirt-daemon-system \
    libvirt-clients \
    virtinst \
    cpu-checker \
    bridge-utils

# Verify KVM support
echo "=== Checking KVM support ==="
kvm-ok || echo "WARNING: KVM may not be fully supported"

# Install Open vSwitch for Neutron
apt-get install -y openvswitch-switch openvswitch-common

systemctl enable openvswitch-switch
systemctl start openvswitch-switch

# Create OVS integration bridge
ovs-vsctl --may-exist add-br br-int

# Configure libvirt
systemctl enable libvirtd
systemctl start libvirtd

# Ensure host libvirt socket is accessible for nova-compute container
LIBVIRTD_CONF="/etc/libvirt/libvirtd.conf"
if [ -f "${LIBVIRTD_CONF}" ]; then
  sed -ri 's|^#?\s*unix_sock_group\s*=.*|unix_sock_group = "libvirt"|' "${LIBVIRTD_CONF}"
  sed -ri 's|^#?\s*unix_sock_ro_perms\s*=.*|unix_sock_ro_perms = "0777"|' "${LIBVIRTD_CONF}"
  sed -ri 's|^#?\s*unix_sock_rw_perms\s*=.*|unix_sock_rw_perms = "0770"|' "${LIBVIRTD_CONF}"
  sed -ri 's|^#?\s*auth_unix_rw\s*=.*|auth_unix_rw = "none"|' "${LIBVIRTD_CONF}"
  # Enable TCP listener for live migration (no auth - internal network only)
  sed -ri 's|^#?\s*auth_tcp\s*=.*|auth_tcp = "none"|' "${LIBVIRTD_CONF}"
fi
systemctl enable libvirtd-tcp.socket
systemctl restart libvirtd

# Add default user to libvirt group
usermod -aG libvirt,kvm $(logname) 2>/dev/null || true

echo ""
echo "=== Node preparation complete ==="
echo ""
echo "Next steps:"
echo "1. Get join command from control plane"
echo "2. Run: kubeadm join <control-plane>:6443 --token <token> --discovery-token-ca-cert-hash <hash>"
echo ""
