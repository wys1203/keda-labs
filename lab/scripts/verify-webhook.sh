#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/lib.sh"

ensure_cluster
require_cmd kubectl
require_cmd helm

DEMO_NS="demo-deprecated"
KDW_BASE_URL="https://raw.githubusercontent.com/wys1203/keda-deprecation-webhook/${KDW_VERSION}"

kdw_curl() {
  local url="$1"
  kubectl -n "${KDW_NAMESPACE}" run "kdw-curl-$$-${RANDOM}" \
    --attach --rm --restart=Never -i --quiet \
    --image=curlimages/curl:8.10.1 \
    --command -- curl -fsS "${url}"
}

# 1. Pod healthy
log "checking pod health"
kubectl -n "${KDW_NAMESPACE}" rollout status deployment/${KDW_HELM_RELEASE}-keda-deprecation-webhook --timeout=60s

# 2. /metrics
log "checking /metrics"
metrics="$(kdw_curl "http://${KDW_HELM_RELEASE}-keda-deprecation-webhook.${KDW_NAMESPACE}.svc:8080/metrics")"
echo "${metrics}" | grep -q '^keda_deprecation_config_generation' \
  || fail "config_generation metric missing"
log "metrics OK"

# 3. Negative: deprecated SO must be rejected
log "applying demo-deprecated SO (expect rejection)"
kubectl apply -f "${KDW_BASE_URL}/examples/demo-deprecated/namespace.yaml"
kubectl apply -f "${KDW_BASE_URL}/examples/demo-deprecated/deployment.yaml"
set +e
APPLY_OUT="$(kubectl apply -f "${KDW_BASE_URL}/examples/demo-deprecated/scaledobject.yaml" 2>&1)"
APPLY_RC=$?
set -e
echo "${APPLY_OUT}"
[[ ${APPLY_RC} -ne 0 ]] || fail "expected webhook rejection, but apply succeeded"
echo "${APPLY_OUT}" | grep -q "KEDA001" \
  || fail "expected KEDA001 in rejection message, got: ${APPLY_OUT}"
log "rejection OK"

# 4. legacy-cpu warn-mode gauge
log "checking warn-mode gauge for legacy-cpu"
metrics="$(kdw_curl "http://${KDW_HELM_RELEASE}-keda-deprecation-webhook.${KDW_NAMESPACE}.svc:8080/metrics")"
echo "${metrics}" \
  | grep 'keda_deprecation_violations{' \
  | grep 'namespace="legacy-cpu"' \
  | grep 'severity="warn"' \
  || fail "expected violations{namespace=legacy-cpu, severity=warn} not found"
log "warn-mode gauge OK"

# 5. Hot-reload: flip legacy-cpu to off, expect series to update.
log "hot-reloading rules to severity=off for legacy-cpu via helm upgrade"
helm upgrade "${KDW_HELM_RELEASE}" kdw/keda-deprecation-webhook \
  --version "${KDW_VERSION#v}" \
  --namespace "${KDW_NAMESPACE}" \
  --reuse-values \
  --set 'rules[0].namespaceOverrides[0].names[0]=legacy-cpu' \
  --set 'rules[0].namespaceOverrides[0].severity=off' \
  --wait --timeout 1m

log "waiting up to 60s for severity flip to propagate"
seen_off=0
for _ in {1..30}; do
  metrics="$(kdw_curl "http://${KDW_HELM_RELEASE}-keda-deprecation-webhook.${KDW_NAMESPACE}.svc:8080/metrics" || true)"
  if echo "${metrics}" | grep 'keda_deprecation_violations{' \
      | grep 'namespace="legacy-cpu"' | grep -q 'severity="off"'; then
    seen_off=1; break
  fi
  sleep 2
done
[[ ${seen_off} -eq 1 ]] || fail "expected severity=off series after upgrade, not seen"

# 6. Restore lab values
log "restoring lab values"
helm upgrade "${KDW_HELM_RELEASE}" kdw/keda-deprecation-webhook \
  --version "${KDW_VERSION#v}" \
  --namespace "${KDW_NAMESPACE}" \
  --values "${ROOT_DIR}/lab/charts/values-kdw-lab.yaml" \
  --wait --timeout 1m

log "verify-webhook: all checks passed"
