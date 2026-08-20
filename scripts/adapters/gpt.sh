#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ] || [ -z "${ANYROUTER_TOKEN:-}" ]; then
  printf 'Usage: %s BASE_URL MODEL PROMPT (token via ANYROUTER_TOKEN)\n' "$0" >&2
  exit 2
fi
token="$ANYROUTER_TOKEN"
base_url_arg="$1"
model="$2"
prompt="$3"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

base_url="$(normalize_base_url "$base_url_arg")"
start_epoch="$(date +%s)"
REQUEST_TIMEOUT_SEC="${REQUEST_TIMEOUT_SEC:-120}"
[[ "$REQUEST_TIMEOUT_SEC" =~ ^[1-9][0-9]*$ ]] || {
  printf 'status=invalid\nhttp_code=000\nelapsed_sec=0\ncli_exit_code=0\nmessage=invalid_timeout_setting\n'
  exit 0
}
[[ "$model" =~ ^[A-Za-z0-9._:/+-]{1,128}$ ]] || {
  printf 'status=invalid\nhttp_code=000\nelapsed_sec=0\ncli_exit_code=0\nmessage=invalid_request\n'
  exit 0
}

umask 077
isolated_home="$(mktemp -d)"
codex_pid=''
stdout_file="$isolated_home/stdout"
stderr_file="$isolated_home/stderr"
config_file="$isolated_home/config.toml"
mkdir -p "$isolated_home/.config"

cleanup_gpt_home() { rm -rf "$isolated_home"; }
stop_gpt_process_tree() {
  local pid="${1:-}" child children='' i exited=false
  [ -n "$pid" ] || return 0
  if [ -r "/proc/$pid/task/$pid/children" ]; then
    children="$(cat "/proc/$pid/task/$pid/children" 2>/dev/null || true)"
  else
    children="$(ps -ef 2>/dev/null | awk -v parent="$pid" '$3 == parent { print $2 }')"
  fi
  for child in $children; do stop_gpt_process_tree "$child"; done
  kill -TERM "$pid" 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ! kill -0 "$pid" 2>/dev/null; then exited=true; break; fi
    sleep 0.1
  done
  [ "$exited" = true ] || kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}
on_gpt_signal() {
  trap - TERM INT
  stop_gpt_process_tree "$codex_pid"
  codex_pid=''
  cleanup_gpt_home
  exit 143
}
trap cleanup_gpt_home EXIT
trap on_gpt_signal TERM INT

cat > "$config_file" <<TOML
model_provider = "anyrouter"
model = "$model"
disable_response_storage = true

[model_providers.anyrouter]
name = "Anyrouter"
base_url = "$base_url"
wire_api = "responses"
env_key = "OPENAI_API_KEY"
TOML

set +e
env -u GITHUB_TOKEN -u QQ_EMAIL -u QQ_SMTP_AUTH_CODE \
  -u ANYROUTER_TOKEN -u ANYROUTER_TOKENS \
  HOME="$isolated_home" USERPROFILE="$isolated_home" \
  XDG_CONFIG_HOME="$isolated_home/.config" CODEX_HOME="$isolated_home" \
  OPENAI_API_KEY="$token" \
  timeout --foreground --kill-after=5 "$REQUEST_TIMEOUT_SEC" \
    codex exec --ephemeral --skip-git-repo-check --sandbox read-only --model "$model" "$prompt" \
    >"$stdout_file" 2>"$stderr_file" &
codex_pid=$!
wait "$codex_pid"
codex_status=$?
codex_pid=''
set -e

elapsed_sec="$(( $(date +%s) - start_epoch ))"
if [ "$codex_status" -eq 0 ]; then
  if [ -s "$stdout_file" ]; then
    printf 'status=success\nhttp_code=000\nelapsed_sec=%s\ncli_exit_code=0\nmessage=non_empty_response\n' "$elapsed_sec"
  else
    printf 'status=retryable\nhttp_code=000\nelapsed_sec=%s\ncli_exit_code=0\nmessage=empty_response\n' "$elapsed_sec"
  fi
elif [ "$codex_status" -eq 124 ]; then
  printf 'status=retryable\nhttp_code=000\nelapsed_sec=%s\ncli_exit_code=124\nmessage=request_timeout\n' "$elapsed_sec"
elif grep -Eqi '(^|[^0-9])429([^0-9]|$)|rate[ _-]*limit|too many requests|capacity' "$stdout_file" "$stderr_file"; then
  printf 'status=rate_limited\nhttp_code=000\nelapsed_sec=%s\ncli_exit_code=%s\nmessage=capacity_limited\n' "$elapsed_sec" "$codex_status"
elif grep -Eqi '(^|[^0-9])(401|403)([^0-9]|$)|unauthorized|forbidden|authentication|invalid[ _-]*(token|api[ _-]*key)' "$stdout_file" "$stderr_file"; then
  printf 'status=invalid\nhttp_code=000\nelapsed_sec=%s\ncli_exit_code=%s\nmessage=authentication_error\n' "$elapsed_sec" "$codex_status"
elif grep -Eqi 'unknown[ _-]*model|model.*(not found|does not exist|unsupported|not supported)|unsupported.*(model|protocol)|protocol.*(unsupported|not supported)' "$stdout_file" "$stderr_file"; then
  printf 'status=invalid\nhttp_code=000\nelapsed_sec=%s\ncli_exit_code=%s\nmessage=model_or_protocol_error\n' "$elapsed_sec" "$codex_status"
elif [ "$codex_status" -eq 126 ] || [ "$codex_status" -eq 127 ] || grep -Eqi 'command not found|no such file or directory|not executable|cannot execute|permission denied' "$stdout_file" "$stderr_file"; then
  printf 'status=retryable\nhttp_code=000\nelapsed_sec=%s\ncli_exit_code=%s\nmessage=cli_command_unavailable\n' "$elapsed_sec" "$codex_status"
elif [ "$codex_status" -eq 2 ] || grep -Eqi 'unknown option|unrecognized option|invalid option|unexpected argument|usage:' "$stdout_file" "$stderr_file"; then
  printf 'status=invalid\nhttp_code=000\nelapsed_sec=%s\ncli_exit_code=%s\nmessage=cli_argument_error\n' "$elapsed_sec" "$codex_status"
elif grep -Eqi 'failed to (load|read|parse) (config|configuration|settings)|invalid (config|configuration|settings)|configuration (error|failed)|settings? (error|failed)|toml parse' "$stdout_file" "$stderr_file"; then
  printf 'status=invalid\nhttp_code=000\nelapsed_sec=%s\ncli_exit_code=%s\nmessage=cli_configuration_error\n' "$elapsed_sec" "$codex_status"
elif grep -Eqi 'tls|ssl|handshake|dns|could not resolve|connection (refused|reset|failed)|network|transport' "$stdout_file" "$stderr_file"; then
  printf 'status=retryable\nhttp_code=000\nelapsed_sec=%s\ncli_exit_code=%s\nmessage=transport_error\n' "$elapsed_sec" "$codex_status"
elif grep -Eqi 'bad request|invalid[ _-]*(request|argument|parameter)|missing[ _-]*(argument|parameter)' "$stdout_file" "$stderr_file"; then
  printf 'status=invalid\nhttp_code=000\nelapsed_sec=%s\ncli_exit_code=%s\nmessage=request_configuration_error\n' "$elapsed_sec" "$codex_status"
else
  printf 'status=retryable\nhttp_code=000\nelapsed_sec=%s\ncli_exit_code=%s\nmessage=cli_or_upstream_error\n' "$elapsed_sec" "$codex_status"
fi
