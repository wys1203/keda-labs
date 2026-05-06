#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ensure_cluster
require_cmd helm

KUBE_STATE_METRICS_IMAGE="${KUBE_STATE_METRICS_IMAGE:-dhi.io/kube-state-metrics:2}"
KUBE_STATE_METRICS_LOAD_IMAGE="${KUBE_STATE_METRICS_LOAD_IMAGE:-true}"
KUBE_STATE_METRICS_LOAD_PLATFORM="${KUBE_STATE_METRICS_LOAD_PLATFORM:-}"

if [[ "${KUBE_STATE_METRICS_LOAD_IMAGE}" == "true" ]]; then
  load_docker_image_to_kind "${KUBE_STATE_METRICS_IMAGE}" "${KUBE_STATE_METRICS_LOAD_PLATFORM}"
fi

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

log "installing Prometheus into namespace ${MONITORING_NAMESPACE}"
helm upgrade --install "${PROMETHEUS_RELEASE}" prometheus-community/prometheus \
  --namespace "${MONITORING_NAMESPACE}" \
  --create-namespace \
  -f "${ROOT_DIR}/prometheus/values.yaml" \
  --wait

# Label the namespace so dashboards' `prodsuite` variable picks it up
# (kube-state-metrics exposes the label per metricLabelsAllowlist in
# the chart values).
kubectl label namespace "${MONITORING_NAMESPACE}" prodsuite=Platform --overwrite >/dev/null

# The configmap-reload sidecar can race with the new Prometheus pod on
# helm-upgrade: the new pod sometimes mounts the previous configmap snapshot
# and never sees an inotify event for the rules change. Force a fresh roll
# so the new pod always starts with the latest /etc/config content.
kubectl -n "${MONITORING_NAMESPACE}" rollout restart deploy/prometheus-server >/dev/null
kubectl_wait_rollout "${MONITORING_NAMESPACE}" deployment/prometheus-server

wait_for_workloads "${MONITORING_NAMESPACE}"
log "Prometheus is ready"
