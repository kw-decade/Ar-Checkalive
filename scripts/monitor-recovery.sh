#!/usr/bin/env bash
# Legacy recovery entry point; use keepalive.yml for the maintained dual-pool chain.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_URL="${BASE_URL:-${ANYROUTER_BASE_URL:-https://anyrouter.top/v1}}"
MODEL="${MODEL:-${ANYROUTER_CLAUDE_MODEL:-}}"
export ANYROUTER_BASE_URL="$BASE_URL" ANYROUTER_CLAUDE_MODEL="$MODEL"
exec bash "$SCRIPT_DIR/run-dual-pool.sh" --mode start --once
