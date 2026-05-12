#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/../../scripts/lib.sh"

ensure_cluster
require_cmd helm

helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

kubectl create namespace "${MONITORING_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "creating Grafana provisioning ConfigMaps"
kubectl create configmap grafana-datasources \
  --namespace "${MONITORING_NAMESPACE}" \
  --from-file="${LAB_DIR}/grafana/provisioning/datasources/prometheus.yaml" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl create configmap grafana-dashboard-providers \
  --namespace "${MONITORING_NAMESPACE}" \
  --from-file="${LAB_DIR}/grafana/provisioning/dashboards/dashboards.yaml" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Fetch the kdw dashboard at the pinned KDW_VERSION (defined in scripts/lib.sh)
KDW_DASHBOARD_TMP="$(mktemp -t kdw-dashboard.XXXXXX.json)"
trap 'rm -f "${KDW_DASHBOARD_TMP}"' EXIT
log "fetching kdw dashboard ${KDW_VERSION}"
curl -fsSL "https://raw.githubusercontent.com/wys1203/keda-deprecation-webhook/${KDW_VERSION}/dashboard.json" \
  -o "${KDW_DASHBOARD_TMP}"

# Dashboards CM merges lab-core dashboards (lab/grafana/dashboards/*.json)
# with KDW's own dashboard (fetched from the upstream repo at the pinned
# KDW_VERSION) into a single ConfigMap. Grafana provisioner picks them all
# up via the dashboards.yaml provider.
kubectl create configmap grafana-dashboards \
  --namespace "${MONITORING_NAMESPACE}" \
  --from-file="${LAB_DIR}/grafana/dashboards" \
  --from-file=keda-deprecations.json="${KDW_DASHBOARD_TMP}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "installing Grafana 11 into namespace ${MONITORING_NAMESPACE}"
helm upgrade --install "${GRAFANA_RELEASE}" grafana/grafana \
  --namespace "${MONITORING_NAMESPACE}" \
  -f "${LAB_DIR}/grafana/values.yaml" \
  --set adminUser="${GRAFANA_ADMIN_USER:-admin}" \
  --set adminPassword="${GRAFANA_ADMIN_PASSWORD:-admin}" \
  --wait

# Grafana provisions datasources only at startup, and dashboard file
# provisioning can lag behind ConfigMap projection updates. Restart after
# refreshing ConfigMaps so re-running this script makes the UI converge on
# the files in grafana/.
kubectl -n "${MONITORING_NAMESPACE}" rollout restart deployment/"${GRAFANA_RELEASE}" >/dev/null
kubectl_wait_rollout "${MONITORING_NAMESPACE}" deployment/"${GRAFANA_RELEASE}"
log "Grafana is ready"
