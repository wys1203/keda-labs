#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

ensure_cluster
require_cmd docker
require_cmd kubectl

KDW_NAMESPACE="${KDW_NAMESPACE:-keda-system}"
KDW_IMAGE="${KDW_IMAGE:-keda-deprecation-webhook:dev}"
MANIFEST_DIR="${ROOT_DIR}/manifests/keda-deprecation-webhook"

log "building keda-deprecation-webhook image: ${KDW_IMAGE}"
docker build -t "${KDW_IMAGE}" -f "${ROOT_DIR}/Dockerfile" "${ROOT_DIR}"

load_docker_image_to_kind "${KDW_IMAGE}"

# Manifests applied in dependency order:
#   namespace → rbac → cert (waits for cert-manager to issue) → cm → svc →
#   deploy → pdb → vwc.
# cert-manager itself is installed transitively by install-keda.sh and is
# expected to be ready before this script runs.
log "applying KDW manifests to ${KDW_NAMESPACE}"
kubectl apply -f "${MANIFEST_DIR}/namespace.yaml"
kubectl apply -f "${MANIFEST_DIR}/rbac.yaml"
kubectl apply -f "${MANIFEST_DIR}/certificate.yaml"

log "waiting for kdw-tls secret to be issued by cert-manager"
for _ in {1..60}; do
  if kubectl -n "${KDW_NAMESPACE}" get secret kdw-tls >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
kubectl -n "${KDW_NAMESPACE}" get secret kdw-tls >/dev/null \
  || fail "cert-manager did not issue kdw-tls within 120s"

kubectl apply -f "${MANIFEST_DIR}/configmap.yaml"
kubectl apply -f "${MANIFEST_DIR}/service.yaml"
kubectl apply -f "${MANIFEST_DIR}/deployment.yaml"
kubectl apply -f "${MANIFEST_DIR}/pdb.yaml"
kubectl apply -f "${MANIFEST_DIR}/validatingwebhookconfiguration.yaml"

kubectl_wait_rollout "${KDW_NAMESPACE}" deployment/keda-deprecation-webhook
log "keda-deprecation-webhook is ready"
