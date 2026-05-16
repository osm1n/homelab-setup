#!/usr/bin/env bash
# Install Prometheus Operator CRDs via server-side apply.
# This avoids client-side annotation-size limits seen with Argo on some CRDs.

set -euo pipefail

BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd}"
CRDS=(
  alertmanagerconfigs
  alertmanagers
  prometheusagents
  prometheuses
  scrapeconfigs
  thanosrulers
)

for crd in "${CRDS[@]}"; do
  echo "Applying CRD: monitoring.coreos.com_${crd}.yaml"
  curl -fsSL "${BASE_URL}/monitoring.coreos.com_${crd}.yaml" | kubectl apply --server-side -f -
done

echo "Prometheus Operator CRDs applied successfully."
