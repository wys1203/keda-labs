#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/lib.sh"

ensure_cluster
require_cmd helm

# KEDA's TLS certs are issued by cert-manager (see keda/values.yaml), so the
# cert-manager controller and CRDs must be present before the helm install
# renders KEDA's Issuer/Certificate resources.
"${SCRIPT_DIR}/install-cert-manager.sh"

helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
helm repo update >/dev/null

log "installing KEDA 2.16.1 into namespace ${KEDA_NAMESPACE}"
helm upgrade --install keda kedacore/keda \
  --version 2.16.1 \
  --namespace "${KEDA_NAMESPACE}" \
  --create-namespace \
  -f "${LAB_DIR}/keda/values.yaml" \
  --wait

wait_for_workloads "${KEDA_NAMESPACE}"

# Label the namespace so the dashboards' `prodsuite` template variable
# picks it up via kube_namespace_labels (KSM exposes the `prodsuite`
# label per prometheus/values.yaml metricLabelsAllowlist).
kubectl label namespace "${KEDA_NAMESPACE}" prodsuite=Platform --overwrite >/dev/null

log "KEDA is ready"
