#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/lib.sh"

BASE="https://raw.githubusercontent.com/wys1203/keda-deprecation-webhook/${KDW_VERSION}/examples/demo-deprecated"

kubectl apply -f "${BASE}/namespace.yaml"
kubectl apply -f "${BASE}/deployment.yaml"
# scaledobject is expected to be rejected by the webhook (KEDA001).
kubectl apply -f "${BASE}/scaledobject.yaml" || true
