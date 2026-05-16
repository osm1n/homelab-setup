# Monitoring Stack Runbook

This runbook enables full-stack observability for Kubernetes, OpenStack, and Ceph.

## Components

- `kube-prometheus-stack` (Prometheus, Alertmanager, Grafana)
- `loki` (central log store)
- `promtail` (log collector on nodes)
- `PrometheusRule` set for OpenStack/Ceph operational alerts

GitOps app definition:
- `apps/monitoring.yaml`

## 1) Deploy via ArgoCD

Bootstrap Prometheus CRDs first (one-time per cluster):

```bash
scripts/bootstrap-prometheus-crds.sh
```

Then sync Argo:

```bash
kubectl annotate application root -n argocd argocd.argoproj.io/refresh=hard --overwrite
kubectl -n argocd get applications | egrep 'monitoring-(kube-prometheus-stack|loki|promtail|rules)'
kubectl -n monitoring get pods
```

## 2) Configure Telegram Alerts

Use your existing bot token and chat id:

```bash
ALERT_TELEGRAM_BOT_TOKEN='<telegram-bot-token>' \
ALERT_TELEGRAM_CHAT_ID='<telegram-chat-id>' \
scripts/setup-alertmanager-telegram.sh
```

Current Telegram routing profile (noise-reduced):
- Sends all `severity=critical` alerts.
- Sends only curated warning alerts matching `OpenStack.*` and `CephClusterWarningOrError`.
- Drops noisy baseline alerts: `KubePodNotReady`, `KubeDeploymentReplicasMismatch`.
- Uses compact message formatting and longer repeat windows to reduce spam.

Profiles:
- `balanced` (default): critical + curated OpenStack/Ceph warnings.
- `critical-only`: only `severity=critical`.

Set profile explicitly:

```bash
ALERT_TELEGRAM_BOT_TOKEN='<telegram-bot-token>' \
ALERT_TELEGRAM_CHAT_ID='<telegram-chat-id>' \
ALERT_TELEGRAM_PROFILE='critical-only' \
scripts/setup-alertmanager-telegram.sh
```

Verify secret:

```bash
kubectl -n monitoring get secret alertmanager-main
```

## 3) Access Grafana

```bash
kubectl -n monitoring get svc
```

Use the Grafana LoadBalancer service IP shown in `monitoring` namespace.

Get Grafana admin password:

```bash
kubectl -n monitoring get secret monitoring-kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d && echo
```

## 4) Quick Health Checks

```bash
kubectl -n monitoring get pods
kubectl -n monitoring get prometheusrules
kubectl -n monitoring logs ds/monitoring-promtail --tail=50
```

## 5) OpenStack Alert Coverage (initial)

- `OpenStackComputeDaemonSetUnavailable`
- `OpenStackNeutronOVSAgentUnavailable`
- `OpenStackKeystoneApiUnavailable`
- `OpenStackSkylineUnavailable`
- `CephClusterWarningOrError`

## Notes

- Alertmanager is configured to load from secret `monitoring/alertmanager-main`.
- Telegram credentials are intentionally not stored in Git.
- If Alertmanager fails before secret exists, run the Telegram setup script and re-sync `monitoring-kube-prometheus-stack`.
- If Argo reports CRD annotation-size failures, run `scripts/bootstrap-prometheus-crds.sh` and re-sync.
