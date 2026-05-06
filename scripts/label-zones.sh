#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ensure_cluster

workers=()
while IFS= read -r node_name; do
  [[ -n "${node_name}" ]] && workers+=("${node_name}")
done < <(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

[[ "${#workers[@]}" -eq 3 ]] || fail "expected 3 worker nodes, found ${#workers[@]}"

zones=(dc1 dc2 dc3)

for i in "${!workers[@]}"; do
  log "labeling ${workers[$i]} with topology.kubernetes.io/zone=${zones[$i]}"
  kubectl label node "${workers[$i]}" "topology.kubernetes.io/zone=${zones[$i]}" --overwrite
done

log "worker node zone labels applied"

routable_node="${workers[0]}"
log "labeling ${routable_node} with node-routable=true"
kubectl label node "${routable_node}" node-routable=true --overwrite
log "tainting ${routable_node} with node-routable=true:NoSchedule"
kubectl taint node "${routable_node}" node-routable=true:NoSchedule --overwrite
