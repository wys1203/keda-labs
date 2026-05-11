#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/lib.sh"

ensure_cluster
wait_for_nodes_ready

"${SCRIPT_DIR}/install-metrics-server.sh"
"${SCRIPT_DIR}/install-prometheus.sh"
"${SCRIPT_DIR}/install-grafana.sh"
