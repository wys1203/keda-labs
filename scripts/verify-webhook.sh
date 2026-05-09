#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

ensure_cluster
require_cmd kubectl

KDW_NS="${KDW_NS:-keda-system}"
DEMO_NS="demo-deprecated"

# Curl helper: spin up a one-shot curlimages/curl pod inside the cluster
# (so we don't depend on local connectivity), run the requested command,
# and capture stdout. `--attach --rm --restart=Never` waits for completion
# and cleans up the pod. `-i` keeps stdin attached so kubectl exits cleanly.
kdw_curl() {
  local url="$1"
  kubectl -n "${KDW_NS}" run "kdw-curl-$$-${RANDOM}" \
    --attach --rm --restart=Never -i --quiet \
    --image=curlimages/curl:8.10.1 \
    --command -- curl -fsS "${url}"
}

# 1. Pod healthy
log "checking pod health"
kubectl -n "${KDW_NS}" rollout status deployment/keda-deprecation-webhook --timeout=60s

# 2. /metrics is reachable from inside the cluster
log "checking /metrics endpoint"
metrics="$(kdw_curl "http://keda-deprecation-webhook.${KDW_NS}.svc:8080/metrics")"
echo "${metrics}" | grep -q '^keda_deprecation_config_generation' \
  || fail "config_generation metric missing"
log "metrics endpoint OK ($(echo "${metrics}" | wc -l | tr -d ' ') lines)"

# 3. CREATE in demo-deprecated → expected REJECTION
log "applying demo-deprecated SO (expecting reject)"
kubectl apply -f "${ROOT_DIR}/manifests/demo-deprecated/namespace.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/demo-deprecated/deployment.yaml"
set +e
APPLY_OUT="$(kubectl apply -f "${ROOT_DIR}/manifests/demo-deprecated/scaledobject.yaml" 2>&1)"
APPLY_RC=$?
set -e
echo "${APPLY_OUT}"
[[ ${APPLY_RC} -ne 0 ]] || fail "expected webhook rejection, but apply succeeded"
echo "${APPLY_OUT}" | grep -q "KEDA001" \
  || fail "expected KEDA001 in rejection message, got: ${APPLY_OUT}"
log "demo-deprecated SO correctly rejected"

# 4. legacy-cpu (warn ns) — should already exist with deprecated form,
#    expect violations gauge = 1 with severity=warn.
log "checking warn-mode gauge for legacy-cpu"
metrics="$(kdw_curl "http://keda-deprecation-webhook.${KDW_NS}.svc:8080/metrics")"
echo "${metrics}" \
  | grep 'keda_deprecation_violations{' \
  | grep 'namespace="legacy-cpu"' \
  | grep 'severity="warn"' \
  || fail "expected violations{namespace=legacy-cpu, severity=warn} not found"
log "warn-mode gauge OK"

# 5. CM hot-reload: flip legacy-cpu severity to off, expect old warn series gone.
log "hot-reloading CM to severity=\"off\" for legacy-cpu"
kubectl -n "${KDW_NS}" patch configmap keda-deprecation-webhook-config \
  --type merge -p "$(cat <<'EOF'
{"data":{"config.yaml":"rules:\n  - id: KEDA001\n    defaultSeverity: error\n    namespaceOverrides:\n      - names: [\"legacy-cpu\"]\n        severity: \"off\"\n"}}
EOF
)"

log "waiting up to 60s for warn series to disappear"
seen_off=0
for _ in {1..30}; do
  metrics="$(kdw_curl "http://keda-deprecation-webhook.${KDW_NS}.svc:8080/metrics" || true)"
  if ! echo "${metrics}" | grep 'keda_deprecation_violations{' \
        | grep 'namespace="legacy-cpu"' | grep -q 'severity="warn"'; then
    if echo "${metrics}" | grep 'keda_deprecation_violations{' \
        | grep 'namespace="legacy-cpu"' | grep -q 'severity="off"'; then
      seen_off=1
      break
    fi
  fi
  sleep 2
done
[[ ${seen_off} -eq 1 ]] \
  || fail "expected severity=\"off\" series after reload, not seen in metrics"
log "severity flip OK — old warn series gone, off series asserted"

# 6. Restore CM to warn mode for the rest of the lab session.
log "restoring CM"
kubectl apply -f "${ROOT_DIR}/manifests/keda-deprecation-webhook/configmap.yaml"

log "verify-webhook: all checks passed"
