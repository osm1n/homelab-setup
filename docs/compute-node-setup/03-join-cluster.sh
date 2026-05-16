#!/bin/bash
# Join Ubuntu node to Talos Kubernetes cluster
# Run as root on the Ubuntu compute node: sudo bash 03-join-cluster.sh

set -euo pipefail

# === CONFIGURATION ===
# Override with env vars when needed:
#   CONTROL_PLANE_ENDPOINTS="192.168.30.15,192.168.30.16" NODE_NAME="hpg9-compute3" NODE_IP="192.168.30.17" sudo -E bash 03-join-cluster.sh
CONTROL_PLANE_ENDPOINTS="${CONTROL_PLANE_ENDPOINTS:-192.168.30.15,192.168.30.16}"
NODE_NAME="${NODE_NAME:-$(hostname -s)}"
NODE_IP="${NODE_IP:-$(ip -4 route get 1.1.1.1 | awk '/src/ {print $7; exit}')}"
# =====================

if [ -z "${NODE_IP}" ]; then
  echo "ERROR: Unable to detect NODE_IP. Set NODE_IP explicitly and retry."
  exit 1
fi

echo "=== Joining Ubuntu node to Talos Kubernetes cluster ==="
echo "Control plane endpoints: ${CONTROL_PLANE_ENDPOINTS}"
echo "Node name: ${NODE_NAME}"
echo "Node IP: ${NODE_IP}"

# Create kubernetes directories
mkdir -p /etc/kubernetes/pki
mkdir -p /var/lib/kubelet

# Create HAProxy config for local API access
# This proxies localhost:6443 to the control plane
apt-get install -y haproxy

cat <<EOF > /etc/haproxy/haproxy.cfg
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
IFS=',' read -r -a cp_array <<< "${CONTROL_PLANE_ENDPOINTS}"
for cp in "${cp_array[@]}"; do
  cp_trimmed="$(echo "${cp}" | xargs)"
  [ -z "${cp_trimmed}" ] && continue
  echo "    server cp${i} ${cp_trimmed}:6443 check" >> /etc/haproxy/haproxy.cfg
  i=$((i + 1))
done

systemctl restart haproxy
systemctl enable haproxy

echo "HAProxy configured with ${CONTROL_PLANE_ENDPOINTS}"

# The following files need to be copied from the Talos control plane
# Run these commands on your local machine that has talosctl configured:
cat <<'INSTRUCTIONS'

=== MANUAL STEP REQUIRED ===

Run these commands on your LOCAL machine (with talosctl access):

1. Get cluster configuration:

   CONTROL_PLANE_IP="<one reachable control plane IP>"

   # Get CA certificate
   talosctl -n $CONTROL_PLANE_IP cat /etc/kubernetes/pki/ca.crt > ca.crt

   # Get bootstrap kubeconfig
   talosctl -n $CONTROL_PLANE_IP cat /etc/kubernetes/bootstrap-kubeconfig > bootstrap-kubelet.conf

   # Update the server URL in bootstrap-kubelet.conf to use localhost:
   sed -i 's|server:.*|server: https://127.0.0.1:6443|' bootstrap-kubelet.conf

2. Copy files to compute node:

   scp ca.crt bootstrap-kubelet.conf ubuntu@<compute-node-ip>:/tmp/

3. Then continue on the compute node...

Press Enter when files are copied to /tmp/ on this node...
INSTRUCTIONS

read -p ""

# Move files to correct locations
cp /tmp/ca.crt /etc/kubernetes/pki/
cp /tmp/bootstrap-kubelet.conf /etc/kubernetes/

# Create kubelet configuration
cat <<EOF > /var/lib/kubelet/config.yaml
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

# Create kubelet service override
mkdir -p /etc/systemd/system/kubelet.service.d

cat <<EOF > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
[Service]
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP} --hostname-override=${NODE_NAME}"
ExecStart=
ExecStart=/usr/bin/kubelet \$KUBELET_KUBECONFIG_ARGS \$KUBELET_CONFIG_ARGS \$KUBELET_EXTRA_ARGS
EOF

# Reload and start kubelet
systemctl daemon-reload
systemctl restart kubelet
systemctl enable kubelet

echo ""
echo "=== Kubelet started ==="
echo ""
echo "The node should now be attempting to join the cluster."
echo "Check status with: systemctl status kubelet"
echo ""
echo "=== NEXT STEP: Approve CSR on control plane ==="
echo ""
echo "Run on your local machine:"
echo "  kubectl get csr"
echo "  kubectl certificate approve <csr-name>"
echo ""
