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
  printf '%s\n' 'Relay requires a valid inherited CHAIN_STARTED_EPOCH.' >&2
  exit 2
fi
if [ "$mode" = start ] && ! [[ "$chain_started_epoch" =~ ^[1-9][0-9]*$ ]]; then
  chain_started_epoch="$(date +%s)"
fi
chain_id="${CHAIN_ID:-}"
[ -n "$chain_id" ] || chain_id="${GITHUB_RUN_ID:-local}-$RANDOM"

check_stop_marker() {
  local marker_file status stopped
  [ "${SKIP_STOP_CHECK:-false}" != true ] || return 0
  marker_file="$(mktemp)"
  status=0
  if [ -n "${STOP_MARKER_FILE:-}" ]; then
    download_latest_stop_marker "$marker_file" || status=$?
  elif [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    download_latest_stop_marker "$marker_file" || status=$?
  else
    rm -f "$marker_file"
    return 0
  fi
  if [ "$status" -eq 1 ]; then
    rm -f "$marker_file"
    return 0
  fi
  if [ "$status" -ne 0 ]; then
    rm -f "$marker_file"
    printf '%s\n' 'Unable to verify the latest stop marker' >&2
    return 1
  fi
  stopped="$(chain_is_stopped "$marker_file" "$chain_started_epoch")" || {
    rm -f "$marker_file"
    printf '%s\n' 'Stop marker is invalid' >&2
    return 1
  }
  rm -f "$marker_file"
  if [ "$stopped" = true ]; then
    printf 'Chain %s was stopped before this run began; no model request will be sent.\n' "$chain_id"
    return 3
  fi
}

stop_status=0
check_stop_marker || stop_status=$?
if [ "$check_only" = true ]; then
  should_run=true
  [ "$stop_status" -eq 3 ] && should_run=false
  [ "$stop_status" -eq 0 ] || [ "$stop_status" -eq 3 ] || exit "$stop_status"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'should_run=%s\nchain_started_epoch=%s\nchain_id=%s\n' \
      "$should_run" "$chain_started_epoch" "$chain_id" >> "$GITHUB_OUTPUT"
  else
    printf 'should_run=%s\nchain_started_epoch=%s\nchain_id=%s\n' \
      "$should_run" "$chain_started_epoch" "$chain_id"
  fi
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

collect_process_tree() {
  local pid="${1:-}" child children=''
  [ -n "$pid" ] || return 0
  if [ -r "/proc/$pid/task/$pid/children" ]; then
    children="$(cat "/proc/$pid/task/$pid/children" 2>/dev/null || true)"
  else
    children="$(ps -ef 2>/dev/null | awk -v parent="$pid" '$3 == parent { print $2 }')"
  fi
  for child in $children; do collect_process_tree "$child"; done
  printf '%s\n' "$pid"
}

cleanup() {
  local pid i any_alive tree_pids=''
  tree_pids="$(collect_process_tree "$claude_pid"; collect_process_tree "$gpt_pid")"
  for pid in $tree_pids; do kill -TERM "$pid" 2>/dev/null || true; done
  for i in 1 2 3 4 5 6 7 8 9 10; do
    any_alive=false
    for pid in $tree_pids; do
      if kill -0 "$pid" 2>/dev/null; then any_alive=true; break; fi
    done
    [ "$any_alive" = true ] || break
    sleep 0.1
  done
  for pid in $tree_pids; do kill -KILL "$pid" 2>/dev/null || true; done
  [ -z "$claude_pid" ] || wait "$claude_pid" 2>/dev/null || true
  [ -z "$gpt_pid" ] || wait "$gpt_pid" 2>/dev/null || true
  rm -rf "$state_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

state_input() {
  local value="$1" default="$2"
  case "$value" in probing|keepalive|config_error) printf '%s\n' "$value" ;; *) printf '%s\n' "$default" ;; esac
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
claude_inherited="$claude_model"
gpt_inherited="$gpt_model"
claude_override="${ANYROUTER_CLAUDE_MODEL:-}"
gpt_override="${ANYROUTER_GPT_MODEL:-}"
claude_candidates="$state_dir/claude.models"
gpt_candidates="$state_dir/gpt.models"

select_model() {
  local family="$1" inherited="$2" override="$3" candidates_file="$4" status=0
  if [ -n "$override" ]; then
    printf '%s\n' "$override" > "$candidates_file"
    printf '%s\n' "$override"
  elif [ -n "$inherited" ]; then
    printf '%s\n' "$inherited" > "$candidates_file"
    printf '%s\n' "$inherited"
  else
    set +e
    discover_models "$family" "$base_url" "$token" "$override" > "$candidates_file"
    status=$?
    set -e
    [ "$status" -eq 0 ] || return "$status"
    sed -n '1p' "$candidates_file"
  fi
}

notify_discovery_error() {
  local family="$1" subject body
  if [ -n "${EMAIL_LOG:-}" ]; then
    mkdir -p "$(dirname "$EMAIL_LOG")"
    printf '%s|config_error\n' "$family" >> "$EMAIL_LOG"
    return 0
  fi
  [ "${DRY_RUN:-false}" != true ] || return 0
  subject="Anyrouter ${family} pool configuration error"
  body="Pool: $family
Status: model discovery failed
Action: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown}/actions/runs/${GITHUB_RUN_ID:-unknown}"
  send_email_safe "$subject" "$body" || printf '%s model discovery notification failed\n' "$family" >&2
}

claude_model_status=0
gpt_model_status=0
set +e
claude_model="$(select_model claude "$claude_model" "$claude_override" "$claude_candidates")"
claude_model_status=$?
gpt_model="$(select_model gpt "$gpt_model" "$gpt_override" "$gpt_candidates")"
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
  local pool="$1" model="$2" state_file="$3" candidates_file="$4" override="$5" rediscovery=false
  [ -z "$override" ] && rediscovery=true
  unset GITHUB_TOKEN ANYROUTER_TOKENS
  CHAIN_ID="$chain_id" CHAIN_STARTED_EPOCH="$chain_started_epoch" \
    MAX_DURATION_SEC="$max_duration" MAX_ITERATIONS="$worker_iterations" \
    MODEL_CANDIDATES_FILE="$candidates_file" MODEL_OVERRIDE="$override" \
    ALLOW_MODEL_REDISCOVERY="$rediscovery" \
    ANYROUTER_TOKEN="$token" bash "$pool_worker" "$pool" "$base_url" "$model" "$state_file"
}

if [ "$claude_phase" != config_error ]; then
  start_pool claude "$claude_model" "$claude_state" "$claude_candidates" "$claude_override" &
  claude_pid=$!
fi
if [ "$gpt_phase" != config_error ]; then
  start_pool gpt "$gpt_model" "$gpt_state" "$gpt_candidates" "$gpt_override" &
  gpt_pid=$!
fi

claude_exit=0
gpt_exit=0
if [ -n "$claude_pid" ]; then wait "$claude_pid" || claude_exit=$?; claude_pid=''; fi
if [ -n "$gpt_pid" ]; then wait "$gpt_pid" || gpt_exit=$?; gpt_pid=''; fi
[ "$claude_exit" -eq 0 ] || printf 'Claude pool worker exited with status %s\n' "$claude_exit" >&2
[ "$gpt_exit" -eq 0 ] || printf 'GPT pool worker exited with status %s\n' "$gpt_exit" >&2

[ "$once" = false ] || exit $((claude_exit || gpt_exit))

claude_phase="$(read_state_value "$claude_state" phase 2>/dev/null || printf probing)"
gpt_phase="$(read_state_value "$gpt_state" phase 2>/dev/null || printf probing)"
claude_model="$(read_state_value "$claude_state" model 2>/dev/null || true)"
gpt_model="$(read_state_value "$gpt_state" model 2>/dev/null || true)"
claude_notified="$(read_state_value "$claude_state" notified 2>/dev/null || printf false)"
gpt_notified="$(read_state_value "$gpt_state" notified 2>/dev/null || printf false)"

if [ "$claude_phase" = config_error ] && [ "$gpt_phase" = config_error ]; then
  printf '%s\n' 'Both pools have configuration errors; relay was not scheduled.' >&2
  exit 0
fi

if ! dispatch_relay "$claude_phase" "$gpt_phase" "$claude_model" "$gpt_model" \
  "$claude_notified" "$gpt_notified" "$chain_id" "$chain_started_epoch"; then
  send_email_safe 'Anyrouter relay failed' \
    "The next keepalive run could not be scheduled. Action: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown}/actions/runs/${GITHUB_RUN_ID:-unknown}" || true
  printf '%s\n' 'Relay dispatch failed; no credentials were placed in the relay body.' >&2
  exit 1
fi
printf 'Relay scheduled for chain %s.\n' "$chain_id"
