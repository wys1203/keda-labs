#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ensure_cluster
require_cmd helm
require_cmd docker
require_cmd kind

# Pinned chart versions — keep in sync with install-*.sh. Pulled out so the
# prepull script renders the SAME chart version that the installer will fetch.
KEDA_CHART_VERSION="${KEDA_CHART_VERSION:-2.16.1}"

helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

# Render each chart with the SAME flags the installer uses, then grep image
# references out of the rendered manifests. Strips quotes; ignores empty values.
extract_images() {
  helm template "$@" 2>/dev/null \
    | awk '$1 == "image:" {
        gsub(/["'\'']/, "", $2);
        if ($2 != "") print $2;
      }'
}

images=()
while IFS= read -r img; do
  [[ -n "${img}" ]] && images+=("${img}")
done < <(
  {
    extract_images keda kedacore/keda --version "${KEDA_CHART_VERSION}" -f "${ROOT_DIR}/keda/values.yaml"
    extract_images cert-manager jetstack/cert-manager --version "${CERT_MANAGER_VERSION}" --set installCRDs=true
    extract_images prometheus prometheus-community/prometheus -f "${ROOT_DIR}/prometheus/values.yaml"
    extract_images grafana grafana/grafana -f "${ROOT_DIR}/grafana/values.yaml"
    # Demo manifests aren't helm charts — enumerate explicitly.
    printf '%s\n' "busybox:1.36" "registry.k8s.io/pause:3.9"
  } | sort -u
)

# dhi.io images are local-only (Docker Hardened Images that the user already
# pulled into docker out-of-band). Their install scripts handle the
# kind-load step; we can't `docker pull` them from a public registry.
filtered=()
for img in "${images[@]}"; do
  [[ "${img}" == dhi.io/* ]] && continue
  filtered+=("${img}")
done
images=("${filtered[@]}")

platform="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.operatingSystem}/{.items[0].status.nodeInfo.architecture}')"
[[ -n "${platform}" ]] || fail "could not determine kind node platform"

log "pre-pulling ${#images[@]} images for ${platform}"
for img in "${images[@]}"; do
  log "  - ${img}"
done

# Pull in parallel (capped). docker pull is the slow leg; kind load is fast and
# we run it serially below to keep output ordered.
PREPULL_PARALLELISM="${PREPULL_PARALLELISM:-4}"

pull_one() {
  local image="$1"
  if docker pull --platform="${platform}" "${image}" >/dev/null 2>&1; then
    log "pulled ${image}"
  else
    fail "docker pull failed for ${image}"
  fi
}

running=0
for image in "${images[@]}"; do
  pull_one "${image}" &
  ((running++)) || true
  if (( running >= PREPULL_PARALLELISM )); then
    wait
    running=0
  fi
done
wait

for img in "${images[@]}"; do
  load_docker_image_to_kind "${img}" "${platform}"
done

log "image prepull complete (${#images[@]} images)"
