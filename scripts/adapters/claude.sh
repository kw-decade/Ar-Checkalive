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
  printf 'status=invalid\nhttp_code=000\nelapsed_sec=0\ncli_exit_code=0\nmessage=invalid_timeout_setting\n'
  exit 0
}
isolated_home="$(mktemp -d)"
stdout_file="$isolated_home/stdout"
stderr_file="$isolated_home/stderr"
claude_pid=''
fable_model_env="${ANTHROPIC_DEFAULT_FABLE_MODEL:-}"
fable_name_env="${ANTHROPIC_DEFAULT_FABLE_MODEL_NAME:-}"
model_lower="${model,,}"
if [ "$model_lower" = 'fable[1m]' ]; then
  fable_model_env='claude-fable-5[1M]'
  fable_name_env='claude-fable-5'
elif [ "$model_lower" = fable ]; then
  fable_model_env='claude-fable-5'
  fable_name_env='claude-fable-5'
elif [[ "$model_lower" == claude-fable-* ]]; then
  fable_name_env="${model%\[1M\]}"
  fable_name_env="${fable_name_env%\[1m\]}"
  fable_model_env="$model"
fi
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

classify_claude_failure() {
  local fallback_message="$1"
  if grep -Eqi '(^|[^0-9])429([^0-9]|$)|rate[ _-]*limit|too many requests' "$stdout_file" "$stderr_file"; then
    printf 'rate_limited|429|capacity_limited\n'
  elif grep -Eqi '(^|[^0-9])529([^0-9]|$)|overloaded|capacity[ _-]*exhausted' "$stdout_file" "$stderr_file"; then
    printf 'rate_limited|529|capacity_limited\n'
  elif grep -Eqi '(^|[^0-9])503([^0-9]|$)|service unavailable' "$stdout_file" "$stderr_file"; then
    printf 'rate_limited|503|capacity_limited\n'
  elif grep -Eqi '(^|[^0-9])(401|403)([^0-9]|$)|unauthorized|forbidden|authentication|invalid[ _-]*(token|api[ _-]*key)' "$stdout_file" "$stderr_file"; then
    printf 'invalid|000|authentication_error\n'
  elif grep -Eqi '(^|[^0-9])(404|405|415|501)([^0-9]|$)|unknown[ _-]*model|model.*(not found|does not exist|unsupported|not supported)|unsupported.*(model|protocol)|protocol.*(unsupported|not supported)|(does not|doesn.t|not).*support.*model|不支持.*模型' "$stdout_file" "$stderr_file"; then
    printf 'invalid|000|model_or_protocol_error\n'
  elif [ "$claude_status" -eq 126 ] || [ "$claude_status" -eq 127 ] || grep -Eqi 'command not found|no such file or directory|not executable|cannot execute|permission denied' "$stdout_file" "$stderr_file"; then
    printf 'retryable|000|cli_command_unavailable\n'
  elif [ "$claude_status" -eq 2 ] || grep -Eqi 'unknown option|unrecognized option|invalid option|unexpected argument|usage:' "$stdout_file" "$stderr_file"; then
    printf 'invalid|000|cli_argument_error\n'
  elif grep -Eqi 'failed to (load|read|parse) (config|configuration|settings)|invalid (config|configuration|settings)|configuration (error|failed)|settings? (error|failed)|toml parse' "$stdout_file" "$stderr_file"; then
    printf 'invalid|000|cli_configuration_error\n'
  elif grep -Eqi 'tls|ssl|handshake|certificate.*(verify|verification)|cert[_ -]*(verify|verification)|dns|could not resolve|connection (refused|reset|failed)|network|transport' "$stdout_file" "$stderr_file"; then
    printf 'retryable|000|transport_error\n'
  elif grep -Eqi 'bad request|invalid[ _-]*(request|argument|parameter)|missing[ _-]*(argument|parameter)|启用.*1m|1m.*(context|上下文).*启用' "$stdout_file" "$stderr_file"; then
    printf 'invalid|000|request_configuration_error\n'
  elif [ "$fallback_message" = request_timeout ]; then
    printf 'retryable|000|request_timeout\n'
  else
    printf 'retryable|000|cli_or_upstream_error\n'
  fi
}

set +e
env -u GITHUB_TOKEN -u QQ_EMAIL -u QQ_SMTP_AUTH_CODE \
  -u ANYROUTER_TOKEN -u ANYROUTER_TOKENS \
  HOME="$isolated_home" \
  USERPROFILE="$isolated_home" \
  XDG_CONFIG_HOME="$isolated_home/.config" \
  CLAUDE_CONFIG_DIR="$isolated_home/.claude" \
  CLAUDE_CODE_MAX_RETRIES=0 \
  ANTHROPIC_DEFAULT_FABLE_MODEL="$fable_model_env" \
  ANTHROPIC_DEFAULT_FABLE_MODEL_NAME="$fable_name_env" \
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
    printf 'status=success\nhttp_code=200\nelapsed_sec=%s\ncli_exit_code=0\nmessage=non_empty_response\n' "$(( $(date +%s) - start_epoch ))"
  else
    printf 'status=retryable\nhttp_code=200\nelapsed_sec=%s\ncli_exit_code=0\nmessage=empty_response\n' "$(( $(date +%s) - start_epoch ))"
  fi
  exit 0
fi

fallback_message=cli_or_upstream_error
[ "$claude_status" -eq 124 ] && fallback_message=request_timeout
IFS='|' read -r failure_status failure_http_code failure_message <<< "$(classify_claude_failure "$fallback_message")"
printf 'status=%s\nhttp_code=%s\nelapsed_sec=%s\ncli_exit_code=%s\nmessage=%s\n' \
  "$failure_status" "$failure_http_code" "$(( $(date +%s) - start_epoch ))" "$claude_status" "$failure_message"
