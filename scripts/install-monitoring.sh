#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"${SCRIPT_DIR}/install-metrics-server.sh"
"${SCRIPT_DIR}/install-prometheus.sh"
"${SCRIPT_DIR}/install-grafana.sh"
