#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ensure_cluster
require_cmd python3

prometheus_active_targets() {
  kubectl -n "${MONITORING_NAMESPACE}" exec deploy/prometheus-server -c prometheus-server -- \
    wget -q -O - "http://localhost:9090/api/v1/targets?state=active" 2>/dev/null
}

expect_active_targets_up() {
  local label="$1"
  local service="$2"
  local expected="$3"
  local result

  result="$(prometheus_active_targets | python3 -c 'import json,sys
service=sys.argv[1]
expected=int(sys.argv[2])
targets=[t for t in json.load(sys.stdin)["data"]["activeTargets"] if t["labels"].get("service") == service]
down=[t for t in targets if t["health"] != "up"]
if len(targets) != expected or down:
    print(f"expected {expected} active targets, got {len(targets)} active and {len(down)} down")
    for target in targets:
        print("{} {} {}".format(target["scrapeUrl"], target["health"], target["lastError"]))
    sys.exit(1)
print(len(targets))' "${service}" "${expected}")" || fail "${label}: ${result//$'\n'/; }"
  log "  ${label}: ${result}"
}

log "verifying monitoring rollouts"
kubectl rollout status -n kube-system deployment/metrics-server --timeout=180s
kubectl_wait_rollout "${MONITORING_NAMESPACE}" deployment/prometheus-server
kubectl_wait_rollout "${MONITORING_NAMESPACE}" deployment/prometheus-kube-state-metrics
kubectl_wait_rollout "${MONITORING_NAMESPACE}" deployment/"${GRAFANA_RELEASE}"
kubectl rollout status -n "${MONITORING_NAMESPACE}" statefulset/prometheus-alertmanager --timeout=180s
kubectl rollout status -n "${MONITORING_NAMESPACE}" daemonset/prometheus-prometheus-node-exporter --timeout=180s

for resource in deployment/prometheus-prometheus-pushgateway service/prometheus-prometheus-pushgateway; do
  if kubectl -n "${MONITORING_NAMESPACE}" get "${resource}" >/dev/null 2>&1; then
    fail "${resource} should be disabled but still exists"
  fi
done

log "verifying monitoring services"
kubectl get --raw "/api/v1/namespaces/${MONITORING_NAMESPACE}/services/http:prometheus-server:80/proxy/-/ready" >/dev/null
kubectl get --raw "/api/v1/namespaces/${MONITORING_NAMESPACE}/services/http:prometheus-alertmanager:9093/proxy/-/ready" >/dev/null
kubectl get --raw "/api/v1/namespaces/${MONITORING_NAMESPACE}/services/http:${GRAFANA_RELEASE}:80/proxy/api/health" >/dev/null

log "verifying Prometheus scrapes"
expect_active_targets_up "kube-state-metrics active targets up" "prometheus-kube-state-metrics" "2"
expect_active_targets_up "node-exporter active targets up" "prometheus-prometheus-node-exporter" "4"

kubectl wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=180s >/dev/null
metrics_api_available="$(kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')"
[[ "${metrics_api_available}" == "True" ]] || fail "metrics-server APIService is not Available"
log "  metrics-server APIService available: ${metrics_api_available}"
metrics_top_ready=false
for _ in {1..30}; do
  if kubectl top nodes >/dev/null 2>&1; then
    metrics_top_ready=true
    break
  fi
  sleep 5
done
[[ "${metrics_top_ready}" == "true" ]] || fail "metrics.k8s.io node metrics are not available"
log "  metrics.k8s.io node metrics: ok"

log "monitoring verification checks completed"
