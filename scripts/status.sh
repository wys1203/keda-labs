#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ensure_cluster

log "nodes"
kubectl get nodes -L topology.kubernetes.io/zone

printf '\n'
log "keda pods"
kubectl get pods -n "${KEDA_NAMESPACE}" || true

printf '\n'
log "monitoring pods"
kubectl get pods -n "${MONITORING_NAMESPACE}" || true

printf '\n'
log "demo resources"
kubectl get deployment,scaledobject,hpa,pods -n "${DEMO_NAMESPACE}" || true
