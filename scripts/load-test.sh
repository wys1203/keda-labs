#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ensure_cluster

LOAD_DURATION="${LOAD_DURATION:-90}"
LOAD_REPLICAS="${LOAD_REPLICAS:-1}"

log "ensuring demo workload exists"
"$(cd "$(dirname "$0")" && pwd)/deploy-demo.sh"

log "resetting demo deployment to ${LOAD_REPLICAS} replica(s)"
kubectl scale deployment/cpu-demo -n "${DEMO_NAMESPACE}" --replicas="${LOAD_REPLICAS}" >/dev/null

log "patching cpu-demo into busy loop for ${LOAD_DURATION}s"
kubectl patch deployment cpu-demo -n "${DEMO_NAMESPACE}" --type='strategic' -p '
spec:
  template:
    spec:
      containers:
        - name: cpu-demo
          command:
            - /bin/sh
            - -c
            - while true; do :; done
' >/dev/null

kubectl_wait_rollout "${DEMO_NAMESPACE}" deployment/cpu-demo
sleep "${LOAD_DURATION}"

log "restoring cpu-demo to idle loop"
kubectl patch deployment cpu-demo -n "${DEMO_NAMESPACE}" --type='strategic' -p '
spec:
  template:
    spec:
      containers:
        - name: cpu-demo
          command:
            - /bin/sh
            - -c
            - while true; do sleep 30; done
' >/dev/null

kubectl_wait_rollout "${DEMO_NAMESPACE}" deployment/cpu-demo
log "load test completed"
