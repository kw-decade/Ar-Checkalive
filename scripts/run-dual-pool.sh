#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/model-discovery.sh
source "$SCRIPT_DIR/lib/model-discovery.sh"
# shellcheck source=lib/actions-api.sh
source "$SCRIPT_DIR/lib/actions-api.sh"

mode=start
once=false
check_only=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) mode="${2:-}"; shift 2 ;;
    --once) once=true; shift ;;
    --check-stop) check_only=true; shift ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
case "$mode" in start|relay) ;; *) printf 'Mode must be start or relay\n' >&2; exit 2 ;; esac

chain_started_epoch="${CHAIN_STARTED_EPOCH:-}"
if [ "$mode" = relay ] && ! [[ "$chain_started_epoch" =~ ^[1-9][0-9]*$ ]]; then
  printf '%s\n' 'relay 模式需要继承有效的 CHAIN_STARTED_EPOCH' >&2
  exit 2
fi
if [ "$mode" = start ] && ! [[ "$chain_started_epoch" =~ ^[1-9][0-9]*$ ]]; then
  chain_started_epoch="$(date +%s)"
fi
chain_id="${CHAIN_ID:-}"
[ -n "$chain_id" ] || chain_id="${GITHUB_RUN_ID:-local}-$RANDOM"

# ---------- stop marker：上一次 mode=stop 是否已经叫停这条链 ----------
check_stop_marker() {
  local marker_file status=0 stopped
  [ "${SKIP_STOP_CHECK:-false}" != true ] || return 0
  if [ -z "${STOP_MARKER_FILE:-}" ] && { [ -z "${GITHUB_TOKEN:-}" ] || [ -z "${GITHUB_REPOSITORY:-}" ]; }; then
    return 0
  fi
  marker_file="$(mktemp)"
  download_latest_stop_marker "$marker_file" || status=$?
  if [ "$status" -eq 1 ]; then rm -f "$marker_file"; return 0; fi
  if [ "$status" -ne 0 ]; then
    rm -f "$marker_file"
    printf '%s\n' '无法核对最新的 stop marker' >&2
    return 1
  fi
  stopped="$(chain_is_stopped "$marker_file" "$chain_started_epoch")" || {
    rm -f "$marker_file"
    printf '%s\n' 'stop marker 内容无效' >&2
    return 1
  }
  rm -f "$marker_file"
  if [ "$stopped" = true ]; then
    printf '链 %s 在本次运行开始前已被停止，不再发送任何请求。\n' "$chain_id"
    return 3
  fi
}

stop_status=0
check_stop_marker || stop_status=$?
if [ "$check_only" = true ]; then
  should_run=true
  [ "$stop_status" -eq 3 ] && should_run=false
  [ "$stop_status" -eq 0 ] || [ "$stop_status" -eq 3 ] || exit "$stop_status"
  printf 'should_run=%s\nchain_started_epoch=%s\nchain_id=%s\n' \
    "$should_run" "$chain_started_epoch" "$chain_id" >> "${GITHUB_OUTPUT:-/dev/stdout}"
  exit 0
fi
[ "$stop_status" -eq 3 ] && exit 0
[ "$stop_status" -eq 0 ] || exit "$stop_status"

token="$(load_single_token)"
base_url="$(normalize_base_url "${ANYROUTER_BASE_URL:-${BASE_URL:-$DEFAULT_BASE_URL}}")"
max_duration="${MAX_DURATION_SEC:-17400}"
[[ "$max_duration" =~ ^[1-9][0-9]*$ ]] || { printf 'Invalid MAX_DURATION_SEC\n' >&2; exit 2; }

state_dir="$(mktemp -d)"
claude_state="$state_dir/claude.state"
gpt_state="$state_dir/gpt.state"
claude_pid=''
gpt_pid=''

cleanup() {
  kill_tree "$claude_pid"
  kill_tree "$gpt_pid"
  rm -rf "$state_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

state_input() {
  local value="$1" default="$2"
  case "$value" in probing|keepalive|config_error|done) printf '%s\n' "$value" ;; *) printf '%s\n' "$default" ;; esac
}

bool_input() {
  case "$1" in true|false) printf '%s\n' "$1" ;; *) printf '%s\n' false ;; esac
}

claude_phase="$(state_input "${CLAUDE_PHASE:-}" probing)"
gpt_phase="$(state_input "${GPT_PHASE:-}" probing)"
claude_notified="$(bool_input "${CLAUDE_NOTIFIED:-false}")"
gpt_notified="$(bool_input "${GPT_NOTIFIED:-false}")"
claude_model="${CLAUDE_MODEL:-}"
gpt_model="${GPT_MODEL:-}"
claude_selector="${ANYROUTER_CLAUDE_MODEL:-}"
gpt_selector="${ANYROUTER_GPT_MODEL:-}"
claude_candidates="$state_dir/claude.models"
gpt_candidates="$state_dir/gpt.models"

# select_model FAMILY INHERITED SELECTOR CANDIDATES_FILE
# 决定本次运行用哪个模型，并把候选列表写进文件供 worker 在 invalid 时换下一个。
#   relay 继承了模型 → 直接沿用（不重新拉 /models，省一次请求）
#   有 selector      → 语义/精确/别名匹配（见 discover_models）
#   Claude 无 selector → 已验证的别名 opus[1m]
#   GPT 无 selector    → 自动发现最新 GPT 文本模型
select_model() {
  local family="$1" inherited="$2" selector="$3" candidates_file="$4" status=0
  if [ -n "$inherited" ]; then
    printf '%s\n' "$inherited" > "$candidates_file"
    printf '%s\n' "$inherited"
    return 0
  fi
  if [ -z "$selector" ] && [ "$family" = claude ]; then
    printf '%s\n' 'opus[1m]' > "$candidates_file"
    printf '%s\n' 'opus[1m]'
    return 0
  fi
  set +e
  discover_models "$family" "$base_url" "$token" "$selector" > "$candidates_file"
  status=$?
  set -e
  if [ "$status" -ne 0 ] && [ "$family" = claude ]; then
    # Claude 选不到就退回默认别名，而不是让整个池报配置错误。
    printf '[Claude池] 选择器「%s」没有匹配到模型，退回 opus[1m]\n' "$selector" >&2
    printf '%s\n' 'opus[1m]' > "$candidates_file"
    printf '%s\n' 'opus[1m]'
    return 0
  fi
  [ "$status" -eq 0 ] || return "$status"
  sed -n '1p' "$candidates_file"
}

notify_discovery_error() {
  local family="$1" family_cn subject body
  case "$family" in claude) family_cn='Claude池' ;; *) family_cn='GPT池' ;; esac
  if [ -n "${EMAIL_LOG:-}" ]; then
    mkdir -p "$(dirname "$EMAIL_LOG")"
    printf '%s|config_error\n' "$family" >> "$EMAIL_LOG"
    return 0
  fi
  [ "${DRY_RUN:-false}" != true ] || return 0
  subject="Anyrouter ${family_cn} 配置错误"
  body="池：$family_cn
状态：模型发现失败
Actions：${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown}/actions/runs/${GITHUB_RUN_ID:-unknown}"
  send_email_safe "$subject" "$body" || printf '[%s] 模型发现失败的通知邮件发送失败\n' "$family_cn" >&2
}

claude_model_status=0
gpt_model_status=0
set +e
claude_model="$(select_model claude "$claude_model" "$claude_selector" "$claude_candidates")"
claude_model_status=$?
gpt_model="$(select_model gpt "$gpt_model" "$gpt_selector" "$gpt_candidates")"
gpt_model_status=$?
set -e
if [ "$claude_model_status" -ne 0 ]; then
  claude_phase=config_error
  claude_notified=false
  notify_discovery_error claude
fi
if [ "$gpt_model_status" -ne 0 ]; then
  gpt_phase=config_error
  gpt_notified=false
  notify_discovery_error gpt
fi

write_state_file "$claude_state" "$claude_phase" "$claude_model" "$claude_notified" "$chain_id" "$chain_started_epoch"
write_state_file "$gpt_state" "$gpt_phase" "$gpt_model" "$gpt_notified" "$chain_id" "$chain_started_epoch"

pool_worker="${POOL_WORKER_COMMAND:-$SCRIPT_DIR/pool-worker.sh}"
worker_iterations="${MAX_ITERATIONS:-0}"
if [ "$once" = true ] && [ "$worker_iterations" -eq 0 ]; then worker_iterations=1; fi

start_pool() {
  local pool="$1" model="$2" state_file="$3" candidates_file="$4" selector="$5"
  unset GITHUB_TOKEN ANYROUTER_TOKENS
  CHAIN_ID="$chain_id" CHAIN_STARTED_EPOCH="$chain_started_epoch" \
    MAX_DURATION_SEC="$max_duration" MAX_ITERATIONS="$worker_iterations" \
    MODEL_CANDIDATES_FILE="$candidates_file" MODEL_OVERRIDE="$selector" \
    ANYROUTER_TOKEN="$token" bash "$pool_worker" "$pool" "$base_url" "$model" "$state_file"
}

case "$claude_phase" in config_error|done) ;; *) start_pool claude "$claude_model" "$claude_state" "$claude_candidates" "$claude_selector" & claude_pid=$! ;; esac
case "$gpt_phase" in config_error|done) ;; *) start_pool gpt "$gpt_model" "$gpt_state" "$gpt_candidates" "$gpt_selector" & gpt_pid=$! ;; esac

claude_exit=0
gpt_exit=0
if [ -n "$claude_pid" ]; then wait "$claude_pid" || claude_exit=$?; claude_pid=''; fi
if [ -n "$gpt_pid" ]; then wait "$gpt_pid" || gpt_exit=$?; gpt_pid=''; fi
[ "$claude_exit" -eq 0 ] || printf '[Claude池] worker 异常退出，状态码 %s\n' "$claude_exit" >&2
[ "$gpt_exit" -eq 0 ] || printf '[GPT池] worker 异常退出，状态码 %s\n' "$gpt_exit" >&2

[ "$once" = false ] || exit $((claude_exit || gpt_exit))

claude_phase="$(read_state_value "$claude_state" phase 2>/dev/null || printf probing)"
gpt_phase="$(read_state_value "$gpt_state" phase 2>/dev/null || printf probing)"
claude_model="$(read_state_value "$claude_state" model 2>/dev/null || true)"
gpt_model="$(read_state_value "$gpt_state" model 2>/dev/null || true)"
claude_notified="$(read_state_value "$claude_state" notified 2>/dev/null || printf false)"
gpt_notified="$(read_state_value "$gpt_state" notified 2>/dev/null || printf false)"

# 两个池都到了终态（配置错误 / 不保活已完成）→ 链结束，不 relay。
if [[ "$claude_phase" =~ ^(config_error|done)$ ]] && [[ "$gpt_phase" =~ ^(config_error|done)$ ]]; then
  printf '两个池均已结束（Claude=%s，GPT=%s），链路终止，不再 relay。\n' "$claude_phase" "$gpt_phase"
  exit 0
fi

if ! dispatch_relay "$claude_phase" "$gpt_phase" "$claude_model" "$gpt_model" \
  "$claude_notified" "$gpt_notified" "$chain_id" "$chain_started_epoch"; then
  send_email_safe 'Anyrouter relay 失败' \
    "下一棒保活没能调度成功。Actions：${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown}/actions/runs/${GITHUB_RUN_ID:-unknown}" || true
  printf '%s\n' 'relay 调度失败；relay body 里没有任何凭据。' >&2
  exit 1
fi
printf '已为链 %s 调度下一棒 relay。\n' "$chain_id"
