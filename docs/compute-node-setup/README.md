# Adding Ubuntu Compute Node to OpenStack Cluster

This guide walks through adding an Ubuntu compute node to the Talos Kubernetes cluster for OpenStack Nova compute workloads.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Kubernetes Cluster                          │
├─────────────────────┬─────────────────┬────────────────────────┤
│   Control Plane     │  Talos Workers  │   Ubuntu Compute       │
│   (Talos Linux)     │  (Talos Linux)  │   (hpg9-compute)       │
├─────────────────────┼─────────────────┼────────────────────────┤
│   dell3000-cp       │  hpg5-worker    │   - nova-compute       │
│   dell7080-cp       │  lenovo-worker  │   - libvirt/QEMU       │
│                     │                 │   - OVS agent          │
│   OpenStack APIs    │  KubeVirt       │   - DHCP/L3/Metadata   │
│   (Keystone, etc)   │  (optional)     │                        │
└─────────────────────┴─────────────────┴────────────────────────┘
```

## Prerequisites

- Physical machine with:
  - CPU with VT-x/AMD-V virtualization support
  - At least 16GB RAM recommended
  - Network connectivity to 192.168.30.x subnet
- Ubuntu 22.04 Server ISO
- `talosctl` configured on your workstation

## Step-by-Step Guide

## Fast Path (Recommended for Repeatable Rebuilds)

Use the new idempotent bootstrap + verify scripts for each compute node.

### On your workstation (once per node)

```bash
CONTROL_PLANE_IP="192.168.30.15"
talosctl -n "${CONTROL_PLANE_IP}" cat /etc/kubernetes/pki/ca.crt > ca.crt
talosctl -n "${CONTROL_PLANE_IP}" cat /etc/kubernetes/bootstrap-kubeconfig > bootstrap-kubelet.conf
scp ca.crt bootstrap-kubelet.conf ubuntu@<compute-ip>:/tmp/
```

### On the compute node

```bash
sudo bash 07-bootstrap-compute-node.sh \
  --iface eno1 \
  --mgmt-ip <compute-ip>/24 \
  --gateway 192.168.30.1 \
  --dns 192.168.10.1 \
  --cp-endpoints 192.168.30.15,192.168.30.16 \
  --kube-api 192.168.30.100 \
  --node-name <node-name> \
  --node-ip <compute-ip> \
  --ca /tmp/ca.crt \
  --bootstrap /tmp/bootstrap-kubelet.conf
```

Then on workstation:

```bash
kubectl get csr
kubectl certificate approve <csr-name>
bash 04-label-node.sh <node-name>
```

Back on node:

```bash
sudo bash 08-verify-compute-node.sh --node-name <node-name> --iface eno1 --mgmt-ip <compute-ip>/24
```

If this verification passes, the node is rebuild-safe and reboot-safe.

### Step 1: Install Ubuntu 22.04

See [01-ubuntu-install.md](01-ubuntu-install.md)

Recommended configuration:
- Hostname: `hpg9-compute`
- IP: `192.168.30.14` (static)
- Enable OpenSSH server

### Step 2: Prepare the Node

SSH into the node and run:

```bash
sudo bash 02-prepare-node.sh
```

This installs:
- containerd (container runtime)
- kubelet, kubeadm, kubectl
- libvirt, QEMU-KVM
- Open vSwitch

### Step 3: Join Kubernetes Cluster

Run the join script:

```bash
# Uses defaults for this homelab
sudo bash 03-join-cluster.sh

# Or provide explicit values (recommended for reproducibility)
sudo CONTROL_PLANE_ENDPOINTS="192.168.30.15,192.168.30.16" \
  NODE_NAME="hpg9-compute2" \
  NODE_IP="192.168.30.13" \
  -E bash 03-join-cluster.sh
```

This requires manual steps to copy PKI from Talos control plane.

**On your workstation:**
```bash
CONTROL_PLANE_IP="192.168.30.15"

# Get CA certificate
talosctl -n $CONTROL_PLANE_IP cat /etc/kubernetes/pki/ca.crt > ca.crt

# Get bootstrap kubeconfig
talosctl -n $CONTROL_PLANE_IP cat /etc/kubernetes/bootstrap-kubeconfig > bootstrap-kubelet.conf

# Update server URL to use localhost (HAProxy)
sed -i 's|server:.*|server: https://127.0.0.1:6443|' bootstrap-kubelet.conf

# Copy to compute node
scp ca.crt bootstrap-kubelet.conf ubuntu@192.168.30.14:/tmp/
```

### Step 4: Approve CSR and Label Node

Once kubelet starts, approve the certificate signing request:

```bash
# Check for pending CSRs
kubectl get csr

# Approve pending CSRs for the new node
kubectl certificate approve <csr-name>

# Wait for node to appear
kubectl get nodes -w

# Label the node
bash 04-label-node.sh <node-name>
```

### Step 5: Set Up OVS Bridge

On the compute node:

```bash
sudo bash 05-setup-ovs-bridge.sh eno1 <mgmt-ip/cidr> <gateway> [dns]
```

Example:
```bash
sudo bash 05-setup-ovs-bridge.sh eno1 192.168.30.13/24 192.168.30.1 192.168.10.1
```

### Step 6: Sync OpenStack via ArgoCD

The Nova and Neutron charts are already updated to deploy on labeled nodes.

```bash
# Trigger ArgoCD sync
kubectl annotate application root -n argocd argocd.argoproj.io/refresh=hard --overwrite

# Watch for nova-compute pod
kubectl get pods -n openstack -l application=nova,component=compute -w

# Watch for neutron agents
kubectl get pods -n openstack -l application=neutron -w
```

### Step 7: Verify in Skyline

1. Access Skyline dashboard
2. Go to Admin → Compute → Hypervisors
3. Verify `hpg9-compute` appears as a hypervisor
4. Check Admin → Network → Agents for OVS agent status

## Troubleshooting

### Node Not Joining

Check kubelet logs:
```bash
journalctl -u kubelet -f
```

Verify HAProxy is running:
```bash
systemctl status haproxy
curl -k https://127.0.0.1:6443/healthz
```

### Compute Pod Not Starting

Check if node is labeled:
```bash
kubectl get node hpg9-compute --show-labels | grep openstack
```

Check pod events:
```bash
kubectl describe pod -n openstack -l application=nova,component=compute
```

### OVS Agent Not Working

Verify OVS bridges:
```bash
ovs-vsctl show
```

Check OVS agent logs:
```bash
kubectl logs -n openstack -l application=neutron,component=ovs-agent
```

If logs show `Bridge br-ex for physical network provider does not exist`, run:
```bash
sudo bash 05-setup-ovs-bridge.sh eno1 <mgmt-ip/cidr> <gateway> [dns]
```

If netplan fails with `unknown key 'bridge'`, ensure the generated file uses:
- `bridges.br-ex.interfaces: [eno1]` (not `ethernets.eno1.openvswitch.bridge`)
- strict permissions: `chmod 600 /etc/netplan/60-ovs-bridge.yaml`

### nova-compute Fails with libvirt-sock Permission Denied

If logs show `Failed to connect socket to '/run/libvirt/libvirt-sock': Permission denied`:
```bash
sudo sed -ri 's|^#?\s*unix_sock_group\s*=.*|unix_sock_group = "libvirt"|' /etc/libvirt/libvirtd.conf
sudo sed -ri 's|^#?\s*unix_sock_ro_perms\s*=.*|unix_sock_ro_perms = "0777"|' /etc/libvirt/libvirtd.conf
sudo sed -ri 's|^#?\s*unix_sock_rw_perms\s*=.*|unix_sock_rw_perms = "0770"|' /etc/libvirt/libvirtd.conf
sudo sed -ri 's|^#?\s*auth_unix_rw\s*=.*|auth_unix_rw = "none"|' /etc/libvirt/libvirtd.conf
sudo systemctl restart libvirtd
```

### Node Lost Network After eno1 -> br-ex Change

Use physical console and run:

```bash
sudo bash 06-recover-ovs-network.sh eno1 <mgmt-ip/cidr> <gateway> [dns]
```

Example:
```bash
sudo bash 06-recover-ovs-network.sh eno1 192.168.30.14/24 192.168.30.1 192.168.10.1
```

## Network Configuration

The default configuration uses:
- **br-int**: Integration bridge (auto-created by OVS agent)
- **br-tun**: Tunnel bridge for VXLAN (auto-created)
- **br-ex**: External bridge for provider network (created manually)

Provider network mapping: `provider:br-ex`

## Node Labels Reference

| Label | Purpose |
|-------|---------|
| `openstack-nova-compute=enabled` | Nova compute pods |
| `openvswitch=enabled` | Neutron OVS agent and network agents |
| `openstack-compute-node=enabled` | General compute marker |

## New Scripts

| Script | Purpose |
|-------|---------|
| `07-bootstrap-compute-node.sh` | End-to-end idempotent compute bootstrap (host prep + kubelet + OVS + netplan + libvirt) |
| `08-verify-compute-node.sh` | Post-bootstrap/reboot validation with PASS/WARN/FAIL summary |
