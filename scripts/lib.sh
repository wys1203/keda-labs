#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-keda-lab}"
KEDA_NAMESPACE="${KEDA_NAMESPACE:-keda}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-demo-cpu}"
GRAFANA_RELEASE="${GRAFANA_RELEASE:-grafana}"
PROMETHEUS_RELEASE="${PROMETHEUS_RELEASE:-prometheus}"

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

ensure_cluster() {
  kind get clusters | grep -qx "${CLUSTER_NAME}" || fail "kind cluster '${CLUSTER_NAME}' not found"
}

kubectl_wait_rollout() {
  local namespace="$1"
  local resource="$2"
  kubectl rollout status -n "${namespace}" "${resource}" --timeout=180s
}

wait_for_pods() {
  local namespace="$1"
  kubectl wait --for=condition=Ready pod --all -n "${namespace}" --timeout=300s
}

wait_for_workloads() {
  local namespace="$1"
  local kind
  local name

  while read -r kind name; do
    [[ -n "${kind}" && -n "${name}" ]] || continue
    kubectl rollout status -n "${namespace}" "${kind}/${name}" --timeout=300s
  done < <(kubectl get deploy,statefulset -n "${namespace}" -o jsonpath='{range .items[*]}{.kind}{" "}{.metadata.name}{"\n"}{end}')
}
