#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ensure_cluster

PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
log "port-forwarding Prometheus to http://localhost:${PROMETHEUS_PORT}"
kubectl port-forward -n "${MONITORING_NAMESPACE}" svc/prometheus-server "${PROMETHEUS_PORT}:80"
