#!/usr/bin/env bash
# Idempotent bootstrap for Ubuntu OpenStack compute nodes.
# Run on the compute node as root.
#
# Example:
#   sudo bash 07-bootstrap-compute-node.sh \
#     --iface eno1 \
#     --mgmt-ip 192.168.30.16/24 \
#     --gateway 192.168.30.1 \
#     --dns 192.168.10.1 \
#     --cp-endpoints 192.168.30.15,192.168.30.16 \
#     --kube-api 192.168.30.100 \
#     --node-name hpg9-compute-3 \
#     --node-ip 192.168.30.16 \
#     --ca /tmp/ca.crt \
#     --bootstrap /tmp/bootstrap-kubelet.conf

set -euo pipefail

IFACE="eno1"
MGMT_IP=""
GATEWAY=""
DNS="192.168.10.1"
CP_ENDPOINTS="192.168.30.15,192.168.30.16"
KUBE_API="192.168.30.100"
NODE_NAME="$(hostname -s)"
NODE_IP=""
CA_SRC="/tmp/ca.crt"
BOOTSTRAP_SRC="/tmp/bootstrap-kubelet.conf"
SKIP_NETPLAN_APPLY="false"
CEPH_SECRETS_DIR=""

usage() {
  cat <<'EOF'
Usage:
  sudo bash 07-bootstrap-compute-node.sh [options]

Options:
  --iface <name>            Physical interface for br-ex (default: eno1)
  --mgmt-ip <cidr>          Management IP/CIDR on br-ex (required)
  --gateway <ip>            Default gateway IP (required)
  --dns <ip[,ip2]>          DNS servers (default: 192.168.10.1)
  --cp-endpoints <csv>      Control-plane endpoints csv (default: 192.168.30.15,192.168.30.16)
  --kube-api <ip>           K8s API VIP used in kubelet configs (default: 192.168.30.100)
  --node-name <name>        Node name override (default: hostname -s)
  --node-ip <ip>            Node IP for kubelet (auto-detected if omitted)
  --ca <path>               Path to ca.crt (default: /tmp/ca.crt)
  --bootstrap <path>        Path to bootstrap kubelet conf (default: /tmp/bootstrap-kubelet.conf)
  --skip-netplan-apply      Render netplan only (for maintenance windows)
  --ceph-secrets-dir <dir>  Dir with libvirt Ceph secrets. Each secret is a pair:
                              <uuid>.xml       (virsh secret-define input)
                              <uuid>.b64       (base64 key from virsh secret-get-value)
                            Without these, live-migration of Ceph-backed VMs
                            TO this node will fail ("Secret not found: <uuid>").
                            Dump from an existing hypervisor:
                              virsh secret-dumpxml <uuid> > <uuid>.xml
                              virsh secret-get-value <uuid> > <uuid>.b64
  -h, --help                Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --iface) IFACE="$2"; shift 2 ;;
    --mgmt-ip) MGMT_IP="$2"; shift 2 ;;
    --gateway) GATEWAY="$2"; shift 2 ;;
    --dns) DNS="$2"; shift 2 ;;
    --cp-endpoints) CP_ENDPOINTS="$2"; shift 2 ;;
    --kube-api) KUBE_API="$2"; shift 2 ;;
    --node-name) NODE_NAME="$2"; shift 2 ;;
    --node-ip) NODE_IP="$2"; shift 2 ;;
    --ca) CA_SRC="$2"; shift 2 ;;
    --bootstrap) BOOTSTRAP_SRC="$2"; shift 2 ;;
    --skip-netplan-apply) SKIP_NETPLAN_APPLY="true"; shift 1 ;;
    --ceph-secrets-dir) CEPH_SECRETS_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run as root."
  exit 1
fi

if [ -z "${MGMT_IP}" ] || [ -z "${GATEWAY}" ]; then
  echo "ERROR: --mgmt-ip and --gateway are required."
  usage
  exit 1
fi

if [ -z "${NODE_IP}" ]; then
  NODE_IP="$(echo "${MGMT_IP}" | awk -F/ '{print $1}')"
fi

if [ ! -f "${CA_SRC}" ] || [ ! -f "${BOOTSTRAP_SRC}" ]; then
  echo "ERROR: missing input files."
  echo "  CA file: ${CA_SRC}"
  echo "  Bootstrap kubeconfig: ${BOOTSTRAP_SRC}"
  exit 1
fi

echo "=== Bootstrap Compute Node ==="
echo "node:          ${NODE_NAME}"
echo "node_ip:       ${NODE_IP}"
echo "iface:         ${IFACE}"
echo "mgmt_ip:       ${MGMT_IP}"
echo "gateway:       ${GATEWAY}"
echo "dns:           ${DNS}"
echo "cp_endpoints:  ${CP_ENDPOINTS}"
echo "kube_api_vip:  ${KUBE_API}"
echo

export DEBIAN_FRONTEND=noninteractive

echo ">>> Ensure /etc/hosts resolves hostname (pods with hostNetwork need this)"
# nova-compute + neutron agents call `hostname --fqdn` inside hostNetwork pods.
# They inherit the host's /etc/hosts, so the OS short hostname AND the k8s node
# name must both map to 127.0.1.1 with ${NODE_NAME} as the canonical name
# (canonical == hypervisor identity stored in nova DB).
OS_HOSTNAME="$(hostname -s)"
if [ "${OS_HOSTNAME}" = "${NODE_NAME}" ]; then
  HOSTS_LINE="127.0.1.1 ${NODE_NAME}"
else
  HOSTS_LINE="127.0.1.1 ${NODE_NAME} ${OS_HOSTNAME}"
fi
if ! grep -qFx "${HOSTS_LINE}" /etc/hosts; then
  sed -i '/^127\.0\.1\.1[[:space:]]/d' /etc/hosts
  if grep -qE '^127\.0\.0\.1[[:space:]]' /etc/hosts; then
    sed -i "/^127\.0\.0\.1[[:space:]]/a ${HOSTS_LINE}" /etc/hosts
  else
    echo "${HOSTS_LINE}" >>/etc/hosts
  fi
fi

echo ">>> Base packages and host dependencies"
apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl gnupg haproxy \
  qemu-kvm libvirt-daemon-system libvirt-clients virtinst cpu-checker \
  bridge-utils openvswitch-switch openvswitch-common

echo ">>> Kernel and sysctl for Kubernetes"
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay || true
modprobe br_netfilter || true

cat >/etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

echo ">>> Disable swap"
swapoff -a || true
sed -i '/\sswap\s/s/^/#/' /etc/fstab

echo ">>> Install containerd"
install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.asc ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
fi
chmod a+r /etc/apt/keyrings/docker.asc
if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    >/etc/apt/sources.list.d/docker.list
fi
apt-get update -y
apt-get install -y containerd.io

mkdir -p /etc/containerd
# Always regenerate: containerd.io package ships a stub config with CRI disabled,
# which breaks kubelet ("unknown service runtime.v1.RuntimeService").
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable containerd
systemctl restart containerd

echo ">>> Install kubelet/kubeadm/kubectl"
KUBE_VERSION="${KUBE_VERSION:-1.34}"
if [ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/ /" \
  >/etc/apt/sources.list.d/kubernetes.list
apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

echo ">>> Configure local API proxy (HAProxy)"
cat >/etc/haproxy/haproxy.cfg <<'EOF'
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5000
    timeout client  50000
    timeout server  50000

frontend kubernetes-frontend
    bind 127.0.0.1:6443
    default_backend kubernetes-backend

backend kubernetes-backend
    balance roundrobin
EOF

i=1
IFS=',' read -r -a cp_array <<<"${CP_ENDPOINTS}"
for cp in "${cp_array[@]}"; do
  cp_trimmed="$(echo "${cp}" | xargs)"
  [ -z "${cp_trimmed}" ] && continue
  echo "    server cp${i} ${cp_trimmed}:6443 check" >>/etc/haproxy/haproxy.cfg
  i=$((i + 1))
done
systemctl enable --now haproxy

echo ">>> Configure kubelet bootstrap and service"
mkdir -p /etc/kubernetes/pki /var/lib/kubelet /etc/systemd/system/kubelet.service.d
install -m 0644 "${CA_SRC}" /etc/kubernetes/pki/ca.crt
install -m 0644 "${BOOTSTRAP_SRC}" /etc/kubernetes/bootstrap-kubelet.conf
# Keep bootstrap pointed at local HAProxy (127.0.0.1:6443) so kubelet has HA
# via the local proxy rather than depending on the kube-vip VIP being up.
# Normalize any upstream server URL to localhost:
sed -i "s#^\([[:space:]]*\)server:.*#\1server: https://127.0.0.1:6443#g" /etc/kubernetes/bootstrap-kubelet.conf || true

cat >/var/lib/kubelet/config.yaml <<'EOF'
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: false
  webhook:
    cacheTTL: 0s
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
  webhook:
    cacheAuthorizedTTL: 0s
    cacheUnauthorizedTTL: 0s
cgroupDriver: systemd
clusterDNS:
  - 10.96.0.10
clusterDomain: cluster.local
containerRuntimeEndpoint: unix:///var/run/containerd/containerd.sock
healthzBindAddress: 127.0.0.1
healthzPort: 10248
rotateCertificates: true
serverTLSBootstrap: true
staticPodPath: /etc/kubernetes/manifests
EOF

cat >/etc/systemd/system/kubelet.service.d/10-kubeadm.conf <<EOF
[Service]
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP} --hostname-override=${NODE_NAME}"
ExecStart=
ExecStart=/usr/bin/kubelet \$KUBELET_KUBECONFIG_ARGS \$KUBELET_CONFIG_ARGS \$KUBELET_EXTRA_ARGS
EOF

systemctl daemon-reload
systemctl restart kubelet
systemctl enable kubelet

if [ -f /etc/kubernetes/kubelet.conf ]; then
  # Keep kubelet.conf pointed at local HAProxy for HA (see bootstrap sed above).
  sed -i "s#^\([[:space:]]*\)server:.*#\1server: https://127.0.0.1:6443#g" /etc/kubernetes/kubelet.conf || true
  systemctl restart kubelet
fi

echo ">>> Configure host OVS (br-int and br-ex)"
systemctl enable --now openvswitch-switch
ovs-vsctl --may-exist add-br br-int
ovs-vsctl --may-exist add-br br-ex
ovs-vsctl --may-exist add-port br-ex "${IFACE}"
ip link set br-ex up
ip addr del "${MGMT_IP}" dev "${IFACE}" 2>/dev/null || true
ip addr add "${MGMT_IP}" dev br-ex 2>/dev/null || true
ip route replace default via "${GATEWAY}" dev br-ex

echo ">>> Persist netplan for OVS bridge"
mkdir -p /etc/netplan/backup
for f in /etc/netplan/*.yaml; do
  [ -f "$f" ] || continue
  if [ "$f" = "/etc/netplan/60-ovs-bridge.yaml" ]; then
    continue
  fi
  if grep -q "${IFACE}" "$f" 2>/dev/null; then
    cp -f "$f" "/etc/netplan/backup/$(basename "$f").$(date +%Y%m%d%H%M%S).bak" || true
    mv "$f" "${f}.disabled"
  fi
done

cat >/etc/netplan/60-ovs-bridge.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${IFACE}:
      dhcp4: false
      dhcp6: false
  bridges:
    br-ex:
      interfaces: [${IFACE}]
      openvswitch: {}
      addresses: [${MGMT_IP}]
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${DNS}]
EOF
chmod 600 /etc/netplan/60-ovs-bridge.yaml
netplan generate
if [ "${SKIP_NETPLAN_APPLY}" != "true" ]; then
  netplan apply
fi

echo ">>> Configure libvirt socket access for nova-compute container"
mkdir -p /etc/systemd/system/libvirtd.socket.d /etc/systemd/system/libvirtd-ro.socket.d
cat >/etc/systemd/system/libvirtd.socket.d/override.conf <<'EOF'
[Socket]
SocketMode=0777
SocketGroup=libvirt
EOF
cat >/etc/systemd/system/libvirtd-ro.socket.d/override.conf <<'EOF'
[Socket]
SocketMode=0777
SocketGroup=libvirt
EOF

LIBVIRTD_CONF="/etc/libvirt/libvirtd.conf"
if [ -f "${LIBVIRTD_CONF}" ]; then
  sed -ri 's|^#?\s*unix_sock_group\s*=.*|unix_sock_group = "libvirt"|' "${LIBVIRTD_CONF}"
  sed -ri 's|^#?\s*unix_sock_ro_perms\s*=.*|unix_sock_ro_perms = "0777"|' "${LIBVIRTD_CONF}"
  sed -ri 's|^#?\s*unix_sock_rw_perms\s*=.*|unix_sock_rw_perms = "0770"|' "${LIBVIRTD_CONF}"
  sed -ri 's|^#?\s*auth_unix_rw\s*=.*|auth_unix_rw = "none"|' "${LIBVIRTD_CONF}"
  # Enable TCP listener for live migration (no auth - internal network only)
  sed -ri 's|^#?\s*auth_tcp\s*=.*|auth_tcp = "none"|' "${LIBVIRTD_CONF}"
fi

systemctl daemon-reload
systemctl enable libvirtd libvirtd-tcp.socket ssh
# libvirtd-tcp.socket can't bind if libvirtd.service is already running (it holds the port).
# Stop libvirtd first, then bring up sockets in order, then restart libvirtd.
systemctl stop libvirtd.service libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket libvirtd-tcp.socket || true
systemctl start libvirtd-tcp.socket libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket
systemctl start libvirtd.service
systemctl start ssh

if [ -n "${CEPH_SECRETS_DIR}" ] && [ -d "${CEPH_SECRETS_DIR}" ]; then
  echo ">>> Installing libvirt Ceph secrets from ${CEPH_SECRETS_DIR}"
  for xml in "${CEPH_SECRETS_DIR}"/*.xml; do
    [ -f "$xml" ] || continue
    uuid="$(basename "$xml" .xml)"
    b64="${CEPH_SECRETS_DIR}/${uuid}.b64"
    if [ ! -f "$b64" ]; then
      echo "  WARN: ${xml} present but ${b64} missing, skipping ${uuid}"
      continue
    fi
    virsh secret-define "$xml" >/dev/null
    virsh secret-set-value --secret "$uuid" --base64 "$(cat "$b64")" >/dev/null
    echo "  defined ${uuid}"
  done
  virsh secret-list
else
  echo ">>> NOTE: --ceph-secrets-dir not provided."
  echo "    Live-migration of Ceph-backed VMs TO this node will fail until"
  echo "    libvirt Ceph secrets are defined. See --help for instructions."
fi

echo
echo "=== Bootstrap Complete ==="
echo "Next on workstation:"
echo "  kubectl get csr"
echo "  kubectl certificate approve <csr-name>"
echo "  bash 04-label-node.sh ${NODE_NAME}"
echo "Then verify:"
echo "  bash 08-verify-compute-node.sh --node-name ${NODE_NAME} --iface ${IFACE} --mgmt-ip ${MGMT_IP} --kube-api ${KUBE_API}"
