#!/usr/bin/env bash
set -euo pipefail

ACTIONS_API_URL="${GITHUB_API_URL:-https://api.github.com}"
ACTIONS_WORKFLOW_ID="${ACTIONS_WORKFLOW_ID:-keepalive.yml}"

python_command() {
  local candidate
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  printf '%s\n' 'Python is required for GitHub API JSON handling' >&2
  return 1
}

require_github_api() {
  [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] || {
    printf '%s\n' 'GitHub API environment is unavailable' >&2
    return 1
  }
}

stop_actions_process_tree() {
  local pid="${1:-}" child children='' i exited=false
  [ -n "$pid" ] || return 0
  if [ -r "/proc/$pid/task/$pid/children" ]; then
    children="$(cat "/proc/$pid/task/$pid/children" 2>/dev/null || true)"
  else
    children="$(ps -ef 2>/dev/null | awk -v parent="$pid" '$3 == parent { print $2 }')"
  fi
  for child in $children; do stop_actions_process_tree "$child"; done
  kill -TERM "$pid" 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ! kill -0 "$pid" 2>/dev/null; then exited=true; break; fi
    sleep 0.1
  done
  [ "$exited" = true ] || kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

github_curl() (
  local curl_config='' status=0 curl_pid=''
  local connect_timeout="${GITHUB_CONNECT_TIMEOUT_SEC:-15}" max_time="${GITHUB_MAX_TIME_SEC:-60}" guard_timeout
  cleanup_github_curl() { [ -n "$curl_config" ] && rm -f "$curl_config"; }
  stop_github_curl() {
    [ -n "$curl_pid" ] || return 0
    stop_actions_process_tree "$curl_pid"
    curl_pid=''
  }
  on_github_curl_signal() {
    trap - TERM INT
    stop_github_curl
    cleanup_github_curl
    exit 143
  }
  trap cleanup_github_curl EXIT
  trap on_github_curl_signal TERM INT
  require_github_api
  [[ "$connect_timeout" =~ ^[1-9][0-9]*$ && "$max_time" =~ ^[1-9][0-9]*$ ]] || {
    printf '%s\n' 'Invalid GitHub API timeout setting' >&2
    return 2
  }
  guard_timeout=$((max_time + 2))
  umask 077
  curl_config="$(mktemp)"
  if [ -n "${TEST_TEMP_PATH_LOG:-}" ]; then printf '%s\n' "$curl_config" >> "$TEST_TEMP_PATH_LOG"; fi
  printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/vnd.github+json"\nheader = "X-GitHub-Api-Version: 2022-11-28"\n' \
    "$GITHUB_TOKEN" > "$curl_config"
  env -u ANYROUTER_TOKEN -u ANYROUTER_TOKENS -u QQ_EMAIL -u QQ_SMTP_AUTH_CODE \
    timeout --kill-after=1 "$guard_timeout" \
    curl --silent --show-error --fail --location \
    --connect-timeout "$connect_timeout" --max-time "$max_time" \
    --config "$curl_config" "$@" &
  curl_pid=$!
  wait "$curl_pid" || status=$?
  curl_pid=''
  return "$status"
)

tracked_github_curl() {
  local status=0
  github_curl "$@" &
  github_request_pid=$!
  wait "$github_request_pid" || status=$?
  github_request_pid=''
  return "$status"
}

chain_is_stopped() {
  local marker_file="$1" chain_started_epoch="$2" py
  [[ "$chain_started_epoch" =~ ^[0-9]+$ ]] || return 2
  if [ ! -f "$marker_file" ]; then
    printf '%s\n' false
    return 0
  fi
  py="$(python_command)"
  "$py" - "$marker_file" "$chain_started_epoch" <<'PY'
import json, sys

try:
    marker = json.load(open(sys.argv[1], encoding="utf-8"))
    cutoff = int(marker["stop_before_epoch"])
    workflow_id = marker["workflow_id"]
    started = int(sys.argv[2])
except (KeyError, TypeError, ValueError, OSError, json.JSONDecodeError):
    raise SystemExit(2)

if workflow_id != "keepalive.yml":
    raise SystemExit(2)
print("true" if started <= cutoff else "false")
PY
}

download_latest_stop_marker() (
  local destination="$1" metadata_file='' artifact_zip='' artifact_id py status=0 github_request_pid=''
  cleanup_download_marker() {
    stop_actions_process_tree "$github_request_pid"
    [ -z "$metadata_file" ] || rm -f "$metadata_file"
    [ -z "$artifact_zip" ] || rm -f "$artifact_zip"
  }
  if [ -n "${TEST_ACTIONS_FUNCTION_PID_FILE:-}" ]; then printf '%s\n' "$BASHPID" > "$TEST_ACTIONS_FUNCTION_PID_FILE"; fi
  trap cleanup_download_marker EXIT
  trap 'trap - TERM INT; cleanup_download_marker; exit 143' TERM INT
  if [ -n "${STOP_MARKER_FILE:-}" ]; then
    [ -f "$STOP_MARKER_FILE" ] || return 1
    cp "$STOP_MARKER_FILE" "$destination"
    return 0
  fi
  require_github_api || return 2
  umask 077
  metadata_file="$(mktemp)"
  artifact_zip="$(mktemp)"
  if ! tracked_github_curl \
    "$ACTIONS_API_URL/repos/$GITHUB_REPOSITORY/actions/artifacts?name=anyrouter-stop-marker&per_page=100" \
    -o "$metadata_file"; then
    return 2
  fi
  py="$(python_command)"
  artifact_id="$($py - "$metadata_file" <<'PY'
import json, sys

try:
    payload = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    raise SystemExit(2)

items = [
    item for item in payload.get("artifacts", [])
    if item.get("name") == "anyrouter-stop-marker" and not item.get("expired", False)
]
if items:
    print(max(items, key=lambda item: (item.get("created_at", ""), int(item.get("id", 0))))["id"])
PY
)" || status=$?
  if [ "$status" -ne 0 ]; then
    return 2
  fi
  if [ -z "$artifact_id" ]; then
    return 1
  fi
  if ! tracked_github_curl \
    "$ACTIONS_API_URL/repos/$GITHUB_REPOSITORY/actions/artifacts/$artifact_id/zip" \
    -o "$artifact_zip"; then
    return 2
  fi
  mkdir -p "$(dirname "$destination")"
  if ! unzip -p "$artifact_zip" stop.json > "$destination"; then
    return 2
  fi
)

active_run_ids() (
  local page=1 response_file='' py count status=0 github_request_pid=''
  cleanup_active_run_ids() {
    stop_actions_process_tree "$github_request_pid"
    [ -z "$response_file" ] || rm -f "$response_file"
  }
  if [ -n "${TEST_ACTIONS_FUNCTION_PID_FILE:-}" ]; then printf '%s\n' "$BASHPID" > "$TEST_ACTIONS_FUNCTION_PID_FILE"; fi
  trap cleanup_active_run_ids EXIT
  trap 'trap - TERM INT; cleanup_active_run_ids; exit 143' TERM INT
  require_github_api
  umask 077
  response_file="$(mktemp)"
  py="$(python_command)"
  while :; do
    if ! tracked_github_curl \
      "$ACTIONS_API_URL/repos/$GITHUB_REPOSITORY/actions/workflows/$ACTIONS_WORKFLOW_ID/runs?per_page=100&page=$page" \
      -o "$response_file"; then
      status=1
      break
    fi
    if ! "$py" - "$response_file" "${GITHUB_RUN_ID:-}" <<'PY'
import json, sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
current = str(sys.argv[2])
active = {"queued", "pending", "waiting", "in_progress"}
for run in payload.get("workflow_runs", []):
    if str(run.get("id")) != current and run.get("status") in active:
        print(run["id"])
PY
    then
      status=1
      break
    fi
    count="$($py - "$response_file" <<'PY'
import json, sys
print(len(json.load(open(sys.argv[1], encoding="utf-8")).get("workflow_runs", [])))
PY
)" || { status=1; break; }
    [ "$count" -eq 100 ] || break
    page=$((page + 1))
  done
  return "$status"
)

cancel_active_workflow_runs() (
  local run_id list_file='' status=0 cancel_failed=false action_child_pid='' github_request_pid=''
  cleanup_cancel_runs() {
    stop_actions_process_tree "$action_child_pid"
    stop_actions_process_tree "$github_request_pid"
    [ -z "$list_file" ] || rm -f "$list_file"
  }
  if [ -n "${TEST_ACTIONS_CANCEL_PID_FILE:-}" ]; then printf '%s\n' "$BASHPID" > "$TEST_ACTIONS_CANCEL_PID_FILE"; fi
  trap cleanup_cancel_runs EXIT
  trap 'trap - TERM INT; cleanup_cancel_runs; exit 143' TERM INT
  umask 077
  list_file="$(mktemp)"
  active_run_ids > "$list_file" &
  action_child_pid=$!
  wait "$action_child_pid" || status=$?
  action_child_pid=''
  if [ "$status" -ne 0 ]; then
    printf '%s\n' 'GitHub Actions cancel scan failed while listing runs.' >&2
    return 1
  fi
  while IFS= read -r run_id; do
    run_id="${run_id//$'\r'/}"
    [ -n "$run_id" ] || continue
    if ! tracked_github_curl -X POST \
      "$ACTIONS_API_URL/repos/$GITHUB_REPOSITORY/actions/runs/$run_id/cancel" \
      >/dev/null 2>&1; then
      cancel_failed=true
    fi
  done < "$list_file"
  if [ "$cancel_failed" = true ]; then
    printf '%s\n' 'GitHub Actions cancel scan failed while cancelling one or more runs.' >&2
    return 1
  fi
)

dispatch_relay() {
  local claude_phase="$1" gpt_phase="$2" claude_model="$3" gpt_model="$4"
  local claude_notified="$5" gpt_notified="$6" chain_id="$7" chain_started_epoch="$8"
  local py payload
  case "$claude_phase:$gpt_phase" in
    probing:probing|probing:keepalive|probing:config_error|keepalive:probing|keepalive:keepalive|keepalive:config_error|config_error:probing|config_error:keepalive|config_error:config_error) ;;
    *) return 2 ;;
  esac
  case "$claude_notified:$gpt_notified" in
    true:true|true:false|false:true|false:false) ;;
    *) return 2 ;;
  esac
  [[ "$chain_started_epoch" =~ ^[0-9]+$ ]] || return 2
  [[ "$claude_model$gpt_model$chain_id" != *$'\n'* ]] || return 2
  require_github_api
  py="$(python_command)"
  payload="$($py - "$GITHUB_REF_NAME" "$claude_phase" "$gpt_phase" "$claude_model" "$gpt_model" \
    "$claude_notified" "$gpt_notified" "$chain_id" "$chain_started_epoch" <<'PY'
import json, sys

values = sys.argv[1:]
payload = {
    "ref": values[0],
    "inputs": {
        "mode": "relay",
        "claude_phase": values[1],
        "gpt_phase": values[2],
        "claude_model": values[3],
        "gpt_model": values[4],
        "claude_notified": values[5],
        "gpt_notified": values[6],
        "chain_id": values[7],
        "chain_started_epoch": values[8],
    },
}
print(json.dumps(payload, separators=(",", ":")))
PY
)"
  github_curl -X POST \
    -H 'Content-Type: application/json' \
    "$ACTIONS_API_URL/repos/$GITHUB_REPOSITORY/actions/workflows/$ACTIONS_WORKFLOW_ID/dispatches" \
    --data-binary "$payload" >/dev/null
}
