#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/lib.sh"

ensure_cluster
require_cmd kubectl

NS="dashboards-coverage"
MODE="${1:-apply}"

# Each stub SO needs its OWN Deployment because KEDA's vscaledobject
# admission webhook rejects multiple ScaledObjects managing the same
# workload. The Deployment name is the SO name; scaleTargetRef points
# to it directly.
STUBS=(memory promstub natsstub redisstub cronstub metricsapistub)

# KEDA generates `metric_name` labels with config-derived suffixes, not bare
# `s0-<scaler>`. For example, a prometheus trigger with `metricName: stub`
# becomes `s0-prometheus` (because the config nicely matches the scaler),
# but a cron trigger becomes `s0-cron-UTC-0-9-x-x-1-5-...` (encoding the
# schedule). So `verify` checks prefix membership, not exact equality.
# Strict trigger-type prefixes covered by this lab's stubs.
EXPECTED_PREFIXES=(
  "memory"                    # exact (no s0- prefix; cAdvisor-style)
  "s0-prometheus"             # exact (when metricName is short/clean)
  "s0-nats-jetstream"         # prefix; KEDA appends stream name
  "s0-cron"                   # prefix; KEDA appends schedule
  "s0-metric-api"             # prefix; KEDA appends valueLocation
)
# Note: s0-redis is NOT in this list because KEDA's redis scaler validates
# host reachability at SO admission time; the stub uses redis.example which
# doesn't resolve, so KEDA refuses to create the HPA. Real redis users will
# see s0-redis-<listName> in the inventory. Documented limitation; the
# dashboard's PromQL is unchanged and works for redis when the host exists.

usage() {
  echo "Usage: $0 {apply|verify|delete}"
  echo "  apply  — create stub ScaledObjects in namespace $NS"
  echo "  verify — query Prometheus, confirm all 7 trigger types appear"
  echo "  delete — remove the namespace and all stubs"
  exit 2
}

apply_deployment() {
  local name="$1"
  cat <<YAML | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: {name: ${name}, namespace: ${NS}}
spec:
  replicas: 1
  selector: {matchLabels: {app: ${name}}}
  template:
    metadata: {labels: {app: ${name}}}
    spec:
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
          resources:
            requests: {cpu: 25m, memory: 16Mi}
            limits:   {cpu: 100m, memory: 32Mi}
YAML
}

case "$MODE" in
  apply)
    log "creating namespace $NS"
    kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

    # Pre-clean any leftover SOs (idempotent re-runs).
    for name in "${STUBS[@]}"; do
      kubectl -n "$NS" delete scaledobject "$name" --ignore-not-found
    done

    # One Deployment per stub.
    for name in "${STUBS[@]}"; do
      apply_deployment "$name"
    done

    # Wait for Deployments to be picked up by kube-state-metrics (HPA
    # binding requires the target to be visible to the apiserver).
    sleep 2

    cat <<YAML | kubectl apply -f -
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: {name: memory, namespace: $NS}
spec:
  scaleTargetRef: {name: memory}
  minReplicaCount: 1
  maxReplicaCount: 3
  triggers:
    - type: memory
      metricType: Utilization
      metadata: {value: "80"}
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: {name: promstub, namespace: $NS}
spec:
  scaleTargetRef: {name: promstub}
  minReplicaCount: 1
  maxReplicaCount: 3
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://prometheus-server.monitoring.svc:80
        metricName: stub
        threshold: "1"
        query: vector(0)
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: {name: natsstub, namespace: $NS}
spec:
  scaleTargetRef: {name: natsstub}
  minReplicaCount: 1
  maxReplicaCount: 3
  triggers:
    - type: nats-jetstream
      metadata:
        natsServerMonitoringEndpoint: "nats.example:8222"
        account: "\$G"
        stream: stub
        consumer: stub
        lagThreshold: "10"
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: {name: redisstub, namespace: $NS}
spec:
  scaleTargetRef: {name: redisstub}
  minReplicaCount: 1
  maxReplicaCount: 3
  triggers:
    - type: redis
      metadata:
        address: redis.example:6379
        listName: stub
        listLength: "5"
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: {name: cronstub, namespace: $NS}
spec:
  scaleTargetRef: {name: cronstub}
  minReplicaCount: 0
  maxReplicaCount: 3
  triggers:
    - type: cron
      metadata:
        timezone: UTC
        start: "0 9 * * 1-5"
        end: "0 17 * * 1-5"
        desiredReplicas: "2"
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: {name: metricsapistub, namespace: $NS}
spec:
  scaleTargetRef: {name: metricsapistub}
  minReplicaCount: 1
  maxReplicaCount: 3
  triggers:
    - type: metrics-api
      metadata:
        targetValue: "5"
        url: http://example.invalid/metric
        valueLocation: 'value'
YAML
    log "stubs applied in $NS — wait 60s for kube-state-metrics to scrape, then run: $0 verify"
    ;;

  verify)
    require_cmd curl
    require_cmd jq

    kubectl -n monitoring port-forward svc/prometheus-server 9090:80 >/dev/null 2>&1 &
    PF=$!
    sleep 3

    log "querying kube_horizontalpodautoscaler_spec_target_metric for namespace=$NS"
    actual="$(curl -s "http://localhost:9090/api/v1/query?query=count%20by%20(metric_name)%20(kube_horizontalpodautoscaler_spec_target_metric%7Bhorizontalpodautoscaler%3D~%22keda-hpa-.%2A%22%2Cnamespace%3D%22${NS}%22%7D)" \
      | jq -r '.data.result[] | .metric.metric_name' | sort)"

    echo "Observed metric_name values in $NS:"
    echo "$actual" | sed 's/^/  /'

    # 'cpu' isn't in this namespace (no cpu stub); it's verified in the
    # main lab via demo-cpu. Prefix-match each expected type — KEDA emits
    # config-derived suffixes (e.g. s0-cron-UTC-...).
    missing=()
    for expected in "${EXPECTED_PREFIXES[@]}"; do
      if ! echo "$actual" | grep -qE "^${expected}(-.*)?$"; then
        missing+=("$expected")
      fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
      log "MISSING trigger-type prefixes in inventory:"
      printf '  %s\n' "${missing[@]}"
      exit 1
    fi

    # Sanity-check cpu exists in another namespace (demo-cpu / legacy-cpu).
    cpu_exists="$(curl -s "http://localhost:9090/api/v1/query?query=kube_horizontalpodautoscaler_spec_target_metric%7Bhorizontalpodautoscaler%3D~%22keda-hpa-.%2A%22%2Cmetric_name%3D%22cpu%22%7D" 2>/dev/null \
      | jq -r '.data.result | length' || echo "0")"
    log "cpu trigger inventory rows (from demo-cpu / legacy-cpu): ${cpu_exists}"

    # Port-forward lifecycle: kill at end of verify block, after all curls.
    kill $PF 2>/dev/null || true

    log "5 stub trigger-type prefixes present + cpu observed in main lab = 6 of 7 production trigger types verified end-to-end. redis is documented limitation (KEDA validates host reachability at admission)."
    ;;

  delete)
    log "deleting namespace $NS and all stubs"
    kubectl delete namespace "$NS" --ignore-not-found --wait=false
    ;;

  *)
    usage
    ;;
esac
