# Post-Sync Validation Automation

## Goal
Automatically validate OpenStack health when Argo OpenStack app state changes, and alert if validation fails.

## Components

- `scripts/openstack-sync-monitor.sh`
  - Watches Argo applications matching `^openstack-`
  - Detects state/revision/health changes
  - Runs:
    - `scripts/openstack-preflight.sh m1.medium`
    - `scripts/openstack-capacity-policy.sh --strict m1.medium m1.large`
  - Sends alert on failure via:
    - generic webhook (`ALERT_WEBHOOK_URL`)
    - Telegram bot (`ALERT_TELEGRAM_BOT_TOKEN` + `ALERT_TELEGRAM_CHAT_ID`)

- `scripts/openstack-capacity-policy.sh`
  - Enforces schedulability policy for medium/large flavors
  - Uses cluster-level signals (`disk_available_least`, `free_ram_mb`, `free_vcpus`)
  - Default safety buffers:
    - `DISK_BUFFER_GB=10`
    - `RAM_BUFFER_MB=1024`

## One-time setup (Mac mini operator node)

From repo root:

```bash
chmod +x scripts/openstack-sync-monitor.sh scripts/openstack-capacity-policy.sh scripts/openstack-preflight.sh
```

(Optional) export webhook URL for alerts:

```bash
export ALERT_WEBHOOK_URL='https://<your-webhook-endpoint>'
```

Or Telegram alerts:

```bash
export ALERT_TELEGRAM_BOT_TOKEN='<bot-token>'
export ALERT_TELEGRAM_CHAT_ID='<chat-id>'
```

Test once:

```bash
scripts/openstack-sync-monitor.sh
```

## Cron automation

Recommended: run twice daily (09:00 and 21:00 local time):

```bash
( crontab -l 2>/dev/null; \
  echo "0 9,21 * * * cd /path/to/openstack-homelab-gitops && ALERT_TELEGRAM_BOT_TOKEN='<bot-token>' ALERT_TELEGRAM_CHAT_ID='<chat-id>' scripts/openstack-sync-monitor.sh >> /tmp/openstack-sync-monitor.log 2>&1" \
) | crontab -
```

## Policy interpretation

- If `m1.medium` or `m1.large` fails policy check, scheduler may return `NoValidHost`.
- In that case:
  - Use smaller flavor (e.g., `m1.small`) as immediate workaround.
  - Free/expand compute disk as long-term fix.

## Manual commands

```bash
scripts/openstack-preflight.sh m1.medium
scripts/openstack-capacity-policy.sh m1.medium m1.large
scripts/openstack-capacity-policy.sh --strict m1.medium m1.large
```
