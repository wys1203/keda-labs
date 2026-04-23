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
kubectl get scaledobject cpu-demo -n "${DEMO_NAMESPACE}" >/dev/null || log "scaledobject cpu-demo not deployed yet"

log "verification checks completed"
