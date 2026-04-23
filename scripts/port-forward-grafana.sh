#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ensure_cluster

GRAFANA_PORT="${GRAFANA_PORT:-3000}"
log "port-forwarding Grafana to http://localhost:${GRAFANA_PORT}"
kubectl port-forward -n "${MONITORING_NAMESPACE}" svc/"${GRAFANA_RELEASE}" "${GRAFANA_PORT}:80"
