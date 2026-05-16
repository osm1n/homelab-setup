#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${ROOT_DIR}/.state"
STATE_FILE="${STATE_DIR}/openstack-sync-snapshot.sha256"
CLOUD="${OS_CLOUD:-homelab}"
APP_REGEX="${APP_REGEX:-^openstack-}"
ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:-}"
ALERT_TELEGRAM_BOT_TOKEN="${ALERT_TELEGRAM_BOT_TOKEN:-}"
ALERT_TELEGRAM_CHAT_ID="${ALERT_TELEGRAM_CHAT_ID:-}"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 2; }
}

require kubectl
require jq
require shasum

mkdir -p "$STATE_DIR"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

alert() {
  local msg="$1"
  printf '[%s] ALERT %s\n' "$(ts)" "$msg"
  if [[ -n "$ALERT_WEBHOOK_URL" ]]; then
    curl -fsS -X POST "$ALERT_WEBHOOK_URL" \
      -H 'Content-Type: application/json' \
      -d "{\"text\":\"${msg//\"/\\\"}\"}" >/dev/null || true
  fi
  if [[ -n "$ALERT_TELEGRAM_BOT_TOKEN" && -n "$ALERT_TELEGRAM_CHAT_ID" ]]; then
    curl -fsS -X POST "https://api.telegram.org/bot${ALERT_TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${ALERT_TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${msg}" >/dev/null || true
  fi
}

snapshot="$({
  kubectl -n argocd get application -o json \
    | jq -r --arg re "$APP_REGEX" '.items[] | select(.metadata.name|test($re)) | [.metadata.name, (.status.sync.status // "Unknown"), (.status.health.status // "Unknown"), (.status.sync.revision // ""), (.status.operationState.phase // "") ] | @tsv' \
    | sort
} | shasum -a 256 | awk '{print $1}')"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "$snapshot" > "$STATE_FILE"
  printf '[%s] baseline snapshot initialized\n' "$(ts)"
fi

prev="$(cat "$STATE_FILE")"
if [[ "$snapshot" == "$prev" ]]; then
  printf '[%s] no OpenStack Argo state change\n' "$(ts)"
  exit 0
fi

echo "$snapshot" > "$STATE_FILE"
printf '[%s] OpenStack Argo state changed; running validation\n' "$(ts)"

set +e
"${ROOT_DIR}/scripts/openstack-preflight.sh" m1.medium
preflight_rc=$?
"${ROOT_DIR}/scripts/openstack-capacity-policy.sh" --strict m1.medium m1.large
capacity_rc=$?
set -e

if (( preflight_rc != 0 || capacity_rc != 0 )); then
  alert "OpenStack post-sync validation failed (preflight=${preflight_rc}, capacity=${capacity_rc})"
  exit 1
fi

printf '[%s] post-sync validation passed\n' "$(ts)"
exit 0
