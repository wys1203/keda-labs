#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ensure_cluster

log "deploying CPU demo workload"
kubectl apply -f "${ROOT_DIR}/manifests/demo-cpu/namespace.yaml" >/dev/null
kubectl apply -f "${ROOT_DIR}/manifests/demo-cpu/deployment.yaml" >/dev/null
kubectl apply -f "${ROOT_DIR}/manifests/demo-cpu/service.yaml" >/dev/null
kubectl apply -f "${ROOT_DIR}/manifests/demo-cpu/scaledobject.yaml" >/dev/null

kubectl_wait_rollout "${DEMO_NAMESPACE}" deployment/cpu-demo
log "CPU demo is ready"
