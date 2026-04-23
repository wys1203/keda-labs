#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

"${SCRIPT_DIR}/prereq-check.sh"
"${SCRIPT_DIR}/create-cluster.sh"
"${SCRIPT_DIR}/label-zones.sh"
"${SCRIPT_DIR}/install-monitoring.sh"
"${SCRIPT_DIR}/install-keda.sh"
"${SCRIPT_DIR}/deploy-demo.sh"
"${SCRIPT_DIR}/verify.sh"
