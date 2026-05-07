#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ensure_cluster
require_cmd helm

helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update >/dev/null

log "installing cert-manager ${CERT_MANAGER_VERSION} into namespace ${CERT_MANAGER_NAMESPACE}"
helm upgrade --install cert-manager jetstack/cert-manager \
  --version "${CERT_MANAGER_VERSION}" \
  --namespace "${CERT_MANAGER_NAMESPACE}" \
  --create-namespace \
  --set crds.enabled=true \
  --wait

wait_for_workloads "${CERT_MANAGER_NAMESPACE}"

log "cert-manager is ready"
