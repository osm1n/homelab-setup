# Error Fixes Documentation

This document tracks errors encountered during the OpenStack homelab deployment and their solutions.

---

## Reproducibility / Drift Prevention

### Compute node rebuild drift (manual step ordering and missed settings)

**Symptoms:**
- Rebuilds depended on session memory and command order.
- Common misses: kubelet API endpoint reverting to `127.0.0.1`, duplicate default routes, missing libvirt socket perms, netplan conflicts from cloud-init files.
- Result: long rebuild times and inconsistent post-reboot behavior.

**Fix:**
- Added idempotent bootstrap script:
  - `docs/compute-node-setup/07-bootstrap-compute-node.sh`
- Added post-bootstrap validator:
  - `docs/compute-node-setup/08-verify-compute-node.sh`
- Updated `docs/compute-node-setup/README.md` with a fast-path workflow for repeatable node bring-up.

**Prevention standard (going forward):**
- Rebuild compute nodes only through `07-bootstrap-compute-node.sh`.
- Gate node acceptance with `08-verify-compute-node.sh` PASS (no FAIL results).
- Keep node-specific values parameterized (`--node-name`, `--node-ip`, `--mgmt-ip`) to reuse across all current/future compute nodes.

---

## Resolved Incident (Feb 22-23, 2026)

### 0. Nova-compute exits cleanly then restarts (`Completed`/`CrashLoopBackOff`) after compute node rebuild

**Symptoms:**
- `nova-compute-default-*` on `hpg9-compute-2` repeatedly transitions between `Running`, `Completed`, and `CrashLoopBackOff`.
- `kubectl describe` shows:
  - `state.waiting.reason=CrashLoopBackOff`
  - `lastState.terminated.reason=Completed`
  - `lastState.terminated.exitCode=0`
- `nova-compute` on `hpg9-compute` stuck in `Init:0/3` waiting for `neutron-ovs-agent` readiness.

**Actual root cause (hpg9-compute-2):**
- `/var/lib/nova/compute_id` on the host contained UUID `110e4306-887c-4a6d-98a4-78f2b5c2f419`.
- The Nova DB `compute_nodes` table had this UUID associated with a stale hostname (`nova-debug`) from a previous debug pod that wrote to the shared hostPath.
- On startup, Nova's `_check_for_host_rename()` in `nova/compute/manager.py:1582` detected the mismatch (`host='nova-debug'` vs current `host='hpg9-compute-2'`) and raised `nova.exception.InvalidConfiguration: Possible rename detected, refusing to start!`
- The process exited with code 0 (oslo_service catches the exception and exits cleanly).

**Why the error was invisible:**
- The error was logged by `oslo_service.backend.eventlet.service` — NOT by a `nova.*` logger.
- The chart's default `logging.conf` routes the root logger to a `null` handler:
  ```
  [logger_root]
  handlers = null
  level = WARNING
  ```
- Only `nova.*` and `os.brick.*` loggers are routed to stdout. All other loggers (oslo_service, oslo_messaging, keystoneauth, sqlalchemy, etc.) are silently discarded.
- This made the ERROR traceback completely invisible in `kubectl logs`.

**What was a red herring:**
- Commits `afb963a` and `7b24dd6` added `DEFAULT.daemon: false` and `oslo_service.daemon: false` to `nova.conf`. These are NOT real Nova or oslo_service config options — they are silently ignored by Nova and had no effect.

**Actual root cause (hpg9-compute):**
- `neutron-ovs-agent` on `hpg9-compute` was `0/1 Running` (not Ready) due to stale OVS port `tap62cc2cca-91`.
- The readiness probe (`ovs-vsctl show | grep error:`) detected the stale port error and failed.
- `nova-compute` init container depended on same-node `neutron-ovs-agent` readiness → deadlock.

**Fixes applied:**

1. **DB cleanup:** Soft-deleted stale `nova-debug` records from `compute_nodes` and `services` tables in Nova DB.
2. **compute_id fix:** Updated `/var/lib/nova/compute_id` on `hpg9-compute-2` from stale UUID (`110e4306`) to the correct UUID (`d6174caf`) matching the real DB record via a Kubernetes hostPath pod.
3. **Stale OVS port:** Removed `tap62cc2cca-91` from `br-int` on `hpg9-compute` via `ovs-vsctl --if-exists del-port`.
4. **Logging fix (durable):** Overrode `conf.logging` in `infrastructure/openstack/nova/values.yaml` to route the root logger to `stdout` instead of `null`. This ensures oslo_service and other non-nova errors are visible in `kubectl logs`.
5. **Removed bogus config:** Removed `DEFAULT.daemon: false` and `oslo_service.daemon: false` from values.yaml (not real config options).

**Result:**
- Both `nova-compute` pods are `1/1 Running` on `hpg9-compute` and `hpg9-compute-2`.
- Both compute services report `enabled / up` in `openstack compute service list`.

**Prevention and operating standard:**
- **NEVER run debug/test pods that mount `/var/lib/nova` as hostPath with a different hostname.** The pod will register itself with its pod hostname, corrupting the `compute_nodes` table for that host's `compute_id`.
- **Keep logging.conf root handler set to stdout**, not null. Without this, any error outside the `nova.*` logger namespace is invisible.
- **Stale OVS ports** can reappear after VM deletions or agent restarts. The neutron readiness probe is disabled in values.yaml (error #35) to prevent this from cascading into a nova-compute deadlock.
- **After any compute node rebuild**, verify the `compute_id` file matches the DB:
  ```bash
  # Read compute_id from host (via hostPath pod or SSH)
  cat /var/lib/nova/compute_id
  # Cross-reference with DB
  kubectl -n openstack exec <nova-api-pod> -c nova-osapi -- python3 -c "
  import pymysql
  conn = pymysql.connect(host='openstack-mariadb.openstack.svc.cluster.local', port=3306, user='nova', password='<your-nova-db-password>', database='nova')
  cur = conn.cursor()
  cur.execute('SELECT uuid, host, hypervisor_hostname FROM compute_nodes WHERE deleted=0')
  for row in cur.fetchall(): print(f'uuid={row[0]} host={row[1]} hypervisor={row[2]}')
  conn.close()
  "
  ```
- Keep the one-step validation flow during incidents:
  1. Prove container exit reason (`Completed` vs `Error`).
  2. **Enable debug logging if error is invisible** — the root logger null handler hides most errors.
  3. Prove effective rendered config in Kubernetes secret.
  4. Prove effective config inside running container.
  5. Commit permanent fix in Git, then hard-refresh Argo.

---

## Infrastructure Issues

### 1. HP G9 Node (hpg9-cp2) Repeatedly Crashing

**Symptoms:**
- Node goes offline ~20-30 minutes after boot
- `kubectl get nodes` shows `NotReady`
- Kubelet stops posting status

**Root Cause:**
- The node had an HDD (not SSD) for Ceph OSD storage
- Heavy Ceph I/O on the slow HDD caused system-wide I/O contention
- Kubelet couldn't respond to health checks in time

**Fix:**
- Removed hpg9-cp2 from Ceph storage nodes in `infrastructure/rook-ceph-cluster/cluster.yaml`
- Purged OSD-0 from Ceph cluster
- Node now runs only lightweight workloads (Ceph monitor)

**Commands used:**
```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd out osd.0
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd purge 0 --yes-i-really-mean-it
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd crush remove hpg9-cp2
```

**Long-term fix:** Replace HDD with SSD on hpg9-cp2 — **RESOLVED (2026-03-27):** Physical inspection confirmed all nodes now have SSDs. hpg9-compute2 has a SPCC Solid State 476.9GB as `sda`; OSD-1 is up and healthy. Replacement disk was likely already installed and forgotten.

---

## ArgoCD / Helm Issues

### 2. ArgoCD Cannot Pull Bitnami Helm Charts

**Error:**
```
Error: invalid_reference: invalid tag
helm pull --repo https://charts.bitnami.com/bitnami mariadb failed
```

**Root Cause:**
- Bitnami helm repo redirects to `https://repo.broadcom.com/bitnami-files/`
- ArgoCD's `helm pull --repo URL` doesn't handle redirects properly
- Direct `--repo` flag bypasses helm's repo caching mechanism

**Fix:**
Use **umbrella charts** stored in git:
1. Create a wrapper chart with the Bitnami chart as a dependency
2. Run `helm dependency build` locally to download the chart
3. Commit the `.tgz` file to git
4. Point ArgoCD to the git path instead of Bitnami URL

**Example structure:**
```
infrastructure/openstack/mariadb/
├── Chart.yaml          # Declares mariadb as dependency
├── Chart.lock          # Lock file
├── values.yaml         # Custom configuration
└── charts/
    └── mariadb-24.1.1.tgz   # Downloaded chart
```

**To upgrade charts in the future:**
```bash
cd infrastructure/openstack/mariadb
# Edit Chart.yaml to update version
helm dependency update
git add . && git commit -m "Upgrade MariaDB to vX.X.X" && git push
```

---

### 3. Bitnami RabbitMQ Images Removed from Docker Hub

**Error:**
```
Failed to pull image "docker.io/bitnami/rabbitmq:4.1.3-debian-12-r1": not found
```

**Root Cause:**
- Bitnami (now owned by Broadcom) removed RabbitMQ images from Docker Hub
- All version tags return "not found"

**Fix:**
Switched to `groundhog2k/rabbitmq` chart which uses official RabbitMQ images:
```yaml
# Chart.yaml
dependencies:
  - name: rabbitmq
    version: 2.2.4
    repository: https://groundhog2k.github.io/helm-charts/
```

---

### 4. RabbitMQ "Too Short Cookie String" Error

**Error:**
```
Kernel pid terminated: "Too short cookie string"
```

**Root Cause:**
- Erlang cookie must be at least 20 characters
- Initial cookie `openstack-erlang-cookie-secret` was too short (actually it was, but the values structure was wrong)

**Fix:**
Use correct values structure for groundhog2k chart:
```yaml
rabbitmq:
  authentication:
    user:
      value: openstack
    password:
      value: <your-rabbitmq-password>
    erlangCookie:
      value: <your-rabbitmq-erlang-cookie>
```

**Note:** The groundhog2k chart uses `authentication.erlangCookie.value`, not `settings.erlangCookie`

---

### 5. Bitnami Chart + Official Image Incompatibility

**Error:**
```
/opt/bitnami/scripts/liblog.sh: No such file or directory
```

**Root Cause:**
- Tried to use official `rabbitmq:3.13-management` image with Bitnami chart
- Bitnami charts have init scripts that expect Bitnami-specific paths
- Official images don't have `/opt/bitnami/` directory structure

**Fix:**
- Use charts designed for official images (e.g., groundhog2k)
- OR use Bitnami images with Bitnami charts (if available)
- Don't mix and match

---

## Ceph Issues

### 6. Ceph OSD Disk Had NTFS Filesystem

**Error:**
```
skipping device "nvme1n1p1": ["Has a FileSystem"]
```

**Root Cause:**
- Samsung 980 NVMe on hpg5-worker had Windows NTFS partition
- Rook-Ceph won't use disks with existing filesystems

**Fix:**
```bash
talosctl -n 192.168.30.10 --talosconfig=./talosconfig wipe disk nvme1n1
```

---

### 7. Ceph Pods Can't Schedule on Control Plane

**Error:**
```
3 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: }
```

**Fix:**
Add tolerations to CephCluster spec:
```yaml
placement:
  all:
    tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
```

---

## MetalLB Issues

### 8. MetalLB Speaker Pods Blocked by PodSecurity

**Error:**
```
violates PodSecurity "baseline:latest": non-default capabilities (NET_ADMIN, NET_RAW, SYS_ADMIN)
```

**Fix:**
Add privileged labels to metallb-system namespace:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: metallb-system
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
```

---

## OpenStack-Helm Issues

### 9. Keystone Jobs Not Running - Helm Hook / ArgoCD Chicken-and-Egg Problem

**Error:**
```
Resolving dependency Job keystone-db-sync in namespace openstack failed: jobs.batch "keystone-db-sync" not found
Resolving dependency Job keystone-credential-setup in namespace openstack failed
Resolving dependency Job keystone-fernet-setup in namespace openstack failed
```

**Root Cause:**
- OpenStack-Helm charts use Helm hooks (`helm.sh/hook: post-install,post-upgrade`) for bootstrap Jobs
- ArgoCD converts `post-install` hooks to `PostSync` hooks
- PostSync hooks only run AFTER all Sync resources are healthy
- But keystone-api Deployment init container waits for these Jobs to complete
- **Chicken-and-egg**: API waits for Jobs, but Jobs only run after API is healthy

**Fix:**
Disable Helm hooks so Jobs run as regular resources:
```yaml
# values.yaml
keystone:
  helm3_hook: false
```

**How it works:**
- `helm3_hook: false` removes `helm.sh/hook` annotations from Jobs
- Jobs are now deployed during the normal Sync phase, not PostSync
- Jobs run before Deployment, allowing init containers to find them

---

### 10. Keystone Cannot Find Memcached Service

**Error:**
```
Resolving dependency Service memcached in namespace openstack failed: endpoints "memcached" not found
```

**Root Cause:**
- OpenStack-Helm expects memcached service at `memcached` (default)
- Our memcached deployment creates service named `openstack-memcached`
- Service name mismatch causes init container to wait forever

**Fix:**
Configure the correct memcached endpoint in values:
```yaml
# values.yaml

---

### 11. kube-prometheus CRDs fail in Argo with annotation size limit

**Error:**
```
CustomResourceDefinition ... is invalid: metadata.annotations: Too long: may not be more than 262144 bytes
```

**Root Cause:**
- Client-side apply path stores large `last-applied-configuration` annotation for big CRDs.
- Some Prometheus Operator CRDs exceed the annotation size limit in this flow.

**Fix:**
- Install Prometheus CRDs via server-side apply before syncing monitoring apps:
```bash
scripts/bootstrap-prometheus-crds.sh
```
- Keep monitoring app configured to manage CRDs out-of-band (`crds.enabled: false`, `skipCrds: true`).

**Prevention:**
- During fresh cluster bootstrap, run `scripts/bootstrap-prometheus-crds.sh` before Argo monitoring sync.
keystone:
  endpoints:
    oslo_cache:
      hosts:
        default: openstack-memcached
      port:
        memcache:
          default: 11211
```

**Note:** This pattern applies to all OpenStack services - always verify service names match between components.

---

### 11. ArgoCD Overwrites Fernet/Credential Keys Secrets

**Error:**
```
keystone.exception.KeysNotFound: An unexpected error prevented the server from fulfilling your request.
```

**Root Cause:**
- Fernet and credential key secrets are created as empty (`data: null`) by Helm
- Setup Jobs populate these secrets with generated keys
- ArgoCD's self-heal detects the secrets have changed (live != desired)
- ArgoCD re-syncs and overwrites the secrets with empty data

**Fix:**
Add `ignoreDifferences` to the ArgoCD Application:
```yaml
spec:
  ignoreDifferences:
    - group: ""
      kind: Secret
      name: keystone-fernet-keys
      jsonPointers:
        - /data
    - group: ""
      kind: Secret
      name: keystone-credential-keys
      jsonPointers:
        - /data
```

**Note:** This pattern applies to any OpenStack service that has setup Jobs that populate secrets.

---

### 12. RabbitMQ User Missing Administrator Tag

**Error:**
```
Managing: User: openstack
*** Access refused: /api/users/openstack
```

**Root Cause:**
- The `openstack` user created by groundhog2k chart only has `[user]` tag
- OpenStack-Helm's rabbit-init Job needs to manage users/vhosts via Management API
- Management API requires `[administrator]` tag for user management operations

**Fix:**
Grant administrator tag to the openstack user:
```bash
kubectl exec openstack-rabbitmq-0 -n openstack -- rabbitmqctl set_user_tags openstack administrator
```

**Permanent fix:** Configure in RabbitMQ values (check groundhog2k chart docs for correct syntax)

---

## General Tips

### ArgoCD Caching Issues

If ArgoCD keeps using old configuration:
1. Delete the Application: `kubectl delete application <name> -n argocd`
2. Restart repo-server: `kubectl rollout restart deployment argocd-repo-server -n argocd`
3. Hard refresh root app: `kubectl annotate application root -n argocd argocd.argoproj.io/refresh=hard --overwrite`

### Checking Helm Chart Values Structure

Before using a new chart, always check its values structure:
```bash
helm show values <repo>/<chart> | head -100
helm show values <repo>/<chart> | grep -A20 "<section>"
```

---

### 13. Nova Placement Credentials Not Templated

**Error:**
```
openstack.exceptions.NotSupported: The placement service for keystone-api.openstack.svc.cluster.local:RegionOne exists but does not have any supported versions.
```

**Root Cause:**
- The `[placement]` section in nova.conf only had `auth_type`, `auth_url`, `auth_version`
- Missing: `username`, `password`, `project_name`, `user_domain_name`, `project_domain_name`
- The chart wasn't correctly templating credentials from `endpoints.identity.auth.placement`

**Fix:**
Add explicit config overrides in values.yaml:
```yaml
nova:
  conf:
    nova:
      placement:
        auth_type: password
        auth_url: http://keystone-api.openstack.svc.cluster.local:5000/v3
        auth_version: v3
        region_name: RegionOne
        project_name: service
        project_domain_name: service
        user_domain_name: service
        username: placement
        password: <your-placement-keystone-password>
        valid_interfaces: internal
```

**Note:** This pattern applies to other services (neutron, cinder) that Nova needs to communicate with.

---

### 14. Nova RabbitMQ Vhost Not Created

**Error:**
```
Nova conductor/scheduler exit with code 0 immediately after starting
```

**Root Cause:**
- We disabled `job_rabbit_init: false` to avoid RabbitMQ admin permission issues
- But this means the `nova` vhost was never created in RabbitMQ
- Nova services connect, find no vhost, and exit cleanly

**Fix:**
Manually create the vhost:
```bash
kubectl exec -n openstack openstack-rabbitmq-0 -- rabbitmqctl add_vhost nova
kubectl exec -n openstack openstack-rabbitmq-0 -- rabbitmqctl set_permissions -p nova openstack ".*" ".*" ".*"
```

**Note:** When disabling `job_rabbit_init`, you must manually create vhosts for each OpenStack service (glance, nova, neutron, cinder, etc.)

---

## Ceph Integration

### 15. Cinder RBD Keyring Format Error

**Error:**
```
[client.cinder]
    key = [client.openstack]
	key = <your-ceph-keyring>
```

**Root Cause:**
- The OpenStack-Helm charts expect the Ceph keyring secret to contain just the key value
- We stored the full keyring format `[client.xxx]\n\tkey = ...` in the secret
- The chart wraps the secret value in its own `[client.cinder]` block, causing nested keyring entries

**Fix:**
Store only the key value (without `[client.xxx]` header) in the secret:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cinder-volume-rbd-keyring
  namespace: openstack
type: Opaque
data:
  # Just the key value, base64 encoded - NOT the full keyring format
  key: <base64-encoded-key-only>
```

**To encode correctly:**
```bash
# Get the key from Ceph
KEY=$(kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph auth get-key client.cinder)
# Base64 encode just the key
echo -n "$KEY" | base64
```

---

### 16. Cinder Storage-Init Requires Admin Ceph Credentials

**Error:**
```
[errno 13] RADOS permission denied (error connecting to the cluster)
```

**Root Cause:**
- The `cinder-storage-init` job needs to create pools and volume types
- This requires Ceph admin-level permissions
- Our `client.cinder` user only has RBD pool access, not admin access

**Fix:**
Disable the storage-init job since cinder-volume works without it:
```yaml
cinder:
  manifests:
    job_storage_init: false
```

**Note:** Volume types can be created manually if needed:
```bash
openstack volume type create ceph --property volume_backend_name=ceph
```

---

### 17. Ceph User Permissions Setup for OpenStack

**Setup Commands:**
Create dedicated Ceph users for each OpenStack service:
```bash
# Cinder user (block storage)
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph auth get-or-create client.cinder \
  mon 'profile rbd' \
  osd 'profile rbd pool=volumes, profile rbd pool=images, profile rbd pool=vms' \
  mgr 'profile rbd pool=volumes, profile rbd pool=images, profile rbd pool=vms'

# Glance user (image storage)
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph auth get-or-create client.glance \
  mon 'profile rbd' \
  osd 'profile rbd pool=images' \
  mgr 'profile rbd pool=images'

# Create pools
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd pool create volumes 32
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd pool create images 32
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd pool create vms 32
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- rbd pool init volumes
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- rbd pool init images
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- rbd pool init vms
```

---

## Talos Linux Limitations

### 18. OpenVSwitch Kernel Module Not Available on Talos

**Issue:**
OpenVSwitch requires the `openvswitch` kernel module, which is not included in the default Talos Linux kernel.

**Verification:**
```bash
# Check if OVS module is available
talosctl -n <node-ip> read /proc/modules | grep openvswitch
# Result: module not loaded and not available
```

**Impact:**
- Cannot deploy Neutron OVS agents on Talos nodes
- Network agents (dhcp, l3, metadata, ovs) cannot run

**Options:**
1. **Build custom Talos image** with OVS kernel module:
   - Use Talos Image Factory to add system extensions
   - Include openvswitch extension if available

2. **Use Linux Bridge networking** (if bridge module available):
   - Set `daemonset_lb_agent: true` in Neutron values
   - Tag nodes with `linuxbridge=enabled`

3. **Use OVN (Open Virtual Network)**:
   - OVN can use userspace datapath or standard kernel networking
   - More complex but doesn't require OVS kernel module

4. **Use external networking**:
   - Configure physical switches with VLANs
   - Use flat/VLAN provider networks only
   - No overlay networking (VXLAN/GRE)

5. **Deploy compute on non-Talos nodes**:
   - Use Ubuntu/Rocky Linux for compute nodes
   - Keep Talos for control plane only

**Current Status:**
Neutron networking agents are disabled. OpenStack control plane APIs work but VM networking requires one of the above solutions.

---

### 19. libvirt Not Available on Talos Linux

**Issue:**
Talos Linux is an immutable, minimal OS without a package manager. libvirt, QEMU, and related virtualization tools cannot be installed.

**Impact:**
- Cannot run traditional Nova compute (nova-compute requires libvirt)
- No hypervisor available for spawning VMs through OpenStack

**Solution: KubeVirt**
KubeVirt is officially supported on Talos Linux and enables running VMs as Kubernetes pods using QEMU inside containers.

**Installation:**
KubeVirt is deployed via ArgoCD in `apps/kubevirt.yaml` pointing to `infrastructure/kubevirt/`.

The kustomization pulls:
- KubeVirt operator v1.4.1
- CDI (Containerized Data Importer) v1.60.3

**Key Features Enabled:**
```yaml
spec:
  configuration:
    developerConfiguration:
      featureGates:
        - LiveMigration     # Migrate VMs between nodes
        - Snapshot          # VM snapshots
        - HotplugVolumes    # Add/remove disks without restart
        - ExpandDisks       # Grow disk size
        - VMExport          # Export VMs as container images
```

**Usage:**
```bash
# Install virtctl CLI
kubectl krew install virt

# Create a VM from DataVolume
kubectl apply -f infrastructure/kubevirt/examples/cirros-vm.yaml

# Access VM console
kubectl virt console cirros-test -n vms

# SSH into VM
kubectl virt ssh ubuntu@ubuntu-server -n vms

# List running VMs
kubectl get vmi -A
```

**Storage:**
- VMs use Ceph block storage via DataVolumes
- CDI imports images from HTTP URLs into PVCs
- Live migration requires shared storage (ceph-filesystem)

**Networking:**
- Default: Pod network with masquerade (NAT)
- Advanced: Multus for bridge networking to physical networks

**Note:** KubeVirt VMs are not managed through OpenStack Horizon/Skyline. They use the Kubernetes API and can be managed via kubectl, virtctl, or ArgoCD.

---

---

## Access / Networking Issues

### 20. OpenStack CLI Commands Fail — Keystone Hostname Not Resolvable

**Error:**
```
Failed to discover available identity versions when contacting
http://keystone.openstack.svc.cluster.local/v3/v3/
```

**Root Cause:**
- `openrc.sh` sets `OS_AUTH_URL=http://keystone.openstack.svc.cluster.local/v3/v3/`
- `keystone.openstack.svc.cluster.local` is a cluster-internal DNS name, not resolvable from the local Mac
- Without port-forwarding or a proper DNS resolver, the OpenStack CLI can't reach Keystone

**Fix:**
Add all OpenStack service hostnames to `/etc/hosts` pointing at the MetalLB nginx ingress IP (`192.168.30.201`):
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

**Note:** `192.168.30.201` is the external IP assigned to the nginx ingress controller by MetalLB. Each hostname must match the `Host` header rules defined in the respective service's ingress resource.

**Note on openrc.sh:** The `OS_AUTH_URL` has a double `/v3/v3/` path which should be `http://keystone.openstack.svc.cluster.local/v3/` — fix this if auth errors persist.

---

### 21. Skyline Dashboard Inaccessible — Wrong Ingress Class

**Symptom:**
- `kubectl get ingress skyline -n openstack` shows no `ADDRESS`
- `skyline.openstack.svc.cluster.local` returns nginx 404

**Root Cause:**
The Skyline Helm chart template reads from `network.skyline.ingress` but the values.yaml was incorrectly setting `network.api.ingress`. This caused the chart to fall back to its default `ingressClassName: ingress-openstack`, which does not exist in the cluster. The nginx ingress controller never picked up the ingress, leaving it with no address assigned.

**Diagnosis:**
```bash
kubectl get ingress skyline -n openstack
# CLASS column shows "ingress-openstack" with no ADDRESS

kubectl get ingress skyline -n openstack -o jsonpath='{.spec.ingressClassName}'
# ingress-openstack  ← wrong, should be nginx
```

**Fix:**
Change the network key in `infrastructure/openstack/skyline/values.yaml` from `api` to `skyline`:
```yaml
# WRONG
network:
  api:
    ingress:
      public: true
      classes:
        namespace: "nginx"
        cluster: "nginx"

# CORRECT
network:
  skyline:
    ingress:
      public: true
      classes:
        namespace: "nginx"
        cluster: "nginx"
```

After ArgoCD sync, the ingress picks up `CLASS: nginx` and gets `ADDRESS: 192.168.30.201`. Access Skyline at `http://skyline.openstack.svc.cluster.local` (port 80 — nginx ingress routes to backend port 9999 internally).

**Note:** Each OpenStack-Helm chart uses a different key under `network.*` matching its service name. Always check the chart template (`templates/ingress.yaml`) to confirm the correct path — don't assume it's always `network.api`.

---

### 22. Ceph Dashboard Not Accessible Externally

**Symptom:**
- Ceph Dashboard exists at `rook-ceph-mgr-dashboard` (ClusterIP, port 8443) but is only reachable via `kubectl port-forward`

**Root Cause:**
The Rook-Ceph operator creates the dashboard service as `ClusterIP` by default. No LoadBalancer or Ingress is provisioned automatically.

**Fix:**
Create a dedicated LoadBalancer service to assign a MetalLB IP:
```yaml
# infrastructure/rook-ceph-cluster/dashboard-loadbalancer.yaml
apiVersion: v1
kind: Service
metadata:
  name: rook-ceph-mgr-dashboard-lb
  namespace: rook-ceph
spec:
  type: LoadBalancer
  loadBalancerIP: 192.168.30.202
  ports:
    - name: dashboard
      port: 8443
      targetPort: 8443
      protocol: TCP
  selector:
    app: rook-ceph-mgr
    rook_cluster: rook-ceph
```

**Access:**
- URL: `https://192.168.30.202:8443`
- Username: `admin`
- Password: `kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath="{['data']['password']}" | base64 --decode`

Accept the self-signed certificate warning in the browser.

**Note:** No `/etc/hosts` entry needed — access is by direct IP via MetalLB L2 advertisement.

---

---

### 23. Nova "Can not find requested image" — Glance api_servers /v2/v2 Path Doubling

**Error:**
```
HttpException: 400: Client Error for url: http://nova-api:8774/v2.1/servers
"Can not find requested image 59f4dba4-... (HTTP 400)"
```

**Root Cause:**
- The Helm chart's `configmap-etc.yaml` auto-generates `api_servers` from endpoints config if empty: `{{- if empty .Values.conf.nova.glance.api_servers -}}`
- It uses the `image` endpoint which includes `/v2` in the path
- This produces `api_servers = http://glance-api.openstack.svc.cluster.local:9292/v2`
- glanceclient v2 always appends `/v2` to the base URL
- Result: requests go to `/v2/v2/images` which returns 404 from Glance
- Nova's `get_api_servers()` function uses `api_servers` directly (bypassing keystoneauth1 adapter which would strip the version suffix)

**Fix:**
Explicitly set `api_servers` WITHOUT the `/v2` suffix in nova values.yaml:
```yaml
nova:
  conf:
    nova:
      glance:
        valid_interfaces: internal
        api_servers: http://glance-api.openstack.svc.cluster.local:9292
```

**Note:** Setting `endpoint_override` does NOT help because Nova checks `CONF.glance.api_servers` first and uses it directly if non-empty.

---

### 24. Neutron OVS Agent Crash Loop — Flannel VXLAN Port Conflict

**Error:**
```
ovs-vsctl show | grep error:
error: "could not add network device vxlan-c0a81e0d to ofproto (Address already in use)"
```

**Root Cause:**
- Flannel CNI uses VXLAN encapsulation on UDP port 4789 (the IANA default)
- Neutron OVS agent also uses port 4789 by default for VXLAN tunnels
- Both try to bind the same UDP port, causing the OVS agent to fail
- The OVS readiness probe (`ovs-vsctl show | grep error:`) detects this and marks the pod as not ready
- This cascades: nova-compute init containers wait for neutron-ovs-agent readiness → nova-compute stuck in Init:0/3

**Fix:**
Set a different VXLAN port for Neutron in neutron values.yaml:
```yaml
neutron:
  conf:
    plugins:
      openvswitch_agent:
        agent:
          vxlan_udp_port: 4790
```

**Temporary fix (manual, reverts on pod restart):**
```bash
ovs-vsctl del-port br-tun vxlan-<hex>  # Delete the conflicting port
```

---

### 25. Nova Cell Mapping Wrong Transport URL — VMs Stuck in BUILD/scheduling

**Error:**
- VMs created but stuck in `BUILD` / `scheduling` state forever
- Nova conductor has almost no logs (only RPC version selection)
- Nova scheduler shows no scheduling activity

**Root Cause:**
- `nova-manage cell_v2 list_cells` showed cell1 transport_url as:
  `rabbit://openstack:****@rabbitmq-rabbitmq-0.openstack-rabbitmq.openstack.svc.cluster.local:5672/nova`
- This hostname `rabbitmq-rabbitmq-0.openstack-rabbitmq` does NOT resolve (DNS lookup fails)
- The cell_setup job generated this wrong URL because `oslo_messaging.statefulset` was not set to `null`
- The Helm chart template constructs a per-pod URL when statefulset config is present
- Conductor couldn't communicate with compute nodes via the cell's transport URL

**Diagnosis:**
```bash
# Check cell mappings
kubectl -n openstack exec <nova-api-pod> -- nova-manage --config-file /etc/nova/nova.conf cell_v2 list_cells

# Verify DNS resolution
kubectl -n openstack exec <nova-api-pod> -- python3 -c "import socket; print(socket.gethostbyname('rabbitmq-rabbitmq-0.openstack-rabbitmq.openstack.svc.cluster.local'))"
# FAILED: Name or service not known
```

**Fix:**
1. Update cell1 transport URL:
```bash
kubectl -n openstack exec <nova-api-pod> -- nova-manage --config-file /etc/nova/nova.conf \
  cell_v2 update_cell --cell_uuid <cell1-uuid> \
  --transport-url "rabbit://openstack:<your-rabbitmq-password>@openstack-rabbitmq.openstack.svc.cluster.local:5672/nova"
```

2. Set `statefulset: null` in all service values.yaml oslo_messaging sections to prevent recurrence:
```yaml
endpoints:
  oslo_messaging:
    statefulset: null
```

3. Restart nova-conductor to pick up the new cell mapping (it caches cell data).

---

### 26. Glance Image Download Fails — "Image has no associated data"

**Error:**
```
nova.exception.ImageUnacceptable: Image 59f4dba4-... is unacceptable: Image has no associated data
```

**Root Cause:**
- Glance was configured to use Ceph RBD as the storage backend (`default_backend: rbd`)
- Glance pods cannot access Ceph directly via librados — `rados.Rados()` fails with "error connecting to the cluster"
- Images were uploaded and metadata was saved to the DB (showing as "active" with a size), but actual image data was never stored (or stored in an inaccessible RBD pool)
- When Nova compute tries to download the image, glanceclient returns no data

**Diagnosis:**
```python
# From inside a pod:
from glanceclient import Client
glance = Client('2', endpoint='http://glance-api:9292', session=sess)
img = glance.images.get('<image-id>')
print(img.status, img.size)  # "active", 21430272
data = glance.images.data('<image-id>')
print(data)  # None — no data!
```

**Fix:**
Switch Glance from direct RBD to filesystem storage with a ceph-block PVC:
```yaml
glance:
  storage: pvc
  conf:
    ceph:
      enabled: false
    glance:
      glance_store:
        default_backend: file
        enabled_backends: "file:file,http:http"
        filesystem_store_datadir: /var/lib/glance/images
      DEFAULT:
        enabled_backends: "file:file,http:http"
  volume:
    class_name: ceph-block
    size: 20Gi
  ceph_client:
    configmap: ""
    user_secret_name: ""
```

**Note:** After switching storage backends, all existing images must be re-uploaded since the old image data is inaccessible.

---

### 27. Nova values.yaml Duplicate Key — conf.nova Overridden

**Issue:**
Nova `values.yaml` has duplicate `nova:` keys under `conf:`:
```yaml
conf:
  nova:          # Line 24 — libvirt settings
    libvirt:
      virt_type: kvm
      ...
  nova:          # Line 30 — placement/neutron/glance settings (OVERRIDES line 24!)
    placement:
      ...
```

**Impact:**
- YAML spec says duplicate keys: last one wins
- The libvirt settings from the first `nova:` block are silently lost
- The chart's default libvirt config may still work, but explicit overrides won't take effect

**Fix:**
Merge both blocks into a single `nova:` key:
```yaml
conf:
  nova:
    libvirt:
      virt_type: kvm
      cpu_mode: host-passthrough
      connection_uri: "qemu:///system"
      images_type: default
    placement:
      ...
    neutron:
      ...
    glance:
      ...
```

**Status:** Known issue, not yet fixed. The chart defaults handle libvirt config adequately for now.

---

### 28. Glance Image Upload Fails — uWSGI Chunked Transfer Error

**Error:**
```
glanceclient.exc.HTTPInternalServerError: HTTP 500 Internal Server Error
```

Glance log:
```
OSError: unable to receive chunked part
```

**Root Cause:**
- glanceclient uses chunked transfer encoding (`Transfer-Encoding: chunked`) for image uploads
- Glance runs behind uWSGI, which has issues receiving chunked data in some configurations
- The `uwsgi.chunked_read()` call fails

**Workaround:**
Upload images using `requests` library with explicit `Content-Length` (not chunked):
```python
import requests

with open('/tmp/image.img', 'rb') as f:
    data = f.read()

headers = {
    'X-Auth-Token': token,
    'Content-Type': 'application/octet-stream',
    'Content-Length': str(len(data))
}
resp = requests.put(f'http://glance-api:9292/v2/images/{image_id}/file',
                    headers=headers, data=data)
```

**Note:** This reads the entire image into memory. For large images (>1GB), consider using curl with `--data-binary` or fixing the uWSGI chunked transfer config.

---

### 29. Skyline Dashboard — "Get instances error. System is error"

**Error:**
Skyline Compute > Instances page shows: "Get instances error. System is error, please try again later." and "No Data", even though VMs exist and are ACTIVE.

**Root Cause:**
- Skyline's `extension/servers` endpoint fetches instance details including images via glanceclient
- glanceclient v2 always appends `/v2` to the base URL from the Keystone service catalog
- The Glance `image` endpoint in Keystone had `path: /v2` configured
- This caused requests to go to `/v2/v2/images` → 404 from Glance
- The image lookup failure cascaded to a full "system error" in Skyline

**Fix:**
1. Remove `/v2` from the Glance image endpoint path in `glance/values.yaml`:
```yaml
glance:
  endpoints:
    image:
      path:
        default: null  # Was /v2 — glanceclient adds /v2 automatically
```

2. Delete and recreate the Keystone endpoints job:
```bash
kubectl -n openstack delete job glance-ks-endpoints
# ArgoCD will recreate it with the corrected path
```

3. Restart Skyline to pick up the endpoint change:
```bash
kubectl -n openstack rollout restart deployment skyline

```

**Status:** Fixed. Skyline now shows instances, images, flavors, and hypervisors correctly.

---

### 30. VM Metadata Service Unreachable (169.254.169.254)

**Error:**
Cirros console output shows:
```
checking http://169.254.169.254/2009-04-04/instance-id
failed 1/20: up 0.86. request failed
failed 2/20: up 2.86. request failed
...
successful after 5/20 tries: up 8.76. iid=i-00000007
```

**Root Cause:**
- `metadata_proxy_shared_secret` mismatch between Nova and Neutron
- Nova's `[neutron]` section defaulted to `metadata_proxy_shared_secret = password` (chart default)
- Neutron's `metadata_agent.ini` had `metadata_proxy_shared_secret = <your-metadata-shared-secret>`
- The proxy chain: VM → 169.254.169.254:80 (haproxy in qdhcp namespace) → Unix socket → neutron-metadata-agent → nova-api-metadata
- The shared secret is used to sign requests between neutron-metadata-agent and nova-api-metadata

**Fix:**
Set the correct shared secret in Nova values.yaml under `conf.nova.neutron`:
```yaml
nova:
  conf:
    nova:
      neutron:
        metadata_proxy_shared_secret: <your-metadata-shared-secret>
        service_metadata_proxy: true
```

**Metadata proxy chain (for reference):**
```
VM (10.0.0.41) → route via 10.0.0.10 (DHCP port)
  → haproxy in qdhcp-<network-id> namespace (169.254.169.254:80)
    → Unix socket /var/lib/neutron/openstack-helm/metadata_proxy
      → neutron-metadata-agent (adds X-Instance-ID header using shared secret)
        → nova-metadata.openstack.svc.cluster.local:8775
```

**Note:** The first 4 requests fail because DHCP hasn't assigned the IP yet (~8 seconds). The metadata route `169.254.169.254 via 10.0.0.10` is only available after DHCP completes. This is expected behavior with Cirros — it retries up to 20 times.

**Status:** Fixed. Metadata service works after DHCP completes (succeeds on try 5 of 20).

---

### 31. Compute Nodes Lose Connectivity After Reboot — br-ex Not Persistent

**Error:**
After adding `eno1` to `br-ex` via `ovs-vsctl` and migrating the management IP with `ip addr`, the compute node loses all network interfaces on reboot. `ip addr show` shows no IP on any interface.

**Root Cause:**
- `ovs-vsctl add-port br-ex eno1` IS persistent (stored in `/etc/openvswitch/conf.db`)
- But `ip addr add/del` is NOT persistent — lost on reboot
- On reboot, OVS starts and enslaves `eno1` to `br-ex` (from ovsdb)
- Netplan/systemd-networkd tries to configure `eno1` with its old IP
- Since `eno1` is enslaved to an OVS bridge, the IP assignment on `eno1` doesn't work properly
- `br-ex` has no IP configured by netplan → no management connectivity

**Fix:**
Use proper netplan OVS bridge configuration that survives reboots:
```yaml
# /etc/netplan/60-ovs-bridge.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    eno1:
      dhcp4: false
      dhcp6: false
  bridges:
    br-ex:
      interfaces: [eno1] # Enslave physical NIC to the bridge
      openvswitch: {}    # Marks this as an OVS bridge (not a Linux bridge)
      addresses:
        - 192.168.30.X/24
      routes:
        - to: default
          via: 192.168.30.1
      nameservers:
        addresses: [192.168.10.1]
```

Key points:
- Use `bridges.br-ex.interfaces: [eno1]` to enslave the physical NIC
- `bridges.br-ex.openvswitch: {}` tells netplan this is an OVS bridge, not a Linux bridge
- The management IP and routes go on `br-ex`, NOT on `eno1`
- Disable any existing netplan config that configures eno1 directly
- Netplan file permissions must be strict (`chmod 600 /etc/netplan/60-ovs-bridge.yaml`)

**Important compatibility note (Ubuntu 22.04/netplan):**
- `ethernets.<iface>.openvswitch.bridge: br-ex` can fail with:
  - `unknown key 'bridge'`
- Prefer the `bridges.br-ex.interfaces` form shown above.

**Setup script:** `docs/compute-node-setup/05-setup-ovs-bridge.sh` handles both runtime and persistent config.

**Recovery (from physical console):**
```bash
sudo ip addr add 192.168.30.X/24 dev br-ex
sudo ip link set br-ex up
sudo ip route add default via 192.168.30.1 dev br-ex
# Then apply the persistent netplan config
sudo bash /path/to/05-setup-ovs-bridge.sh eno1
```

**Lesson:** Never make network changes with runtime-only commands. Always pair with persistent config.

---

### 32. Structural Hardening for Reproducible Redeploys

**Issues addressed:**
- `openrc.sh` had `OS_AUTH_URL` with `/v3/v3/`
- `neutron/values.yaml` had duplicate `conf.neutron` keys (YAML key collision risk)
- `keystone/values.yaml` used `oslo_messaging.statefulset.replicas` while other services use `statefulset: null`
- Compute node setup scripts were hardcoded to a single node/IP

**Fixes applied:**
- Set `OS_AUTH_URL` to `http://keystone.openstack.svc.cluster.local/v3/`
- Merged Neutron `conf.neutron` config into one key block
- Set Keystone `endpoints.oslo_messaging.statefulset: null` for consistency
- Parameterized compute scripts:
  - `03-join-cluster.sh` now supports `CONTROL_PLANE_ENDPOINTS`, `NODE_NAME`, `NODE_IP`
  - HAProxy backend now supports multiple control-plane endpoints
  - `04-label-node.sh` now accepts `<node-name>` as argument
- Added `06-recover-ovs-network.sh` for physical-console network recovery after `eno1`/`br-ex` migration failures

**Result:**
- Better reproducibility and less drift between docs, scripts, and runtime behavior
- Faster recovery path when bridge migration causes management-plane outage

---

### 33. Compute Node OVS/Nova Runtime Checks (Post Bridge Migration)

**Symptoms:**
- `neutron-ovs-agent` crash loop with:
  - `Bridge br-ex for physical network provider does not exist. Agent terminated!`
- `nova-compute` crash loop with:
  - `Failed to connect socket to '/run/libvirt/libvirt-sock': Permission denied`

**Root Cause:**
- Host bridge `br-ex` was not present/persistent on one compute node
- Host libvirt socket permissions were not aligned with nova-compute container access

**Fix:**
- Recreate and persist OVS bridge:
  - `sudo bash docs/compute-node-setup/05-setup-ovs-bridge.sh eno1 <mgmt-ip/cidr> <gateway> <dns>`
  - For disconnected nodes from physical console: `06-recover-ovs-network.sh`
- Re-apply libvirt host prerequisites:
  - Set in `/etc/libvirt/libvirtd.conf`:
    - `unix_sock_group = "libvirt"`
    - `unix_sock_ro_perms = "0777"`
    - `unix_sock_rw_perms = "0770"`
    - `auth_unix_rw = "none"`
  - Restart libvirt: `sudo systemctl restart libvirtd`

---

### 34. OpenVSwitch DaemonSet Kept Reappearing Even After values.yaml Changes

**Symptoms:**
- `openvswitch` DaemonSet pods kept crash-looping on both compute nodes
- `git commit` for `infrastructure/openstack/openvswitch/values.yaml` often showed “no changes added to commit”
- ArgoCD appeared to keep reconciling `openvswitch` resources

**Root Cause:**
- The disabling change was already present in Git history, so repeated commit attempts had no diff to commit.
- Confusion was from stale runtime pods during transition and mixed troubleshooting steps.

**Fix/Verification:**
- Confirm Argo app revision for `openstack-openvswitch` pointed to the expected commit.
- Confirm Argo sync history showed `DaemonSet/openvswitch` as **Pruned**.
- Validate live state:
  - `kubectl -n openstack get ds openvswitch` returns NotFound
  - only Neutron/Nova daemonsets remain for compute path

**Result:** Host OVS mode is now stable; chart OVS daemonset is no longer active.

---

### 35. Nova Compute Stuck Init:0/3 Due to Neutron OVS Readiness Deadlock

**Symptoms:**
- On `hpg9-compute-2`, `nova-compute` stuck in `Init:0/3`
- Same-node `neutron-ovs-agent` running but not Ready (`0/1 Running`)
- OVS showed intermittent stale interface errors (e.g. missing tap device), causing readiness probe failure

**Root Cause:**
- `nova-compute` init depended on same-node `neutron-ovs-agent` readiness
- Neutron OVS readiness script is strict:
  - fails if `ovs-vsctl show` contains any `error:`
- transient/stale OVS interface records can trigger this, creating a deadlock

**Fix:**
- In `infrastructure/openstack/neutron/values.yaml`, disable the strict OVS-agent readiness probe:
```yaml
neutron:
  pod:
    probes:
      neutron:
        ovs_agent:
          ovs_agent:
            readiness:
              enabled: false
```
- Commit/push and force Argo refresh.

**Result:**
- `neutron-ovs-agent-default` rolled out `2/2`
- `nova-compute-default` rolled out `2/2`
- both compute nodes returned to stable Running state for Neutron + Nova.

---

### 36. Skyline Login Fails Again (Keystone Auth HTTP 500) After Key Secrets Drift

**Symptoms:**
- Skyline login returns 401 (sometimes with generic system/auth error)
- `openstack --os-cloud homelab token issue` fails with HTTP 500
- Keystone pod is up, but token issuance is broken

**Root Cause:**
- Keystone key secrets (`keystone-fernet-keys`, `keystone-credential-keys`) were present but had no `data` field (effectively empty keys).
- Rotation jobs fail with:
  - `KeyError: 'data'` in `/tmp/fernet-manage.py`
  - because rotate expects existing key data to copy before rotate.
- With empty key repositories, Keystone cannot issue/validate tokens and returns:
  - `An unexpected error prevented the server from fulfilling your request. (HTTP 500)`

**Why this happens:**
- Helm manifests define those secrets as empty placeholders.
- Setup jobs are responsible for generating and writing real key material.
- If secrets drift/reset to empty during reconciliation, Keystone breaks until setup is rerun.

**Recovery (what worked):**
1. Verify failure:
   ```bash
   openstack --os-cloud homelab token issue -f value -c id
   kubectl -n openstack get secret keystone-fernet-keys -o yaml
   kubectl -n openstack get secret keystone-credential-keys -o yaml
   ```
2. Re-run setup jobs (not rotate jobs) by cloning current job templates:
   ```bash
   kubectl -n openstack get job keystone-fernet-setup -o json \
   | jq '.metadata.name="keystone-fernet-setup-rerun-0220" | del(.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,.metadata.managedFields,.status,.spec.selector,.spec.template.metadata.labels["batch.kubernetes.io/controller-uid"],.spec.template.metadata.labels["batch.kubernetes.io/job-name"],.spec.template.metadata.labels["controller-uid"],.spec.template.metadata.labels["job-name"])' \
   | kubectl -n openstack apply -f -

   kubectl -n openstack get job keystone-credential-setup -o json \
   | jq '.metadata.name="keystone-credential-setup-rerun-0220" | del(.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,.metadata.managedFields,.status,.spec.selector,.spec.template.metadata.labels["batch.kubernetes.io/controller-uid"],.spec.template.metadata.labels["batch.kubernetes.io/job-name"],.spec.template.metadata.labels["controller-uid"],.spec.template.metadata.labels["job-name"])' \
   | kubectl -n openstack apply -f -
   ```
3. Wait for completion:
   ```bash
   kubectl -n openstack wait --for=condition=complete job/keystone-fernet-setup-rerun-0220 --timeout=180s
   kubectl -n openstack wait --for=condition=complete job/keystone-credential-setup-rerun-0220 --timeout=180s
   ```
4. Confirm keys now exist:
   ```bash
   kubectl -n openstack get secret keystone-fernet-keys -o go-template='{{.metadata.name}} keys={{range $k,$v := .data}}{{$k}} {{end}}{{"\n"}}'
   kubectl -n openstack get secret keystone-credential-keys -o go-template='{{.metadata.name}} keys={{range $k,$v := .data}}{{$k}} {{end}}{{"\n"}}'
   ```
5. Restart auth/UI deployments and retest:
   ```bash
   kubectl -n openstack rollout restart deployment keystone-api skyline
   openstack --os-cloud homelab token issue -f value -c id
   ```

**Prevention:**
- Keep `ignoreDifferences` in ArgoCD on `/data` for both key secrets.
- Do not rotate when secrets are empty; rotate jobs will fail with `KeyError: 'data'`.
- Add an auth health check after major sync/restart events:
  - `openstack --os-cloud homelab token issue`
- Keep setup jobs available for rerun and treat them as auth recovery primitives.

---

### 37. Grafana Ceph Panel Shows "No data" Even Though Ceph Is Running

**Symptoms:**
- Ceph panel in Grafana dashboard showed `No data`
- Prometheus queries like `ceph_health_status` returned empty results
- Ceph services existed (`rook-ceph-mgr:9283`, `rook-ceph-exporter:9926`) but were not represented in scraped metrics

**Root Cause:**
- Prometheus in kube-prometheus-stack is configured to scrape only `ServiceMonitor` objects matching label:
  - `release=monitoring-kube-prometheus-stack`
- No Ceph ServiceMonitor with that label existed, so Ceph targets were never scraped.

**Fix:**
- Added explicit ServiceMonitors in monitoring rules:
  - `infrastructure/monitoring-rules/ceph-servicemonitors.yaml`
  - `ServiceMonitor/rook-ceph-mgr` targeting port `http-metrics`
  - `ServiceMonitor/rook-ceph-exporter` targeting port `ceph-exporter-http-metrics`
- Added them to:
  - `infrastructure/monitoring-rules/kustomization.yaml`
- Updated Grafana dashboard with focused Ceph status cards:
  - health, OSD up/in/total, MON quorum, MGR active

**Validation:**
```bash
kubectl -n monitoring get servicemonitor rook-ceph-mgr rook-ceph-exporter

# Query from Prometheus pod
ceph_health_status
sum(ceph_osd_up)
sum(ceph_mon_quorum_status)
max(ceph_mgr_status)
```

**Prevention:**
- Any new ServiceMonitor/PodMonitor must carry label:
  - `release=monitoring-kube-prometheus-stack`
- After adding a metrics source, always validate with direct Prometheus queries before relying on Grafana panels.

---

### 38. Telegram Alerts Not Delivered From Alertmanager (Secret Mismatch)

**Symptoms:**
- Monitoring stack was healthy
- Test alerts fired in Prometheus, but no Telegram message arrived

**Root Cause:**
- Alertmanager operator was not using the intended Telegram config secret initially.
- Effective config secret selection did not align with the created `alertmanager-main` secret.

**Fix:**
- Pin Alertmanager to the explicit secret in `apps/monitoring.yaml`:
```yaml
alertmanager:
  enabled: true
  alertmanagerSpec:
    useExistingSecret: alertmanager-main
    configSecret: alertmanager-main
```
- Re-sync Argo app and validate active alert routing via Alertmanager API/test rule.

**Validation:**
- `kubectl -n monitoring get secret alertmanager-main`
- Trigger test alert and confirm Telegram delivery.

**Prevention:**
- Keep one canonical Alertmanager secret name (`alertmanager-main`) across scripts/docs/values.
- Run a synthetic alert test after any Alertmanager/monitoring chart upgrade.

---

## Resolved Incident (Feb 27, 2026)

### Cinder volume attach fails with "Permission denied" on QEMU blockdev-add

**Symptoms:**
- `openstack server add volume` returns success and reports `/dev/vdb`, but the volume never appears inside the VM.
- Cinder shows volume as `available` with empty attachments; Nova and Cinder are out of sync.
- `nova volume-detach` returns 404 saying volume is not attached.
- Nova-compute logs show:
  ```
  libvirt.libvirtError: internal error: unable to execute QEMU command 'blockdev-add': error connecting: Permission denied
  ```

**Investigation steps:**
1. Initial assumption was QEMU sandbox (`-sandbox on,resourcecontrol=deny`) blocking hot-attach — this was a **red herring**. Sandbox blocks new resource connections at runtime, but the root cause was auth.
2. Checked QEMU command line in `/var/log/libvirt/qemu/instance-*.log` — boot disk uses `"user":"nova"` on pool `vms`; Cinder volume uses `"user":"cinder"` on pool `volumes`.
3. Both used the same `key-secret` derived from libvirt secret UUID `457eb676-33da-42ec-9a8c-9293d545c337`.
4. That libvirt secret held the `client.nova` keyring (`<your-ceph-nova-keyring>`).
5. QEMU tried to authenticate as `user: cinder` with the `client.nova` key — Ceph rejected the mismatch.

**Root cause:**
- Cinder's `cinder.conf` had `rbd_user = cinder` and `rbd_secret_uuid = 457eb676-33da-42ec-9a8c-9293d545c337`.
- That UUID's libvirt secret on the compute nodes contained the `client.nova` key, not the `client.cinder` key.
- Nova ephemeral disks worked fine because they use `user: nova` with the nova key (same secret).
- Cinder volumes authenticate as `user: cinder` but QEMU used the nova key from the same libvirt secret — Ceph rejected it.

**Additional issue found during fix:**
- `client.nova` Ceph auth caps only allowed access to pool `vms`. Extended to include `volumes` pool:
  ```bash
  ceph auth caps client.nova \
    mon 'profile rbd' \
    osd 'profile rbd pool=vms, profile rbd pool=volumes' \
    mgr 'profile rbd pool=vms, profile rbd pool=volumes'
  ```

**Fix (3 parts):**

1. **Created a separate libvirt secret for `client.cinder`** on both compute nodes:
   ```bash
   cat <<'EOF' | sudo tee /tmp/cinder-secret.xml
   <secret ephemeral='no' private='no'>
     <uuid>457eb676-33da-42ec-9a8c-9293d545c338</uuid>
     <usage type='ceph'>
       <name>ceph client.cinder secret</name>
     </usage>
   </secret>
   EOF
   sudo virsh secret-define /tmp/cinder-secret.xml
   sudo virsh secret-set-value 457eb676-33da-42ec-9a8c-9293d545c338 <your-ceph-cinder-keyring>
   rm /tmp/cinder-secret.xml
   ```

2. **Updated Cinder `rbd_secret_uuid`** in `infrastructure/openstack/cinder/values.yaml`:
   ```yaml
   rbd_secret_uuid: 457eb676-33da-42ec-9a8c-9293d545c338  # was c337 (nova secret)
   ```

3. **Pushed to git, synced via ArgoCD, restarted cinder-volume:**
   ```bash
   git push origin main
   kubectl rollout restart -n openstack deployment/cinder-volume
   ```

**Validation:**
```bash
# Cinder config has new UUID
kubectl -n openstack exec -it <cinder-volume-pod> -- grep rbd_secret_uuid /etc/cinder/cinder.conf
# Expected: 457eb676-33da-42ec-9a8c-9293d545c338

# Volume attaches and shows in-use
openstack server add volume <server-id> <volume-id> --device /dev/vdb
openstack volume show <volume-id> -c status
# Expected: in-use

# Visible inside VM
lsblk  # Expected: vdb 200G

# Both libvirt secrets present on compute nodes
sudo virsh secret-list
# Expected: c337 (client.nova) + c338 (client.cinder)
```

**Prevention:**
- When adding Ceph-backed storage services that use a different `rbd_user`, always create a **dedicated libvirt secret** with that user's keyring on all compute nodes.
- Do NOT share a single libvirt secret UUID across multiple Ceph users (nova, cinder, glance) — each user needs its own secret with its own key.
- Add libvirt secret creation for `client.cinder` to `docs/compute-node-setup/07-bootstrap-compute-node.sh` so new compute nodes get both secrets automatically.

**Libvirt secrets reference (both compute nodes):**

| UUID | Usage | Ceph User | Key |
|------|-------|-----------|-----|
| `457eb676-33da-42ec-9a8c-9293d545c337` | `ceph client.nova secret` | `client.nova` | `<your-ceph-nova-keyring>` |
| `457eb676-33da-42ec-9a8c-9293d545c338` | `ceph client.cinder secret` | `client.cinder` | `<your-ceph-cinder-keyring>` |

---

## Resolved Incident (Feb 28, 2026)

### RabbitMQ CrashLoopBackOff — Erlang cookie file permission denied

**Symptoms:**
- `openstack-rabbitmq-0` in `CrashLoopBackOff` with 8+ restarts.
- All Nova services (compute, conductor, scheduler) failing with `[Errno 111] ECONNREFUSED` on RabbitMQ connection.
- Skyline dashboard login failing (can't query Nova without RabbitMQ).
- Telegram alert: `[firing][critical] OpenStackComputeDaemonSetUnavailable`.

**Error:**
```
Cookie file /var/lib/rabbitmq/.erlang.cookie must be accessible by owner only
Kernel pid terminated (application_controller) "{application_start_failure,rabbitmq_prelaunch,...}"
```

**Root Cause:**
- The RabbitMQ pod's `podSecurityContext` had `fsGroup: 999`.
- Kubernetes `fsGroup` recursively sets group ownership on all files in a PVC on every mount, changing file permissions to include group-readable (e.g., `660`).
- Erlang requires `.erlang.cookie` to be strictly `600` (owner-only, no group or world access).
- The init container (`rabbitmq-init`) runs `chmod 600 /var/lib/rabbitmq/.erlang.cookie`, but Kubernetes applies `fsGroup` **after** the init container completes, overriding the permissions back to `660`.
- This was not an issue when the pod was first created (cookie didn't exist yet, init container creates it with `600`, and `fsGroup` only adds group ownership without changing the permission bits on new files). It became an issue after a pod restart where the cookie file already existed on the PVC — Kubernetes re-applies `fsGroup` permissions on mount.

**Fix:**
1. **Deleted the corrupted cookie file** so the init container recreates it:
   ```bash
   kubectl exec -n openstack openstack-rabbitmq-0 -c rabbitmq -- rm /var/lib/rabbitmq/.erlang.cookie
   ```

2. **Added `fsGroupChangePolicy: OnRootMismatch`** to `infrastructure/openstack/rabbitmq/values.yaml`:
   ```yaml
   podSecurityContext:
     fsGroup: 999
     fsGroupChangePolicy: OnRootMismatch
     supplementalGroups:
       - 999
   ```
   `OnRootMismatch` prevents Kubernetes from recursively changing permissions on every mount — it only applies `fsGroup` when the root directory ownership doesn't match.

3. **Deleted the pod** to trigger a fresh init with the recreated cookie:
   ```bash
   kubectl delete pod -n openstack openstack-rabbitmq-0
   ```

**Cascade impact:**
- RabbitMQ down → Nova conductor/scheduler/compute lose message queue → Nova API can't process requests → Skyline dashboard fails to load instance data → login appears broken.
- Neutron agents also affected (same RabbitMQ dependency).
- All services auto-recovered once RabbitMQ came back — no manual intervention needed for downstream services.

**Validation:**
```bash
# RabbitMQ running
kubectl get pods -n openstack | grep rabbit
# Expected: 1/1 Running

# Vhosts intact
kubectl exec -n openstack openstack-rabbitmq-0 -- rabbitmqctl list_vhosts
# Expected: /, nova, neutron, cinder, glance

# All Nova services healthy
kubectl get pods -n openstack -l application=nova | grep -v Completed
# Expected: all 1/1 Running

# Skyline login works
# Browse to http://skyline.openstack.svc.cluster.local
```

**Prevention:**
- Always set `fsGroupChangePolicy: OnRootMismatch` on any StatefulSet that stores Erlang cookies or other permission-sensitive files on a PVC.
- If RabbitMQ enters CrashLoopBackOff with cookie errors, the quick fix is: `kubectl exec -n openstack openstack-rabbitmq-0 -c rabbitmq -- rm /var/lib/rabbitmq/.erlang.cookie` then delete the pod.
- Note: ArgoCD self-heal will immediately scale RabbitMQ back up if you try to scale the StatefulSet to 0. To work around this, exec into the crashing container during its brief running window (between crash and restart).

---

## Resolved Incident (Mar 1, 2026)

### 39. Repeating `KubeProxyDown` Telegram alerts (alert fatigue)

**Symptoms:**
- Telegram channel received repeated `[firing][critical] KubeProxyDown` messages several times per day.
- Message body: `target: Target disappeared from Prometheus target discovery.`
- Monitoring apps and pods were otherwise healthy.

**Root Cause:**
- `KubeProxyDown` stayed in `firing` state.
- Alertmanager Telegram routing intentionally repeats critical alerts every `4h`.
- Existing noise-drop list did not include `KubeProxyDown`, so repeats were expected behavior.

**Fix:**
1. Updated `scripts/setup-alertmanager-telegram.sh` to drop `KubeProxyDown` before critical routing in both profiles:
   - `critical-only`
   - `balanced`
2. Re-applied the live Alertmanager secret:
   ```bash
   ALERT_TELEGRAM_BOT_TOKEN='<token>' ALERT_TELEGRAM_CHAT_ID='<chat-id>' scripts/setup-alertmanager-telegram.sh
   ```
3. Confirmed Argo monitoring apps remained healthy/synced after update.

**Validation:**
- Secret update applied:
  - `secret/alertmanager-main configured`
- Generated runtime config contains matcher:
  - `alertname="KubeProxyDown"`
- Monitoring apps:
  - `monitoring-kube-prometheus-stack` → `Synced/Healthy`
  - `monitoring-loki` → `Synced/Healthy`
  - `monitoring-promtail` → `Synced/Healthy`
  - `monitoring-rules` → `Synced/Healthy`

**Prevention:**
- Keep persistent noisy baseline alerts in explicit drop matchers (not only severity filters).
- After any Alertmanager route change, verify both:
  1. source secret (`alertmanager-main`)
  2. generated runtime secret (`alertmanager-*-generated`)
- Keep `scripts/setup-alertmanager-telegram.sh` as the canonical path for secret-driven Alertmanager config updates.

---

## Resolved Incident (Mar 11-14, 2026)

### 40. Kali Linux VM creation — multi-stage failure and lessons learned

**Symptoms (attempt 1):**
- `openstack server create` with Kali image returned `MaxRetriesExceeded` — scheduler couldn't reach compute nodes.

**Root Cause (attempt 1):**
- Transient RabbitMQ connectivity issues — conductor couldn't reach compute nodes via AMQP.
- Self-resolved after RabbitMQ recovered.

**Symptoms (attempt 2):**
- VM created ACTIVE but console showed SeaBIOS stuck at "Booting from Hard Disk..."

**Root Cause (attempt 2):**
- Kali image was built for UEFI only. Setting `hw_firmware_type=bios` made it bootable by SeaBIOS, but the OS itself requires UEFI to boot.
- Setting `hw_firmware_type=uefi` fails because Nova compute containers lack `/usr/share/OVMF/` and `/usr/share/qemu/firmware/` from the host. Error: `Failed to locate firmware descriptor files`.
- Fix would require `pod.mounts.nova_compute.nova_compute` hostPath volumes in `nova/values.yaml`, but user chose not to add UEFI support at this time.

**Symptoms (attempt 3 — fresh image download):**
- Downloaded `kali-linux-2025.1-cloud-genericcloud-amd64.qcow2` — file was 10 bytes ("Not Found"). Version didn't exist.
- Correct URL found at `cdimage.kali.org/current/kali-linux-2025.4-qemu-amd64.7z` (QEMU desktop image, ~3GB compressed, ~68GB virtual).

**Symptoms (attempt 4 — Glance upload failures):**
- `openstack image create --file` → `415 Unsupported Media Type` (uWSGI rejects chunked transfer)
- Skyline UI upload → `502 Bad Gateway` (nginx body size limit)
- `curl --data-binary` → out of memory (entire file loaded into RAM)
- `curl -T` → `502 Bad Gateway`

**Workaround — manual Glance image injection:**
1. SCP image to compute node `/tmp/`
2. Create helper busybox pod mounting both host `/tmp` (hostPath) and `glance-images` PVC:
   ```bash
   kubectl apply -f - <<'EOF'
   apiVersion: v1
   kind: Pod
   metadata:
     name: glance-helper
     namespace: openstack
   spec:
     nodeSelector:
       kubernetes.io/hostname: hpg9-compute
     containers:
     - name: helper
       image: busybox
       command: ["sleep", "3600"]
       volumeMounts:
       - name: host-tmp
         mountPath: /host-tmp
       - name: glance-images
         mountPath: /glance-images
     volumes:
     - name: host-tmp
       hostPath:
         path: /tmp
     - name: glance-images
       persistentVolumeClaim:
         claimName: glance-images
   EOF
   ```
3. Copy file and fix ownership:
   ```bash
   kubectl exec -n openstack glance-helper -- cp /host-tmp/<image-file> /glance-images/<image-uuid>
   kubectl exec -n openstack glance-helper -- chown 42424:42424 /glance-images/<image-uuid>
   ```
4. Insert DB records:
   ```sql
   -- In openstack-mariadb, database: glance
   UPDATE images SET status='active', size=<bytes> WHERE id='<uuid>';
   INSERT INTO image_locations (image_id, value, meta_data, status, created_at, updated_at, deleted)
     VALUES ('<uuid>', 'file:///var/lib/glance/images/<uuid>', '{"store": "file"}', 'active', NOW(), NOW(), 0);
   ```

**Symptoms (attempt 5 — VM creation with manually uploaded image):**
- `Unable to convert image to raw` — qemu-img I/O error at byte 73846620160
- Root cause: Kali QEMU desktop image has 68GB virtual size. Nova's qcow2→raw conversion for Ceph RBD exceeded available resources.

**Final Resolution:**
- Abandoned Kali on OpenStack. The image is too large and requires UEFI support not currently available in the Nova compute pods.
- Moved Kali to Proxmox cluster (`pve-node0`) where QEMU/KVM with OVMF firmware is natively available.
- Cleaned up all Kali-related Glance images, orphan files, and local downloads.
- **No persistent changes were made to OpenStack Helm values or cluster configuration.**

**Lessons Learned:**
1. **UEFI images on OpenStack-Helm:** Requires mounting host OVMF firmware into nova-compute pods via `pod.mounts.nova_compute` hostPath volumes. Not worth the complexity for a homelab unless many UEFI-only images are needed.
2. **Glance large image uploads:** The standard API path (CLI, UI, curl) fails for images >1GB due to uWSGI chunked transfer limitations. Use the helper pod method documented above.
3. **Image compatibility:** Always verify an image's boot type (BIOS vs UEFI) and virtual disk size before uploading. Cloud images (small, BIOS-compatible) work best on OpenStack; desktop/QEMU images are better suited for Proxmox.
4. **Kali Linux:** No official BIOS-compatible cloud image exists. The `genericcloud` variant is UEFI-only, and the QEMU desktop image is 68GB virtual — too large for OpenStack's conversion pipeline.

---

### 41. Stale Nova compute services cleanup (Mar 11)

**Symptoms:**
- `openstack compute service list` showed 20+ entries with `State: down` for `nova-scheduler` and `nova-conductor`.
- Services accumulated from daily pod rollouts (each new pod registers a new service entry).

**Fix:**
```bash
# List stale services
openstack compute service list --long | grep down
# Delete one by one with 5s delay to avoid 503s
for id in <list-of-ids>; do
  openstack compute service delete $id
  sleep 5
done
```

**Prevention:**
- `nova-service-cleaner` CronJob is enabled (`cron_job_service_cleaner: true` in `nova/values.yaml`) but its pods sometimes get stuck in `Init:0/1`. Monitor and manually delete stuck pods.
- Periodic manual cleanup every 1-2 weeks if CronJob is unreliable.

---

### 42. Ceph HEALTH_WARN — NFS mgr module crash (Mar 14)

**Symptoms:**
- `ceph -s` showed `HEALTH_WARN: 1 daemons have recently crashed`
- `ceph crash ls-new` showed a crash from the `mgr` daemon

**Root Cause:**
- Ceph mgr NFS module called `cluster_ls()` which requires an orchestrator backend.
- Rook-Ceph uses its own orchestrator, not cephadm — the NFS module's internal `cluster_ls` RPC fails with `NoOrchestrator`.
- The NFS module was enabled by default but not actually used.

**Fix:**
```bash
# From rook-ceph-tools pod
ceph crash archive-all    # Clear the HEALTH_WARN
ceph mgr module disable nfs   # Prevent future crashes
```

**Notes:**
- Disabling the NFS module does NOT affect Ceph dashboard visibility — block, object, and file storage types still appear.
- The NFS option in the Ceph dashboard was always non-functional in a Rook deployment since it requires cephadm orchestrator.

---

## Live Migration

### MariaDB 12.x innodb_snapshot_isolation breaks Nova live migration

**Symptoms:**
- Live migration accepted by scheduler but never starts at libvirt level
- Compute logs show: `(1020, "Record has changed since last read in table 'instance_actions'")`
- VM stuck in MIGRATING state indefinitely

**Root cause:**
MariaDB 12.x enables `innodb_snapshot_isolation = ON` by default. This enforces strict snapshot isolation that conflicts with OpenStack's concurrent read/write pattern on the `instance_actions` table (both compute and conductor update the same row simultaneously during migration).

**Fix:**
```yaml
# infrastructure/openstack/mariadb/values.yaml
mariadb:
  primary:
    configuration: |-
      [mysqld]
      innodb_snapshot_isolation=OFF
```

Also set at runtime: `SET GLOBAL innodb_snapshot_isolation = OFF`

---

### QEMU postcopy not supported in container environment

**Symptoms:**
- Live migration starts but immediately aborts
- Compute logs: `Live Migration failure: internal error: unable to execute QEMU command 'migrate-set-capabilities': Postcopy is not supported`

**Fix:**
```yaml
# infrastructure/openstack/nova/values.yaml - conf.nova.libvirt
live_migration_permit_post_copy: false
```

---

### CPU compatibility check fails during live migration (compareHypervisorCPU returns 0)

**Symptoms:**
- Scheduler selects destination host, but conductor pre-check fails
- Second scheduling pass has no valid hosts
- Logs show CPU feature mismatch (arch-lbr, pconfig, core-capability, pks, etc.)

**Root cause:**
Nova uses `compareHypervisorCPU` (not `compareCPU`) which checks QEMU emulation capabilities. Container QEMU doesn't recognize 12th Gen Intel CPU features even though both hosts have identical CPUs.

**Fix:**
```yaml
# infrastructure/openstack/nova/values.yaml - conf.nova
workarounds:
  skip_cpu_compare_on_dest: true
```
Safe with QEMU >= 2.9 and libvirt >= 4.4.0.

---

### Stale Neutron port bindings after failed live migration

**Symptoms:**
- Subsequent migration attempts fail with: `Binding for port <uuid> on host <host> already exists`
- Neutron server logs show `PortBindingLevel` identity key conflicts and may fail readiness probes

**Fix:**
Clean up stale entries from both `ml2_port_bindings` and `ml2_port_binding_levels` tables:
```sql
-- Find stale bindings
SELECT port_id, host, status FROM ml2_port_bindings WHERE status = 'INACTIVE';

-- Delete stale binding and its levels
DELETE FROM ml2_port_binding_levels WHERE port_id = '<port_id>' AND host = '<stale_host>';
DELETE FROM ml2_port_bindings WHERE port_id = '<port_id>' AND host = '<stale_host>';
```
Then restart the neutron-server pod.

---

### Libvirt TCP listener for live migration

**Symptoms:**
- Live migration hangs because source compute can't connect to destination libvirt over TCP
- `virsh -c qemu+tcp://<host>/system` fails with authentication error or connection refused

**Fix (on each compute node):**
```bash
# Set auth_tcp = "none" in /etc/libvirt/libvirtd.conf
sed -ri 's|^#?\s*auth_tcp\s*=.*|auth_tcp = "none"|' /etc/libvirt/libvirtd.conf

# Enable and start TCP socket
systemctl enable libvirtd-tcp.socket
systemctl stop libvirtd.service libvirtd.socket libvirtd-ro.socket
systemctl start libvirtd-tcp.socket libvirtd.socket libvirtd.service
```
Verify with: `ss -tlnp | grep 16509`

---

### DNS resolution for compute hostnames in K8s pods

**Symptoms:**
- Nova compute can't resolve bare hostnames (e.g., `hpg9-compute`) for libvirt TCP connections
- Migration fails at pre_live_migration stage

**Fix:**
Add `hosts` plugin to CoreDNS configmap in kube-system (before `forward` directive):
```
hosts {
    192.168.30.14 hpg9-compute
    192.168.30.13 hpg9-compute-2
    fallthrough
}
```
Note: This is a manual configmap patch and is not persisted through ArgoCD.

---

### Live migration complete configuration summary

Working Nova live migration requires:
1. `live_migration_scheme: "tcp"` in `conf.nova.libvirt`
2. `live_migration_permit_auto_converge: true`
3. `live_migration_permit_post_copy: false` (container QEMU limitation)
4. `cpu_mode: host-model` (not host-passthrough)
5. `skip_cpu_compare_on_dest: true` under `conf.nova.workarounds`
6. `innodb_snapshot_isolation = OFF` in MariaDB 12.x
7. `libvirtd-tcp.socket` enabled with `auth_tcp = "none"` on all compute nodes
8. CoreDNS `hosts` entries for compute node bare hostnames

---

---

### 43. Ceph Running With Only 2 Mons — No Quorum Resilience (Mar 27, 2026)

**Situation:**
- `cluster.yaml` had `mon.count: 2` with placement pinned to control-plane nodes only
- Only 2 control plane nodes (`dell3000-cp`, `dell7080-cp`) → 2 mons maximum
- With 2 mons, losing either one loses quorum (1/2 is not a majority) → cluster becomes read-only

**Fix:**
- Changed `mon.count: 2 → 3` in `infrastructure/rook-ceph-cluster/cluster.yaml`
- Extended mon `nodeAffinity` to allow scheduling on `lenovo-worker` via an additional `nodeSelectorTerms` entry (OR logic alongside the existing control-plane rule)
- Rook spun up `rook-ceph-mon-f` on `lenovo-worker` with zero downtime
- Cluster went 2→3 mons with no quorum interruption; `carecircle.network` was unaffected throughout

**Result:**
- 3 mons: `b` (dell3000-cp), `e` (dell7080-cp), `f` (lenovo-worker)
- Can now tolerate 1 mon failure and maintain quorum
- Ceph `HEALTH_OK`, 2 MGRs unchanged (a active, b standby — both on CP nodes, correct for this cluster size)

**Why 2 MGRs is correct:**
- MGR is orchestration/stats only — no data plane involvement
- Active + hot standby is the standard for a cluster this size
- A 3rd MGR would give no benefit; there is no suitable CP node to host it without relaxing placement constraints

**Mon placement config (cluster.yaml):**
```yaml
mon:
  count: 3
  allowMultiplePerNode: false
...
placement:
  mon:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: Exists
          - matchExpressions:
              - key: kubernetes.io/hostname
                operator: In
                values:
                  - lenovo-worker
```

*Last updated: 2026-03-27*

---

## Resolved Incident (Apr 5, 2026)

### `hostname --fqdn` returns empty → nova-compute + all neutron agents crash on every compute node

**Symptoms:**
- nova-compute and all neutron agents (ovs, dhcp, l3, metadata) in `CrashLoopBackOff` on **every** Ubuntu compute node
- Logs: `oslo_config.cfg.ConfigFileValueError: Value for option host from ... is not valid:  is not a valid host address`
- Same error for `/tmp/pod-shared/nova-hypervisor.conf` and `/tmp/pod-shared/neutron-agent.ini`
- Latent for ~12 days; discovered during hpg9-compute3 bootstrap

**Root cause:**
OpenStack-Helm's init container writes `host = $(hostname --fqdn)` to a shared conf file. With `hostNetwork: true`, the container inherits the host's `/etc/hosts`. At some point the nodes' OS hostnames were changed from `hpg9-compute*` to `compute{1,2,3}` (to match SSH aliases) but `/etc/hosts` was not updated to match. `hostname --fqdn` does a forward/reverse resolution of the current hostname; with no entry, it fails silently (returns empty) and the init container writes `host = `, which crashes nova/neutron.

**Diagnosis:**
```bash
# On compute node:
hostname              # returns: compute1 / compute2 / compute3
grep 127.0.1.1 /etc/hosts  # shows: 127.0.1.1 hpg9-compute*  (doesn't include short name)
hostname --fqdn       # should return hostname, fails → returns empty

# In pod init logs:
kubectl -n openstack logs <nova-compute-pod> -c nova-compute-init | tail -5
# ends at "++ hostname --fqdn" followed by "hostname: Name or service not known"
```

**Fix (on each compute node):**
Add the short hostname as an alias, keeping the canonical k8s node name first (canonical name is what `hostname --fqdn` returns, and what nova stores as the hypervisor identity):
```bash
# compute1
sudo sed -i 's|^127.0.1.1 hpg9-compute$|127.0.1.1 hpg9-compute compute1|' /etc/hosts
# compute2
sudo sed -i 's|^127.0.1.1 hpg9-compute-2$|127.0.1.1 hpg9-compute-2 compute2|' /etc/hosts
# compute3
sudo sed -i 's|^127.0.1.1 hpg9-compute3$|127.0.1.1 hpg9-compute3 compute3|' /etc/hosts

# Verify
hostname --fqdn   # now returns hpg9-compute / hpg9-compute-2 / hpg9-compute3
```

Then delete the crashing pods to restart them:
```bash
kubectl -n openstack delete pod -l application=nova,component=compute
kubectl -n openstack delete pod -l application=neutron,component=neutron-ovs-agent
kubectl -n openstack delete pod -l application=neutron,component=dhcp-agent
kubectl -n openstack delete pod -l application=neutron,component=l3-agent
kubectl -n openstack delete pod -l application=neutron,component=metadata-agent
```

All 12 pods came up 1/1 Running within ~3 minutes; nova cell1 still lists `hpg9-compute*` hypervisors with original identities (DB unchanged).

**Persisted in** `docs/compute-node-setup/07-bootstrap-compute-node.sh` — the script now ensures `/etc/hosts` has `127.0.1.1 ${NODE_NAME} $(hostname -s)` on bootstrap.

---

### Compute-node HAProxy stale backends + `kubeprism-frontend` port conflict

**Symptoms:**
- On compute1 (hpg9-compute-2 — node named after alias), `systemctl start haproxy` fails immediately
- `sudo haproxy -Ws -f /etc/haproxy/haproxy.cfg` shows: `cannot bind socket (Address already in use) [127.0.0.1:7445]`
- On compute2 (hpg9-compute), HAProxy running for weeks but one backend points at a dead IP (`192.168.30.12`, the retired dell3000-cp)
- Running config points at `192.168.30.13:6443` as a "CP" — but `.13` is a compute node, not a control plane

**Root cause (port conflict):**
An extra `kubeprism-frontend` block was in `/etc/haproxy/haproxy.cfg` trying to bind `127.0.0.1:7445` — but a standalone `socat` process was already listening there as a KubePrism-compatible proxy to the kube-vip VIP, making HAProxy's second frontend redundant *and* blocking.

**Root cause (stale backends):**
Bootstrap used `.12,.15` as control-plane endpoints when the nodes were first joined. dell3000-cp (`.12`) was later retired and dell7080-cp2 (`.16`) added, but the existing nodes' `/etc/haproxy/haproxy.cfg` was never rewritten.

**Fix:**
```bash
# Remove the redundant kubeprism-frontend block
sudo sed -i '/^  frontend kubeprism-frontend/,/default_backend kubernetes-backend/d' /etc/haproxy/haproxy.cfg

# Fix backends (vary by node's current state)
sudo sed -i 's|192.168.30.12:6443|192.168.30.16:6443|g' /etc/haproxy/haproxy.cfg

sudo haproxy -c -f /etc/haproxy/haproxy.cfg   # validate
sudo systemctl reset-failed haproxy
sudo systemctl enable --now haproxy
```

---

### Kubelet bypassed local HAProxy (compute nodes relied on kube-vip VIP directly)

**Symptoms:**
- Compute-node `kubelet.conf` had `server: https://192.168.30.100:6443` (the kube-vip VIP)
- Local HAProxy on compute nodes was running but never used — and on one node had been *failed* for 1 month 11 days without anyone noticing
- If the VIP ever failed, all compute nodes would simultaneously lose API access

**Root cause:**
The `07-bootstrap-compute-node.sh` script was setting up local HAProxy + kubelet pointing at it, but then **rewriting** both `kubelet.conf` and `bootstrap-kubelet.conf` from `127.0.0.1:6443` to the VIP at the end — defeating the purpose.

**Fix (on each compute node):**
```bash
sudo cp -a /etc/kubernetes/kubelet.conf /etc/kubernetes/kubelet.conf.bak-vip
sudo cp -a /etc/kubernetes/bootstrap-kubelet.conf /etc/kubernetes/bootstrap-kubelet.conf.bak-vip
sudo sed -i 's|server: https://192.168.30.100:6443|server: https://127.0.0.1:6443|' /etc/kubernetes/kubelet.conf
sudo sed -i 's|server: https://192.168.30.100:6443|server: https://127.0.0.1:6443|' /etc/kubernetes/bootstrap-kubelet.conf
sudo systemctl restart kubelet
# Verify node Ready from the CP: kubectl get node <name>
```

Each compute node now has genuine HA — any single CP can fail without taking that node down.

**Persisted in** `07-bootstrap-compute-node.sh` — sed normalizes both files to `https://127.0.0.1:6443` and leaves them there.

---

### Live migration fails: `Secret not found: no secret with matching uuid '457eb676-...c337'`

**Symptoms:**
- Live migration from compute1 → compute3 (newly joined node) fails immediately
- Source nova-compute logs: `libvirt.libvirtError: Secret not found: no secret with matching uuid '457eb676-33da-42ec-9a8c-9293d545c337'`
- Migration back from a healthy pair (compute1 ↔ compute2) works fine

**Root cause:**
Ceph-backed VMs reference the libvirt Ceph auth secret by UUID in their domain XML. Every hypervisor needs those same secrets (same UUIDs) defined via virsh. compute3 was bootstrapped fresh and had **zero** secrets defined — `virsh secret-list` returned empty.

**Fix (from an existing hypervisor, e.g. compute1):**
```bash
# On source hypervisor - dump the definitions and keys
sudo virsh secret-dumpxml 457eb676-33da-42ec-9a8c-9293d545c337 > /tmp/secret-nova.xml
sudo virsh secret-dumpxml 457eb676-33da-42ec-9a8c-9293d545c338 > /tmp/secret-cinder.xml
sudo virsh secret-get-value 457eb676-33da-42ec-9a8c-9293d545c337  # print NOVA-VALUE
sudo virsh secret-get-value 457eb676-33da-42ec-9a8c-9293d545c338  # print CINDER-VALUE

# scp XMLs to new hypervisor
scp /tmp/secret-nova.xml /tmp/secret-cinder.xml <user>@<new-node>:/tmp/

# On new hypervisor
sudo virsh secret-define /tmp/secret-nova.xml
sudo virsh secret-define /tmp/secret-cinder.xml
sudo virsh secret-set-value --secret 457eb676-33da-42ec-9a8c-9293d545c337 --base64 '<NOVA-VALUE>'
sudo virsh secret-set-value --secret 457eb676-33da-42ec-9a8c-9293d545c338 --base64 '<CINDER-VALUE>'
sudo virsh secret-list   # verify both present
```

**Persisted in** `07-bootstrap-compute-node.sh` via the new `--ceph-secrets-dir` flag.

---

### Live migration: `guest CPU doesn't match specification: missing features: pcid`

**Symptoms:**
- Live-migrate long-running VM (`openclaw`, booted months ago) from compute1 → compute3: fails
- Source nova-compute logs: `operation failed: guest CPU doesn't match specification: missing features: pcid`
- **Same VM migrates compute1 ↔ compute2 fine**
- Fresh VM created today migrates in **both** directions between all 3 hosts fine
- All three hosts have identical i5-12500 CPUs and `pcid` in `/proc/cpuinfo`

**Root cause:**
`cpu_mode = host-model` makes libvirt pick a preset CPU model at VM boot. An older libvirt combo (at the time the legacy VMs were first booted) resolved host-model to `Cooperlake`; the current libvirt 8.0.0 resolves it to `Skylake-Client-noTSX-IBRS`. The Cooperlake model is baked into each legacy VM's persistent libvirt XML. compute3 ships QEMU `6.2.0-2ubuntu6.29` (compute1/compute2 have `.28`) which is stricter about Cooperlake's required features and refuses the migration even though the underlying CPU supports `pcid`.

**Fix:** Hard-reboot the affected VM:
```bash
openstack server reboot --hard <vm-name>
```
This regenerates the libvirt domain XML against the current host-model (`Skylake-Client-noTSX-IBRS`), which all hypervisors support. Downtime ~30-60s. Applies to legacy VMs only — VMs created after 2026-04-05 are born with the new model and live-migrate freely across all 3 hosts.

Affected legacy VMs: `openclaw`, `carecircle-staging`, `carecircle-app`, `wazuh`.

*Last updated: 2026-04-05*
