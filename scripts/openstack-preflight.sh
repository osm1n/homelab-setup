#!/usr/bin/env bash
set -euo pipefail

CLOUD="${OS_CLOUD:-homelab}"
FLAVOR="${1:-m1.medium}"
NS="openstack"

pass() { printf '[PASS] %s\n' "$1"; }
warn() { printf '[WARN] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1"; FAILED=1; }

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 2; }
}

require kubectl
require openstack
require awk
require grep

FAILED=0

echo "OpenStack preflight"
echo "- cloud: $CLOUD"
echo "- flavor check: $FLAVOR"
echo

# 1) Keystone auth sanity.
if openstack --os-cloud "$CLOUD" token issue -f value -c id >/dev/null 2>&1; then
  pass "Keystone token issue succeeds"
else
  fail "Keystone token issue failed (Skyline/OpenStack auth path unhealthy)"
fi

# 2) Keystone key secrets must contain data.
fernet_keys="$(kubectl -n "$NS" get secret keystone-fernet-keys -o go-template='{{range $k,$v := .data}}{{$k}} {{end}}' 2>/dev/null || true)"
cred_keys="$(kubectl -n "$NS" get secret keystone-credential-keys -o go-template='{{range $k,$v := .data}}{{$k}} {{end}}' 2>/dev/null || true)"

if [[ -n "${fernet_keys// /}" ]]; then
  pass "keystone-fernet-keys populated (${fernet_keys})"
else
  fail "keystone-fernet-keys empty; rerun keystone-fernet-setup"
fi

if [[ -n "${cred_keys// /}" ]]; then
  pass "keystone-credential-keys populated (${cred_keys})"
else
  fail "keystone-credential-keys empty; rerun keystone-credential-setup"
fi

# 3) Critical Argo app statuses.
if kubectl -n argocd get application openstack-keystone >/dev/null 2>&1; then
  ksync="$(kubectl -n argocd get application openstack-keystone -o jsonpath='{.status.sync.status}')"
  khealth="$(kubectl -n argocd get application openstack-keystone -o jsonpath='{.status.health.status}')"
  if [[ "$ksync" == "Synced" && "$khealth" == "Healthy" ]]; then
    pass "Argo app openstack-keystone is Synced/Healthy"
  else
    warn "Argo app openstack-keystone is ${ksync}/${khealth}"
  fi
else
  warn "Argo application openstack-keystone not found"
fi

if kubectl -n argocd get application openstack-nova >/dev/null 2>&1; then
  nsync="$(kubectl -n argocd get application openstack-nova -o jsonpath='{.status.sync.status}')"
  nhealth="$(kubectl -n argocd get application openstack-nova -o jsonpath='{.status.health.status}')"
  if [[ "$nsync" == "Synced" && "$nhealth" == "Healthy" ]]; then
    pass "Argo app openstack-nova is Synced/Healthy"
  else
    warn "Argo app openstack-nova is ${nsync}/${nhealth}"
  fi
fi

# 4) Compute services up.
svc_table="$(openstack --os-cloud "$CLOUD" compute service list -f value -c Binary -c Host -c State 2>/dev/null || true)"
compute_up_count="$(printf '%s\n' "$svc_table" | awk '$1=="nova-compute" && $3=="up" {c++} END{print c+0}')"
if [[ "$compute_up_count" -ge 1 ]]; then
  pass "nova-compute services up: $compute_up_count"
else
  fail "No nova-compute service is up"
fi

# 5) Capacity signal for chosen flavor.
flavor_disk="$(openstack --os-cloud "$CLOUD" flavor show "$FLAVOR" -f value -c disk 2>/dev/null || echo 0)"
least_disk="$(openstack --os-cloud "$CLOUD" hypervisor stats show -f value -c disk_available_least 2>/dev/null | tail -n1 || echo 0)"

if [[ "$flavor_disk" =~ ^[0-9]+$ && "$least_disk" =~ ^[0-9]+$ ]]; then
  if (( least_disk >= flavor_disk )); then
    pass "disk_available_least (${least_disk}G) >= ${FLAVOR} disk (${flavor_disk}G)"
  else
    warn "disk_available_least (${least_disk}G) < ${FLAVOR} disk (${flavor_disk}G): risk of NoValidHost"
  fi
else
  warn "Could not evaluate flavor/capacity disk check"
fi

echo
if [[ "$FAILED" -eq 0 ]]; then
  echo "Preflight result: OK"
  exit 0
fi

echo "Preflight result: FAIL"
exit 1
