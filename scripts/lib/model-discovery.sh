#!/usr/bin/env bash
set -euo pipefail

MODEL_DISCOVERY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F normalize_base_url >/dev/null 2>&1; then
  # shellcheck source=common.sh
  source "$MODEL_DISCOVERY_DIR/common.sh"
fi

# discover_models FAMILY BASE_URL TOKEN [SELECTOR]
# 从 /models 拉候选并排序输出（每行一个，最优在前）。
# SELECTOR 语义：
#   空                         → 该家族全部聊天模型
#   含 '[' 或形如 claude-*/gpt-* → 别名或完整 id，原样返回不请求（用户明确指定就信用户）
#   其他（如 "5.5"、"opus 5.5"）  → 去掉 -._ 后做包含匹配，命中集合再排序
# 返回码：2 参数错，3 请求失败，4 无命中/无 python。
discover_models() (
  local family="${1:-}" base_url="${2:-}" token="${3:-}" selector="${4:-}"
  local python_bin curl_config='' response_file='' curl_pid='' status=0
  trap 'rm -f "$curl_config" "$response_file"' EXIT
  trap 'trap - TERM INT; kill_tree "$curl_pid"; rm -f "$curl_config" "$response_file"; exit 143' TERM INT
  case "$family" in claude|gpt) ;; *) return 2 ;; esac
  if [[ "$selector" == *'['* || "$selector" =~ ^(claude|gpt)- ]]; then
    printf '%s\n' "$selector"
    return 0
  fi
  umask 077
  curl_config="$(mktemp)"
  response_file="$(mktemp)"
  if [ -n "${TEST_TEMP_PATH_LOG:-}" ]; then printf '%s\n' "$curl_config" "$response_file" >> "$TEST_TEMP_PATH_LOG"; fi
  printf 'header = "Authorization: Bearer %s"\n' "$token" > "$curl_config"
  set +e
  env -u GITHUB_TOKEN -u QQ_EMAIL -u QQ_SMTP_AUTH_CODE \
    -u ANYROUTER_TOKEN -u ANYROUTER_TOKENS \
    curl --silent --show-error --fail --max-time 20 \
      --config "$curl_config" \
      "$(normalize_base_url "$base_url")/models" >"$response_file" 2>/dev/null &
  curl_pid=$!
  wait "$curl_pid" || status=$?
  curl_pid=''
  set -e
  if [ "$status" -ne 0 ]; then
    printf '%s\n' '拉取 /models 失败' >&2
    return 3
  fi
  python_bin="$(py)" || return 4
  if ! "$python_bin" - "$family" "$selector" "$response_file" <<'PY'
import json, re, sys

family, selector, response_path = sys.argv[1], sys.argv[2].strip(), sys.argv[3]
excluded = ("embedding", "image", "audio", "tts", "transcribe", "realtime")
unstable = ("preview", "beta", "experimental")
try:
    with open(response_path, encoding="utf-8") as handle:
        payload = json.load(handle)
except (OSError, TypeError, ValueError):
    raise SystemExit(1)

ids = []
for item in payload.get("data", []):
    model_id = item.get("id") if isinstance(item, dict) else None
    if isinstance(model_id, str) and model_id:
        ids.append(model_id)

def squash(text):
    return re.sub(r"[-._\s]", "", text.lower())

# ponytail: 语义匹配就是「去掉分隔符后的子串包含」。"5.5" -> "55"，
# "claude-opus-5-5-20260301" -> "claudeopus5520260301"。够用；误命中靠 rank 的 tier 兜底。
tokens = [squash(t) for t in re.split(r"[\s,]+", selector) if t]

candidates = []
for model_id in ids:
    lower = model_id.lower()
    if any(word in lower for word in excluded):
        continue
    if family == "claude" and "claude" not in lower:
        continue
    if family == "gpt" and not lower.startswith("gpt-"):
        continue
    if tokens and not all(t in squash(model_id) for t in tokens):
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
        tier = 4 if "fable" in lower else 3 if "opus" in lower else 2 if "sonnet" in lower else 1 if "haiku" in lower else 0
    elif not any(word in lower for word in ("mini", "nano")):
        tier = 1
    # 有 selector 时 tier 优先（"5.5" 要选 opus 而不是 haiku）；无 selector 时版本号优先。
    if tokens:
        return (not any(word in lower for word in unstable), tier, numbers, max(dates, default=0), lower)
    return (not any(word in lower for word in unstable), numbers, max(dates, default=0), tier, lower)

if not candidates:
    raise SystemExit(1)
for model_id in sorted(set(candidates), key=rank, reverse=True):
    print(model_id)
PY
  then
    printf '没有找到匹配的 %s 模型（选择器: %s）\n' "$family" "${selector:-无}" >&2
    return 4
  fi
)
