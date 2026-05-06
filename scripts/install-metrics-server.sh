#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_cmd kind
require_cmd curl
ensure_cluster

# Use the official high-availability manifest for Kubernetes 1.21+.
# Keep the release pinned so this Kubernetes 1.24 kind lab does not
# accidentally start tracking a future metrics-server release.
METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-v0.6.4}"
METRICS_SERVER_MANIFEST_URL="${METRICS_SERVER_MANIFEST_URL:-https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/high-availability-1.21+.yaml}"
METRICS_SERVER_IMAGE="${METRICS_SERVER_IMAGE:-dhi.io/metrics-server:0-alpine3.23-dev}"
METRICS_SERVER_LOAD_IMAGE="${METRICS_SERVER_LOAD_IMAGE:-true}"
METRICS_SERVER_LOAD_PLATFORM="${METRICS_SERVER_LOAD_PLATFORM:-}"

if [[ "${METRICS_SERVER_LOAD_IMAGE}" == "true" ]]; then
  load_docker_image_to_kind "${METRICS_SERVER_IMAGE}" "${METRICS_SERVER_LOAD_PLATFORM}"
fi

log "installing metrics-server ${METRICS_SERVER_VERSION} from ${METRICS_SERVER_MANIFEST_URL} (image: ${METRICS_SERVER_IMAGE})"
curl -fsSL "${METRICS_SERVER_MANIFEST_URL}" \
  | awk -v image="${METRICS_SERVER_IMAGE}" '
      /image: .*\/metrics-server:.*/ {
        sub(/image: .*/, "image: " image)
      }
      /--kubelet-preferred-address-types=/ {
        sub(/--kubelet-preferred-address-types=.*/, "--kubelet-preferred-address-types=InternalIP,Hostname,InternalDNS,ExternalDNS,ExternalIP")
      }
      { print }
      /--metric-resolution=15s/ {
        print "        - --kubelet-insecure-tls"
      }
    ' \
  | kubectl apply -f - >/dev/null

kubectl rollout status -n kube-system deployment/metrics-server --timeout=300s
log "metrics-server is ready"
