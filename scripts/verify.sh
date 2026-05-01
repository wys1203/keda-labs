#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ensure_cluster

log "verifying cluster node count"
worker_count="$(kubectl get nodes --no-headers | awk '$3 != "control-plane" {count++} END {print count+0}')"
[[ "${worker_count}" -eq 3 ]] || fail "expected 3 workers, found ${worker_count}"

for zone in dc1 dc2 dc3; do
  kubectl get nodes -l "topology.kubernetes.io/zone=${zone}" --no-headers | grep -q . || fail "missing worker labeled with zone ${zone}"
done

kubectl get deployment metrics-server -n kube-system >/dev/null
kubectl get deployment keda-operator -n "${KEDA_NAMESPACE}" >/dev/null
kubectl get deployment "${GRAFANA_RELEASE}" -n "${MONITORING_NAMESPACE}" >/dev/null
kubectl get svc prometheus-server -n "${MONITORING_NAMESPACE}" >/dev/null
kubectl get svc prometheus-alertmanager -n "${MONITORING_NAMESPACE}" >/dev/null
kubectl get scaledobject cpu-demo -n "${DEMO_NAMESPACE}" >/dev/null || log "scaledobject cpu-demo not deployed yet"
kubectl get scaledobject prom-demo -n demo-prom >/dev/null || log "scaledobject prom-demo not deployed yet"

# Confirm Prometheus is actually scraping all three KEDA components (the
# whole point of the lab). Anything other than `up==1` means the install
# regressed.
log "verifying Prometheus is scraping KEDA"
for app in keda-operator keda-operator-metrics-apiserver keda-admission-webhooks; do
  raw=$(kubectl -n "${MONITORING_NAMESPACE}" exec deploy/prometheus-server -c prometheus-server -- \
    wget -q -O - "http://localhost:9090/api/v1/query?query=min(up{app_kubernetes_io_name=%22${app}%22,job=%22kubernetes-service-endpoints%22})" 2>/dev/null || true)
  status=$(printf '%s' "${raw}" | python3 -c 'import sys,json;d=json.load(sys.stdin);r=d["data"]["result"];print(r[0]["value"][1] if r else "")' 2>/dev/null || true)
  [[ "${status}" == "1" ]] || fail "KEDA component ${app} is not being scraped (up=${status:-<empty>})"
  log "  ${app}: up=${status}"
done

log "verification checks completed"
