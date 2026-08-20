#!/usr/bin/env bash
# Legacy compatibility entry point. The maintained workflow uses run-dual-pool.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_URL="${BASE_URL:-${ANYROUTER_BASE_URL:-https://anyrouter.top/v1}}"
MODEL="${MODEL:-${ANYROUTER_CLAUDE_MODEL:-}}"
export ANYROUTER_BASE_URL="$BASE_URL" ANYROUTER_CLAUDE_MODEL="$MODEL"
if [ "${1:-}" = --once ]; then
  exec bash "$SCRIPT_DIR/run-dual-pool.sh" --mode start --once
fi
exec bash "$SCRIPT_DIR/run-dual-pool.sh" --mode start
