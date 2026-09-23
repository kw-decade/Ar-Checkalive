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
  printf '%s\n' 'Anyrouter base URL 无效' >&2
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

random_between() {
  local min="${1:-}" max="${2:-}" seed="${3:-$RANDOM}"
  [[ "$min" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ && "$seed" =~ ^[0-9]+$ ]] || return 2
  [ "$max" -ge "$min" ] || return 2
  printf '%s\n' "$((min + (seed % (max - min + 1))))"
}

# 找到可用的 python3，JSON 处理全走它。
py() {
  local candidate
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  printf '%s\n' 'python3 is required' >&2
  return 1
}

# 先 TERM 再 KILL 整棵子进程树。先递归处理孩子，再处理自己。
# /proc 在 Linux runner 上可用；其他平台回退到 ps -ef。
kill_tree() {
  local pid="${1:-}" child children='' i
  [ -n "$pid" ] || return 0
  if [ -r "/proc/$pid/task/$pid/children" ]; then
    children="$(cat "/proc/$pid/task/$pid/children" 2>/dev/null || true)"
  else
    children="$(ps -ef 2>/dev/null | awk -v parent="$pid" '$3 == parent { print $2 }')"
  fi
  for child in $children; do kill_tree "$child"; done
  kill -TERM "$pid" 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
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

send_email_safe() (
  local subject="${1:-}" body="${2:-}" mail_file curl_config curl_pid='' curl_status=0
  local connect_timeout="${SMTP_CONNECT_TIMEOUT_SEC:-15}" max_time="${SMTP_MAX_TIME_SEC:-30}"
  if [ -z "${QQ_EMAIL:-}" ] || [ -z "${QQ_SMTP_AUTH_CODE:-}" ]; then
    return 0
  fi
  [[ "$connect_timeout" =~ ^[1-9][0-9]*$ && "$max_time" =~ ^[1-9][0-9]*$ ]] || {
    printf '%s\n' 'SMTP 超时设置无效' >&2
    return 2
  }
  umask 077
  mail_file="$(mktemp)"
  curl_config="$(mktemp)"
  if [ -n "${TEST_TEMP_PATH_LOG:-}" ]; then printf '%s\n' "$mail_file" "$curl_config" >> "$TEST_TEMP_PATH_LOG"; fi
  trap 'rm -f "$mail_file" "$curl_config"' EXIT
  trap 'trap - TERM INT; kill_tree "$curl_pid"; rm -f "$mail_file" "$curl_config"; exit 143' TERM INT
  printf 'From: %s\nTo: %s\nSubject: %s\nContent-Type: text/plain; charset=utf-8\n\n%s\n' \
    "$QQ_EMAIL" "$QQ_EMAIL" "$subject" "$body" > "$mail_file"
  # 凭据写进 curl --config 文件而不是命令行，避免出现在 ps 里。
  printf 'user = "%s:%s"\nmail-from = "%s"\nmail-rcpt = "%s"\nupload-file = "%s"\n' \
    "$QQ_EMAIL" "$QQ_SMTP_AUTH_CODE" "$QQ_EMAIL" "$QQ_EMAIL" "$mail_file" > "$curl_config"
  set +e
  env -u GITHUB_TOKEN -u ANYROUTER_TOKEN -u ANYROUTER_TOKENS \
    -u QQ_EMAIL -u QQ_SMTP_AUTH_CODE \
    timeout --kill-after=1 "$((max_time + 2))" \
    curl --silent --show-error --ssl-reqd --fail \
      --connect-timeout "$connect_timeout" --max-time "$max_time" \
      --url 'smtps://smtp.qq.com:465' \
      --login-options 'AUTH=LOGIN' \
      --config "$curl_config" >/dev/null 2>&1 &
  curl_pid=$!
  wait "$curl_pid" || curl_status=$?
  curl_pid=''
  set -e
  return "$curl_status"
)
