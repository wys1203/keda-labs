#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ensure_cluster

log "deploying CPU demo workload (resource trigger)"
kubectl apply -f "${ROOT_DIR}/manifests/demo-cpu/namespace.yaml" >/dev/null
kubectl apply -f "${ROOT_DIR}/manifests/demo-cpu/deployment.yaml" >/dev/null
kubectl apply -f "${ROOT_DIR}/manifests/demo-cpu/service.yaml" >/dev/null
kubectl apply -f "${ROOT_DIR}/manifests/demo-cpu/scaledobject.yaml" >/dev/null

kubectl_wait_rollout "${DEMO_NAMESPACE}" deployment/cpu-demo
log "CPU demo is ready"

# The Prometheus-trigger demo exists so the adapter -> operator gRPC path
# is exercised. Without an external scaler in the cluster, KEDA registers
# its scaler-level Prometheus collectors lazily and they never appear,
# leaving the dashboard's "Adapter ↔ Operator gRPC" + "External scalers"
# rows empty.
log "deploying Prometheus demo workload (external trigger)"
kubectl apply -f "${ROOT_DIR}/manifests/demo-prom/namespace.yaml" >/dev/null
kubectl apply -f "${ROOT_DIR}/manifests/demo-prom/deployment.yaml" >/dev/null
kubectl apply -f "${ROOT_DIR}/manifests/demo-prom/scaledobject.yaml" >/dev/null

kubectl_wait_rollout demo-prom deployment/prom-demo
log "Prometheus demo is ready"
