#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-keda-lab}"
KEDA_NAMESPACE="${KEDA_NAMESPACE:-platform-keda}"
CERT_MANAGER_NAMESPACE="${CERT_MANAGER_NAMESPACE:-cert-manager}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.16.2}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-demo-cpu}"
GRAFANA_RELEASE="${GRAFANA_RELEASE:-grafana}"
PROMETHEUS_RELEASE="${PROMETHEUS_RELEASE:-prometheus}"

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

# Pin every kubectl/helm call in this shell to the kind-${CLUSTER_NAME}
# cluster, regardless of the user's current default context. Important
# when more than one kind cluster is running side by side (e.g. an
# `istio-lab` next to `keda-lab`) — without this, switching contexts in
# another terminal would silently target the wrong cluster.
#
# We do this by writing kind's kubeconfig for our cluster to a temp file
# and exporting KUBECONFIG just for the duration of the script's process.
ensure_cluster() {
  kind get clusters | grep -qx "${CLUSTER_NAME}" || fail "kind cluster '${CLUSTER_NAME}' not found"
  if [[ -z "${KUBECONFIG_PINNED:-}" ]]; then
    local kc
    kc="$(mktemp -t "${CLUSTER_NAME}-kubeconfig.XXXXXX")"
    kind export kubeconfig --name "${CLUSTER_NAME}" --kubeconfig "${kc}" >/dev/null
    export KUBECONFIG="${kc}"
    export KUBECONFIG_PINNED=1
    # Expand ${kc} at trap-set time so the EXIT handler doesn't depend on
    # `kc` being in scope (it's a function-local; under `set -u` a lazy
    # expansion would fail with "unbound variable" once we leave the
    # function).
    trap "rm -f '${kc}'" EXIT
  fi
}

wait_for_nodes_ready() {
  local expected_count
  local actual_count

  expected_count="$(awk '/^[[:space:]]*-[[:space:]]role:/ { count++ } END { print count + 0 }' "${ROOT_DIR}/kind/cluster.yaml")"
  [[ "${expected_count}" -gt 0 ]] || expected_count=1

  log "waiting for ${expected_count} kind node(s) to register"
  for _ in {1..150}; do
    actual_count="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')"
    [[ "${actual_count}" -ge "${expected_count}" ]] && break
    sleep 2
  done

  [[ "${actual_count}" -ge "${expected_count}" ]] || fail "expected ${expected_count} nodes, found ${actual_count:-0}"

  log "waiting for cluster nodes to be Ready"
  kubectl wait --for=condition=Ready node --all --timeout=300s
}

load_docker_image_to_kind() {
  local image="$1"
  local platform="${2:-}"
  local image_archive

  require_cmd kind
  require_cmd docker

  docker image inspect "${image}" >/dev/null 2>&1 || fail "image '${image}' not found in local Docker; run: docker pull ${image}"

  if [[ -z "${platform}" ]]; then
    platform="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.operatingSystem}/{.items[0].status.nodeInfo.architecture}')"
  fi
  [[ -n "${platform}" ]] || fail "could not determine kind node platform for image load"

  image_archive="$(mktemp -t kind-image.XXXXXX.tar)"
  log "loading image into kind cluster '${CLUSTER_NAME}' for ${platform}: ${image}"
  # Don't pass `--platform` to `docker save`: digest-pulled images may not
  # carry platform metadata in their config and `docker save --platform`
  # then refuses with "no suitable export target found … does not provide
  # the specified platform". Multi-arch filtering is enforced below by
  # `ctr import --platform=…` which is the layer that actually matters.
  docker save -o "${image_archive}" "${image}" || {
    rm -f "${image_archive}"
    fail "failed to export ${image}"
  }

  # Bypass `kind load image-archive` and import via ctr directly. kind
  # passes `--all-platforms` to ctr import, which on a multi-arch image
  # also pulls in the attestation-manifest blob shipped alongside the
  # arch-specific image. ctr then fails with "mismatched rootfs and
  # manifest layers" because the attestation references content that
  # isn't in the local tar. Using a single `--platform` filter restricts
  # the import to just this arch's image + layers, ignoring attestation.
  #
  # Skip the control-plane node: it carries the standard
  # node-role.kubernetes.io/control-plane:NoSchedule taint, so user
  # workloads never land there and there's nothing to gain from
  # pre-loading. Skipping also dodges a tricky edge case where a
  # control-plane's content store, after earlier failed imports, holds
  # a leftover attestation blob that re-triggers the mismatch error
  # even with `--platform` set.
  local nodes node
  nodes="$(kind get nodes --name "${CLUSTER_NAME}" | grep -v -- '-control-plane$' || true)"
  for node in ${nodes}; do
    docker exec -i "${node}" ctr -n k8s.io image import \
      --platform="${platform}" --digests - < "${image_archive}" >/dev/null || {
      rm -f "${image_archive}"
      fail "failed to import ${image} into kind node ${node}"
    }
  done
  rm -f "${image_archive}"
}

kubectl_wait_rollout() {
  local namespace="$1"
  local resource="$2"
  kubectl rollout status -n "${namespace}" "${resource}" --timeout=180s
}

wait_for_pods() {
  local namespace="$1"
  kubectl wait --for=condition=Ready pod --all -n "${namespace}" --timeout=300s
}

wait_for_workloads() {
  local namespace="$1"
  local kind
  local name

  while read -r kind name; do
    [[ -n "${kind}" && -n "${name}" ]] || continue
    kubectl rollout status -n "${namespace}" "${kind}/${name}" --timeout=300s
  done < <(kubectl get deploy,statefulset -n "${namespace}" -o jsonpath='{range .items[*]}{.kind}{" "}{.metadata.name}{"\n"}{end}')
}
