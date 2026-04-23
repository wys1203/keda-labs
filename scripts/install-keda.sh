#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ensure_cluster
require_cmd helm

helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
helm repo update >/dev/null

log "installing KEDA 2.18.3 into namespace ${KEDA_NAMESPACE}"
helm upgrade --install keda kedacore/keda \
  --version 2.18.3 \
  --namespace "${KEDA_NAMESPACE}" \
  --create-namespace \
  --wait

wait_for_workloads "${KEDA_NAMESPACE}"
log "KEDA is ready"
