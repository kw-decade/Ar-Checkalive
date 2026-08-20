#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 4 ]; then
  printf 'Usage: %s POOL BASE_URL MODEL STATE_FILE (token via ANYROUTER_TOKEN)\n' "$0" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/model-discovery.sh
source "$SCRIPT_DIR/lib/model-discovery.sh"

pool="$1"
if [ "$#" -ge 5 ]; then
  token="$2"
  base_url_arg="$3"
  model="$4"
  state_file="$5"
elif [ -n "${ANYROUTER_TOKEN:-}" ]; then
  token="$ANYROUTER_TOKEN"
  base_url_arg="$2"
  model="$3"
  state_file="$4"
else
  printf 'ANYROUTER_TOKEN is required\n' >&2
  exit 2
fi
base_url="$(normalize_base_url "$base_url_arg")"
case "$pool" in claude|gpt) ;; *) printf 'Unknown pool\n' >&2; exit 2 ;; esac

PROBE_MIN_SEC="${PROBE_MIN_SEC:-3}"
PROBE_MAX_SEC="${PROBE_MAX_SEC:-10}"
KEEPALIVE_MIN_SEC="${KEEPALIVE_MIN_SEC:-30}"
KEEPALIVE_MAX_SEC="${KEEPALIVE_MAX_SEC:-120}"
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

state_or_default() {
  local key="$1" default="$2" value
  value="$(read_state_value "$state_file" "$key" 2>/dev/null || true)"
  printf '%s\n' "${value:-$default}"
}

phase="$(state_or_default phase probing)"
notified="$(state_or_default notified false)"
[ -n "$CHAIN_ID" ] || CHAIN_ID="$(state_or_default chain_id '')"
[ "$CHAIN_STARTED_EPOCH" != 0 ] || CHAIN_STARTED_EPOCH="$(state_or_default chain_started_epoch 0)"
case "$phase" in probing|keepalive|config_error|stopped) ;; *) phase=probing ;; esac
case "$notified" in true|false) ;; *) notified=false ;; esac

persist_state() {
  write_state_file "$state_file" "$phase" "$model" "$notified" "$CHAIN_ID" "$CHAIN_STARTED_EPOCH"
}

model_candidates=()
model_candidate_index=0
model_candidates_loaded=false
model_candidates_rediscovered=false

discover_candidate_list() {
  local candidate_output status=0
  if [ -n "$MODEL_DISCOVERY_COMMAND" ]; then
    set +e
    candidate_output="$(env -u GITHUB_TOKEN -u QQ_EMAIL -u QQ_SMTP_AUTH_CODE -u ANYROUTER_TOKENS \
      ANYROUTER_TOKEN="$token" "$MODEL_DISCOVERY_COMMAND" "$pool" "$base_url" "$MODEL_OVERRIDE" 2>/dev/null)"
    status=$?
    set -e
    [ "$status" -eq 0 ] || return 1
  else
    set +e
    candidate_output="$(discover_models "$pool" "$base_url" "$token" "$MODEL_OVERRIDE" 2>/dev/null)"
    status=$?
    set -e
    [ "$status" -eq 0 ] || return 1
  fi
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
  [ -z "$MODEL_OVERRIDE" ] || return 1
  load_model_candidates || return 1
  next_model_candidate && return 0
  rediscover_model_candidates || return 1
  next_model_candidate
}

adapter_pid=''
sleep_pid=''
adapter_result_file="$(mktemp)"
adapter_pgid=''

cleanup_worker() {
  rm -f "$adapter_result_file"
}

stop_tracked_process() {
  local pid="$1" i exited=false
  [ -n "$pid" ] || return 0
  kill "$pid" 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ! kill -0 "$pid" 2>/dev/null; then exited=true; break; fi
    sleep 0.1
  done
  [ "$exited" = true ] || kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

stop_adapter_tree() {
  local pid="$1" child children='' i exited=false
  [ -n "$pid" ] || return 0
  if [ -r "/proc/$pid/task/$pid/children" ]; then
    children="$(cat "/proc/$pid/task/$pid/children" 2>/dev/null || true)"
    for child in $children; do
      [ -n "$child" ] || continue
      stop_adapter_tree "$child"
    done
  else
    children="$(ps -ef 2>/dev/null | awk -v parent="$pid" '$3 == parent { print $2 }')"
    for child in $children; do
      stop_adapter_tree "$child"
    done
  fi
  kill -TERM "$pid" 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ! kill -0 "$pid" 2>/dev/null; then exited=true; break; fi
    sleep 0.1
  done
  [ "$exited" = true ] || kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

stop_worker() {
  trap - INT TERM
  stop_adapter_tree "$adapter_pid"
  stop_tracked_process "$sleep_pid"
  adapter_pid=''
  sleep_pid=''
  phase=stopped
  persist_state
  exit 0
}
trap stop_worker INT TERM
trap cleanup_worker EXIT

persist_state
case "$phase" in config_error|stopped) exit 0 ;; esac

pick_prompt() {
  printf '%s\n' "${prompts[RANDOM % ${#prompts[@]}]}"
}

result_value() {
  local result="$1" key="$2"
  awk -F= -v wanted="$key" '$1 == wanted { sub(/^[^=]*=/, ""); print; exit }' <<< "$result"
}

safe_log_value() {
  printf '%s' "$1" | tr '\r\n' '  ' | tr -cd '[:alnum:]_.:/+-' | cut -c1-96
}

log_result() {
  local log_phase="$1" log_status="$2" log_http="$3" log_elapsed="$4" log_message="$5"
  [[ "$log_http" =~ ^[0-9]{3}$ ]] || log_http=000
  [[ "$log_elapsed" =~ ^[0-9]+$ ]] || log_elapsed=0
  case "$log_message" in
    non_empty_response|empty_response|capacity_limited|authentication_error|model_or_protocol_error|request_configuration_error|request_timeout|cli_or_upstream_error|transport_error|upstream_error|unexpected_http_status|test_result) ;;
    *) log_message=unspecified ;;
  esac
  printf '[%s] phase=%s model=%s status=%s http_code=%s elapsed_sec=%s message=%s\n' \
    "$pool" "$log_phase" "$(safe_log_value "$model")" "$log_status" "$log_http" "$log_elapsed" "$log_message"
}

actions_url() {
  if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
    printf '%s/%s/actions/runs/%s\n' "$GITHUB_SERVER_URL" "$GITHUB_REPOSITORY" "$GITHUB_RUN_ID"
  else
    printf '%s\n' 'Actions run URL unavailable'
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
      subject="Anyrouter ${pool} pool is available"
      body="Pool: $pool
Model: $model
Status: available
Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Action: $(actions_url)
Use the workflow stop mode when you want to end keepalive."
      ;;
    config_error)
      subject="Anyrouter ${pool} pool configuration error"
      body="Pool: $pool
Model: $model
Status: configuration error
Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Action: $(actions_url)"
      ;;
    *) return 2 ;;
  esac
  if ! send_email_safe "$subject" "$body"; then
    printf '%s notification email failed\n' "$pool" >&2
  fi
}

sleep_for_phase() {
  local delay sleep_status=0
  if [ "$phase" = keepalive ]; then
    delay="$(random_between "$KEEPALIVE_MIN_SEC" "$KEEPALIVE_MAX_SEC")"
  else
    delay="$(random_between "$PROBE_MIN_SEC" "$PROBE_MAX_SEC")"
  fi
  printf '[%s] phase=%s next_delay_sec=%s\n' "$pool" "$phase" "$delay"
  "$SLEEP_COMMAND" "$delay" &
  sleep_pid=$!
  wait "$sleep_pid" || sleep_status=$?
  sleep_pid=''
  [ "$sleep_status" -eq 0 ]
}

start_epoch="$(date +%s)"
iterations=0
while :; do
  now_epoch="$(date +%s)"
  [ $((now_epoch - start_epoch)) -lt "$MAX_DURATION_SEC" ] || break
  if [ "$MAX_ITERATIONS" -gt 0 ] && [ "$iterations" -ge "$MAX_ITERATIONS" ]; then break; fi

  prompt="$(pick_prompt)"
  adapter_exit=0
  : > "$adapter_result_file"
  env -u GITHUB_TOKEN -u QQ_EMAIL -u QQ_SMTP_AUTH_CODE -u ANYROUTER_TOKENS \
    ANYROUTER_TOKEN="$token" "$ADAPTER_COMMAND" "$base_url" "$model" "$prompt" >"$adapter_result_file" 2>&1 &
  adapter_pid=$!
  wait "$adapter_pid" || adapter_exit=$?
  adapter_pid=''
  result="$(cat "$adapter_result_file")"
  if [ "$adapter_exit" -ne 0 ]; then
    status=retryable
    message=cli_or_upstream_error
    http_code=000
    elapsed_sec=0
  else
    status="$(result_value "$result" status)"
    message="$(result_value "$result" message)"
    http_code="$(result_value "$result" http_code)"
    elapsed_sec="$(result_value "$result" elapsed_sec)"
    case "$status" in success|rate_limited|invalid|retryable) ;; *) status=retryable ;; esac
  fi

  case "$status" in
    success)
      phase=keepalive
      if [ "$notified" != true ]; then
        notified=true
        persist_state
        notify_event success
      else
        persist_state
      fi
      log_result "$phase" "$status" "$http_code" "$elapsed_sec" "$message"
      ;;
    rate_limited)
      phase=probing
      notified=false
      persist_state
      log_result "$phase" "$status" "$http_code" "$elapsed_sec" "$message"
      ;;
    retryable)
      persist_state
      log_result "$phase" "$status" "$http_code" "$elapsed_sec" "$message"
      ;;
    invalid)
      log_result "$phase" "$status" "$http_code" "$elapsed_sec" "$message"
      if [ "$message" = model_or_protocol_error ] && advance_model_after_invalid; then
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
