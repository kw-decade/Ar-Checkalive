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

base_url="$(normalize_base_url "$base_url_arg")"
start_epoch="$(date +%s)"
umask 077
request_file="$(mktemp)"
response_file="$(mktemp)"
curl_error_file="$(mktemp)"
curl_config="$(mktemp)"
http_code_file="$(mktemp)"
curl_pid=''
if [ -n "${TEST_TEMP_PATH_LOG:-}" ]; then
  printf '%s\n' "$request_file" "$response_file" "$curl_error_file" "$curl_config" "$http_code_file" >> "$TEST_TEMP_PATH_LOG"
fi
cleanup_gpt_files() {
  rm -f "$request_file" "$response_file" "$curl_error_file" "$curl_config" "$http_code_file"
}
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
  stop_gpt_process_tree "$curl_pid"
  curl_pid=''
  cleanup_gpt_files
  exit 143
}
trap cleanup_gpt_files EXIT
trap on_gpt_signal TERM INT

if python3 -c '' >/dev/null 2>&1; then
  python_command=python3
elif python -c '' >/dev/null 2>&1; then
  python_command=python
else
  printf 'status=invalid\nhttp_code=000\nelapsed_sec=%s\nmessage=python_unavailable\n' "$(( $(date +%s) - start_epoch ))"
  exit 0
fi

"$python_command" - "$model" "$prompt" > "$request_file" <<'PY'
import json, sys
json.dump({
    "model": sys.argv[1],
    "messages": [{"role": "user", "content": sys.argv[2]}],
    "max_tokens": 600,
}, sys.stdout, ensure_ascii=False)
PY

printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$token" > "$curl_config"
curl_status=0
set +e
env -u GITHUB_TOKEN -u QQ_EMAIL -u QQ_SMTP_AUTH_CODE \
  -u ANYROUTER_TOKEN -u ANYROUTER_TOKENS curl --silent --show-error \
  --connect-timeout 20 --max-time 120 \
  --output "$response_file" --write-out '%{http_code}' \
  --config "$curl_config" \
  --data-binary "@$request_file" \
  "$base_url/chat/completions" >"$http_code_file" 2>"$curl_error_file" &
curl_pid=$!
wait "$curl_pid" || curl_status=$?
curl_pid=''
set -e
http_code="$(cat "$http_code_file")"
http_code="${http_code:-000}"

if [ "$curl_status" -ne 0 ]; then
  printf 'status=retryable\nhttp_code=%s\nelapsed_sec=%s\nmessage=transport_error\n' "$http_code" "$(( $(date +%s) - start_epoch ))"
  exit 0
fi

case "$http_code" in
  2??)
    if "$python_command" - "$response_file" >/dev/null 2>&1 <<'PY'
import json, sys
try:
    payload = json.load(open(sys.argv[1], encoding="utf-8"))
    content = payload["choices"][0]["message"]["content"]
except (IndexError, KeyError, TypeError, ValueError, OSError):
    raise SystemExit(1)
raise SystemExit(0 if isinstance(content, str) and content.strip() else 1)
PY
    then
      printf 'status=success\nhttp_code=%s\nelapsed_sec=%s\nmessage=non_empty_response\n' "$http_code" "$(( $(date +%s) - start_epoch ))"
    else
      printf 'status=retryable\nhttp_code=%s\nelapsed_sec=%s\nmessage=empty_or_invalid_response\n' "$http_code" "$(( $(date +%s) - start_epoch ))"
    fi
    ;;
  429)
    printf 'status=rate_limited\nhttp_code=429\nelapsed_sec=%s\nmessage=capacity_limited\n' "$(( $(date +%s) - start_epoch ))"
    ;;
  401|403)
    printf 'status=invalid\nhttp_code=%s\nelapsed_sec=%s\nmessage=authentication_error\n' "$http_code" "$(( $(date +%s) - start_epoch ))"
    ;;
  400|404)
    if grep -Eqi 'model[_ -]*not[_ -]*found|unknown[ _-]*model|model.*(does not exist|not available|unsupported|not supported)|unsupported.*(model|chat|endpoint|protocol)|not supported.*(chat|endpoint|protocol)' "$response_file"; then
      printf 'status=invalid\nhttp_code=%s\nelapsed_sec=%s\nmessage=model_or_protocol_error\n' "$http_code" "$(( $(date +%s) - start_epoch ))"
    else
      printf 'status=invalid\nhttp_code=%s\nelapsed_sec=%s\nmessage=request_configuration_error\n' "$http_code" "$(( $(date +%s) - start_epoch ))"
    fi
    ;;
  422)
    printf 'status=invalid\nhttp_code=%s\nelapsed_sec=%s\nmessage=request_configuration_error\n' "$http_code" "$(( $(date +%s) - start_epoch ))"
    ;;
  5??)
    printf 'status=retryable\nhttp_code=%s\nelapsed_sec=%s\nmessage=upstream_error\n' "$http_code" "$(( $(date +%s) - start_epoch ))"
    ;;
  *)
    printf 'status=retryable\nhttp_code=%s\nelapsed_sec=%s\nmessage=unexpected_http_status\n' "$http_code" "$(( $(date +%s) - start_epoch ))"
    ;;
esac
