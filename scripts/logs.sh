#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ensure_cluster

log "keda operator logs"
kubectl logs -n "${KEDA_NAMESPACE}" deploy/keda-operator --tail=80 || true

printf '\n'
log "metrics-server logs"
kubectl logs -n kube-system deploy/metrics-server --tail=80 || true

printf '\n'
log "cpu-demo logs"
kubectl logs -n "${DEMO_NAMESPACE}" deploy/cpu-demo --tail=80 || true
