#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/lib.sh"

ensure_cluster
require_cmd helm

log "adding kdw helm repo"
helm repo add kdw "${KDW_HELM_REPO_URL}" >/dev/null 2>&1 || true
helm repo update >/dev/null

log "installing keda-deprecation-webhook ${KDW_VERSION} from helm repo"
helm upgrade --install "${KDW_HELM_RELEASE}" kdw/keda-deprecation-webhook \
  --version "${KDW_VERSION#v}" \
  --namespace "${KDW_NAMESPACE}" --create-namespace \
  --values "${ROOT_DIR}/lab/charts/values-kdw-lab.yaml" \
  --wait --timeout 2m

# Lab-specific: the chart's namespace template does not carry the
# prodsuite label that lab monitoring uses to group workloads.
# Apply it after helm install.
kubectl label namespace "${KDW_NAMESPACE}" prodsuite=Platform --overwrite

log "keda-deprecation-webhook ${KDW_VERSION} ready"
