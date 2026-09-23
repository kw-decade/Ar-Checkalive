#!/usr/bin/env bash
set -euo pipefail

ACTIONS_API_URL="${GITHUB_API_URL:-https://api.github.com}"
ACTIONS_WORKFLOW_ID="${ACTIONS_WORKFLOW_ID:-keepalive.yml}"

ACTIONS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F kill_tree >/dev/null 2>&1; then
  # shellcheck source=common.sh
  source "$ACTIONS_LIB_DIR/common.sh"
fi

require_github_api() {
  [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] || {
    printf '%s\n' 'GitHub API environment is unavailable' >&2
    return 1
  }
}

# github_curl ARGS... —— token 写进 --config 文件，不进 argv。
github_curl() (
  local curl_config='' status=0 curl_pid=''
  local connect_timeout="${GITHUB_CONNECT_TIMEOUT_SEC:-15}" max_time="${GITHUB_MAX_TIME_SEC:-60}"
  trap '[ -z "$curl_config" ] || rm -f "$curl_config"' EXIT
  trap 'trap - TERM INT; kill_tree "$curl_pid"; [ -z "$curl_config" ] || rm -f "$curl_config"; exit 143' TERM INT
  require_github_api
  [[ "$connect_timeout" =~ ^[1-9][0-9]*$ && "$max_time" =~ ^[1-9][0-9]*$ ]] || {
    printf '%s\n' 'GitHub API 超时设置无效' >&2
    return 2
  }
  umask 077
  curl_config="$(mktemp)"
  if [ -n "${TEST_TEMP_PATH_LOG:-}" ]; then printf '%s\n' "$curl_config" >> "$TEST_TEMP_PATH_LOG"; fi
  printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/vnd.github+json"\nheader = "X-GitHub-Api-Version: 2022-11-28"\n' \
    "$GITHUB_TOKEN" > "$curl_config"
  env -u ANYROUTER_TOKEN -u ANYROUTER_TOKENS -u QQ_EMAIL -u QQ_SMTP_AUTH_CODE \
    timeout --kill-after=1 "$((max_time + 2))" \
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
  local marker_file="$1" chain_started_epoch="$2"
  [[ "$chain_started_epoch" =~ ^[0-9]+$ ]] || return 2
  if [ ! -f "$marker_file" ]; then
    printf '%s\n' false
    return 0
  fi
  "$(py)" - "$marker_file" "$chain_started_epoch" <<'PY'
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

# 返回码：0 已下载，1 没有 marker，2 请求/解析失败
download_latest_stop_marker() (
  local destination="$1" metadata_file='' artifact_zip='' artifact_id status=0 github_request_pid=''
  cleanup_download_marker() {
    kill_tree "$github_request_pid"
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
  artifact_id="$("$(py)" - "$metadata_file" <<'PY'
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
  [ "$status" -eq 0 ] || return 2
  [ -n "$artifact_id" ] || return 1
  if ! tracked_github_curl \
    "$ACTIONS_API_URL/repos/$GITHUB_REPOSITORY/actions/artifacts/$artifact_id/zip" \
    -o "$artifact_zip"; then
    return 2
  fi
  mkdir -p "$(dirname "$destination")"
  unzip -p "$artifact_zip" stop.json > "$destination" || return 2
)

active_run_ids() (
  local page=1 response_file='' python_bin count status=0 github_request_pid=''
  cleanup_active_run_ids() {
    kill_tree "$github_request_pid"
    [ -z "$response_file" ] || rm -f "$response_file"
  }
  if [ -n "${TEST_ACTIONS_FUNCTION_PID_FILE:-}" ]; then printf '%s\n' "$BASHPID" > "$TEST_ACTIONS_FUNCTION_PID_FILE"; fi
  trap cleanup_active_run_ids EXIT
  trap 'trap - TERM INT; cleanup_active_run_ids; exit 143' TERM INT
  require_github_api
  umask 077
  response_file="$(mktemp)"
  python_bin="$(py)"
  while :; do
    if ! tracked_github_curl \
      "$ACTIONS_API_URL/repos/$GITHUB_REPOSITORY/actions/workflows/$ACTIONS_WORKFLOW_ID/runs?per_page=100&page=$page" \
      -o "$response_file"; then
      status=1
      break
    fi
    "$python_bin" - "$response_file" "${GITHUB_RUN_ID:-}" <<'PY' || { status=1; break; }
import json, sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
current = str(sys.argv[2])
active = {"queued", "pending", "waiting", "in_progress"}
for run in payload.get("workflow_runs", []):
    if str(run.get("id")) != current and run.get("status") in active:
        print(run["id"])
PY
    count="$("$python_bin" -c 'import json,sys; print(len(json.load(open(sys.argv[1], encoding="utf-8")).get("workflow_runs", [])))' "$response_file")" || { status=1; break; }
    [ "$count" -eq 100 ] || break
    page=$((page + 1))
  done
  return "$status"
)

cancel_active_workflow_runs() (
  local run_id list_file='' status=0 cancel_failed=false action_child_pid='' github_request_pid=''
  cleanup_cancel_runs() {
    kill_tree "$action_child_pid"
    kill_tree "$github_request_pid"
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
    printf '%s\n' '取消扫描失败：列出 run 时出错。' >&2
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
    printf '%s\n' '取消扫描失败：至少一个 run 取消失败。' >&2
    return 1
  fi
)

dispatch_relay() {
  local claude_phase="$1" gpt_phase="$2" claude_model="$3" gpt_model="$4"
  local claude_notified="$5" gpt_notified="$6" chain_id="$7" chain_started_epoch="$8"
  local value payload
  for value in "$claude_phase" "$gpt_phase"; do
    case "$value" in probing|keepalive|config_error|done) ;; *) return 2 ;; esac
  done
  for value in "$claude_notified" "$gpt_notified"; do
    case "$value" in true|false) ;; *) return 2 ;; esac
  done
  [[ "$chain_started_epoch" =~ ^[0-9]+$ ]] || return 2
  [[ "$claude_model$gpt_model$chain_id" != *$'\n'* ]] || return 2
  require_github_api
  payload="$("$(py)" - "$GITHUB_REF_NAME" "$claude_phase" "$gpt_phase" "$claude_model" "$gpt_model" \
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
