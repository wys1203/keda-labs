#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/lib.sh"

ensure_cluster
require_cmd kubectl

NS="dashboards-coverage"
MODE="${1:-apply}"

EXPECTED_METRIC_NAMES=(
  "cpu"
  "memory"
  "s0-prometheus"
  "s0-nats-jetstream"
  "s0-redis"
  "s0-cron"
  "s0-metrics-api"
)

usage() {
  echo "Usage: $0 {apply|verify|delete}"
  echo "  apply  — create stub ScaledObjects in namespace $NS"
  echo "  verify — query Prometheus, confirm all 7 trigger types appear"
  echo "  delete — remove the namespace and all stubs"
  exit 2
}

case "$MODE" in
  apply)
    log "creating namespace $NS"
    kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

    cat <<YAML | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: {name: target, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: target}}
  template:
    metadata: {labels: {app: target}}
    spec:
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
          resources:
            requests: {cpu: 50m, memory: 32Mi}
            limits:   {cpu: 200m, memory: 64Mi}
YAML

    for name in memory promstub natsstub redisstub cronstub metricsapistub; do
      kubectl -n "$NS" delete scaledobject "$name" --ignore-not-found
    done

    cat <<YAML | kubectl apply -f -
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: {name: memory, namespace: $NS}
spec:
  scaleTargetRef: {name: target}
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
  scaleTargetRef: {name: target}
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
  scaleTargetRef: {name: target}
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
  scaleTargetRef: {name: target}
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
  scaleTargetRef: {name: target}
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
  scaleTargetRef: {name: target}
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

    kill $PF 2>/dev/null

    echo "Observed metric_name values in $NS:"
    echo "$actual" | sed 's/^/  /'

    missing=()
    for expected in "${EXPECTED_METRIC_NAMES[@]}"; do
      if ! echo "$actual" | grep -qx "$expected"; then
        missing+=("$expected")
      fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
      log "MISSING trigger types in inventory:"
      printf '  %s\n' "${missing[@]}"
      exit 1
    fi
    log "all 7 trigger types present in Inventory dashboard's source query"
    ;;

  delete)
    log "deleting namespace $NS and all stubs"
    kubectl delete namespace "$NS" --ignore-not-found --wait=false
    ;;

  *)
    usage
    ;;
esac
