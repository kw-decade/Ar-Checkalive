#!/usr/bin/env bash
set -euo pipefail

# 用法: pool-worker.sh POOL BASE_URL MODEL STATE_FILE   （token 只走 ANYROUTER_TOKEN）
if [ "$#" -ne 4 ] || [ -z "${ANYROUTER_TOKEN:-}" ]; then
  printf 'Usage: %s POOL BASE_URL MODEL STATE_FILE (token via ANYROUTER_TOKEN)\n' "$0" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/model-discovery.sh
source "$SCRIPT_DIR/lib/model-discovery.sh"

pool="$1"
token="$ANYROUTER_TOKEN"
base_url="$(normalize_base_url "$2")"
model="$3"
state_file="$4"
case "$pool" in claude|gpt) ;; *) printf 'Unknown pool\n' >&2; exit 2 ;; esac

PROBE_MIN_SEC="${PROBE_MIN_SEC:-3}"
PROBE_MAX_SEC="${PROBE_MAX_SEC:-10}"
# KEEPALIVE_SEC: 空 → 默认 180–300 秒随机；"0" → 不保活，成功通知后该池结束；
# 单个数字 N → 固定 N 秒；"A-B" → A 到 B 秒随机。
KEEPALIVE_SEC="${KEEPALIVE_SEC:-}"
KEEPALIVE_MIN_SEC="${KEEPALIVE_MIN_SEC:-180}"
KEEPALIVE_MAX_SEC="${KEEPALIVE_MAX_SEC:-300}"
keepalive_enabled=true
if [ "$KEEPALIVE_SEC" = 0 ]; then
  keepalive_enabled=false
elif [[ "$KEEPALIVE_SEC" =~ ^([0-9]+)-([0-9]+)$ ]]; then
  KEEPALIVE_MIN_SEC="${BASH_REMATCH[1]}"; KEEPALIVE_MAX_SEC="${BASH_REMATCH[2]}"
elif [[ "$KEEPALIVE_SEC" =~ ^[0-9]+$ ]]; then
  KEEPALIVE_MIN_SEC="$KEEPALIVE_SEC"; KEEPALIVE_MAX_SEC="$KEEPALIVE_SEC"
elif [ -n "$KEEPALIVE_SEC" ]; then
  printf 'KEEPALIVE_SEC 格式无效（应为 0、N 或 A-B）\n' >&2; exit 2
fi
MAX_DURATION_SEC="${MAX_DURATION_SEC:-17400}"
MAX_ITERATIONS="${MAX_ITERATIONS:-0}"
PROMPTS_FILE="${PROMPTS_FILE:-$SCRIPT_DIR/prompts.txt}"
SLEEP_COMMAND="${SLEEP_COMMAND:-sleep}"
ADAPTER_COMMAND="${ADAPTER_COMMAND:-$SCRIPT_DIR/adapters/$pool.sh}"
CHAIN_ID="${CHAIN_ID:-}"
CHAIN_STARTED_EPOCH="${CHAIN_STARTED_EPOCH:-0}"
DRY_RUN="${DRY_RUN:-false}"
MODEL_CANDIDATES_FILE="${MODEL_CANDIDATES_FILE:-}"
MODEL_DISCOVERY_COMMAND="${MODEL_DISCOVERY_COMMAND:-}"
ALLOW_MODEL_REDISCOVERY="${ALLOW_MODEL_REDISCOVERY:-true}"
MODEL_OVERRIDE="${MODEL_OVERRIDE:-${ANYROUTER_MODEL_OVERRIDE:-}}"

for value in "$PROBE_MIN_SEC" "$PROBE_MAX_SEC" "$KEEPALIVE_MIN_SEC" "$KEEPALIVE_MAX_SEC" "$MAX_DURATION_SEC" "$MAX_ITERATIONS"; do
  [[ "$value" =~ ^[0-9]+$ ]] || { printf 'Invalid numeric worker setting\n' >&2; exit 2; }
done
[ -r "$PROMPTS_FILE" ] || { printf 'Prompt file is unavailable\n' >&2; exit 2; }

mapfile -t prompts < <(awk 'NF && $0 !~ /^[[:space:]]*#/' "$PROMPTS_FILE")
[ "${#prompts[@]}" -gt 0 ] || { printf 'Prompt file has no usable entries\n' >&2; exit 2; }

# ---------- 中文映射表：只用于人看的日志/邮件，state 文件和 relay 仍用英文 ----------
declare -A POOL_CN=([claude]='Claude池' [gpt]='GPT池')
declare -A PHASE_CN=([probing]='探测中' [keepalive]='保活中' [config_error]='配置错误' [stopped]='已停止' [done]='已完成')
declare -A STATUS_CN=([success]='成功' [rate_limited]='限流' [retryable]='可重试' [invalid]='无效')
declare -A MESSAGE_CN=(
  [non_empty_response]='收到回复'
  [empty_response]='空回复'
  [capacity_limited]='容量受限'
  [authentication_error]='鉴权失败'
  [model_or_protocol_error]='模型不存在或协议不兼容'
  [request_configuration_error]='请求参数错误'
  [request_timeout]='请求超时'
  [cli_or_upstream_error]='CLI或上游错误'
  [cli_command_unavailable]='CLI命令不可用'
  [cli_argument_error]='CLI参数错误'
  [cli_configuration_error]='CLI配置错误'
  [transport_error]='网络错误'
  [response_stream_error]='响应流中断'
  [upstream_error]='上游错误'
  [unexpected_http_status]='意外HTTP状态'
  [test_result]='测试结果'
)
pool_cn="${POOL_CN[$pool]}"

state_or_default() {
  local key="$1" default="$2" value
  value="$(read_state_value "$state_file" "$key" 2>/dev/null || true)"
  printf '%s\n' "${value:-$default}"
}

phase="$(state_or_default phase probing)"
notified="$(state_or_default notified false)"
[ -n "$CHAIN_ID" ] || CHAIN_ID="$(state_or_default chain_id '')"
[ "$CHAIN_STARTED_EPOCH" != 0 ] || CHAIN_STARTED_EPOCH="$(state_or_default chain_started_epoch 0)"
case "$phase" in probing|keepalive|config_error|stopped|done) ;; *) phase=probing ;; esac
case "$notified" in true|false) ;; *) notified=false ;; esac

persist_state() {
  write_state_file "$state_file" "$phase" "$model" "$notified" "$CHAIN_ID" "$CHAIN_STARTED_EPOCH"
}

# ---------- 模型候选：invalid 时依次换下一个 ----------
model_candidates=()
model_candidate_index=0
model_candidates_loaded=false
model_candidates_rediscovered=false

discover_candidate_list() {
  local candidate_output status=0
  set +e
  if [ -n "$MODEL_DISCOVERY_COMMAND" ]; then
    candidate_output="$(env -u GITHUB_TOKEN -u QQ_EMAIL -u QQ_SMTP_AUTH_CODE -u ANYROUTER_TOKENS \
      ANYROUTER_TOKEN="$token" "$MODEL_DISCOVERY_COMMAND" "$pool" "$base_url" "$MODEL_OVERRIDE" 2>/dev/null)"
  else
    candidate_output="$(discover_models "$pool" "$base_url" "$token" "$MODEL_OVERRIDE" 2>/dev/null)"
  fi
  status=$?
  set -e
  [ "$status" -eq 0 ] || return 1
  candidate_output="${candidate_output//$'\r'/}"
  mapfile -t model_candidates <<< "$candidate_output"
  model_candidate_index=0
  [ "${#model_candidates[@]}" -gt 0 ]
}

load_model_candidates() {
  [ "$model_candidates_loaded" = true ] && return 0
  model_candidates_loaded=true
  if [ -n "$MODEL_CANDIDATES_FILE" ] && [ -r "$MODEL_CANDIDATES_FILE" ]; then
    mapfile -t model_candidates < <(awk 'NF && $0 !~ /^[[:space:]]*#/' "$MODEL_CANDIDATES_FILE")
    model_candidate_index=0
    [ "${#model_candidates[@]}" -gt 0 ]
    return
  fi
  discover_candidate_list
}

rediscover_model_candidates() {
  [ "$model_candidates_rediscovered" = false ] || return 1
  model_candidates_rediscovered=true
  discover_candidate_list
}

next_model_candidate() {
  local candidate
  while [ "$model_candidate_index" -lt "${#model_candidates[@]}" ]; do
    candidate="${model_candidates[$model_candidate_index]}"
    model_candidate_index=$((model_candidate_index + 1))
    [ -n "$candidate" ] || continue
    [ "$candidate" = "$model" ] && continue
    model="$candidate"
    phase=probing
    notified=false
    persist_state
    return 0
  done
  return 1
}

advance_model_after_invalid() {
  [ "$ALLOW_MODEL_REDISCOVERY" = true ] || return 1
  load_model_candidates || return 1
  next_model_candidate && return 0
  rediscover_model_candidates || return 1
  next_model_candidate
}

# ---------- 进程与信号 ----------
adapter_pid=''
sleep_pid=''
adapter_result_file="$(mktemp)"

stop_worker() {
  trap - INT TERM
  kill_tree "$adapter_pid"
  kill_tree "$sleep_pid"
  adapter_pid=''
  sleep_pid=''
  phase=stopped
  persist_state
  exit 0
}
trap stop_worker INT TERM
trap 'rm -f "$adapter_result_file"' EXIT

persist_state
case "$phase" in config_error|stopped|done) exit 0 ;; esac

# ---------- 日志 / 通知 ----------
safe_log_value() {
  printf '%s' "$1" | tr '\r\n' '  ' | tr -cd '[:alnum:]_.:/+\[\]-' | cut -c1-96
}

log_result() {
  local log_phase="$1" log_status="$2" log_http="$3" log_elapsed="$4" log_cli_exit="$5" log_message="$6"
  [[ "$log_http" =~ ^[0-9]{3}$ ]] || log_http=000
  [[ "$log_elapsed" =~ ^[0-9]+$ ]] || log_elapsed=0
  [[ "$log_cli_exit" =~ ^[0-9]+$ ]] || log_cli_exit=0
  printf '[%s] 阶段=%s 模型=%s 状态=%s HTTP=%s 耗时=%s秒 CLI退出码=%s 原因=%s\n' \
    "$pool_cn" "${PHASE_CN[$log_phase]:-未知}" "$(safe_log_value "$model")" \
    "${STATUS_CN[$log_status]:-未知}" "$log_http" "$log_elapsed" "$log_cli_exit" \
    "${MESSAGE_CN[$log_message]:-未分类}"
}

actions_url() {
  if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
    printf '%s/%s/actions/runs/%s\n' "$GITHUB_SERVER_URL" "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID"
  else
    printf '%s\n' '（无 Actions 链接）'
  fi
}

notify_event() {
  local event="$1" subject body
  if [ -n "${EMAIL_LOG:-}" ]; then
    mkdir -p "$(dirname "$EMAIL_LOG")"
    printf '%s|%s\n' "$pool" "$event" >> "$EMAIL_LOG"
    return 0
  fi
  [ "$DRY_RUN" != true ] || return 0
  case "$event" in
    success)
      subject="Anyrouter ${pool_cn} 已可用"
      body="池：$pool_cn
模型：$model
状态：可用
时间：$(date -u '+%Y-%m-%d %H:%M:%S UTC')
Actions：$(actions_url)
不需要继续保活时，在 Actions 里以 mode=stop 运行一次 workflow。"
      ;;
    config_error)
      subject="Anyrouter ${pool_cn} 配置错误"
      body="池：$pool_cn
模型：$model
状态：配置错误
时间：$(date -u '+%Y-%m-%d %H:%M:%S UTC')
Actions：$(actions_url)"
      ;;
    *) return 2 ;;
  esac
  if ! send_email_safe "$subject" "$body"; then
    printf '[%s] 通知邮件发送失败\n' "$pool_cn" >&2
  fi
}

sleep_for_phase() {
  local delay sleep_status=0
  if [ "$phase" = keepalive ]; then
    delay="$(random_between "$KEEPALIVE_MIN_SEC" "$KEEPALIVE_MAX_SEC")"
  else
    delay="$(random_between "$PROBE_MIN_SEC" "$PROBE_MAX_SEC")"
  fi
  printf '[%s] 阶段=%s 下次等待=%s秒\n' "$pool_cn" "${PHASE_CN[$phase]}" "$delay"
  "$SLEEP_COMMAND" "$delay" &
  sleep_pid=$!
  wait "$sleep_pid" || sleep_status=$?
  sleep_pid=''
  [ "$sleep_status" -eq 0 ]
}

# ---------- 主循环 ----------
start_epoch="$(date +%s)"
iterations=0
while :; do
  now_epoch="$(date +%s)"
  [ $((now_epoch - start_epoch)) -lt "$MAX_DURATION_SEC" ] || break
  if [ "$MAX_ITERATIONS" -gt 0 ] && [ "$iterations" -ge "$MAX_ITERATIONS" ]; then break; fi

  prompt="${prompts[RANDOM % ${#prompts[@]}]}"
  adapter_exit=0
  : > "$adapter_result_file"
  env -u GITHUB_TOKEN -u QQ_EMAIL -u QQ_SMTP_AUTH_CODE -u ANYROUTER_TOKENS \
    ANYROUTER_TOKEN="$token" bash "$ADAPTER_COMMAND" "$base_url" "$model" "$prompt" >"$adapter_result_file" 2>&1 &
  adapter_pid=$!
  wait "$adapter_pid" || adapter_exit=$?
  adapter_pid=''
  result="$(cat "$adapter_result_file")"
  if [ "$adapter_exit" -ne 0 ]; then
    status=retryable message=cli_or_upstream_error http_code=000 elapsed_sec=0 cli_exit_code="$adapter_exit"
  else
    status="$(awk -F= '$1 == "status" { print $2; exit }' <<< "$result")"
    message="$(awk -F= '$1 == "message" { print $2; exit }' <<< "$result")"
    http_code="$(awk -F= '$1 == "http_code" { print $2; exit }' <<< "$result")"
    elapsed_sec="$(awk -F= '$1 == "elapsed_sec" { print $2; exit }' <<< "$result")"
    cli_exit_code="$(awk -F= '$1 == "cli_exit_code" { print $2; exit }' <<< "$result")"
    case "$status" in success|rate_limited|invalid|retryable) ;; *) status=retryable ;; esac
  fi

  case "$status" in
    success)
      if [ "$keepalive_enabled" = true ]; then phase=keepalive; else phase=done; fi
      if [ "$notified" != true ]; then
        notified=true
        persist_state
        notify_event success
      else
        persist_state
      fi
      log_result "$phase" "$status" "$http_code" "$elapsed_sec" "$cli_exit_code" "$message"
      [ "$phase" != done ] || break
      ;;
    rate_limited)
      phase=probing
      notified=false
      persist_state
      log_result "$phase" "$status" "$http_code" "$elapsed_sec" "$cli_exit_code" "$message"
      ;;
    retryable)
      persist_state
      log_result "$phase" "$status" "$http_code" "$elapsed_sec" "$cli_exit_code" "$message"
      ;;
    invalid)
      log_result "$phase" "$status" "$http_code" "$elapsed_sec" "$cli_exit_code" "$message"
      if [ "$message" = model_or_protocol_error ] && advance_model_after_invalid; then
        printf '[%s] 换用下一个候选模型：%s\n' "$pool_cn" "$(safe_log_value "$model")"
        iterations=$((iterations + 1))
        if [ "$MAX_ITERATIONS" -gt 0 ] && [ "$iterations" -ge "$MAX_ITERATIONS" ]; then break; fi
        continue
      fi
      phase=config_error
      persist_state
      notify_event config_error
      break
      ;;
  esac

  iterations=$((iterations + 1))
  if [ "$MAX_ITERATIONS" -gt 0 ] && [ "$iterations" -ge "$MAX_ITERATIONS" ]; then break; fi
  sleep_for_phase
done
