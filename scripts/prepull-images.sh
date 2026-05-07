#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ensure_cluster
require_cmd helm
require_cmd docker
require_cmd kind
require_cmd python3   # used to parse manifest-list JSON

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

# macOS ships bash 3.2 by default; the obvious idiom
#   while ... ; do ... ; done < <( { ... } | sort -u )
# parses with `bash -n` but fails at runtime with
# "bad substitution: no closing `)' in <(". Use a temp file as the
# intermediary instead — works on bash 3.2 and stays readable.
# (No EXIT trap: lib.sh's ensure_cluster already owns one for kubeconfig
# cleanup, and bash only allows one EXIT trap per shell.)
image_list="$(mktemp -t prepull-images.XXXXXX)"

{
  extract_images keda kedacore/keda --version "${KEDA_CHART_VERSION}" -f "${ROOT_DIR}/keda/values.yaml"
  extract_images cert-manager jetstack/cert-manager --version "${CERT_MANAGER_VERSION}" --set crds.enabled=true
  extract_images prometheus prometheus-community/prometheus -f "${ROOT_DIR}/prometheus/values.yaml"
  extract_images grafana grafana/grafana -f "${ROOT_DIR}/grafana/values.yaml"
  # Demo manifests aren't helm charts — enumerate explicitly.
  printf '%s\n' "busybox:1.36" "registry.k8s.io/pause:3.9"
} | sort -u > "${image_list}"

images=()
while IFS= read -r img; do
  [[ -n "${img}" ]] && images+=("${img}")
done < "${image_list}"
rm -f "${image_list}"

# Filter out images we shouldn't try to pre-pull:
#   * dhi.io/* — local-only Docker Hardened Images that the user already
#     pulled into docker out-of-band; their install scripts handle the
#     kind-load step. Not pullable from any public registry.
#   * docker.io/bats/* — helm test hook images (grafana chart attaches
#     bats/bats:v1.4.1 to a `helm test` Pod). Never scheduled in normal
#     cluster operation, and old releases of bats only published amd64,
#     so a literal arm64 pull would fail.
filtered=()
for img in "${images[@]}"; do
  [[ "${img}" == dhi.io/* ]] && continue
  [[ "${img}" == docker.io/bats/* ]] && continue
  filtered+=("${img}")
done
images=("${filtered[@]}")

platform="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.operatingSystem}/{.items[0].status.nodeInfo.architecture}')"
[[ -n "${platform}" ]] || fail "could not determine kind node platform"

# `docker pull --platform=...` of a multi-arch image leaves the manifest
# list metadata in local docker. `docker save | kind load image-archive`
# (and `kind load docker-image`) then emit a tar that ctr inside the kind
# node refuses with "mismatched rootfs / digest not found" — the classic
# Apple Silicon (and any heterogeneous-platform) failure mode.
#
# Workaround: resolve the per-platform digest from the manifest list,
# pull *by digest* to get a single-arch image with no manifest list, and
# retag back to the canonical name. After that, kind load works.
#
# For images that are already single-arch (no `manifests` array in the
# manifest), there's no digest to look up and we fall back to the regular
# tag pull (which is also safe to load: no manifest list to confuse ctr).
resolve_arch_digest() {
  local image="$1"
  local os="${platform%%/*}"
  local arch="${platform##*/}"
  local raw

  # Prefer `docker buildx imagetools inspect` — it's reliable against
  # docker.io's anonymous-manifest-API throttle, where plain
  # `docker manifest inspect` repeatedly returns empty under load. Fall
  # back to manifest inspect if buildx isn't available. Empty result
  # after both means "treat as single-arch": the caller does a regular
  # tag pull, which loads cleanly (no manifest list to confuse ctr).
  raw="$(docker buildx imagetools inspect "${image}" --raw 2>/dev/null || true)"
  if [[ -z "${raw}" ]]; then
    raw="$(docker manifest inspect "${image}" 2>/dev/null || true)"
  fi
  [[ -n "${raw}" ]] || return 0

  printf '%s' "${raw}" | python3 -c "
import sys, json
data = sys.stdin.read().strip()
if not data:
    sys.exit(0)
m = json.loads(data)
for x in m.get('manifests', []):
    p = x.get('platform', {})
    if p.get('architecture') == '${arch}' and p.get('os') == '${os}':
        print(x['digest'])
        break
"
}

# Pre-resolve digests SERIALLY before parallel pulls. Running
# `docker manifest inspect` 4-way in parallel against quay.io / docker.io
# occasionally returns empty under throttling — that silently flips an
# image onto the fallback (multi-arch) pull path, which then breaks
# `kind load` later. Doing the inspects up-front (cheap, metadata-only,
# no layer downloads) eliminates the race.
log "resolving per-arch digests for ${platform}…"
digest_map="$(mktemp -t prepull-digests.XXXXXX)"
for image in "${images[@]}"; do
  digest="$(resolve_arch_digest "${image}" || true)"
  printf '%s\t%s\n' "${image}" "${digest}" >> "${digest_map}"
done

lookup_digest() {
  awk -F'\t' -v img="$1" '$1 == img { print $2; exit }' "${digest_map}"
}

# Track failures from background pulls via a shared file: backgrounded
# subshells can't propagate exit codes through `wait` on bash 3.2, so a
# failed `pull_one` inside a `&`-launched subshell would otherwise be
# silently lost. Each failure appends a line; we abort if non-empty.
fail_log="$(mktemp -t prepull-failures.XXXXXX)"

try_pull_once() {
  local image="$1"
  local repo="${image%@*}"      # everything before @ (no-op if no digest)
  repo="${repo%:*}"             # strip :tag
  local digest
  digest="$(lookup_digest "${image}")"

  if [[ -n "${digest}" ]]; then
    # Multi-arch: nuke any existing local refs for this repo BEFORE the
    # digest pull. A previous `docker pull --platform=…` fallback would
    # have stashed an attestation-manifest blob in docker's content
    # store; `docker rmi -f tag` only drops the tag, the attestation
    # blob lingers and `docker save` later includes it, which ctr inside
    # the kind node refuses with "mismatched rootfs and manifest
    # layers". Removing every local ref for the repo (tags AND digest
    # refs) clears the underlying content so the next digest pull
    # produces a clean single-arch image.
    local existing_ids
    existing_ids="$(docker images "${repo}" -q 2>/dev/null | sort -u)"
    if [[ -n "${existing_ids}" ]]; then
      # shellcheck disable=SC2086
      docker rmi -f ${existing_ids} >/dev/null 2>&1 || true
    fi
    if docker pull "${repo}@${digest}" >/dev/null 2>&1 \
       && docker tag "${repo}@${digest}" "${image}" >/dev/null 2>&1; then
      log "pulled ${image} (via ${digest:0:19}…)"
      return 0
    fi
  else
    # Single-arch image (or manifest inspect unavailable): regular pull.
    if docker pull --platform="${platform}" "${image}" >/dev/null 2>&1; then
      log "pulled ${image}"
      return 0
    fi
  fi
  return 1
}

# One retry handles transient registry hiccups — quay.io in particular
# rate-limits parallel manifest fetches, which surfaces as a single
# spurious failure under PREPULL_PARALLELISM=4. The pull itself is
# idempotent, so retrying is safe.
pull_one() {
  local image="$1"
  if try_pull_once "${image}"; then
    return 0
  fi
  sleep 2
  if try_pull_once "${image}"; then
    return 0
  fi
  log "WARN: docker pull failed for ${image} (after retry)"
  echo "${image}" >> "${fail_log}"
  return 1
}

log "pre-pulling ${#images[@]} images for ${platform}"
for img in "${images[@]}"; do
  log "  - ${img}"
done

PREPULL_PARALLELISM="${PREPULL_PARALLELISM:-4}"
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

if [[ -s "${fail_log}" ]]; then
  failed_list="$(tr '\n' ' ' < "${fail_log}")"
  rm -f "${fail_log}"
  fail "docker pull failed for: ${failed_list}"
fi
rm -f "${fail_log}"

# Loading is best-effort: this is a CACHE optimization, not a correctness
# requirement. If `docker save | ctr import` fails for an image (e.g. a
# stray attestation blob in the local docker content store causing
# "mismatched rootfs and manifest layers"), kubelet on the kind node
# will pull it on-demand from the registry — slower first start, but the
# install still succeeds. We surface the list so the user can decide
# whether to clean up local docker (`docker system prune`) for next run.
load_failures=()
for img in "${images[@]}"; do
  # Run in a subshell so load_docker_image_to_kind's `fail` (which calls
  # exit 1) only kills the subshell and we can keep going.
  if ! ( load_docker_image_to_kind "${img}" "${platform}" ); then
    log "WARN: load failed for ${img}; kubelet will pull on-demand"
    load_failures+=("${img}")
  fi
done

if [[ "${#load_failures[@]}" -gt 0 ]]; then
  log "image prepull complete (${#images[@]} images, ${#load_failures[@]} fell back to on-demand)"
else
  log "image prepull complete (${#images[@]} images)"
fi
rm -f "${digest_map}"
