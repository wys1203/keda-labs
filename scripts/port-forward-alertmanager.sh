#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ensure_cluster

ALERTMANAGER_PORT="${ALERTMANAGER_PORT:-9093}"
log "port-forwarding Alertmanager to http://localhost:${ALERTMANAGER_PORT}"
kubectl port-forward -n "${MONITORING_NAMESPACE}" svc/prometheus-alertmanager "${ALERTMANAGER_PORT}:9093"
