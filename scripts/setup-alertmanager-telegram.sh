#!/usr/bin/env bash
# Configure Alertmanager Telegram receiver secret used by kube-prometheus-stack.
#
# Usage:
#   ALERT_TELEGRAM_BOT_TOKEN="123:abc" ALERT_TELEGRAM_CHAT_ID="123456789" \
#   scripts/setup-alertmanager-telegram.sh

set -euo pipefail

NAMESPACE="${NAMESPACE:-monitoring}"
SECRET_NAME="${SECRET_NAME:-alertmanager-main}"
BOT_TOKEN="${ALERT_TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${ALERT_TELEGRAM_CHAT_ID:-}"
PROFILE="${ALERT_TELEGRAM_PROFILE:-balanced}"

if [ -z "${BOT_TOKEN}" ] || [ -z "${CHAT_ID}" ]; then
  echo "ERROR: set ALERT_TELEGRAM_BOT_TOKEN and ALERT_TELEGRAM_CHAT_ID."
  exit 1
fi

if [ "${PROFILE}" != "balanced" ] && [ "${PROFILE}" != "critical-only" ]; then
  echo "ERROR: ALERT_TELEGRAM_PROFILE must be one of: balanced, critical-only"
  exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

if [ "${PROFILE}" = "critical-only" ]; then
cat >"${tmp}" <<EOF
global:
  resolve_timeout: 5m
route:
  receiver: drop
  group_by: ['alertname', 'namespace', 'severity']
  group_wait: 30s
  group_interval: 15m
  repeat_interval: 12h
  routes:
    # Drop kube-proxy alert for clusters where kube-proxy is intentionally absent.
    - receiver: drop
      matchers:
        - alertname="KubeProxyDown"
    - receiver: telegram
      matchers:
        - severity="critical"
      group_wait: 30s
      group_interval: 10m
      repeat_interval: 4h
receivers:
  - name: drop
  - name: telegram
    telegram_configs:
      - bot_token: "${BOT_TOKEN}"
        chat_id: ${CHAT_ID}
        parse_mode: ""
        send_resolved: true
        message: |
          [{{ .Status }}][{{ .CommonLabels.severity }}] {{ .CommonLabels.alertname }}
          {{- if .CommonLabels.namespace }} namespace={{ .CommonLabels.namespace }}{{ end }}
          {{- range .Alerts }}
          - {{ or .Labels.pod .Labels.instance .Labels.node .Labels.job "target" }}: {{ or .Annotations.summary .Annotations.description "no summary" }}
          {{- end }}
EOF
else
cat >"${tmp}" <<EOF
global:
  resolve_timeout: 5m
route:
  receiver: drop
  group_by: ['alertname', 'namespace', 'severity']
  group_wait: 2m
  group_interval: 30m
  repeat_interval: 12h
  routes:
    # Drop kube-proxy alert for clusters where kube-proxy is intentionally absent.
    - receiver: drop
      matchers:
        - alertname="KubeProxyDown"
    # Drop common noisy kube-state alerts that create alert fatigue during rollouts/restarts.
    - receiver: drop
      matchers:
        - alertname=~"KubePodNotReady|KubeDeploymentReplicasMismatch"
    # Send critical alerts for all namespaces.
    - receiver: telegram
      matchers:
        - severity="critical"
      group_wait: 30s
      group_interval: 10m
      repeat_interval: 4h
    # Send warning-level alerts only for curated OpenStack/Ceph signals.
    - receiver: telegram
      matchers:
        - severity="warning"
        - alertname=~"OpenStack.*|CephClusterWarningOrError"
      group_wait: 2m
      group_interval: 30m
      repeat_interval: 12h
inhibit_rules:
  - source_matchers:
      - severity="critical"
    target_matchers:
      - severity="warning"
    equal: ['alertname', 'namespace']
receivers:
  - name: drop
  - name: telegram
    telegram_configs:
      - bot_token: "${BOT_TOKEN}"
        chat_id: ${CHAT_ID}
        parse_mode: ""
        send_resolved: true
        message: |
          [{{ .Status }}][{{ .CommonLabels.severity }}] {{ .CommonLabels.alertname }}
          {{- if .CommonLabels.namespace }} namespace={{ .CommonLabels.namespace }}{{ end }}
          {{- range .Alerts }}
          - {{ or .Labels.pod .Labels.instance .Labels.node .Labels.job "target" }}: {{ or .Annotations.summary .Annotations.description "no summary" }}
          {{- end }}
EOF
fi

kubectl -n "${NAMESPACE}" create secret generic "${SECRET_NAME}" \
  --from-file=alertmanager.yaml="${tmp}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Alertmanager Telegram secret applied: ${NAMESPACE}/${SECRET_NAME}"
echo "Profile: ${PROFILE}"
echo "If this is first setup, sync Argo app monitoring-kube-prometheus-stack and check alertmanager pod status."
