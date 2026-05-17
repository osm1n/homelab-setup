# usman-homelab-setup

A full OpenStack private cloud deployed on bare-metal Kubernetes, managed entirely through GitOps. This repo contains all the ArgoCD applications, Helm chart values, infrastructure manifests, compute node setup scripts, and operational runbooks used to run it.

All sensitive values (passwords, Ceph keyrings, credentials) have been replaced with clearly-labelled `<your-...>` placeholders. The structure and configuration are otherwise identical to what is running in production.

---

## What This Is

A homelab mini-rack running:

- **Talos Linux** on Kubernetes control plane and worker nodes (immutable, SSH-less OS)
- **Ubuntu 22.04** on dedicated OpenStack compute nodes (host libvirt/QEMU + Open vSwitch)
- **Rook-Ceph** for distributed block storage (~2.5TB across 6 OSDs)
- **OpenStack-Helm** for the full OpenStack control plane, deployed and reconciled by **ArgoCD**
- **kube-prometheus-stack + Loki** for observability, with Alertmanager pushing to Telegram

The key design constraint: everything is **declarative and GitOps-driven**. If it isn't in this repo, it doesn't exist in the cluster.

---

## Hardware

| Role | Device | Count |
|------|--------|-------|
| Kubernetes Control Plane | Dell Optiplex 7080 (Talos Linux) | 2 |
| Kubernetes Workers + Ceph OSDs | HP EliteDesk G5 + Lenovo ThinkCenter M720q (Talos Linux) | 2 |
| OpenStack Compute Nodes | HP EliteDesk G9 (Ubuntu 22.04) | 3 |
| NAS | Synology DS920+ | 1 |
| Network | UniFi Cloud Gateway Max + Enterprise 8 PoE + 16 PoE Lite | — |

---

## Architecture

```
Talos Linux ──── bootstraps Kubernetes (2 CP + 2 workers)
Ubuntu 22.04 ─── 3 compute nodes join cluster via kubeadm
                 run host libvirt/QEMU + Open vSwitch

ArgoCD ────────── syncs everything from this repo in wave order:

  Wave 1-2  →  MetalLB  +  Rook-Ceph Operator
  Wave 3    →  Rook-Ceph Cluster (OSDs, MONs, Dashboard)
  Wave 4    →  Ingress-Nginx  +  cert-manager
  Wave 5    →  MariaDB  +  RabbitMQ  +  Memcached
  Wave 6    →  Keystone
  Wave 7    →  Glance
  Wave 8    →  Placement
  Wave 9    →  Libvirt  +  OpenVSwitch
  Wave 10   →  Nova  +  Neutron
  Wave 11   →  Cinder
  Wave 12   →  Skyline
  Wave 13   →  KubeVirt (experimental)

Rook-Ceph (6 OSDs, ~2.5TB) ── storage backend for:
  Glance  →  image store (ceph-block PVC)
  Nova    →  ephemeral VM root disks (RBD vms pool)
  Cinder  →  persistent volumes (RBD volumes pool)

Neutron (ML2/OVS + VXLAN) ── tenant overlay network
  br-ex → br-int → br-tun  (persisted via netplan on compute nodes)

MetalLB (L2, 192.168.30.200–250) ── exposes:
  Nginx Ingress  →  all OpenStack API endpoints
  Ceph Dashboard
  Grafana

Prometheus + Loki + Promtail → Grafana → Alertmanager → Telegram
```

### VLAN Layout

| VLAN | Purpose | Subnet |
|------|---------|--------|
| 30 | Talos/K8s management | 192.168.30.0/24 |
| 40 | Kubernetes pods & services | 192.168.40.0/24 |
| 50 | Ceph replication | 192.168.50.0/24 |
| 60 | OpenStack tenant VMs | 192.168.60.0/24 |

---

## Repo Structure

```
.
├── apps/                          # ArgoCD Application manifests (one per stack)
│   ├── infrastructure.yaml        # MetalLB, Rook-Ceph, Ingress, cert-manager
│   ├── monitoring.yaml            # kube-prometheus-stack, Loki, Promtail
│   ├── openstack.yaml             # All OpenStack services
│   ├── headlamp.yaml              # Kubernetes UI
│   └── kubevirt.yaml              # KubeVirt (experimental)
│
├── argocd/                        # ArgoCD bootstrap (root app, namespace)
│
├── infrastructure/
│   ├── openstack/                 # Helm chart values for each OpenStack service
│   │   ├── mariadb/
│   │   ├── rabbitmq/
│   │   ├── keystone/
│   │   ├── glance/
│   │   ├── placement/
│   │   ├── nova/
│   │   ├── neutron/
│   │   ├── cinder/
│   │   ├── skyline/
│   │   ├── libvirt/
│   │   ├── openvswitch/
│   │   └── ceph-config/           # Ceph keyring Secrets + ceph.conf ConfigMap
│   ├── rook-ceph-cluster/         # CephCluster CR, StorageClass, dashboard LB
│   ├── rook-ceph-operator/        # Operator namespace
│   ├── metallb-config/            # IP pool + L2Advertisement
│   ├── monitoring-rules/          # Custom PrometheusRules + Ceph ServiceMonitors
│   ├── headlamp/
│   └── kubevirt/
│
├── docs/
│   ├── memory.md                  # Full operational context — architecture, gotchas, status
│   ├── error-fixes.md             # Incident log with root causes and fixes
│   ├── instructions.md            # Setup walkthrough
│   ├── compute-node-setup/        # Step-by-step scripts to provision Ubuntu compute nodes
│   └── runbooks/                  # Monitoring, VM provisioning, post-sync validation
│
└── scripts/                       # Operational scripts (preflight, capacity, sync monitor)
```

---

## Key Design Decisions

**`helm3_hook: false` on all OpenStack-Helm charts** — ArgoCD converts Helm post-install hooks to PostSync hooks, which deadlocks with Deployment init containers waiting for Jobs that haven't started yet. Disabling this makes Jobs run as regular resources.

**`oslo_messaging.statefulset: null`** on all charts — without this the chart generates per-pod RabbitMQ transport URLs (`rabbitmq-0.openstack-rabbitmq`) which don't resolve correctly. This also affects Nova cell mappings.

**Host OVS mode on compute nodes** — Talos Linux has no OVS kernel module, so all Neutron OVS agents (ovs-agent, dhcp-agent, l3-agent, metadata-agent) run only on Ubuntu compute nodes via node selector `openvswitch=enabled`. The OpenVSwitch chart is present but its DaemonSet is disabled.

**VXLAN port 4790 for Neutron** — Flannel CNI uses 4789 (default). Both trying to own the same UDP port causes OVS agent crash loops. Set `vxlan_udp_port: 4790` in neutron values.

**Glance uses a `ceph-block` PVC, not direct Ceph RBD** — Glance pods cannot access Ceph via librados in this setup. Filesystem storage backed by a CSI-provisioned PVC works reliably.

**`br-ex` must be persistent via netplan** — The OVS provider bridge configuration (`eno1` enslaved to `br-ex`, management IP on `br-ex`) must be written to `/etc/netplan/60-ovs-bridge.yaml`. Runtime-only `ovs-vsctl` commands are lost on reboot.

**Root logger override in nova/values.yaml** — OpenStack-Helm's default `logging.conf` routes the root logger to a `null` handler. Errors from `oslo_service`, `oslo_messaging`, and `keystoneauth` are silently discarded. The Nova values in this repo override `conf.logging` to route root to stdout.

**Local HAProxy on each compute node** — Each Ubuntu compute node runs a HAProxy instance on `127.0.0.1:6443` proxying to both Kubernetes control plane nodes. kubelet points at localhost, so a single CP failure does not take the hypervisors offline.

---

## Prerequisites

Before deploying, you will need:

- A Kubernetes cluster running **Talos Linux** (see [Talos docs](https://www.talos.dev/))
- Ubuntu 22.04 compute nodes joined to the cluster (see `docs/compute-node-setup/`)
- A **UniFi** (or equivalent) network with VLANs configured per the layout above
- **ArgoCD** bootstrapped into the cluster (`argocd/` directory)
- **Ceph** users and pools created manually before OpenStack charts sync:
  ```bash
  ceph osd pool create volumes 32
  ceph osd pool create images 32
  ceph osd pool create vms 32

  ceph auth get-or-create client.glance mon 'profile rbd' osd 'profile rbd pool=images'
  ceph auth get-or-create client.cinder mon 'profile rbd' osd 'profile rbd pool=volumes,images,vms'
  ceph auth get-or-create client.nova   mon 'profile rbd' osd 'profile rbd pool=vms,volumes' mgr 'profile rbd pool=vms,volumes'
  ```

---

## Credentials Setup

Every `<your-...>` placeholder in this repo must be filled in before deploying. The pattern is consistent — the same logical credential uses the same placeholder name across all chart values files.

**Ceph keyring secrets** (`infrastructure/openstack/ceph-config/`):

Get each key from Ceph and base64-encode it:
```bash
ceph auth get-key client.glance | base64
ceph auth get-key client.nova   | base64
ceph auth get-key client.cinder | base64
```

Paste the output into the respective `*-rbd-keyring-secret.yaml` `data.key` field.

The raw (non-base64) nova keyring also goes into `nova/values.yaml` at `conf.ceph.cinder.keyring`.

**Service passwords** — choose your own and apply them consistently. Every chart's `values.yaml` uses the same placeholder name for the same credential:

| Placeholder | Used by |
|-------------|---------|
| `<your-mariadb-root-password>` | MariaDB root, referenced by all charts |
| `<your-openstack-admin-password>` | Keystone admin account |
| `<your-rabbitmq-password>` | RabbitMQ openstack user |
| `<your-rabbitmq-erlang-cookie>` | RabbitMQ cluster cookie |
| `<your-metadata-shared-secret>` | Nova ↔ Neutron metadata proxy |
| `<your-*-db-password>` | Per-service MariaDB user passwords |
| `<your-*-keystone-password>` | Per-service Keystone user passwords |

---

## Getting Started

1. **Bootstrap ArgoCD** into your cluster:
   ```bash
   kubectl apply -k argocd/
   ```

2. **Fill in credentials** — replace all `<your-...>` placeholders in the values files and keyring secrets with your own values.

3. **Apply the root app** — ArgoCD will pick up everything else:
   ```bash
   kubectl apply -f argocd/root-app.yaml
   ```

4. **Provision compute nodes** — follow `docs/compute-node-setup/` in order (scripts 01–08).

5. **Run preflight before creating VMs:**
   ```bash
   source openrc.sh
   scripts/openstack-preflight.sh m1.medium
   ```

See `docs/memory.md` for the full operational picture, and `docs/error-fixes.md` for a log of every incident and how it was resolved.

---

## Monitoring

Grafana is exposed via a MetalLB LoadBalancer service. Loki is wired in as a datasource automatically. Custom dashboards for Ceph health (OSD up/in, MON quorum, MGR active) and OpenStack alerts are deployed via `infrastructure/monitoring-rules/`.

Alertmanager is configured to push to Telegram — see `scripts/setup-alertmanager-telegram.sh`.

---

## Docs

| File | What it covers |
|------|---------------|
| `docs/error-fixes.md` | Incident log with root causes and exact fixes — the honest record of what went wrong |
| `docs/compute-node-setup/` | Scripts 01–08 to go from a bare Ubuntu 22.04 install to a fully operational OpenStack compute node |
| `docs/runbooks/monitoring-stack.md` | Monitoring stack operation and alert tuning |
| `docs/runbooks/vm-provisioning-ssh.md` | Canonical workflow for creating and SSH-ing into OpenStack VMs |
| `docs/runbooks/post-sync-validation.md` | What to verify after every ArgoCD sync |
