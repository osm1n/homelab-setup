# VM Provisioning and SSH Runbook

## Goal
Create VMs consistently and avoid drift around image users, keypairs, and common scheduler failures.

## 1) Preflight (required)
Run preflight before creating VMs:

```bash
scripts/openstack-preflight.sh m1.medium
```

If it warns about `disk_available_least`, either use a smaller flavor (`m1.small`) or free compute disk.

## 2) Create VM (standard)
Use config-drive and explicit keypair:

```bash
openstack --os-cloud homelab server create \
  --flavor m1.small \
  --image "Rocky Linux 9 Cloud" \
  --network internal-net \
  --key-name homelab-key \
  --config-drive true \
  vm-rocky-<suffix>
```

## 3) Floating IP attach
```bash
openstack --os-cloud homelab floating ip create external-net
openstack --os-cloud homelab server add floating ip vm-rocky-<suffix> <fip-address>
```

## 4) Image default SSH users
Use these users first:

- Ubuntu cloud image: `ubuntu`
- Debian cloud image: `debian`
- Rocky cloud image: `rocky` (in this homelab; if not, test `cloud-user`)
- Kali cloud image: `kali` or `debian` depending on image build

## 5) Match keypair to private key file
Always verify key fingerprint before SSH.

```bash
openstack --os-cloud homelab keypair show homelab-key -f value -c fingerprint
for k in ~/.ssh/*.pub; do echo "== $k =="; ssh-keygen -E md5 -lf "$k"; done
```

Use the private key whose `.pub` fingerprint matches.

## 6) SSH command template
```bash
chmod 600 ~/.ssh/<private-key>
ssh -o IdentitiesOnly=yes -i ~/.ssh/<private-key> <user>@<floating-ip>
```

## 7) Common failures and fixes

### A) `UNPROTECTED PRIVATE KEY FILE`
Fix file mode:
```bash
chmod 600 <keyfile>
```

### B) `Permission denied (publickey,...)`
Checklist:
1. Use `IdentitiesOnly=yes`.
2. Confirm image default user.
3. Confirm key fingerprint matches OpenStack keypair.
4. If still failing, rebuild with `--config-drive true`.

### C) `NoValidHost` during create
This is scheduler/placement capacity mismatch.

Quick checks:
```bash
openstack --os-cloud homelab hypervisor stats show -f yaml
openstack --os-cloud homelab compute service list -f table
```

Immediate workaround:
- Use `m1.small` instead of `m1.medium`.

Long-term fix:
- Add/expand compute storage, or reduce root disk in flavor design.

## 8) Post-create validation
```bash
openstack --os-cloud homelab server list --long -f table
openstack --os-cloud homelab server show vm-rocky-<suffix> -f yaml
```

A healthy VM should show:
- `status: ACTIVE`
- `OS-EXT-SRV-ATTR:host` populated
- Internal IP + floating IP attached
