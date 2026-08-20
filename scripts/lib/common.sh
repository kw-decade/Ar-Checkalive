#!/usr/bin/env bash
set -euo pipefail

DEFAULT_BASE_URL="https://anyrouter.top/v1"

normalize_base_url() {
  local value="${1:-$DEFAULT_BASE_URL}"
  [ -n "$value" ] || value="$DEFAULT_BASE_URL"
  while [[ "$value" == */ ]]; do value="${value%/}"; done
  if [[ "$value" == 'https://anyrouter.top' || "$value" =~ ^https://anyrouter\.top(/v1)+$ ]]; then
    printf '%s\n' "$DEFAULT_BASE_URL"
    return 0
  fi
  printf '%s\n' 'Invalid Anyrouter base URL' >&2
  return 2
}

normalize_claude_base_url() {
  local value
  value="$(normalize_base_url "${1:-$DEFAULT_BASE_URL}")"
  if [[ "$value" == */v1 ]]; then value="${value%/v1}"; fi
  while [[ "$value" == */ ]]; do value="${value%/}"; done
  printf '%s\n' "$value"
}

load_single_token() {
  local line trimmed
  while IFS= read -r line; do
    line="${line//$'\r'/}"
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    if [ -n "$trimmed" ]; then
      printf '%s\n' "$trimmed"
      return 0
    fi
  done <<< "${ANYROUTER_TOKENS:-}"
  printf '%s\n' 'No token configured' >&2
  return 1
}

safe_token_preview() {
  local token="${1:-}"
  printf '%s...\n' "${token:0:4}"
}

random_between() {
  local min="${1:-}" max="${2:-}" seed="${3:-$RANDOM}"
  [[ "$min" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ && "$seed" =~ ^[0-9]+$ ]] || return 2
  [ "$max" -ge "$min" ] || return 2
  printf '%s\n' "$((min + (seed % (max - min + 1))))"
}

write_state_file() {
  local state_file="$1" phase="$2" model="$3" notified="$4" chain_id="$5" chain_started_epoch="$6"
  local directory tmp
  case "$phase:$model:$notified:$chain_id:$chain_started_epoch" in
    *$'\n'*|*'='*) return 2 ;;
  esac
  directory="$(dirname "$state_file")"
  mkdir -p "$directory"
  tmp="$(mktemp "$directory/.state.XXXXXX")"
  printf 'phase=%s\nmodel=%s\nnotified=%s\nchain_id=%s\nchain_started_epoch=%s\n' \
    "$phase" "$model" "$notified" "$chain_id" "$chain_started_epoch" > "$tmp"
  mv -f "$tmp" "$state_file"
}

read_state_value() {
  local state_file="$1" key="$2"
  case "$key" in
    phase|model|notified|chain_id|chain_started_epoch) ;;
    *) return 2 ;;
  esac
  [ -f "$state_file" ] || return 1
  awk -F= -v wanted="$key" '$1 == wanted { sub(/^[^=]*=/, ""); print; found=1; exit } END { if (!found) exit 1 }' "$state_file"
}

state_value() {
  read_state_value "$@"
}

send_email_safe() (
  local subject="${1:-}" body="${2:-}" mail_file curl_status curl_config curl_pid=''
  local connect_timeout="${SMTP_CONNECT_TIMEOUT_SEC:-15}" max_time="${SMTP_MAX_TIME_SEC:-30}" guard_timeout
  if [ -z "${QQ_EMAIL:-}" ] || [ -z "${QQ_SMTP_AUTH_CODE:-}" ]; then
    return 0
  fi
  [[ "$connect_timeout" =~ ^[1-9][0-9]*$ && "$max_time" =~ ^[1-9][0-9]*$ ]] || {
    printf '%s\n' 'Invalid SMTP timeout setting' >&2
    return 2
  }
  guard_timeout=$((max_time + 2))
  umask 077
  mail_file="$(mktemp)"
  curl_config="$(mktemp)"
  if [ -n "${TEST_TEMP_PATH_LOG:-}" ]; then printf '%s\n' "$mail_file" "$curl_config" >> "$TEST_TEMP_PATH_LOG"; fi
  cleanup_mail_files() { rm -f "$mail_file" "$curl_config"; }
  stop_mail_process_tree() {
    local pid="${1:-}" child children='' _i exited=false
    [ -n "$pid" ] || return 0
    if [ -r "/proc/$pid/task/$pid/children" ]; then
      children="$(cat "/proc/$pid/task/$pid/children" 2>/dev/null || true)"
    else
      children="$(ps -ef 2>/dev/null | awk -v parent="$pid" '$3 == parent { print $2 }')"
    fi
    for child in $children; do stop_mail_process_tree "$child"; done
    kill -TERM "$pid" 2>/dev/null || true
    for _i in 1 2 3 4 5 6 7 8 9 10; do
      if ! kill -0 "$pid" 2>/dev/null; then exited=true; break; fi
      sleep 0.1
    done
    [ "$exited" = true ] || kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  }
  stop_mail_curl() {
    [ -n "$curl_pid" ] || return 0
    stop_mail_process_tree "$curl_pid"
    curl_pid=''
  }
  on_mail_signal() {
    trap - TERM INT
    stop_mail_curl
    cleanup_mail_files
    exit 143
  }
  trap cleanup_mail_files EXIT
  trap on_mail_signal TERM INT
  printf 'From: %s\nTo: %s\nSubject: %s\nContent-Type: text/plain; charset=utf-8\n\n%s\n' \
    "$QQ_EMAIL" "$QQ_EMAIL" "$subject" "$body" > "$mail_file"
  printf 'user = "%s:%s"\nmail-from = "%s"\nmail-rcpt = "%s"\nupload-file = "%s"\n' \
    "$QQ_EMAIL" "$QQ_SMTP_AUTH_CODE" "$QQ_EMAIL" "$QQ_EMAIL" "$mail_file" > "$curl_config"
  set +e
  env -u GITHUB_TOKEN -u ANYROUTER_TOKEN -u ANYROUTER_TOKENS \
    -u QQ_EMAIL -u QQ_SMTP_AUTH_CODE \
    timeout --kill-after=1 "$guard_timeout" \
    curl --silent --show-error --ssl-reqd --fail \
      --connect-timeout "$connect_timeout" --max-time "$max_time" \
      --url 'smtps://smtp.qq.com:465' \
      --login-options 'AUTH=LOGIN' \
      --config "$curl_config" >/dev/null 2>&1 &
  curl_pid=$!
  curl_status=0
  wait "$curl_pid" || curl_status=$?
  curl_pid=''
  set -e
  return "$curl_status"
)
