#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

for cmd in docker kind kubectl helm make curl; do
  require_cmd "${cmd}"
done

log "all required commands are available"
