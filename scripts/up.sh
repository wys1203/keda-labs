#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

"${SCRIPT_DIR}/prereq-check.sh"
"${ROOT_DIR}/lab/scripts/create-cluster.sh"
"${ROOT_DIR}/lab/scripts/label-zones.sh"
"${ROOT_DIR}/lab/scripts/prepull-images.sh"
"${ROOT_DIR}/lab/scripts/install-monitoring.sh"
"${ROOT_DIR}/lab/scripts/install-keda.sh"
"${ROOT_DIR}/kdw/scripts/install-webhook.sh"
"${ROOT_DIR}/lab/scripts/deploy-demo.sh"
"${SCRIPT_DIR}/verify.sh"
