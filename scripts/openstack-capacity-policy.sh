#!/usr/bin/env bash
set -euo pipefail

CLOUD="${OS_CLOUD:-homelab}"
DISK_BUFFER_GB="${DISK_BUFFER_GB:-10}"
RAM_BUFFER_MB="${RAM_BUFFER_MB:-1024}"
STRICT=0

if [[ "${1:-}" == "--strict" ]]; then
  STRICT=1
  shift
fi

FLAVORS=("$@")
if [[ "${#FLAVORS[@]}" -eq 0 ]]; then
  FLAVORS=(m1.medium m1.large)
fi

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 2; }
}

require openstack
require awk

get_stat() {
  local col="$1"
  openstack --os-cloud "$CLOUD" hypervisor stats show -f value -c "$col" 2>/dev/null \
    | awk '/^[0-9]+$/{v=$1} END{if(v=="") v=0; print v}'
}

least_disk="$(get_stat disk_available_least)"
free_ram="$(get_stat free_ram_mb)"
vcpus_total="$(get_stat vcpus)"
vcpus_used="$(get_stat vcpus_used)"
free_vcpus=$(( vcpus_total - vcpus_used ))

printf 'Capacity policy check\n'
printf -- '- cloud: %s\n' "$CLOUD"
printf -- '- buffers: disk +%sG, ram +%sMB\n\n' "$DISK_BUFFER_GB" "$RAM_BUFFER_MB"

printf 'Cluster stats: least_disk=%sG free_ram=%sMB free_vcpus=%s\n\n' "$least_disk" "$free_ram" "$free_vcpus"

failed=0

for flavor in "${FLAVORS[@]}"; do
  if ! openstack --os-cloud "$CLOUD" flavor show "$flavor" >/dev/null 2>&1; then
    printf '[WARN] flavor %s not found\n' "$flavor"
    failed=1
    continue
  fi

  disk="$(openstack --os-cloud "$CLOUD" flavor show "$flavor" -f value -c disk)"
  ram="$(openstack --os-cloud "$CLOUD" flavor show "$flavor" -f value -c ram)"
  vcpu="$(openstack --os-cloud "$CLOUD" flavor show "$flavor" -f value -c vcpus)"

  need_disk=$(( disk + DISK_BUFFER_GB ))
  need_ram=$(( ram + RAM_BUFFER_MB ))
  need_vcpu=$(( vcpu ))

  ok_disk=0; ok_ram=0; ok_vcpu=0
  (( least_disk >= need_disk )) && ok_disk=1
  (( free_ram >= need_ram )) && ok_ram=1
  (( free_vcpus >= need_vcpu )) && ok_vcpu=1

  if (( ok_disk && ok_ram && ok_vcpu )); then
    printf '[PASS] %-12s needs disk=%sG(+%s) ram=%sMB(+%s) vcpu=%s -> schedulable\n' \
      "$flavor" "$disk" "$DISK_BUFFER_GB" "$ram" "$RAM_BUFFER_MB" "$vcpu"
  else
    printf '[WARN] %-12s needs disk=%sG(+%s) ram=%sMB(+%s) vcpu=%s -> risk of NoValidHost\n' \
      "$flavor" "$disk" "$DISK_BUFFER_GB" "$ram" "$RAM_BUFFER_MB" "$vcpu"
    printf '       checks: disk(%s>=%s)=%s ram(%s>=%s)=%s vcpu(%s>=%s)=%s\n' \
      "$least_disk" "$need_disk" "$ok_disk" \
      "$free_ram" "$need_ram" "$ok_ram" \
      "$free_vcpus" "$need_vcpu" "$ok_vcpu"
    failed=1
  fi
done

if (( STRICT && failed )); then
  exit 1
fi
exit 0
