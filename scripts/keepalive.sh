#!/usr/bin/env bash
# Compatibility wrapper for the legacy single-Claude entry point.
set -euo pipefail

TOKEN="${1:-}"
if [ -z "$TOKEN" ]; then
  printf 'Usage: %s <token> [base_url] [model]\n' "$0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

base_url="$(normalize_base_url "${2:-${ANYROUTER_BASE_URL:-$DEFAULT_BASE_URL}}")"
model="${3:-${ANYROUTER_CLAUDE_MODEL:-}}"
if [ -z "$model" ]; then
  model='claude-compat'
fi

mapfile -t prompts < <(awk 'NF && $0 !~ /^[[:space:]]*#/' "$SCRIPT_DIR/prompts.txt")
prompt="${prompts[RANDOM % ${#prompts[@]}]:-Review this code for one correctness risk and suggest a concise fix. Answer in 100-300 tokens.}"

result="$(ANYROUTER_TOKEN="$TOKEN" bash "$SCRIPT_DIR/adapters/claude.sh" "$base_url" "$model" "$prompt")"
status="$(awk -F= '$1 == "status" { print $2; exit }' <<< "$result")"
printf '  Prompt: %s...\n' "${prompt:0:60}"
printf '%s\n' "$result"
case "$status" in
  success) printf '%s\n' '  SUCCESS'; exit 0 ;;
  *) printf '  FAILED (%s)\n' "${status:-unknown}"; exit 1 ;;
esac
