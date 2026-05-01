#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ensure_cluster
require_cmd helm

helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

kubectl create namespace "${MONITORING_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "creating Grafana provisioning ConfigMaps"
kubectl create configmap grafana-datasources \
  --namespace "${MONITORING_NAMESPACE}" \
  --from-file="${ROOT_DIR}/grafana/provisioning/datasources/prometheus.yaml" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl create configmap grafana-dashboard-providers \
  --namespace "${MONITORING_NAMESPACE}" \
  --from-file="${ROOT_DIR}/grafana/provisioning/dashboards/dashboards.yaml" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl create configmap grafana-dashboards \
  --namespace "${MONITORING_NAMESPACE}" \
  --from-file="${ROOT_DIR}/grafana/dashboards" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "installing Grafana 11 into namespace ${MONITORING_NAMESPACE}"
helm upgrade --install "${GRAFANA_RELEASE}" grafana/grafana \
  --namespace "${MONITORING_NAMESPACE}" \
  -f "${ROOT_DIR}/grafana/values.yaml" \
  --set adminUser="${GRAFANA_ADMIN_USER:-admin}" \
  --set adminPassword="${GRAFANA_ADMIN_PASSWORD:-admin}" \
  --wait

kubectl_wait_rollout "${MONITORING_NAMESPACE}" deployment/"${GRAFANA_RELEASE}"
log "Grafana is ready"
