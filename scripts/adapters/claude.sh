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

base_url="$(normalize_claude_base_url "$base_url_arg")"
start_epoch="$(date +%s)"
REQUEST_TIMEOUT_SEC="${REQUEST_TIMEOUT_SEC:-120}"
[[ "$REQUEST_TIMEOUT_SEC" =~ ^[1-9][0-9]*$ ]] || {
  printf 'status=invalid\nhttp_code=000\nelapsed_sec=0\ncli_exit_code=0\nmessage=invalid_timeout_setting\n'
  exit 0
}

# Anyrouter 的 Claude 通道要求 1M 上下文。Claude Code 的做法是：
# `--model opus[1m]` 这类别名 → CLI 读 ANTHROPIC_DEFAULT_OPUS_MODEL 拿真实 id → 走 1M 分支。
# 所以：传进来的是别名（含 '['）就原样用；是完整 id 就按 tier 塞进对应 env，并把 --model 换成 "<tier>[1m]"。
cli_model="$model"
default_model_env=''
default_model_value=''
if [[ "$model" != *'['* ]]; then
  model_lower="${model,,}"
  case "$model_lower" in
    *fable*) tier=fable ;;
    *sonnet*) tier=sonnet ;;
    *haiku*) tier=haiku ;;
    *) tier=opus ;;
  esac
  if [ "$model_lower" = "$tier" ]; then
    # 裸别名 "opus"/"fable" 等：CLI 自己会解析，只补 [1m]
    cli_model="${tier}[1m]"
  else
    cli_model="${tier}[1m]"
    default_model_env="ANTHROPIC_DEFAULT_${tier^^}_MODEL"
    default_model_value="${model}[1M]"
  fi
fi

isolated_home="$(mktemp -d)"
stdout_file="$isolated_home/stdout"
stderr_file="$isolated_home/stderr"
claude_pid=''
mkdir -p "$isolated_home/.claude"

trap 'rm -rf "$isolated_home"' EXIT
trap 'trap - TERM INT; kill_tree "$claude_pid"; rm -rf "$isolated_home"; exit 143' TERM INT

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

# 通过 env 数组把可选的 ANTHROPIC_DEFAULT_*_MODEL 传进去；为空就不设。
extra_env=()
[ -z "$default_model_env" ] || extra_env+=("$default_model_env=$default_model_value")

set +e
# 先清掉调用环境里可能存在的 Claude Code 配置（模型别名、API key），只保留我们显式给的。
env -u GITHUB_TOKEN -u QQ_EMAIL -u QQ_SMTP_AUTH_CODE \
  -u ANYROUTER_TOKEN -u ANYROUTER_TOKENS \
  -u ANTHROPIC_API_KEY -u ANTHROPIC_MODEL \
  -u ANTHROPIC_DEFAULT_OPUS_MODEL -u ANTHROPIC_DEFAULT_SONNET_MODEL \
  -u ANTHROPIC_DEFAULT_HAIKU_MODEL -u ANTHROPIC_DEFAULT_FABLE_MODEL \
  HOME="$isolated_home" \
  USERPROFILE="$isolated_home" \
  XDG_CONFIG_HOME="$isolated_home/.config" \
  CLAUDE_CONFIG_DIR="$isolated_home/.claude" \
  CLAUDE_CODE_MAX_RETRIES=0 \
  ANTHROPIC_AUTH_TOKEN="$token" \
  ANTHROPIC_BASE_URL="$base_url" \
  "${extra_env[@]}" \
  timeout --foreground --kill-after=5 "$REQUEST_TIMEOUT_SEC" \
    claude -p "$prompt" --print --model "$cli_model" --bare >"$stdout_file" 2>"$stderr_file" &
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
