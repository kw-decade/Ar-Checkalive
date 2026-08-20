#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/actions-api.sh
source "$SCRIPT_DIR/lib/actions-api.sh"

write_marker() {
  local marker_file="$1" stop_before_epoch="$2" py
  [[ "$stop_before_epoch" =~ ^[0-9]+$ ]] || return 2
  mkdir -p "$(dirname "$marker_file")"
  py="$(python_command)"
  "$py" - "$marker_file" "$stop_before_epoch" <<'PY'
import json, sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"stop_before_epoch": int(sys.argv[2]), "workflow_id": "keepalive.yml"}, handle, separators=(",", ":"))
    handle.write("\n")
PY
}

cancel_runs() {
  local delay="${STOP_SCAN_DELAY_SEC:-5}"
  local status=0
  [[ "$delay" =~ ^[0-9]+$ ]] || return 2
  cancel_active_workflow_runs || {
    printf '%s\n' 'First cancel scan failed.' >&2
    status=1
  }
  sleep "$delay"
  cancel_active_workflow_runs || {
    printf '%s\n' 'Second cancel scan failed.' >&2
    status=1
  }
  return "$status"
}

case "${1:-}" in
  write-marker)
    [ "$#" -eq 3 ] || { printf 'Usage: %s write-marker PATH EPOCH\n' "$0" >&2; exit 2; }
    write_marker "$2" "$3"
    ;;
  cancel-runs)
    [ "$#" -eq 1 ] || { printf 'Usage: %s cancel-runs\n' "$0" >&2; exit 2; }
    cancel_runs
    ;;
  *)
    printf 'Usage: %s write-marker PATH EPOCH | cancel-runs\n' "$0" >&2
    exit 2
    ;;
esac
