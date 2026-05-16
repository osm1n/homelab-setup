# Deployment Memory — OpenStack Homelab

This file is a complete context dump for resuming work on this deployment.
Consult this document to get fully up to speed on the current state of the cluster.

**Last updated:** 2026-03-27

---

## Start Here (Fast Handoff)

- **What this is:** Talos Kubernetes + OpenStack-Helm GitOps deployment on UniFi VLAN fabric, with Ubuntu compute nodes running host libvirt + host OVS.
- **Current cluster posture:** Core services are running; Keystone/Skyline auth path is healthy; compute nodes are reboot-safe with persistent `br-ex`; monitoring stack is live (Grafana/Loki/Promtail/Alertmanager Telegram). Both `nova-compute` pods are stable and `1/1 Running` on both compute nodes. Ceph is `HEALTH_OK` with 4 OSDs, **3 MONs** (b on dell3000-cp, e on dell7080-cp, f on lenovo-worker — NFS mgr module disabled to prevent crash-loop warnings), 2 MGRs (a active, b standby on CP nodes). **Live migration is working** bidirectionally between both compute nodes.
- **Critical gotchas:** Keystone key secrets must stay populated (`keystone-fernet-keys`, `keystone-credential-keys`), and medium flavor builds can fail with `NoValidHost` when per-host disk headroom is low.
- **Image upload gotcha:** Glance uWSGI rejects large image uploads via chunked transfer (415/502 errors). For images >1GB, use the helper pod method: SCP to compute node, create a busybox pod mounting both host `/tmp` and `glance-images` PVC, copy the file in, then insert `image_locations` DB record manually. See `docs/error-fixes.md` for details.
- **Run before VM create:** `scripts/openstack-preflight.sh m1.medium`
- **Capacity policy gate (medium/large):** `scripts/openstack-capacity-policy.sh --strict m1.medium m1.large`
- **Compute rebuild fast-path:** `docs/compute-node-setup/07-bootstrap-compute-node.sh` then `docs/compute-node-setup/08-verify-compute-node.sh`
- **Canonical VM workflow:** `docs/runbooks/vm-provisioning-ssh.md`
- **Post-sync automation runbook:** `docs/runbooks/post-sync-validation.md`
- **Monitoring runbook:** `docs/runbooks/monitoring-stack.md`
- **Incident history + fixes:** `docs/error-fixes.md`

### Resolved Incident (Feb 22-23, 2026)

- **Incident:** `nova-compute` pods on `hpg9-compute` and `hpg9-compute-2` were restarting (`Completed`/`CrashLoopBackOff`).
- **Root cause (hpg9-compute-2):** Stale `compute_id` → DB hostname mismatch. `/var/lib/nova/compute_id` pointed to a UUID whose DB record had `host='nova-debug'` (from a debug pod), but the real host was `hpg9-compute-2`. Nova's `_check_for_host_rename()` raised `InvalidConfiguration` and exited cleanly (code 0). The error was invisible because the chart's `logging.conf` routes the root logger to `null` — only `nova.*` loggers go to stdout, so `oslo_service` errors were silently discarded.
- **Root cause (hpg9-compute):** Stale OVS tap port (`tap62cc2cca-91`) caused `neutron-ovs-agent` readiness probe failure, which deadlocked `nova-compute` init container.
- **Red herring:** Commits `afb963a`/`7b24dd6` added `daemon: false` to `nova.conf` — this is NOT a real Nova/oslo_service config option and was silently ignored.
- **Fixes applied:**
  - Soft-deleted stale `nova-debug` records from Nova DB (`compute_nodes` + `services` tables).
  - Updated `/var/lib/nova/compute_id` on `hpg9-compute-2` to correct UUID (`d6174caf`).
  - Removed stale OVS port `tap62cc2cca-91` from `br-int` on `hpg9-compute`.
  - Overrode `conf.logging` in `nova/values.yaml` to route root logger to `stdout` (not `null`).
  - Removed bogus `daemon: false` settings from `nova/values.yaml`.
- **Status:** Both `nova-compute` pods `1/1 Running`, both compute services `enabled/up`. See `docs/error-fixes.md` §0 for full details.

---

## 1. Who You Are Talking To

- **User:** Usman Garba (`usmangarba`)
- **Mac:** Mac Mini on VLAN 1 (`192.168.10.x`), hostname `Mac-mini`
- **Git remote:** `https://github.com/osm1n/openstack-homelab-gitops.git` (branch: `main`)
- **Local repo path:** `/path/to/openstack-homelab-gitops/`
- **Talos config path:** `/path/to/talos/`

### Design Principles (IMPORTANT — follow these at all times)

1. **Reboot/power-outage safe** — Every change must survive node reboots and power outages. Never rely on runtime-only commands (`ip addr`, `ovs-vsctl`) without a persistent backing config (netplan, systemd unit, etc.). If a runtime command is needed, always pair it with a persistent config file.
2. **Reproducible** — The entire infrastructure should be deployable from scratch using the git repo + documented scripts. A new compute node should be set up by running the scripts in `docs/compute-node-setup/` in order.
3. **Structurally robust** — Prefer declarative config (netplan YAML, Helm values, ArgoCD Applications) over imperative commands. Keep config DRY — single source of truth for each setting.
4. **Reusable** — Scripts and configs should be parameterized (not hardcoded to a single node). Use variables for node-specific values (IP, hostname, interface name).
5. **Long-term maintainable** — Document every non-obvious decision in `docs/error-fixes.md`. Keep `memory.md` current so any future session can resume without context loss.

---

## 2. Physical Network Topology

```
Internet (Odido Fiber 2Gbps – 87.212.133.115)
    ↓
☁  Cloud Gateway Max (192.168.10.1)
    ↓ Port 1 (2.5 GbE)
◆  Enterprise 8 PoE "Core Switch" (192.168.20.174)
    ├── Port 1:     Reolink Doorbell          (VLAN 1 – 192.168.10.247)
    ├── Port 2:     Cloud Gateway Max Uplink  (Native VLAN 1, Tagged All)
    ├── Port 3:     Flex 2.5G Entertainment   (Native VLAN 1, Tagged All – 192.168.10.166)
    ├── Port 4:     U7 Pro Max AP             (Native VLAN 1, Tagged VLAN 20 – 192.168.10.136)
    ├── Port 5:     IKEA Dirigera Hub         (VLAN 1 – 192.168.10.251)
    ├── Port 6:     CalDigit Hub → Mac Mini   (VLAN 1 – 192.168.10.245)
    ├── Port 7:     Philips Hue Bridge        (VLAN 1 – 192.168.10.137)
    └── SFP+ 2:     → Homelab Switch          (10GbE, Native VLAN 1, Tagged All – 192.168.20.27)
                ↓ (through patch panel in Geek Pi T2 rack)
◆  Unifi 16 PoE Lite "Homelab" (192.168.20.27)
    ├── Port 1:     Teleport – Raspberry Pi   (VLAN 1 – 192.168.10.238)
    ├── Port 2:     revMate – Raspberry Pi    (VLAN 1 – 192.168.10.237)
    ├── Port 3:     U6 Long Range AP          (Native VLAN 1, Tagged VLAN 20 – 192.168.10.197)
    ├── Port 4:     dell7080-cp2              (Native VLAN 30, Tagged 40,50 – 192.168.30.16)
    ├── Port 5:     dell7080-cp               (Native VLAN 30, Tagged 40,50 – 192.168.30.15)
    ├── Port 6:     hpg5-worker               (Native VLAN 30, Tagged 40,50,60 – 192.168.30.10)
    ├── Port 7:     lenovo-worker             (Native VLAN 30, Tagged 40,50,60 – 192.168.30.11)
    ├── Port 8:     dell3000-cp               (retiring 2026-04-07 — shipping to buyer; profile flips to OpenStack-Compute for hpg9-compute3)
    ├── Port 9:     hpg9-compute2             (Native VLAN 30, Tagged 40,50,60 – 192.168.30.13)
    ├── Port 10:    Synology NAS DS920+       (VLAN 1 – 192.168.10.117)
    ├── Port 11:    hpg9-compute              (Native VLAN 30, Tagged 40,50,60 – 192.168.30.14)
    ├── Ports 12–15: (Available)
    └── Port 16:    Uplink to Core Switch     (Native VLAN 1, Tagged All – 192.168.20.174)

◆  Flex 2.5G "Entertainment" (192.168.10.166)
    ├── Port 1:  Sony PlayStation 5  (VLAN 1 – 192.168.10.91)
    ├── Port 2:  Polk Soundbar       (VLAN 1 – 192.168.10.194)
    ├── Port 3:  Apple TV            (VLAN 1 – 192.168.10.163)
    ├── Port 4:  Sony Bravia TV      (currently unplugged)
    └── Port 5:  Uplink to Core Switch Port 3
```

---

## 3. VLAN Design

| VLAN | Name                  | Subnet              | Purpose                                      |
|------|-----------------------|---------------------|----------------------------------------------|
| 1    | Home Network          | 192.168.10.0/24     | Home devices, IoT, Mac Mini, NAS             |
| 20   | Management Network    | 192.168.20.0/24     | Switch mgmt, Proxmox, infrastructure         |
| 30   | Talos / OpenStack Mgmt | 192.168.30.0/24   | All OpenStack cluster nodes + K8s API        |
| 40   | K8s Pods & Services   | 192.168.40.0/24     | Pod network, K8s service CIDR                |
| 50   | Ceph Storage          | 192.168.50.0/24     | Ceph replication traffic                     |
| 60   | OpenStack Tenant VMs  | 192.168.60.0/24     | VM tenant/provider network                   |
| 70   | Proxmox Cluster       | 192.168.70.0/24     | Proxmox nodes and VMs                        |

**Switch Port Profiles (UniFi):**
- `OpenStack-CP` → Native: VLAN 30, Tagged: 40, 50
- `OpenStack-Worker` → Native: VLAN 30, Tagged: 40, 50, 60
- `OpenStack-Compute` → Native: VLAN 30, Tagged: 40, 50, 60
- `Proxmox` → Native: VLAN 70

---

## 4. Physical Hardware Inventory

### Homelab Mini-Rack (Geek Pi T2)

| Slot | Hostname         | Device                    | CPU          | RAM  | Disks                          | Role                        |
|------|------------------|---------------------------|--------------|------|--------------------------------|-----------------------------|
| 0    | hpg9-compute2    | HP EliteDesk G9 800       | i5 12th Gen  | 24GB | 256GB NVMe KIOXIA KBG40 (OS) + 476.9GB SATA SPCC SSD (OSD) | OpenStack Compute (Ubuntu)  |
| 1    | hpg9-compute     | HP EliteDesk G9 800       | i5 12th Gen  | 24GB | 256GB NVMe KIOXIA KBG50 (OS) + 465.8GB SATA Crucial MX500 (OSD) | OpenStack Compute (Ubuntu)  |
| 2    | hpg5-worker      | HP EliteDesk G5 800       | i7 10th Gen  | 32GB | 256GB NVMe KIOXIA KXG60 (OS) + 500GB NVMe Samsung 980 (OSD) | Talos Worker + Ceph OSD     |
| 3    | lenovo-worker    | Lenovo ThinkCenter M720q  | i5 8th Gen   | 32GB | 256GB SATA Samsung MZ7LH (OS) + 500GB NVMe Samsung 980 (OSD) | Talos Worker + Ceph OSD     |
| 4    | dell3000-cp      | Dell Optiplex 3000        | i5 12th Gen  | 16GB | 256GB NVMe Micron 2450 (OS, ships w/ unit) | **Retiring — sold, shipping 2026-04-07** (drained 2026-04-05; SanDisk SATA SSD pulled and moving to hpg9-compute3 as 2nd Ceph OSD) |
| 5    | dell7080-cp2     | Dell Optiplex 7080        | i5 10th Gen  | 16GB | 256GB NVMe KIOXIA KBG40 (OS) + 250GB SATA Samsung 860 EVO (idle) | Talos Control Plane         |
| 6    | dell7080-cp      | Dell Optiplex 7080        | i5 10th Gen  | 16GB | 256GB NVMe KIOXIA KBG40 (OS) + 240GB SATA Lexar NQ100 (idle) | Talos Control Plane         |
| 7    | —                | Synology NAS DS920+       | —            | 12GB | 4× 4TB HDD                     | NAS (VLAN 1)                |

### Proxmox (retired)
- `pve-node0` was wiped and repurposed as Talos control plane `dell7080-cp2` (192.168.30.16) on 2026-04-05. Its two test VMs (`docker-host`, `k3d-cluster`) were disposable and discarded.
- `pve-node1` was previously repurposed as an OpenStack compute node.
- No Proxmox nodes remain in the homelab.

---

## 5. Kubernetes Cluster (Talos Linux)

**OS:** Talos Linux (immutable, no SSH, managed via `talosctl`)
**K8s VIP (HA):** `192.168.30.100`
**Talos config:** `talos/talosconfig`
**Kubeconfig:** standard `~/.kube/config` or via `talosctl kubeconfig`

### Nodes

| Hostname       | IP              | Role          | Talos config file    |
|----------------|-----------------|---------------|----------------------|
| dell7080-cp    | 192.168.30.15   | Control Plane | `dell7080-cp.yaml`   |
| dell7080-cp2   | 192.168.30.16   | Control Plane | `dell7080-cp2.yaml`  |
| lenovo-worker  | 192.168.30.11   | Worker        | `lenovo-worker.yaml` |
| hpg5-worker    | 192.168.30.10   | Worker        | `hpg5-worker.yaml`   |

**Note:** `dell3000-cp` was retired from the cluster on 2026-04-05 (drained, `etcd leave`, `kubectl delete node`). Hardware sold and ships 2026-04-07. `dell7080-cp2` remains at 192.168.30.16 permanently — IP 192.168.30.12 retires with the Dell. Cluster is now 2-CP (dell7080-cp + dell7080-cp2). A new OpenStack compute node `hpg9-compute3` (HP EliteDesk 900 G9, IP 192.168.30.17) will join via Port 8 after Dell ships.

**Note:** `hpg9-compute` and `hpg9-compute2` run **Ubuntu 22.04**, not Talos. They join the cluster as worker nodes via kubeadm scripts. They run Nova compute + libvirt/QEMU + Open vSwitch at the host OS level.

### Compute Node SSH Credentials

| Hostname       | IP             | SSH User       | Password    |
|----------------|----------------|----------------|-------------|
| hpg9-compute   | 192.168.30.14  | hpg9-compute   | <your-ssh-password>  |
| hpg9-compute-2 | 192.168.30.13  | compute2       | <your-ssh-password>  |

### Node Labels (important for scheduling)

| Label                         | Value     | Nodes                          | Used by             |
|-------------------------------|-----------|--------------------------------|---------------------|
| `openvswitch=enabled`         | enabled   | hpg9-compute, hpg9-compute2    | Neutron OVS agents  |
| `openstack-nova-compute`      | enabled   | hpg9-compute, hpg9-compute2    | Nova compute pods   |

---

## 6. Storage — Rook-Ceph

**Ceph version:** v19.2.0 (Squid)
**Rook operator:** v1.16.5
**Namespace:** `rook-ceph`

### OSDs

| Node           | Disk Device | Size  | Type      |
|----------------|-------------|-------|-----------|
| lenovo-worker  | nvme0n1     | 500GB | NVMe      |
| hpg5-worker    | nvme1n1     | 500GB | Samsung NVMe |
| hpg9-compute   | sda         | 500GB | SATA SSD  |
| hpg9-compute2  | sda         | 500GB | SATA SSD  |

**Note:** `hpg9-cp2` (now `hpg9-compute2`) previously had an HDD as OSD which caused node crashes — removed. `hpg9-cp1` (now `hpg9-compute`) OSD was also removed during repurpose.

### Mons
- 3 mons: `rook-ceph-mon-b` (10.110.72.200), `rook-ceph-mon-e` (10.101.147.242), `rook-ceph-mon-f` (10.97.178.211)
- b and e on control plane nodes; f on `lenovo-worker` (added 2026-03-27 for quorum resilience)
- Placement: `nodeAffinity` allows control-plane nodes OR `lenovo-worker` by hostname
- Can now tolerate 1 mon failure without losing quorum

### Pools (created manually)
```bash
ceph osd pool create volumes 32   # Cinder block volumes
ceph osd pool create images 32    # Glance images
ceph osd pool create vms 32       # Nova ephemeral
```

### Ceph Users
- `client.cinder` — `mon 'profile rbd', osd 'profile rbd pool=volumes,images,vms'`
- `client.glance` — `mon 'profile rbd', osd 'profile rbd pool=images'`
- `client.nova` — `mon 'profile rbd', osd 'profile rbd pool=vms, profile rbd pool=volumes', mgr 'profile rbd pool=vms, profile rbd pool=volumes'`

### Dashboard Access
- **URL:** `https://192.168.30.202:8443` (MetalLB LoadBalancer — `rook-ceph-mgr-dashboard-lb` svc)
- **Username:** `admin`
- **Password:** `kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath="{['data']['password']}" | base64 --decode`

---

## 7. OpenStack Deployment

**Method:** OpenStack-Helm charts, deployed via ArgoCD GitOps
**Namespace:** `openstack`
**Git repo:** `https://github.com/osm1n/openstack-homelab-gitops.git`
**ArgoCD sync waves:** Infrastructure (waves 1–4) → OpenStack prereqs (wave 5) → Services (waves 6–12)

### Services Deployed

| Service    | Chart Source       | Wave | Purpose                         |
|------------|--------------------|------|---------------------------------|
| MariaDB    | Bitnami (umbrella) | 5    | Database backend                |
| RabbitMQ   | groundhog2k        | 5    | Message queue                   |
| Memcached  | Bitnami (umbrella) | 5    | Token caching                   |
| Keystone   | OpenStack-Helm     | 6    | Identity & auth                 |
| Glance     | OpenStack-Helm     | 7    | Image service (filesystem/PVC)  |
| Placement  | OpenStack-Helm     | 8    | Resource tracking               |
| Libvirt    | OpenStack-Helm     | 9    | Hypervisor daemon (compute nodes) |
| OpenVSwitch | OpenStack-Helm    | 9    | Chart kept; OVS daemonset disabled (host OVS mode) |
| Nova       | OpenStack-Helm     | 10   | Compute service                 |
| Neutron    | OpenStack-Helm     | 10   | Networking (ML2/OVS/VXLAN)      |
| Cinder     | OpenStack-Helm     | 11   | Block storage (Ceph RBD)        |
| Skyline    | OpenStack-Helm     | 12   | Web dashboard                   |

**Important — Helm chart versions (umbrella chart pattern):**
All OpenStack-Helm charts are vendored as `.tgz` files under `infrastructure/openstack/<service>/charts/`.
Bitnami charts are stored as umbrella charts (to avoid Bitnami redirect issues with ArgoCD).

### Key Config Decisions

- **`helm3_hook: false`** on all OpenStack-Helm charts — prevents ArgoCD chicken-and-egg deadlock with Jobs
- **`job_rabbit_init: false`** on Nova and Neutron — RabbitMQ vhosts created manually
- **Nova compute** uses `connection_uri: "qemu:///system"` (host libvirt socket) with `cpu_mode: host-passthrough`
- **Nova Ceph enabled** (`ceph_client: configmap: ceph-etc`) — Nova uses Ceph RBD (`vms` pool) for ephemeral root disks via `client.nova` user
- **Nova Glance config** — `api_servers` must be set WITHOUT `/v2` suffix (chart auto-generates with `/v2` causing `/v2/v2/images` 404). Set explicitly: `api_servers: http://glance-api.openstack.svc.cluster.local:9292`
- **Nova cell mapping** — cell1 transport_url must match `openstack-rabbitmq.openstack.svc.cluster.local` (not statefulset pod DNS). Set `oslo_messaging.statefulset: null` in values to prevent wrong URL generation
- **Neutron ML2** with `openvswitch` driver, VXLAN tunnels (`vni_ranges: 1:65535`, **UDP port 4790** to avoid Flannel conflict), `bridge_mappings: provider:br-ex`
- **Glance** uses filesystem storage backed by a `ceph-block` PVC (not direct RBD — Glance pods can't access Ceph via librados)
- **Cinder** uses Ceph RBD (`volumes` pool) as backend, `job_storage_init: false`, `rbd_secret_uuid: 457eb676-33da-42ec-9a8c-9293d545c338` (dedicated cinder libvirt secret, NOT the nova one)
- **RabbitMQ** uses `groundhog2k/rabbitmq` chart (not Bitnami) — Bitnami removed images from Docker Hub

### Nova Flavors (auto-created by bootstrap)
| Name      | vCPU | RAM   | Disk |
|-----------|------|-------|------|
| m1.tiny   | 1    | 512MB | 1GB  |
| m1.small  | 1    | 2GB   | 20GB |
| m1.medium | 2    | 4GB   | 40GB |
| m1.large  | 4    | 8GB   | 80GB |
| m1.xlarge | 8    | 16GB  | 160GB |

### Active VMs

| Name         | ID       | Flavor    | Image         | Compute Node   | IPs                            | Volumes            |
|-------------|----------|-----------|---------------|----------------|--------------------------------|--------------------|
| ArchSmalls  | 9c61b3a6 | m1.medium | Arch          | —              | 10.0.0.47, 192.168.60.116      | —                  |
| wazuh       | 524f471a | m1.large  | Ubuntu-22.04  | hpg9-compute   | 10.0.0.26, 192.168.60.185      | wazuh-data (200GB) |
| RockySmalls | f4789693 | m1.small  | Rocky Linux 9 | —              | 10.0.0.113, 192.168.60.111     | —                  |
| UbuntuSmalls| 5a4a2e8a | m1.small  | Ubuntu24.04   | —              | 10.0.0.21, 192.168.60.186      | —                  |
| DebianSmalls| 0ffcd0d9 | m1.small  | Debian12      | —              | 10.0.0.199, 192.168.60.117     | —                  |

---

## 8. Infrastructure Layer (ArgoCD Managed)

| Component        | Version  | IP / Access                  | Notes                               |
|------------------|----------|------------------------------|-------------------------------------|
| MetalLB          | 0.14.9   | Pool: 192.168.30.200–250     | L2 advertisement mode               |
| Nginx Ingress    | 4.12.0   | 192.168.30.201               | LoadBalancer via MetalLB            |
| Rook-Ceph Op.    | v1.16.5  | —                            | Manages CephCluster CR              |
| Cert-Manager     | v1.17.1  | —                            | TLS cert management                 |
| ArgoCD           | —        | 192.168.20.200 (via port?)   | Manages all resources               |

---

## 9. External Access (from Mac Mini)

### /etc/hosts entries required

```
# OpenStack Services (via MetalLB Ingress 192.168.30.201)
192.168.30.201 keystone.openstack.svc.cluster.local
192.168.30.201 glance.openstack.svc.cluster.local
192.168.30.201 nova.openstack.svc.cluster.local
192.168.30.201 neutron.openstack.svc.cluster.local
192.168.30.201 cinder.openstack.svc.cluster.local
192.168.30.201 placement.openstack.svc.cluster.local
192.168.30.201 metadata.openstack.svc.cluster.local
192.168.30.201 novncproxy.openstack.svc.cluster.local
192.168.30.201 skyline.openstack.svc.cluster.local
```

### Service URLs

| Service               | URL                                          | Notes                              |
|-----------------------|----------------------------------------------|------------------------------------|
| Skyline Dashboard     | `http://skyline.openstack.svc.cluster.local` | user: admin / pw: see below       |
| Keystone API          | `http://keystone.openstack.svc.cluster.local/v3` | Used by openrc.sh             |
| Nova API              | `http://nova.openstack.svc.cluster.local`    | Port 8774 internally               |
| Neutron API           | `http://neutron.openstack.svc.cluster.local` | Port 9696 internally               |
| Glance API            | `http://glance.openstack.svc.cluster.local`  | Port 9292 internally               |
| Cinder API            | `http://cinder.openstack.svc.cluster.local`  | Port 8776 internally               |
| Ceph Dashboard        | `https://192.168.30.202:8443`                | Direct MetalLB IP, self-signed cert|

### OpenRC (CLI auth)

File: `talos/openrc.sh`

```bash
source talos/openrc.sh
# Enter password when prompted: <your-openstack-admin-password>
```

`openrc.sh` should use `OS_AUTH_URL=http://keystone.openstack.svc.cluster.local/v3/` (single `/v3`).

### OpenStack Credentials

| Account   | Username | Password                   | Project |
|-----------|----------|----------------------------|---------|
| Admin     | admin    | `<your-openstack-admin-password>` | admin   |
| Skyline UI| admin    | `<your-openstack-admin-password>` | admin   |

---

## 10. Key Passwords Reference

| Service           | Username   | Password                         |
|-------------------|------------|----------------------------------|
| MariaDB root      | root       | `<your-mariadb-root-password>`        |
| MariaDB keystone  | keystone   | `<your-keystone-db-password>`           |
| MariaDB nova      | nova       | `<your-nova-db-password>`               |
| MariaDB neutron   | neutron    | `<your-neutron-db-password>`            |
| MariaDB cinder    | cinder     | `<your-cinder-db-password>`             |
| MariaDB glance    | glance     | `<your-glance-db-password>`             |
| MariaDB skyline   | skyline    | `<your-skyline-db-password>`            |
| RabbitMQ          | openstack  | `<your-rabbitmq-password>`    |
| Keystone admin    | admin      | `<your-openstack-admin-password>`       |
| Keystone nova     | nova       | `<your-nova-keystone-password>`         |
| Keystone neutron  | neutron    | `<your-neutron-keystone-password>`      |
| Keystone glance   | glance     | `<your-glance-keystone-password>`       |
| Keystone cinder   | cinder     | `<your-cinder-keystone-password>`       |
| Keystone placement| placement  | `<your-placement-keystone-password>`    |
| Keystone skyline  | skyline    | `<your-skyline-keystone-password>`      |
| Metadata proxy    | —          | `<your-metadata-shared-secret>`         |
| Ceph Dashboard    | admin      | (from k8s secret, see §6)        |

---

## 11. Networking Architecture (Neutron)

**Driver:** ML2 + OpenVSwitch
**Mechanism drivers:** `openvswitch`, `l2population`
**Type drivers:** `flat`, `vlan`, `vxlan`
**Tenant network type:** `vxlan` (VNI range: 1–65535)
**Provider network:** `flat` on `br-ex` (mapped to physical interface on compute nodes)

### OVS Bridge Layout (on compute nodes)

```
Physical NIC (VLAN 60 trunk)
    ↓
br-ex  (provider network bridge — bridge_mappings: provider:br-ex)
    ↓
br-int (integration bridge — all VM ports patch here)
    ↓
br-tun (tunnel bridge — VXLAN encapsulation between compute nodes)
```

**Agents running on compute nodes** (via DaemonSet, node selector `openvswitch=enabled`):
- `neutron-ovs-agent`
- `neutron-dhcp-agent`
- `neutron-l3-agent`
- `neutron-metadata-agent`

**Nova-Neutron integration:** Nova passes `neutron.auth_url`, `neutron.username`, etc. via `nova.conf [neutron]` section. Metadata proxy uses shared secret `<your-metadata-shared-secret>`.

---

## 12. ArgoCD Sync Wave Order

```
Wave 1:  MetalLB + MetalLB config
Wave 2:  Rook-Ceph operator + operator config
Wave 3:  Rook-Ceph cluster (CephCluster CR, OSDs, dashboard LB)
Wave 4:  Ingress-Nginx + Cert-Manager
Wave 5:  OpenStack namespace + MariaDB + RabbitMQ + Memcached
Wave 6:  Keystone
Wave 7:  Glance
Wave 8:  Placement
Wave 9:  Libvirt + OpenVSwitch
Wave 10: Nova + Neutron
Wave 11: Cinder
Wave 12: Skyline
```

---

## 13. Known Quirks & Gotchas

### OpenStack-Helm specific
- **`logging.conf` root handler is `null` by default** — The chart's default `logging.conf` routes the root logger to a `null` handler. This means errors from `oslo_service`, `oslo_messaging`, `keystoneauth`, `sqlalchemy`, and any non-`nova.*` logger are **silently discarded**. Override `conf.logging` in values.yaml to route root to `stdout`. This is already done for Nova; check other services if they exhibit invisible crashes.
- **`/var/lib/nova/compute_id` and hostname mismatch** — Nova stores a `compute_id` UUID file on the host via hostPath. If a debug pod or test pod with a different hostname runs on the same node and mounts `/var/lib/nova`, it will register that UUID under the wrong hostname. The real daemonset pod then fails with `InvalidConfiguration: Possible rename detected, refusing to start!` — and this error is invisible if root logger goes to null. Never mount `/var/lib/nova` from a pod with a non-matching hostname.
- **`network.<servicename>.ingress`** — each chart uses a different key under `network.*` matching its own service name. Skyline uses `network.skyline.ingress`, NOT `network.api.ingress`. Always check `templates/ingress.yaml` in the chart to confirm.
- **`helm3_hook: false`** is required on all OpenStack-Helm charts when using ArgoCD. Without it, Jobs become PostSync hooks and create a deadlock with Deployment init containers.
- **`job_rabbit_init: false`** on Nova and Neutron — vhosts must be created manually:
  ```bash
  kubectl exec -n openstack openstack-rabbitmq-0 -- rabbitmqctl add_vhost nova
  kubectl exec -n openstack openstack-rabbitmq-0 -- rabbitmqctl set_permissions -p nova openstack ".*" ".*" ".*"
  ```
- **Keystone fernet/credential keys** — ArgoCD `ignoreDifferences` on `/data` of those secrets is required to prevent ArgoCD from wiping them on self-heal.
  - Failure mode when keys are empty: Keystone auth returns HTTP 500 on `/v3/auth/tokens`, Skyline login returns 401/500 symptoms, and `openstack token issue` fails.
  - Fast verification:
    ```bash
    kubectl -n openstack get secret keystone-fernet-keys -o go-template='{{range $k,$v := .data}}{{$k}} {{end}}{{"\n"}}'
    kubectl -n openstack get secret keystone-credential-keys -o go-template='{{range $k,$v := .data}}{{$k}} {{end}}{{"\n"}}'
    openstack --os-cloud homelab token issue -f value -c id
    ```
  - Recovery if keys are empty:
    - Re-run setup jobs (create one-off copies from existing Job templates)
    - Restart `keystone-api` and `skyline` deployments
  - Prevention:
    - Keep Argo ignore rules for `/data` on both key secrets
    - Avoid manual edits/deletions on key secrets
    - After any Argo hard refresh/self-heal event, run the fast verification commands above
- **Ceph keyring secrets** — store only the raw key value (no `[client.xxx]` header) in the K8s secret.
- **Libvirt Ceph secrets must exist on host** — Each Ceph RBD user needs its own libvirt secret on every compute node. Without it, VMs fail at launch with `Secret not found` or volume attach fails with `Permission denied`. Secrets are persistent across reboots (stored in `/etc/libvirt/secrets/`). **Two secrets are required** on each compute node:
  ```bash
  # Secret 1: client.nova (for ephemeral disks in 'vms' pool)
  cat > /tmp/nova-secret.xml <<'EOF'
  <secret ephemeral='no' private='no'>
    <uuid>457eb676-33da-42ec-9a8c-9293d545c337</uuid>
    <usage type='ceph'>
      <name>ceph client.nova secret</name>
    </usage>
  </secret>
  EOF
  sudo virsh secret-define /tmp/nova-secret.xml
  sudo virsh secret-set-value 457eb676-33da-42ec-9a8c-9293d545c337 <your-ceph-nova-keyring>

  # Secret 2: client.cinder (for Cinder volumes in 'volumes' pool)
  cat > /tmp/cinder-secret.xml <<'EOF'
  <secret ephemeral='no' private='no'>
    <uuid>457eb676-33da-42ec-9a8c-9293d545c338</uuid>
    <usage type='ceph'>
      <name>ceph client.cinder secret</name>
    </usage>
  </secret>
  EOF
  sudo virsh secret-define /tmp/cinder-secret.xml
  sudo virsh secret-set-value 457eb676-33da-42ec-9a8c-9293d545c338 <your-ceph-cinder-keyring>
  rm /tmp/nova-secret.xml /tmp/cinder-secret.xml
  ```
  **IMPORTANT:** Do NOT share a single libvirt secret UUID across multiple Ceph users. Nova uses UUID `c337` with the `client.nova` key; Cinder uses UUID `c338` with the `client.cinder` key. Mixing them causes `Permission denied` on volume attach.
- **Nova chart `conf.ceph.cinder` naming** — despite the name, `conf.ceph.cinder.user` controls the Ceph user for Nova ephemeral disks. Set to `nova` (not `cinder`). Provide `conf.ceph.cinder.keyring` inline to skip the admin-auth init container which fails without Ceph admin credentials.

### Talos Linux limitations
- **No OVS kernel module** — Neutron OVS agents cannot run on Talos nodes. All OVS/networking runs on Ubuntu compute nodes only.
- **No libvirt** — Nova compute runs only on Ubuntu compute nodes (`hpg9-compute`, `hpg9-compute2`).
- **Immutable OS** — no `apt`, no SSH. Use `talosctl` for node management.

### RabbitMQ
- Uses `groundhog2k/rabbitmq` chart, NOT Bitnami (Bitnami removed images from Docker Hub).
- **`fsGroupChangePolicy: OnRootMismatch` is required** — Without this, Kubernetes `fsGroup` recursively sets `.erlang.cookie` to group-readable (`660`) on every PVC mount. Erlang requires `600`. Quick fix if it happens: `kubectl exec -n openstack openstack-rabbitmq-0 -c rabbitmq -- rm /var/lib/rabbitmq/.erlang.cookie` then delete the pod.
- The `openstack` user needs `administrator` tag for OpenStack-Helm rabbit-init jobs:
  ```bash
  kubectl exec openstack-rabbitmq-0 -n openstack -- rabbitmqctl set_user_tags openstack administrator
  ```
- **`oslo_messaging.statefulset: null`** MUST be set in all OpenStack service values. Without this, the chart generates a per-pod transport_url (e.g., `rabbitmq-rabbitmq-0.openstack-rabbitmq`) which doesn't resolve. This affects cell mappings in Nova.
- Stale RabbitMQ queues accumulate from restarted pods (conductor, scheduler). Harmless but noisy. Can be cleaned with `rabbitmqctl delete_queue`.

### OVS br-ex Bridge (CRITICAL — must be persistent)
- `br-ex` is the external/provider network bridge. It MUST have the physical NIC (`eno1`) as an OVS port.
- The management IP (192.168.30.x) MUST be on `br-ex`, NOT on `eno1`, because `eno1` is enslaved to the bridge.
- **Runtime-only `ip addr` / `ovs-vsctl` commands are NOT enough** — they are lost on reboot.
- Persistent config is via netplan at `/etc/netplan/60-ovs-bridge.yaml` using `bridges.br-ex.interfaces: [eno1]` plus `openvswitch: {}`.
- The setup script `docs/compute-node-setup/05-setup-ovs-bridge.sh` handles both runtime and persistent config.
- **Lesson learned:** Adding `eno1` to `br-ex` without persistent netplan config caused both compute nodes to lose connectivity on reboot.

### Flannel / VXLAN
- Flannel CNI uses VXLAN on UDP port **4789** (default). Neutron OVS agent also defaults to 4789. This causes `"could not add network device vxlan-* to ofproto (Address already in use)"` errors and OVS agent crash loops.
- **Fix:** Set `vxlan_udp_port: 4790` in neutron values under `plugins.openvswitch_agent.agent`.

### Glance Storage
- Glance pods CANNOT access Ceph directly via librados — `rados.Rados(conffile=...)` fails with "error connecting to the cluster".
- Use filesystem storage backed by a `ceph-block` PVC (Ceph CSI) instead of direct RBD.
- After switching backends, existing images will show as "active" with a size but return "no associated data" on download. Must re-upload images.

### Ceph OSD history
- `hpg9-cp2` (now `hpg9-compute2`) had an HDD OSD — caused node crashes from I/O contention. Removed.
- `hpg9-cp1` (now `hpg9-compute`) was repurposed from control plane to compute. Legacy config files `hpg9-cp1.yaml` / `hpg9-cp2.yaml` remain in `talos/` for reference only.
- Samsung 980 NVMe on `hpg5-worker` had NTFS partitions — had to wipe with `talosctl wipe disk`.

---

## 14. Current Status (as of 2026-04-05)

### Working ✅
- Talos Kubernetes cluster (2 CP + 2 workers + 3 Ubuntu compute nodes)
- Rook-Ceph cluster operational; CSI provisioning works
- Ceph Dashboard at `https://192.168.30.202:8443`
- MetalLB + Nginx Ingress (192.168.30.201)
- All OpenStack API services reachable from Mac via `/etc/hosts`
- OpenStack CLI (`openstack server list`, etc.) working from Mac
- Nova compute agents running on `hpg9-compute`, `hpg9-compute-2`, and `hpg9-compute3`
- Neutron OVS agents running on all 3 compute nodes (VXLAN port 4790, no Flannel conflict)
- Nova scheduling and conductor RPC working (cell1 transport_url fixed)
- Nova can reach Glance images (api_servers fix, no /v2/v2 doubling)
- Glance filesystem storage on ceph-block PVC (20Gi, Bound)
- Cirros 0.6.2 image uploaded and downloadable (image ID: `8a26e961-a766-40fa-84a2-350b7ab88932`)
- **VM creation works end-to-end!** test-vm-3 ACTIVE on hpg9-compute-2, IP 10.0.0.41, Cirros booted with DHCP
- **Live migration** — bidirectional between all 3 compute nodes (hpg9-compute, hpg9-compute-2, hpg9-compute3) for VMs created after 2026-04-05. Legacy VMs pinned to compute1/compute2 until hard-rebooted — see `docs/error-fixes.md` "Apr 5, 2026" incident "guest CPU doesn't match specification: missing features: pcid"
- **Compute-node HA** — each Ubuntu compute node runs local HAProxy (`127.0.0.1:6443`) proxying to both CPs (`.15`, `.16`). kubelet points at localhost, so any single CP can fail without taking compute nodes offline
- Cinder block storage (Ceph RBD backend) — volume attach verified working
- Wazuh VM (`524f471a`) with 200GB Cinder volume (`wazuh-data`, `5a182f16`) attached as `/dev/vdb`
- Networks created: external-net, internal-net, HA network
- Flavors: m1.tiny, m1.small, m1.medium, m1.large, m1.xlarge
- Monitoring stack healthy in ArgoCD:
  - `monitoring-kube-prometheus-stack`
  - `monitoring-loki`
  - `monitoring-promtail`
  - `monitoring-rules`
- Alerting path works end-to-end (Alertmanager -> Telegram)
- Ceph metrics are now scraped into Prometheus via ServiceMonitors:
  - `rook-ceph-mgr`
  - `rook-ceph-exporter`
- Grafana OpenStack+Ceph dashboard now shows:
  - cluster health
  - OSD up/in/total
  - MON quorum
  - MGR active
- Point-in-time Ceph telemetry observed from Prometheus during last validation:
  - `ceph_health_status=1` (WARN)
  - `sum(ceph_osd_up)=2`
  - `sum(ceph_mon_quorum_status)=2`
  - `max(ceph_mgr_status)=1`

### Known Issues 🔧
- **Glance image upload via chunked transfer** — uWSGI returns `OSError: unable to receive chunked part` or `415 Unsupported Media Type` or `502 Bad Gateway` for large images. Skyline UI upload also fails. **Workaround for large images (>1GB):** SCP to compute node, create helper pod mounting host `/tmp` + `glance-images` PVC, `cp` the file, fix ownership (`chown 42424:42424`), then insert `image_locations` DB record and set `status=active` + `size=<bytes>` in `images` table. See `docs/error-fixes.md` for full procedure.
- **UEFI VM images require OVMF firmware mount** — Nova compute containers lack `/usr/share/OVMF/` and `/usr/share/qemu/firmware/` from the host. Images with `hw_firmware_type=uefi` fail with `Failed to locate firmware descriptor files`. To support UEFI images, add `pod.mounts.nova_compute` hostPath volumes for those paths in `nova/values.yaml`. Currently not enabled — use BIOS-compatible images only.
- **Stale Nova services accumulate daily** — Each nova-scheduler/conductor pod rollout leaves a `down` service entry. These should be periodically cleaned: `openstack compute service list | grep down` then `openstack compute service delete <id>`. Add a 5s delay between deletions to avoid Nova API 503s.
- **CronJob pods stuck in Init:0/1** — `cinder-volume-usage-audit` and `nova-service-cleaner` CronJob pods periodically get stuck. Safe to delete: `kubectl delete pod -n openstack <pod-name>`.
- **Metadata initial failures on boot** — First 4 metadata requests fail because DHCP hasn't assigned the IP yet (~8s). Succeeds on 5th try. This is normal Cirros behavior — not a real issue.
- **Nova ephemeral disks now on Ceph RBD** — `NoValidHost` due to local disk headroom is resolved. Ephemeral root disks land in the `vms` Ceph pool (~1.8 TiB capacity). Preflight/capacity scripts may still be useful for RAM/vCPU checks:
  - `scripts/openstack-preflight.sh m1.medium`
  - `scripts/openstack-capacity-policy.sh --strict m1.medium m1.large`

### Recently Fixed ✅
- **hpg9-compute3 joined + Ceph OSDs added (Apr 5)** — HP EliteDesk G9 provisioned as 3rd Ubuntu compute node at 192.168.30.17. 2 new Ceph OSDs (osd.4 nvme1n1, osd.5 sda — ex-dell3000-cp). Bidirectional live-migration verified with fresh VMs. Cold-reboot survival verified (network, services, OVS, OSDs all persist).
- **Compute-node HA via local HAProxy (Apr 5)** — All 3 compute nodes switched from depending on kube-vip VIP to using a local HAProxy (`127.0.0.1:6443`) with both CPs as backends. Fixed stale backends (`.12` retired), removed redundant `kubeprism-frontend` port conflict, and updated `07-bootstrap-compute-node.sh` to stop rewriting kubelet.conf to the VIP.
- **nova-compute + neutron agents crashing on all compute nodes (Apr 5)** — 12-day-old latent bug. `hostname --fqdn` returned empty inside hostNetwork pods because `/etc/hosts` was missing the OS short hostname. Fixed by adding `compute{1,2,3}` as aliases to the `127.0.1.1` lines; persisted in bootstrap script.
- **Live migration working (Mar 22)** — Bidirectional live migration between `hpg9-compute` and `hpg9-compute-2` verified. Required: `live_migration_scheme: tcp`, `postcopy: false`, `skip_cpu_compare_on_dest: true`, `cpu_mode: host-model`, `innodb_snapshot_isolation=OFF` (MariaDB 12.x), libvirtd TCP socket with `auth_tcp=none`, CoreDNS `hosts` plugin for compute hostnames. See `docs/error-fixes.md` for full details.
- **Stale Nova services cleanup (Mar 11)** — 20+ stale `down` service entries accumulated from daily pod rollouts. Cleaned up via `openstack compute service delete <id>` with 5s delay between deletions to avoid 503s.
- **Ceph HEALTH_WARN — NFS mgr module crash (Mar 14)** — Ceph mgr NFS module crashed trying `cluster_ls` with no orchestrator backend (Rook, not cephadm). Fixed by `ceph crash archive-all` + `ceph mgr module disable nfs`. NFS module is not needed — Rook-Ceph doesn't use cephadm orchestrator.
- **KubeProxyDown Telegram alert noise suppressed (Mar 1)** — Added explicit drop matcher `alertname="KubeProxyDown"` in `scripts/setup-alertmanager-telegram.sh`.
- **RabbitMQ CrashLoopBackOff — erlang cookie permissions (Feb 28)** — Fixed by adding `fsGroupChangePolicy: OnRootMismatch`.
- **Cinder volume attach Permission denied (Feb 27)** — Created dedicated libvirt secret (UUID `c338`) with `client.cinder` key. Updated Cinder `values.yaml`.
- **Nova Ceph RBD integration (Feb 23)** — Enabled ephemeral disks on Ceph `vms` pool. Fixed stale mon IP, chart user default, and missing libvirt secret.
- **Nova-compute CrashLoopBackOff (Feb 23)** — Stale `compute_id` → DB hostname mismatch. Fixed DB + `compute_id` file + logging override.
- See `docs/error-fixes.md` for full details on all incidents.

### In Progress 🔧
- Kali Linux VM moved to Proxmox (`pve-node0`) — downloaded QEMU image, converted with `qemu-img convert -O qcow2 -c`, created VM with UEFI/OVMF. Boot issues being debugged (BdsDxe: No bootable option found).
- Ceph health is HEALTH_OK after archiving NFS crash and disabling the module.

### Next Steps 🔜
- Make CoreDNS `hosts` entries for compute nodes persistent (currently manual configmap patch, not ArgoCD-managed)
- Debug Kali VM boot on Proxmox (EFI disk setup, boot order)
- Keep daily dashboard/alert review loop active and tune alert thresholds if needed
- Add the new storage device on `hpg9-compute2`, then rebalance Ceph capacity
- Use `docs/runbooks/vm-provisioning-ssh.md` as the canonical VM create + SSH workflow
- Periodically clean stale Nova services (every 1-2 weeks)

---

## 15. Useful Commands

### Cluster health
```bash
kubectl get nodes
kubectl get pods -n openstack
kubectl get pods -n rook-ceph
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
```

### OpenStack CLI
```bash
source talos/openrc.sh
openstack service list
openstack compute service list
openstack network agent list
openstack hypervisor list
scripts/openstack-preflight.sh m1.medium
scripts/openstack-capacity-policy.sh m1.medium m1.large
```

### Talos node management
```bash
talosctl --nodes 192.168.30.12 --talosconfig=talos/talosconfig health
talosctl --nodes 192.168.30.12 --talosconfig=talos/talosconfig services
```

### ArgoCD (when reachable)
```bash
argocd app list
argocd app sync openstack-skyline
```

### ArgoCD force refresh (without CLI)
```bash
kubectl annotate application root -n argocd argocd.argoproj.io/refresh=hard --overwrite
kubectl rollout restart deployment argocd-repo-server -n argocd
```

### RabbitMQ vhost setup (if needed)
```bash
for vhost in nova neutron cinder glance; do
  kubectl exec -n openstack openstack-rabbitmq-0 -- rabbitmqctl add_vhost $vhost
  kubectl exec -n openstack openstack-rabbitmq-0 -- rabbitmqctl set_permissions -p $vhost openstack ".*" ".*" ".*"
done
```

### Ceph tools
```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd status
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph df
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- rbd ls volumes
```

**Tip:** Ceph CLI is NOT installed locally — it runs via the `rook-ceph-tools` pod. Add a shell alias for convenience:
```bash
# Add to ~/.zshrc or ~/.bashrc
alias ceph='kubectl -n rook-ceph exec deploy/rook-ceph-tools --'
# Then use: ceph ceph status, ceph ceph osd df, ceph rbd ls vms, etc.
```
**Note:** The double `ceph` (e.g., `ceph ceph -s`) is because the alias expands to the kubectl exec prefix, and the first arg is the `ceph` command itself.
