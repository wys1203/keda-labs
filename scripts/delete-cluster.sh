#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  log "deleting kind cluster '${CLUSTER_NAME}'"
  kind delete cluster --name "${CLUSTER_NAME}"
else
  log "cluster '${CLUSTER_NAME}' does not exist"
fi
