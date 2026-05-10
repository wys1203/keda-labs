#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/../../scripts/lib.sh"

require_cmd kind
require_cmd kubectl

if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  log "cluster '${CLUSTER_NAME}' already exists"
  exit 0
fi

log "creating kind cluster '${CLUSTER_NAME}'"
kind create cluster --name "${CLUSTER_NAME}" --config "${LAB_DIR}/kind/cluster.yaml"
kubectl cluster-info >/dev/null
wait_for_nodes_ready
log "kind cluster '${CLUSTER_NAME}' is ready"
