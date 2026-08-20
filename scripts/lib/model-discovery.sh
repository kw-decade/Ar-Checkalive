#!/usr/bin/env bash
set -euo pipefail

MODEL_DISCOVERY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F normalize_base_url >/dev/null 2>&1; then
  # shellcheck source=common.sh
  source "$MODEL_DISCOVERY_DIR/common.sh"
fi

model_python() {
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys' >/dev/null 2>&1; then
    command -v python3
  elif command -v python >/dev/null 2>&1 && python -c 'import sys' >/dev/null 2>&1; then
    command -v python
  else
    printf '%s\n' 'Python is required for model discovery' >&2
    return 1
  fi
}

discover_models() (
  local family="${1:-}" base_url="${2:-}" token="${3:-}" override="${4:-}"
  local json python_command curl_config='' response_file='' curl_pid='' status=0
  cleanup_discovery() { rm -f "$curl_config" "$response_file"; }
  stop_discovery_curl() {
    local i
    [ -n "$curl_pid" ] || return 0
    kill -TERM -- "-$curl_pid" 2>/dev/null || kill -TERM "$curl_pid" 2>/dev/null || true
    for i in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$curl_pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL -- "-$curl_pid" 2>/dev/null || kill -KILL "$curl_pid" 2>/dev/null || true
    wait "$curl_pid" 2>/dev/null || true
    curl_pid=''
  }
  on_discovery_signal() {
    trap - TERM INT
    stop_discovery_curl
    cleanup_discovery
    exit 143
  }
  trap cleanup_discovery EXIT
  trap on_discovery_signal TERM INT
  case "$family" in claude|gpt) ;; *) return 2 ;; esac
  if [ -n "$override" ]; then
    printf '%s\n' "$override"
    return 0
  fi
  umask 077
  curl_config="$(mktemp)"
  response_file="$(mktemp)"
  if [ -n "${TEST_TEMP_PATH_LOG:-}" ]; then printf '%s\n' "$curl_config" "$response_file" >> "$TEST_TEMP_PATH_LOG"; fi
  printf 'header = "Authorization: Bearer %s"\n' "$token" > "$curl_config"
  set +e
  if [ "${DISABLE_SETSID:-false}" != true ] && command -v setsid >/dev/null 2>&1; then
    setsid env -u GITHUB_TOKEN -u QQ_EMAIL -u QQ_SMTP_AUTH_CODE \
      -u ANYROUTER_TOKEN -u ANYROUTER_TOKENS \
      curl --silent --show-error --fail --max-time 20 \
        --config "$curl_config" \
        "$(normalize_base_url "$base_url")/models" >"$response_file" 2>/dev/null &
  else
    env -u GITHUB_TOKEN -u QQ_EMAIL -u QQ_SMTP_AUTH_CODE \
      -u ANYROUTER_TOKEN -u ANYROUTER_TOKENS \
      curl --silent --show-error --fail --max-time 20 \
        --config "$curl_config" \
        "$(normalize_base_url "$base_url")/models" >"$response_file" 2>/dev/null &
  fi
  curl_pid=$!
  wait "$curl_pid" || status=$?
  curl_pid=''
  set -e
  if [ "$status" -ne 0 ]; then
    printf '%s\n' 'Model discovery request failed' >&2
    return 3
  fi
  json="$(cat "$response_file")"
  python_command="$(model_python)" || return 4
  if ! printf '%s' "$json" | "$python_command" -c '
import json, re, sys

family = sys.argv[1]
excluded = ("embedding", "image", "audio", "tts", "transcribe", "realtime")
unstable = ("preview", "beta", "experimental")
try:
    payload = json.load(sys.stdin)
except (TypeError, ValueError):
    raise SystemExit(1)

candidates = []
for item in payload.get("data", []):
    model_id = item.get("id") if isinstance(item, dict) else None
    if not isinstance(model_id, str) or not model_id:
        continue
    lower = model_id.lower()
    if any(word in lower for word in excluded):
        continue
    if family == "claude" and "claude" not in lower:
        continue
    if family == "gpt" and not lower.startswith("gpt-"):
        continue
    candidates.append(model_id)

def rank(model_id):
    lower = model_id.lower()
    date_pattern = r"(?<!\d)(20\d{2})[-_.]?(\d{2})[-_.]?(\d{2})(?!\d)"
    dates = [int("".join(parts)) for parts in re.findall(date_pattern, lower)]
    without_dates = re.sub(date_pattern, "", lower)
    numbers = tuple(int(value) for value in re.findall(r"\d+", without_dates))
    numbers = (numbers + (0,) * 8)[:8]
    tier = 0
    if family == "claude":
        tier = 3 if "opus" in lower else 2 if "sonnet" in lower else 1 if "haiku" in lower else 0
    elif not any(word in lower for word in ("mini", "nano")):
        tier = 1
    return (not any(word in lower for word in unstable), numbers, max(dates, default=0), tier, lower)

if not candidates:
    raise SystemExit(1)
for model_id in sorted(set(candidates), key=rank, reverse=True):
    print(model_id)
' "$family"; then
    printf '%s\n' "No usable $family chat model found" >&2
    return 4
  fi
)

discover_model() {
  local model status=0
  model="$(discover_models "$@" | sed -n '1p')" || status=$?
  [ "$status" -eq 0 ] || return "$status"
  [ -n "$model" ] || return 4
  printf '%s\n' "$model"
}
