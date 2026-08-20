#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ge 4 ]; then
  token="$1"
  base_url_arg="$2"
  model="$3"
  prompt="$4"
elif [ "$#" -ge 3 ] && [ -n "${ANYROUTER_TOKEN:-}" ]; then
  token="$ANYROUTER_TOKEN"
  base_url_arg="$1"
  model="$2"
  prompt="$3"
else
  printf 'Usage: %s BASE_URL MODEL PROMPT (token via ANYROUTER_TOKEN)\n' "$0" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

base_url="$(normalize_claude_base_url "$base_url_arg")"
start_epoch="$(date +%s)"
REQUEST_TIMEOUT_SEC="${REQUEST_TIMEOUT_SEC:-120}"
[[ "$REQUEST_TIMEOUT_SEC" =~ ^[1-9][0-9]*$ ]] || {
  printf 'status=invalid\nhttp_code=000\nelapsed_sec=0\nmessage=invalid_timeout_setting\n'
  exit 0
}
isolated_home="$(mktemp -d)"
stdout_file="$isolated_home/stdout"
stderr_file="$isolated_home/stderr"
claude_pid=''
mkdir -p "$isolated_home/.claude"

cleanup_claude_home() {
  rm -rf "$isolated_home"
}

stop_claude_process_tree() {
  local pid="${1:-}" child children='' i exited=false
  [ -n "$pid" ] || return 0
  if [ -r "/proc/$pid/task/$pid/children" ]; then
    children="$(cat "/proc/$pid/task/$pid/children" 2>/dev/null || true)"
  else
    children="$(ps -ef 2>/dev/null | awk -v parent="$pid" '$3 == parent { print $2 }')"
  fi
  for child in $children; do stop_claude_process_tree "$child"; done
  kill -TERM "$pid" 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ! kill -0 "$pid" 2>/dev/null; then exited=true; break; fi
    sleep 0.1
  done
  [ "$exited" = true ] || kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

on_claude_signal() {
  trap - TERM INT
  stop_claude_process_tree "$claude_pid"
  claude_pid=''
  cleanup_claude_home
  exit 143
}

trap cleanup_claude_home EXIT
trap on_claude_signal TERM INT

set +e
env -u GITHUB_TOKEN -u QQ_EMAIL -u QQ_SMTP_AUTH_CODE \
  -u ANYROUTER_TOKEN -u ANYROUTER_TOKENS \
  HOME="$isolated_home" \
  USERPROFILE="$isolated_home" \
  XDG_CONFIG_HOME="$isolated_home/.config" \
  CLAUDE_CONFIG_DIR="$isolated_home/.claude" \
  ANTHROPIC_AUTH_TOKEN="$token" \
  ANTHROPIC_BASE_URL="$base_url" \
  timeout --foreground --kill-after=5 "$REQUEST_TIMEOUT_SEC" \
    claude -p "$prompt" --print --model "$model" --bare >"$stdout_file" 2>"$stderr_file" &
claude_pid=$!
wait "$claude_pid"
claude_status=$?
claude_pid=''
set -e

if [ "$claude_status" -eq 0 ]; then
  if [ -s "$stdout_file" ]; then
    printf 'status=success\nhttp_code=200\nelapsed_sec=%s\nmessage=non_empty_response\n' "$(( $(date +%s) - start_epoch ))"
  else
    printf 'status=retryable\nhttp_code=200\nelapsed_sec=%s\nmessage=empty_response\n' "$(( $(date +%s) - start_epoch ))"
  fi
  exit 0
fi

if [ "$claude_status" -eq 124 ]; then
  printf 'status=retryable\nhttp_code=000\nelapsed_sec=%s\nmessage=request_timeout\n' "$(( $(date +%s) - start_epoch ))"
  exit 0
fi

if grep -Eqi '(^|[^0-9])429([^0-9]|$)|rate[ _-]*limit|too many requests' "$stdout_file" "$stderr_file"; then
  printf 'status=rate_limited\nhttp_code=429\nelapsed_sec=%s\nmessage=capacity_limited\n' "$(( $(date +%s) - start_epoch ))"
elif grep -Eqi '(^|[^0-9])(401|403)([^0-9]|$)|unauthorized|forbidden|authentication|invalid[ _-]*(token|api[ _-]*key)' "$stdout_file" "$stderr_file"; then
  printf 'status=invalid\nhttp_code=000\nelapsed_sec=%s\nmessage=authentication_error\n' "$(( $(date +%s) - start_epoch ))"
elif grep -Eqi 'unknown[ _-]*model|model.*(not found|does not exist|unsupported|not supported)|unsupported.*(model|protocol)|protocol.*(unsupported|not supported)' "$stdout_file" "$stderr_file"; then
  printf 'status=invalid\nhttp_code=000\nelapsed_sec=%s\nmessage=model_or_protocol_error\n' "$(( $(date +%s) - start_epoch ))"
elif grep -Eqi 'bad request|invalid[ _-]*(request|argument|parameter)|missing[ _-]*(argument|parameter)' "$stdout_file" "$stderr_file"; then
  printf 'status=invalid\nhttp_code=000\nelapsed_sec=%s\nmessage=request_configuration_error\n' "$(( $(date +%s) - start_epoch ))"
else
  printf 'status=retryable\nhttp_code=000\nelapsed_sec=%s\nmessage=cli_or_upstream_error\n' "$(( $(date +%s) - start_epoch ))"
fi
