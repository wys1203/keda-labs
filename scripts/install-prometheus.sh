#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ensure_cluster
require_cmd helm

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

log "installing Prometheus into namespace ${MONITORING_NAMESPACE}"
helm upgrade --install "${PROMETHEUS_RELEASE}" prometheus-community/prometheus \
  --namespace "${MONITORING_NAMESPACE}" \
  --create-namespace \
  --set alertmanager.enabled=false \
  --set pushgateway.enabled=false \
  --set server.persistentVolume.enabled=false \
  --wait

wait_for_workloads "${MONITORING_NAMESPACE}"
log "Prometheus is ready"
