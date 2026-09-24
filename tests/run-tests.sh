#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
  local expected="$1" actual="$2"
  [ "$actual" = "$expected" ] || {
    printf 'expected <%s>, got <%s>\n' "$expected" "$actual" >&2
    return 1
  }
}

assert_contains() {
  local value="$1" expected="$2"
  [[ "$value" == *"$expected"* ]] || {
    printf 'expected output to contain <%s>, got <%s>\n' "$expected" "$value" >&2
    return 1
  }
}

assert_not_contains() {
  local value="$1" forbidden="$2"
  [[ "$value" != *"$forbidden"* ]] || {
    printf 'output exposed forbidden value <%s>\n' "$forbidden" >&2
    return 1
  }
}

run_case() {
  local name="$1"
  shift
  if ("$@"); then
    printf 'ok - %s\n' "$name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    printf 'not ok - %s\n' "$name"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

with_common() {
  # shellcheck source=../scripts/lib/common.sh
  source "$ROOT_DIR/scripts/lib/common.sh"
}

test_normalize_base_url() {
  with_common || return
  assert_eq "https://anyrouter.top/v1" "$(normalize_base_url 'https://anyrouter.top/v1///')"
}

test_normalize_claude_base_url() {
  with_common || return
  assert_eq "https://anyrouter.top" "$(normalize_claude_base_url 'https://anyrouter.top/v1///')"
}

test_base_url_allowlist_and_canonicalization() {
  with_common || return
  local input output status
  for input in \
    'https://anyrouter.top' \
    'https://anyrouter.top/' \
    'https://anyrouter.top/v1' \
    'https://anyrouter.top/v1/' \
    'https://anyrouter.top/v1/v1///'; do
    output="$(normalize_base_url "$input")" || return
    assert_eq 'https://anyrouter.top/v1' "$output" || return
    assert_eq 'https://anyrouter.top' "$(normalize_claude_base_url "$input")" || return
  done
  for input in \
    'http://anyrouter.top/v1' \
    'https://example.com/v1' \
    'https://anyrouter.top/extra' \
    'https://anyrouter.top/v1/models' \
    'https://anyrouter.top/v1?x=1' \
    $'https://anyrouter.top/v1\nbase_url = "https://example.com/v1"' \
    'https://anyrouter.top/v1"'; do
    output="$(normalize_base_url "$input" 2>/dev/null)"
    status=$?
    [ "$status" -ne 0 ] || {
      printf 'unsafe base URL was accepted: %s -> %s\n' "$input" "$output" >&2
      return 1
    }
  done
}

test_load_single_token() {
  with_common || return
  local output
  output="$(ANYROUTER_TOKENS=$'\n  \r\nsk-ant-test-one\r\nsk-ant-test-two' load_single_token)" || return
  assert_eq "sk-ant-test-one" "$output"
}

test_random_between() {
  with_common || return
  local output
  output="$(random_between 3 10 7)" || return
  [ "$output" -ge 3 ] && [ "$output" -le 10 ]
}

test_state_file_allowlist() {
  with_common || return
  local test_dir state_file keys
  test_dir="$(mktemp -d)" || return
  state_file="$test_dir/gpt.state"
  write_state_file "$state_file" "keepalive" "gpt-test" "true" "chain-1" "123" || {
    rm -rf "$test_dir"
    return 1
  }
  keys="$(cut -d= -f1 "$state_file" | paste -sd, -)"
  assert_eq "phase,model,notified,chain_id,chain_started_epoch" "$keys" &&
    assert_eq "keepalive" "$(read_state_value "$state_file" phase)"
  local status=$?
  rm -rf "$test_dir"
  return "$status"
}

test_send_email_failure_is_safe() {
  with_common || return
  local test_dir output status
  test_dir="$(mktemp -d)" || return
  mkdir -p "$test_dir/bin"
  printf '#!/usr/bin/env bash\nprintf "smtp unavailable\\n" >&2\nexit 7\n' > "$test_dir/bin/curl"
  chmod +x "$test_dir/bin/curl"
  set +e
  output="$(PATH="$test_dir/bin:$PATH" QQ_EMAIL='test@qq.com' QQ_SMTP_AUTH_CODE='smtp-secret-value' send_email_safe 'subject' 'body' 2>&1)"
  status=$?
  set -e
  rm -rf "$test_dir"
  [ "$status" -ne 0 ] && assert_not_contains "$output" "smtp-secret-value"
}

test_send_email_hides_smtp_secret_from_curl_argv() {
  with_common || return
  local test_dir output status config_path
  test_dir="$(mktemp -d)" || return
  mkdir -p "$test_dir/bin"
  export CURL_SECURITY_DIR="$test_dir"
  cat > "$test_dir/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$CURL_SECURITY_DIR/curl.argv"
printf 'GITHUB_TOKEN=%s\nANYROUTER_TOKEN=%s\nANYROUTER_TOKENS=%s\nQQ_EMAIL=%s\nQQ_SMTP_AUTH_CODE=%s\n' \
  "${GITHUB_TOKEN+x}" "${ANYROUTER_TOKEN+x}" "${ANYROUTER_TOKENS+x}" \
  "${QQ_EMAIL+x}" "${QQ_SMTP_AUTH_CODE+x}" > "$CURL_SECURITY_DIR/curl.env"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config|-K)
      printf '%s\n' "$2" > "$CURL_SECURITY_DIR/config.path"
      stat -c '%a' "$2" > "$CURL_SECURITY_DIR/config.mode"
      cp "$2" "$CURL_SECURITY_DIR/config.copy"
      shift 2
      ;;
    *) shift ;;
  esac
done
exit 7
SH
  chmod +x "$test_dir/bin/curl"
  set +e
  output="$(PATH="$test_dir/bin:$PATH" GITHUB_TOKEN=present ANYROUTER_TOKEN=present \
    ANYROUTER_TOKENS=present QQ_EMAIL='test@qq.com' \
    QQ_SMTP_AUTH_CODE='smtp-secret-value' send_email_safe 'subject' 'body' 2>&1)"
  status=$?
  set -e
  config_path="$(cat "$test_dir/config.path" 2>/dev/null || true)"
  [ "$status" -ne 0 ] && [ -n "$config_path" ] &&
    ! grep -q 'smtp-secret-value' "$test_dir/curl.argv" &&
    grep -q 'smtp-secret-value' "$test_dir/config.copy" &&
    assert_eq 600 "$(cat "$test_dir/config.mode")" &&
    grep -q '^GITHUB_TOKEN=$' "$test_dir/curl.env" &&
    grep -q '^ANYROUTER_TOKEN=$' "$test_dir/curl.env" &&
    grep -q '^ANYROUTER_TOKENS=$' "$test_dir/curl.env" &&
    grep -q '^QQ_EMAIL=$' "$test_dir/curl.env" &&
    grep -q '^QQ_SMTP_AUTH_CODE=$' "$test_dir/curl.env" &&
    [ ! -e "$config_path" ] && assert_not_contains "$output" 'smtp-secret-value'
  local assertion_status=$?
  rm -rf "$test_dir"
  return "$assertion_status"
}

test_send_email_rejects_invalid_timeout_settings() {
  with_common || return
  local test_dir status_one status_two
  test_dir="$(mktemp -d)" || return
  mkdir -p "$test_dir/bin"
  printf '#!/usr/bin/env bash\ntouch "$TIMEOUT_TEST_CURL_CALLED"\n' > "$test_dir/bin/curl"
  chmod +x "$test_dir/bin/curl"
  set +e
  TIMEOUT_TEST_CURL_CALLED="$test_dir/called" PATH="$test_dir/bin:$PATH" \
    SMTP_CONNECT_TIMEOUT_SEC=0 SMTP_MAX_TIME_SEC=1 QQ_EMAIL=x QQ_SMTP_AUTH_CODE=x \
    send_email_safe subject body >/dev/null 2>&1
  status_one=$?
  TIMEOUT_TEST_CURL_CALLED="$test_dir/called" PATH="$test_dir/bin:$PATH" \
    SMTP_CONNECT_TIMEOUT_SEC=1 SMTP_MAX_TIME_SEC=invalid QQ_EMAIL=x QQ_SMTP_AUTH_CODE=x \
    send_email_safe subject body >/dev/null 2>&1
  status_two=$?
  set -e
  [ "$status_one" -eq 2 ] && [ "$status_two" -eq 2 ] && [ ! -e "$test_dir/called" ]
  local assertion_status=$?
  rm -rf "$test_dir"
  return "$assertion_status"
}

run_common_tests() {
  run_case "normalize_base_url strips trailing slashes" test_normalize_base_url
  run_case "normalize_claude_base_url removes one trailing v1" test_normalize_claude_base_url
  run_case "base URLs are canonicalized to the single approved Anyrouter endpoint" test_base_url_allowlist_and_canonicalization
  run_case "load_single_token uses the first non-empty line" test_load_single_token
  run_case "random_between stays inside inclusive bounds" test_random_between
  run_case "state files contain only approved keys" test_state_file_allowlist
  run_case "SMTP failure returns safely without exposing credentials" test_send_email_failure_is_safe
  run_case "SMTP credentials are read from a private temporary curl config" test_send_email_hides_smtp_secret_from_curl_argv
  run_case "SMTP timeout settings must be positive integers" test_send_email_rejects_invalid_timeout_settings
}

with_model_discovery() {
  with_common || return
  # shellcheck source=../scripts/lib/model-discovery.sh
  source "$ROOT_DIR/scripts/lib/model-discovery.sh"
}

setup_model_fixture() {
  MODEL_TEST_DIR="$(mktemp -d)" || return
  mkdir -p "$MODEL_TEST_DIR/bin"
  MODELS_FIXTURE="$MODEL_TEST_DIR/models.json"
  CURL_CALLS="$MODEL_TEST_DIR/curl.calls"
  export MODEL_TEST_DIR MODELS_FIXTURE CURL_CALLS
  cat > "$MODELS_FIXTURE" <<'JSON'
{"data":[{"id":"text-embedding-3-small"},{"id":"claude-sonnet-4-20250514"},{"id":"claude-opus-4-20250601"},{"id":"claude-audio-99-20990101"},{"id":"gpt-9.1-mini"},{"id":"gpt-9.2-example"},{"id":"gpt-audio-99"}]}
JSON
  cat > "$MODEL_TEST_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
  : "${MODEL_TEST_DIR:?}"
  printf '%s\n' "$*" > "$MODEL_TEST_DIR/curl.argv"
  printf 'GITHUB_TOKEN=%s\nQQ_EMAIL=%s\nQQ_SMTP_AUTH_CODE=%s\nANYROUTER_TOKEN=%s\nANYROUTER_TOKENS=%s\n' \
    "${GITHUB_TOKEN+x}" "${QQ_EMAIL+x}" "${QQ_SMTP_AUTH_CODE+x}" \
    "${ANYROUTER_TOKEN+x}" "${ANYROUTER_TOKENS+x}" > "$MODEL_TEST_DIR/curl.env"
url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config|-K)
      printf '%s\n' "$2" > "$MODEL_TEST_DIR/config.path"
      stat -c '%a' "$2" > "$MODEL_TEST_DIR/config.mode"
      cp "$2" "$MODEL_TEST_DIR/config.copy"
      shift 2
      ;;
    -H|--header|--max-time) shift 2 ;;
    --silent|--show-error|--fail) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >> "$CURL_CALLS"
cat "$MODELS_FIXTURE"
SH
  chmod +x "$MODEL_TEST_DIR/bin/curl"
}

test_discover_claude_model() {
  setup_model_fixture || return
  with_model_discovery || { rm -rf "$MODEL_TEST_DIR"; return 1; }
  local output
  output="$(PATH="$MODEL_TEST_DIR/bin:$PATH" discover_models claude 'https://anyrouter.top/v1/' 'sk-ant-test-secret' '' | sed -n 1p)"
  local status=$?
  assert_eq "claude-opus-4-20250601" "$output" &&
    assert_eq "https://anyrouter.top/v1/models" "$(tail -n 1 "$CURL_CALLS")" &&
    assert_not_contains "$output" "sk-ant-test-secret"
  local assertion_status=$?
  rm -rf "$MODEL_TEST_DIR"
  [ "$status" -eq 0 ] && return "$assertion_status"
}

test_discover_gpt_model() {
  setup_model_fixture || return
  with_model_discovery || { rm -rf "$MODEL_TEST_DIR"; return 1; }
  local output
  output="$(PATH="$MODEL_TEST_DIR/bin:$PATH" discover_models gpt 'https://anyrouter.top/v1' 'sk-ant-test-secret' '' | sed -n 1p)"
  local status=$?
  assert_eq "gpt-9.2-example" "$output"
  local assertion_status=$?
  rm -rf "$MODEL_TEST_DIR"
  [ "$status" -eq 0 ] && return "$assertion_status"
}

test_discover_models_returns_ranked_candidates() {
  setup_model_fixture || return
  with_model_discovery || { rm -rf "$MODEL_TEST_DIR"; return 1; }
  local output status
  output="$(PATH="$MODEL_TEST_DIR/bin:$PATH" discover_models gpt 'https://anyrouter.top/v1' 'sk-ant-test-secret' '')"
  status=$?
  [ "$status" -eq 0 ] && assert_eq "gpt-9.2-example" "$(sed -n '1p' <<< "$output")" &&
    assert_eq "gpt-9.1-mini" "$(sed -n '2p' <<< "$output")" &&
    assert_not_contains "$output" "gpt-audio-99"
  local assertion_status=$?
  rm -rf "$MODEL_TEST_DIR"
  return "$assertion_status"
}

test_discover_gpt_semantic_version_beats_date() {
  setup_model_fixture || return
  printf '%s\n' '{"data":[{"id":"gpt-5-2025-08-07"},{"id":"gpt-5.6-sol"}]}' > "$MODELS_FIXTURE"
  with_model_discovery || { rm -rf "$MODEL_TEST_DIR"; return 1; }
  local output
  output="$(PATH="$MODEL_TEST_DIR/bin:$PATH" discover_models gpt 'https://anyrouter.top/v1' 'sk-ant-test-secret' '' | sed -n 1p)"
  local status=$?
  assert_eq "gpt-5.6-sol" "$output"
  local assertion_status=$?
  rm -rf "$MODEL_TEST_DIR"
  [ "$status" -eq 0 ] && return "$assertion_status"
}

test_discover_model_override_skips_http() {
  setup_model_fixture || return
  with_model_discovery || { rm -rf "$MODEL_TEST_DIR"; return 1; }
  local output
  output="$(PATH="$MODEL_TEST_DIR/bin:$PATH" discover_models gpt 'https://anyrouter.top/v1' 'sk-ant-test-secret' 'gpt-user-choice' | sed -n 1p)"
  local status=$?
  assert_eq "gpt-user-choice" "$output" && [ ! -e "$CURL_CALLS" ]
  local assertion_status=$?
  rm -rf "$MODEL_TEST_DIR"
  [ "$status" -eq 0 ] && return "$assertion_status"
}

test_claude_model_selection_uses_opus_1m_without_variable_or_inherited_model() {
  setup_dual_pool_fixture || return
  local output status
  output="$(unset ANYROUTER_CLAUDE_MODEL CLAUDE_MODEL; ANYROUTER_GPT_MODEL=gpt-test \
    POOL_WORKER_COMMAND="$DUAL_TEST_DIR/bin/fake-worker" MAX_ITERATIONS=1 MAX_DURATION_SEC=5 \
    SKIP_STOP_CHECK=true ANYROUTER_TOKENS=sk-ant-test-only \
    bash "$ROOT_DIR/scripts/run-dual-pool.sh" --mode start --once 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && grep -q '^claude|opus\[1m\]$' "$DUAL_TEST_DIR/worker.models" &&
    assert_not_contains "$output" 'sk-ant-test-only'
  local assertion_status=$?
  rm -rf "$DUAL_TEST_DIR"
  return "$assertion_status"
}

test_claude_variable_still_overrides_default_model() {
  setup_dual_pool_fixture || return
  local output status
  output="$(ANYROUTER_CLAUDE_MODEL=claude-user-choice ANYROUTER_GPT_MODEL=gpt-test \
    POOL_WORKER_COMMAND="$DUAL_TEST_DIR/bin/fake-worker" MAX_ITERATIONS=1 MAX_DURATION_SEC=5 \
    SKIP_STOP_CHECK=true ANYROUTER_TOKENS=sk-ant-test-only \
    bash "$ROOT_DIR/scripts/run-dual-pool.sh" --mode start --once 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && grep -q '^claude|claude-user-choice$' "$DUAL_TEST_DIR/worker.models"
  local assertion_status=$?
  rm -rf "$DUAL_TEST_DIR"
  return "$assertion_status"
}

test_discover_model_rejects_empty_family() {
  setup_model_fixture || return
  printf '%s\n' '{"data":[{"id":"text-embedding-3-small"},{"id":"gpt-audio-test"}]}' > "$MODELS_FIXTURE"
  with_model_discovery || { rm -rf "$MODEL_TEST_DIR"; return 1; }
  local output status
  set +e
  output="$(PATH="$MODEL_TEST_DIR/bin:$PATH" discover_models gpt 'https://anyrouter.top/v1' 'sk-ant-test-secret' '' 2>&1)"
  status=$?
  set -e
  rm -rf "$MODEL_TEST_DIR"
  [ "$status" -eq 4 ] && assert_not_contains "$output" "sk-ant-test-secret"
}

test_model_discovery_hides_bearer_from_curl_argv() {
  setup_model_fixture || return
  with_model_discovery || { rm -rf "$MODEL_TEST_DIR"; return 1; }
  local output status config_path
  export PATH="$MODEL_TEST_DIR/bin:$PATH"
  GITHUB_TOKEN=present QQ_EMAIL=present QQ_SMTP_AUTH_CODE=present \
    ANYROUTER_TOKEN=present ANYROUTER_TOKENS=present discover_models gpt \
    'https://anyrouter.top/v1' 'sk-ant-model-secret' '' > "$MODEL_TEST_DIR/output"
  status=$?
  output="$(cat "$MODEL_TEST_DIR/output")"
  config_path="$(cat "$MODEL_TEST_DIR/config.path" 2>/dev/null || true)"
  [ "$status" -eq 0 ] && [ -n "$config_path" ] &&
    ! grep -q 'sk-ant-model-secret' "$MODEL_TEST_DIR/curl.argv" &&
    grep -q 'Authorization: Bearer sk-ant-model-secret' "$MODEL_TEST_DIR/config.copy" &&
    assert_eq 600 "$(cat "$MODEL_TEST_DIR/config.mode")" && [ ! -e "$config_path" ] &&
    grep -q '^GITHUB_TOKEN=$' "$MODEL_TEST_DIR/curl.env" &&
    grep -q '^QQ_EMAIL=$' "$MODEL_TEST_DIR/curl.env" &&
    grep -q '^QQ_SMTP_AUTH_CODE=$' "$MODEL_TEST_DIR/curl.env" &&
    grep -q '^ANYROUTER_TOKEN=$' "$MODEL_TEST_DIR/curl.env" &&
    grep -q '^ANYROUTER_TOKENS=$' "$MODEL_TEST_DIR/curl.env" &&
    assert_not_contains "$output" 'sk-ant-model-secret'
  local assertion_status=$?
  rm -rf "$MODEL_TEST_DIR"
  return "$assertion_status"
}

test_discover_models_semantic_selector() {
  setup_model_fixture || return
  printf '%s\n' '{"data":[{"id":"claude-fable-5-1-20260601"},{"id":"claude-haiku-5-5-20260401"},{"id":"claude-opus-5-5-20260301"},{"id":"claude-opus-5-20251101"},{"id":"claude-sonnet-5-5-20260301"},{"id":"gpt-5.5"},{"id":"gpt-5.5-mini"},{"id":"gpt-5.4"}]}' > "$MODELS_FIXTURE"
  with_model_discovery || { rm -rf "$MODEL_TEST_DIR"; return 1; }
  local claude gpt sonnet missing_status=0
  export PATH="$MODEL_TEST_DIR/bin:$PATH"
  claude="$(discover_models claude 'https://anyrouter.top/v1' 'sk-test' '5.5')" || return
  sonnet="$(discover_models claude 'https://anyrouter.top/v1' 'sk-test' 'sonnet 5.5' | sed -n 1p)"
  gpt="$(discover_models gpt 'https://anyrouter.top/v1' 'sk-test' '5.5')" || return
  discover_models claude 'https://anyrouter.top/v1' 'sk-test' '9.9' >/dev/null 2>&1 || missing_status=$?
  assert_eq claude-fable-5-1-20260601 "$(discover_models claude 'https://anyrouter.top/v1' 'sk-test' 'fable51')" || return
  assert_eq claude-opus-5-5-20260301 "$(sed -n 1p <<< "$claude")" &&
    assert_eq claude-haiku-5-5-20260401 "$(sed -n 3p <<< "$claude")" &&
    assert_not_contains "$claude" 'claude-opus-5-20251101' &&
    assert_eq claude-sonnet-5-5-20260301 "$sonnet" &&
    assert_eq gpt-5.5 "$(sed -n 1p <<< "$gpt")" &&
    assert_not_contains "$gpt" 'gpt-5.4' &&
    assert_eq 4 "$missing_status"
  local assertion_status=$?
  rm -rf "$MODEL_TEST_DIR"
  return "$assertion_status"
}

test_claude_semantic_variable_falls_back_to_opus_1m() {
  setup_dual_pool_fixture || return
  printf '%s\n' '{"data":[{"id":"claude-opus-5-5-20260301"}]}' > "$DUAL_TEST_DIR/models.json"
  cat > "$DUAL_TEST_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
cat "$DUAL_TEST_DIR/models.json"
SH
  chmod +x "$DUAL_TEST_DIR/bin/curl"
  local output status
  output="$(PATH="$DUAL_TEST_DIR/bin:$PATH" ANYROUTER_CLAUDE_MODEL=5.5 ANYROUTER_GPT_MODEL=gpt-test \
    POOL_WORKER_COMMAND="$DUAL_TEST_DIR/bin/fake-worker" MAX_ITERATIONS=1 MAX_DURATION_SEC=5 \
    SKIP_STOP_CHECK=true ANYROUTER_TOKENS=sk-ant-test-only \
    bash "$ROOT_DIR/scripts/run-dual-pool.sh" --mode start --once 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && grep -q '^claude|claude-opus-5-5-20260301$' "$DUAL_TEST_DIR/worker.models" || {
    rm -rf "$DUAL_TEST_DIR"; return 1; }
  rm -f "$DUAL_TEST_DIR/worker.models" "$DUAL_TEST_DIR/"*.started
  output="$(PATH="$DUAL_TEST_DIR/bin:$PATH" ANYROUTER_CLAUDE_MODEL=9.9 ANYROUTER_GPT_MODEL=gpt-test \
    POOL_WORKER_COMMAND="$DUAL_TEST_DIR/bin/fake-worker" MAX_ITERATIONS=1 MAX_DURATION_SEC=5 \
    SKIP_STOP_CHECK=true ANYROUTER_TOKENS=sk-ant-test-only \
    bash "$ROOT_DIR/scripts/run-dual-pool.sh" --mode start --once 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && grep -q '^claude|opus\[1m\]$' "$DUAL_TEST_DIR/worker.models" &&
    assert_contains "$output" '退回 opus[1m]'
  local assertion_status=$?
  rm -rf "$DUAL_TEST_DIR"
  return "$assertion_status"
}

run_model_tests() {
  run_case "semantic selector 5.5 picks the newest matching tier and rejects misses" test_discover_models_semantic_selector
  run_case "Claude semantic Variable resolves via /models and falls back to opus[1m]" test_claude_semantic_variable_falls_back_to_opus_1m
  run_case "model discovery selects the newest Claude chat model" test_discover_claude_model
  run_case "model discovery selects the newest GPT chat model" test_discover_gpt_model
  run_case "model discovery returns every usable candidate in ranked order" test_discover_models_returns_ranked_candidates
  run_case "GPT semantic version outranks a newer dated snapshot" test_discover_gpt_semantic_version_beats_date
  run_case "a model Variable override skips the models request" test_discover_model_override_skips_http
  run_case "model discovery returns a dedicated error for no candidates" test_discover_model_rejects_empty_family
  run_case "model discovery keeps its Bearer token out of curl argv" test_model_discovery_hides_bearer_from_curl_argv
  run_case "Claude selection defaults to opus[1m] without a Variable" test_claude_model_selection_uses_opus_1m_without_variable_or_inherited_model
  run_case "Claude Variable still overrides the fixed default" test_claude_variable_still_overrides_default_model
}

setup_adapter_fixture() {
  ADAPTER_TEST_DIR="$(mktemp -d)" || return
  mkdir -p "$ADAPTER_TEST_DIR/bin" "$ADAPTER_TEST_DIR/original-home"
  export ADAPTER_TEST_DIR
}

write_fake_codex() {
  cat > "$ADAPTER_TEST_DIR/bin/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$CODEX_TEST_DIR/argv"
printf '%s\n' "${HOME:-}" > "$CODEX_TEST_DIR/home"
printf '%s\n' "${CODEX_HOME:-}" > "$CODEX_TEST_DIR/codex-home"
printf '%s\n' "${OPENAI_API_KEY:+set}" > "$CODEX_TEST_DIR/key-state"
printf 'GITHUB_TOKEN=%s\nQQ_EMAIL=%s\nQQ_SMTP_AUTH_CODE=%s\nANYROUTER_TOKEN=%s\nANYROUTER_TOKENS=%s\n' \
  "${GITHUB_TOKEN+x}" "${QQ_EMAIL+x}" "${QQ_SMTP_AUTH_CODE+x}" \
  "${ANYROUTER_TOKEN+x}" "${ANYROUTER_TOKENS+x}" > "$CODEX_TEST_DIR/env"
if [ -n "${CODEX_HOME:-}" ] && [ -r "$CODEX_HOME/config.toml" ]; then
  cp "$CODEX_HOME/config.toml" "$CODEX_TEST_DIR/config.toml"
fi
printf '%s' "${CODEX_STDOUT:-safe response}"
printf '%s' "${CODEX_STDERR:-}" >&2
exit "${CODEX_EXIT:-0}"
SH
  chmod +x "$ADAPTER_TEST_DIR/bin/codex"
}

test_gpt_adapter_success_and_json() {
  setup_adapter_fixture || return
  write_fake_codex
  export CODEX_TEST_DIR="$ADAPTER_TEST_DIR" CODEX_EXIT=0 CODEX_STDOUT='Use a bounded queue.' CODEX_STDERR=''
  local output status
  output="$(PATH="$ADAPTER_TEST_DIR/bin:$PATH" HOME="$ADAPTER_TEST_DIR/original-home" \
    GITHUB_TOKEN=present QQ_EMAIL=present QQ_SMTP_AUTH_CODE=present ANYROUTER_TOKENS=present \
    ANYROUTER_TOKEN='sk-ant-secret-value' bash "$ROOT_DIR/scripts/adapters/gpt.sh" \
    'https://anyrouter.top/v1/' 'gpt-test' 'Review "quoted" input safely.' 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && assert_contains "$output" 'status=success' &&
    assert_contains "$output" 'http_code=000' &&
    assert_contains "$output" 'cli_exit_code=0' &&
    [[ "$output" =~ elapsed_sec=[0-9]+ ]] &&
    assert_not_contains "$output" 'sk-ant-secret-value' &&
    assert_not_contains "$output" 'Use a bounded queue.' &&
    ! grep -q 'sk-ant-secret-value' "$ADAPTER_TEST_DIR/argv" &&
    ! grep -q 'sk-ant-secret-value' "$ADAPTER_TEST_DIR/config.toml" &&
    assert_eq set "$(cat "$ADAPTER_TEST_DIR/key-state")" &&
    ! grep -q '=x$' "$ADAPTER_TEST_DIR/env" &&
    grep -q '^model_provider = "anyrouter"$' "$ADAPTER_TEST_DIR/config.toml" &&
    grep -q '^model = "gpt-test"$' "$ADAPTER_TEST_DIR/config.toml" &&
    grep -q '^wire_api = "responses"$' "$ADAPTER_TEST_DIR/config.toml" &&
    grep -q '^request_max_retries = 0$' "$ADAPTER_TEST_DIR/config.toml" &&
    grep -q '^stream_max_retries = 0$' "$ADAPTER_TEST_DIR/config.toml" &&
    grep -q '^base_url = "https://anyrouter.top/v1"$' "$ADAPTER_TEST_DIR/config.toml" &&
    assert_contains "$(cat "$ADAPTER_TEST_DIR/argv")" 'exec' &&
    assert_contains "$(cat "$ADAPTER_TEST_DIR/argv")" '--json' &&
    assert_contains "$(cat "$ADAPTER_TEST_DIR/argv")" '--ephemeral' &&
    assert_contains "$(cat "$ADAPTER_TEST_DIR/argv")" '--skip-git-repo-check' &&
    assert_contains "$(cat "$ADAPTER_TEST_DIR/argv")" '--sandbox read-only' &&
    assert_contains "$(cat "$ADAPTER_TEST_DIR/argv")" '--model gpt-test' &&
    [ "$(cat "$ADAPTER_TEST_DIR/home")" != "$ADAPTER_TEST_DIR/original-home" ] &&
    [ "$(cat "$ADAPTER_TEST_DIR/codex-home")" != "$ADAPTER_TEST_DIR/original-home" ]
  local assertion_status=$?
  rm -rf "$ADAPTER_TEST_DIR"
  return "$assertion_status"
}

test_gpt_adapter_rate_limit() {
  setup_adapter_fixture || return
  write_fake_codex
  export CODEX_TEST_DIR="$ADAPTER_TEST_DIR" CODEX_EXIT=1 CODEX_STDOUT='{"type":"error","message":"unexpected HTTP status 429 busy secret response"}' CODEX_STDERR=''
  local output status
  output="$(PATH="$ADAPTER_TEST_DIR/bin:$PATH" ANYROUTER_TOKEN='sk-ant-secret-value' \
    bash "$ROOT_DIR/scripts/adapters/gpt.sh" \
    'https://anyrouter.top/v1' 'gpt-test' 'Review code' 2>&1)"
  status=$?
  rm -rf "$ADAPTER_TEST_DIR"
  [ "$status" -eq 0 ] && assert_contains "$output" 'status=rate_limited' &&
    assert_contains "$output" 'http_code=429' &&
    assert_contains "$output" 'cli_exit_code=1' &&
    assert_not_contains "$output" 'sk-ant-secret-value' &&
    assert_not_contains "$output" 'busy secret response'
}

test_gpt_adapter_invalid_model() {
  setup_adapter_fixture || return
  write_fake_codex
  export CODEX_TEST_DIR="$ADAPTER_TEST_DIR" CODEX_EXIT=1 CODEX_STDOUT='{"type":"error","message":"unknown model private upstream detail"}' CODEX_STDERR=''
  local output status
  output="$(PATH="$ADAPTER_TEST_DIR/bin:$PATH" ANYROUTER_TOKEN='sk-ant-secret-value' \
    bash "$ROOT_DIR/scripts/adapters/gpt.sh" \
    'https://anyrouter.top/v1' 'gpt-test' 'Review code' 2>&1)"
  status=$?
  rm -rf "$ADAPTER_TEST_DIR"
  [ "$status" -eq 0 ] && assert_contains "$output" 'status=invalid' &&
    assert_contains "$output" 'message=model_or_protocol_error' &&
    assert_contains "$output" 'cli_exit_code=1' &&
    assert_not_contains "$output" 'private upstream detail'
}

test_gpt_adapter_authentication_error_is_distinct() {
  setup_adapter_fixture || return
  write_fake_codex
  export CODEX_TEST_DIR="$ADAPTER_TEST_DIR" CODEX_EXIT=1 CODEX_STDOUT='{"type":"error","message":"HTTP 401 private credential detail"}' CODEX_STDERR=''
  local output status
  output="$(PATH="$ADAPTER_TEST_DIR/bin:$PATH" ANYROUTER_TOKEN='sk-ant-secret-value' \
    bash "$ROOT_DIR/scripts/adapters/gpt.sh" \
    'https://anyrouter.top/v1' 'gpt-test' 'Review code' 2>&1)"
  status=$?
  rm -rf "$ADAPTER_TEST_DIR"
  [ "$status" -eq 0 ] && assert_contains "$output" 'status=invalid' &&
    assert_contains "$output" 'message=authentication_error' &&
    assert_contains "$output" 'cli_exit_code=1' &&
    assert_not_contains "$output" 'private credential detail'
}

test_gpt_adapter_request_configuration_error() {
  setup_adapter_fixture || return
  write_fake_codex
  export CODEX_TEST_DIR="$ADAPTER_TEST_DIR" CODEX_EXIT=1 CODEX_STDOUT='{"type":"error","message":"invalid parameter detail"}' CODEX_STDERR=''
  local output status
  output="$(PATH="$ADAPTER_TEST_DIR/bin:$PATH" ANYROUTER_TOKEN='sk-ant-secret-value' \
    bash "$ROOT_DIR/scripts/adapters/gpt.sh" \
    'https://anyrouter.top/v1' 'gpt-test' 'Review code' 2>&1)"
  status=$?
  rm -rf "$ADAPTER_TEST_DIR"
  [ "$status" -eq 0 ] && assert_contains "$output" 'status=invalid' &&
    assert_contains "$output" 'http_code=000' &&
    assert_contains "$output" 'message=request_configuration_error' &&
    assert_contains "$output" 'cli_exit_code=1' &&
    [[ "$output" =~ elapsed_sec=[0-9]+ ]] &&
    assert_not_contains "$output" 'invalid parameter detail'
}

test_gpt_adapter_network_failure() {
  setup_adapter_fixture || return
  write_fake_codex
  export CODEX_TEST_DIR="$ADAPTER_TEST_DIR" CODEX_STDOUT='{"type":"error","message":"transport failure"}' CODEX_STDERR='' CODEX_EXIT=7
  local output status
  output="$(PATH="$ADAPTER_TEST_DIR/bin:$PATH" ANYROUTER_TOKEN='sk-ant-secret-value' \
    bash "$ROOT_DIR/scripts/adapters/gpt.sh" \
    'https://anyrouter.top/v1' 'gpt-test' 'Review code' 2>&1)"
  status=$?
  rm -rf "$ADAPTER_TEST_DIR"
  [ "$status" -eq 0 ] && assert_contains "$output" 'status=retryable' &&
    assert_contains "$output" 'http_code=000' &&
    assert_contains "$output" 'cli_exit_code=7'
}

test_gpt_adapter_timeout_is_retryable() {
  setup_adapter_fixture || return
  cat > "$ADAPTER_TEST_DIR/bin/codex" <<'SH'
#!/usr/bin/env bash
/usr/bin/sleep 3
printf '%s\n' 'late private response'
SH
  chmod +x "$ADAPTER_TEST_DIR/bin/codex"
  local output status start_epoch elapsed
  start_epoch="$(date +%s)"
  output="$(PATH="$ADAPTER_TEST_DIR/bin:$PATH" REQUEST_TIMEOUT_SEC=1 \
    ANYROUTER_TOKEN='sk-ant-secret-value' bash "$ROOT_DIR/scripts/adapters/gpt.sh" \
    'https://anyrouter.top/v1' 'gpt-test' 'Review code' 2>&1)"
  status=$?
  elapsed=$(( $(date +%s) - start_epoch ))
  rm -rf "$ADAPTER_TEST_DIR"
  [ "$status" -eq 0 ] && [ "$elapsed" -lt 3 ] &&
    assert_contains "$output" 'status=retryable' &&
    assert_contains "$output" 'message=request_timeout' &&
    assert_contains "$output" 'cli_exit_code=124' &&
    assert_not_contains "$output" 'late private response'
}

write_fake_claude() {
  cat > "$ADAPTER_TEST_DIR/bin/claude" <<'SH'
#!/usr/bin/env bash
printf 'HOME=%s\nUSERPROFILE=%s\nXDG_CONFIG_HOME=%s\nBASE=%s\nCONFIG=%s\nARGS=%s\n' \
  "$HOME" "${USERPROFILE:-}" "${XDG_CONFIG_HOME:-}" "${ANTHROPIC_BASE_URL:-}" \
  "${CLAUDE_CONFIG_DIR:-}" "$*" > "$ADAPTER_TEST_DIR/claude.call"
printf 'GITHUB_TOKEN=%s\nQQ_EMAIL=%s\nQQ_SMTP_AUTH_CODE=%s\nANYROUTER_TOKEN=%s\nANYROUTER_TOKENS=%s\nANTHROPIC_AUTH_TOKEN=%s\nCLAUDE_CODE_MAX_RETRIES=%s\nANTHROPIC_DEFAULT_FABLE_MODEL=%s\nANTHROPIC_DEFAULT_OPUS_MODEL=%s\nANTHROPIC_DEFAULT_SONNET_MODEL=%s\n' \
  "${GITHUB_TOKEN+x}" "${QQ_EMAIL+x}" "${QQ_SMTP_AUTH_CODE+x}" \
  "${ANYROUTER_TOKEN+x}" "${ANYROUTER_TOKENS+x}" "${ANTHROPIC_AUTH_TOKEN+x}" \
  "${CLAUDE_CODE_MAX_RETRIES:-}" "${ANTHROPIC_DEFAULT_FABLE_MODEL:-}" \
  "${ANTHROPIC_DEFAULT_OPUS_MODEL:-}" "${ANTHROPIC_DEFAULT_SONNET_MODEL:-}" >> "$ADAPTER_TEST_DIR/claude.call"
printf '%s' "${CLAUDE_STDOUT:-}"
printf '%s' "${CLAUDE_STDERR:-}" >&2
exit "${CLAUDE_EXIT:-0}"
SH
  chmod +x "$ADAPTER_TEST_DIR/bin/claude"
}

test_claude_adapter_isolated_success() {
  setup_adapter_fixture || return
  write_fake_claude
  export CLAUDE_STDOUT='Use a bounded queue.' CLAUDE_STDERR='' CLAUDE_EXIT=0
  local output status call_home
  output="$(PATH="$ADAPTER_TEST_DIR/bin:$PATH" HOME="$ADAPTER_TEST_DIR/original-home" \
    USERPROFILE="$ADAPTER_TEST_DIR/original-profile" XDG_CONFIG_HOME="$ADAPTER_TEST_DIR/original-xdg" \
    CLAUDE_CONFIG_DIR="$ADAPTER_TEST_DIR/original-claude" GITHUB_TOKEN=present \
    QQ_EMAIL=present QQ_SMTP_AUTH_CODE=present ANYROUTER_TOKENS=present \
    ANYROUTER_TOKEN='sk-ant-secret-value' bash "$ROOT_DIR/scripts/adapters/claude.sh" \
    'https://anyrouter.top/v1/' 'claude-test' 'Review code' 2>&1)"
  status=$?
  call_home="$(sed -n 's/^HOME=//p' "$ADAPTER_TEST_DIR/claude.call")"
  [ "$status" -eq 0 ] && assert_contains "$output" 'status=success' &&
    assert_contains "$output" 'cli_exit_code=0' &&
    [[ "$output" =~ elapsed_sec=[0-9]+ ]] &&
    assert_not_contains "$output" 'sk-ant-secret-value' &&
    [ "$call_home" != "$ADAPTER_TEST_DIR/original-home" ] &&
    grep -q "^USERPROFILE=$call_home$" "$ADAPTER_TEST_DIR/claude.call" &&
    grep -q "^XDG_CONFIG_HOME=$call_home/.config$" "$ADAPTER_TEST_DIR/claude.call" &&
    grep -q "^CONFIG=$call_home/.claude$" "$ADAPTER_TEST_DIR/claude.call" &&
    grep -q '^BASE=https://anyrouter.top$' "$ADAPTER_TEST_DIR/claude.call" &&
    grep -q '^GITHUB_TOKEN=$' "$ADAPTER_TEST_DIR/claude.call" &&
    grep -q '^QQ_EMAIL=$' "$ADAPTER_TEST_DIR/claude.call" &&
    grep -q '^QQ_SMTP_AUTH_CODE=$' "$ADAPTER_TEST_DIR/claude.call" &&
    grep -q '^ANYROUTER_TOKEN=$' "$ADAPTER_TEST_DIR/claude.call" &&
    grep -q '^ANYROUTER_TOKENS=$' "$ADAPTER_TEST_DIR/claude.call" &&
    grep -q '^ANTHROPIC_AUTH_TOKEN=x$' "$ADAPTER_TEST_DIR/claude.call" &&
    grep -q '^CLAUDE_CODE_MAX_RETRIES=0$' "$ADAPTER_TEST_DIR/claude.call" &&
    grep -q '^ANTHROPIC_DEFAULT_FABLE_MODEL=$' "$ADAPTER_TEST_DIR/claude.call" &&
    grep -q '^ANTHROPIC_DEFAULT_OPUS_MODEL=claude-test\[1M\]$' "$ADAPTER_TEST_DIR/claude.call" &&
    grep -q -- '--model opus\[1m\]' "$ADAPTER_TEST_DIR/claude.call" &&
    [ ! -e "$ADAPTER_TEST_DIR/original-home/.claude/settings.json" ]
  local assertion_status=$?
  rm -rf "$ADAPTER_TEST_DIR"
  return "$assertion_status"
}

test_claude_adapter_error_categories_are_distinct() {
  setup_adapter_fixture || return
  write_fake_claude
  local output status
  export CLAUDE_STDOUT='' CLAUDE_STDERR='HTTP 401 private auth detail' CLAUDE_EXIT=1
  output="$(PATH="$ADAPTER_TEST_DIR/bin:$PATH" ANYROUTER_TOKEN='sk-ant-secret-value' bash "$ROOT_DIR/scripts/adapters/claude.sh" \
    'https://anyrouter.top/v1' 'claude-test' 'Review code' 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && assert_contains "$output" 'message=authentication_error' &&
    assert_contains "$output" 'cli_exit_code=1' || {
    rm -rf "$ADAPTER_TEST_DIR"
    return 1
  }
  export CLAUDE_STDERR='unknown model private model detail'
  output="$(PATH="$ADAPTER_TEST_DIR/bin:$PATH" ANYROUTER_TOKEN='sk-ant-secret-value' bash "$ROOT_DIR/scripts/adapters/claude.sh" \
    'https://anyrouter.top/v1' 'claude-test' 'Review code' 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && assert_contains "$output" 'message=model_or_protocol_error' &&
    assert_contains "$output" 'cli_exit_code=1' &&
    assert_not_contains "$output" 'private model detail' || {
    rm -rf "$ADAPTER_TEST_DIR"
    return 1
  }
  export CLAUDE_STDERR='API Error: 404 private unsupported alias detail'
  output="$(PATH="$ADAPTER_TEST_DIR/bin:$PATH" ANYROUTER_TOKEN='sk-ant-secret-value' bash "$ROOT_DIR/scripts/adapters/claude.sh" \
    'https://anyrouter.top/v1' 'fable[1m]' 'Review code' 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && assert_contains "$output" 'status=invalid' &&
    assert_contains "$output" 'message=model_or_protocol_error' &&
    assert_contains "$output" 'cli_exit_code=1' &&
    assert_not_contains "$output" 'private unsupported alias detail' || {
    rm -rf "$ADAPTER_TEST_DIR"
    return 1
  }
  export CLAUDE_STDERR='API Error: 当前 API 不支持所选模型 fable[1m]'
  output="$(PATH="$ADAPTER_TEST_DIR/bin:$PATH" ANYROUTER_TOKEN='sk-ant-secret-value' bash "$ROOT_DIR/scripts/adapters/claude.sh" \
    'https://anyrouter.top/v1' 'fable[1m]' 'Review code' 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && assert_contains "$output" 'status=invalid' &&
    assert_contains "$output" 'message=model_or_protocol_error' &&
    assert_contains "$output" 'cli_exit_code=1' &&
    assert_not_contains "$output" '当前 API 不支持所选模型'
  local assertion_status=$?
  rm -rf "$ADAPTER_TEST_DIR"
  return "$assertion_status"
}

test_claude_adapter_passes_alias_through_untouched() {
  setup_adapter_fixture || return
  write_fake_claude
  export CLAUDE_STDOUT='Use a bounded queue.' CLAUDE_STDERR='' CLAUDE_EXIT=0
  local output status
  output="$(PATH="$ADAPTER_TEST_DIR/bin:$PATH" ANYROUTER_TOKEN='sk-ant-secret-value' bash "$ROOT_DIR/scripts/adapters/claude.sh"     'https://anyrouter.top/v1' 'fable[1m]' 'Review code' 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && assert_contains "$output" 'status=success' &&
    grep -q -- '--model fable\[1m\]' "$ADAPTER_TEST_DIR/claude.call" &&
    grep -q '^ANTHROPIC_DEFAULT_FABLE_MODEL=$' "$ADAPTER_TEST_DIR/claude.call" &&
    grep -q '^ANTHROPIC_DEFAULT_OPUS_MODEL=$' "$ADAPTER_TEST_DIR/claude.call"
  local assertion_status=$?
  rm -rf "$ADAPTER_TEST_DIR"
  return "$assertion_status"
}

test_claude_adapter_maps_full_id_to_1m_alias() {
  setup_adapter_fixture || return
  write_fake_claude
  export CLAUDE_STDOUT='Use a bounded queue.' CLAUDE_STDERR='' CLAUDE_EXIT=0
  local output status
  output="$(PATH="$ADAPTER_TEST_DIR/bin:$PATH" ANYROUTER_TOKEN='sk-ant-secret-value' bash "$ROOT_DIR/scripts/adapters/claude.sh"     'https://anyrouter.top/v1' 'claude-fable-5' 'Review code' 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && assert_contains "$output" 'status=success' &&
    grep -q -- '--model fable\[1m\]' "$ADAPTER_TEST_DIR/claude.call" &&
    grep -q '^ANTHROPIC_DEFAULT_FABLE_MODEL=claude-fable-5\[1M\]$' "$ADAPTER_TEST_DIR/claude.call" || {
    rm -rf "$ADAPTER_TEST_DIR"; return 1; }
  output="$(PATH="$ADAPTER_TEST_DIR/bin:$PATH" ANYROUTER_TOKEN='sk-ant-secret-value' bash "$ROOT_DIR/scripts/adapters/claude.sh"     'https://anyrouter.top/v1' 'claude-sonnet-5-5-20260301' 'Review code' 2>&1)"
  status=$?
  [ "$status" -eq 0 ] &&
    grep -q -- '--model sonnet\[1m\]' "$ADAPTER_TEST_DIR/claude.call" &&
    grep -q '^ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5-5-20260301\[1M\]$' "$ADAPTER_TEST_DIR/claude.call"
  local assertion_status=$?
  rm -rf "$ADAPTER_TEST_DIR"
  return "$assertion_status"
}

test_claude_adapter_rate_limit_is_safe() {
  setup_adapter_fixture || return
  write_fake_claude
  export CLAUDE_STDOUT='' CLAUDE_STDERR='HTTP 429 private upstream response' CLAUDE_EXIT=1
  local output status
  output="$(PATH="$ADAPTER_TEST_DIR/bin:$PATH" HOME="$ADAPTER_TEST_DIR/original-home" \
    ANYROUTER_TOKEN=\'sk-ant-secret-value\' bash "$ROOT_DIR/scripts/adapters/claude.sh" 'https://anyrouter.top/v1' \
    'claude-test' 'Review code' 2>&1)"
  status=$?
  rm -rf "$ADAPTER_TEST_DIR"
  [ "$status" -eq 0 ] && assert_contains "$output" 'status=rate_limited' &&
    assert_contains "$output" 'http_code=429' &&
    assert_contains "$output" 'cli_exit_code=1' &&
    assert_not_contains "$output" 'private upstream response'
}

test_claude_adapter_service_unavailable_is_capacity_limited() {
  setup_adapter_fixture || return
  write_fake_claude
  export CLAUDE_STDOUT='' CLAUDE_STDERR='HTTP 503 Service Unavailable private upstream response' CLAUDE_EXIT=1
  local output status
  output="$(PATH="$ADAPTER_TEST_DIR/bin:$PATH" ANYROUTER_TOKEN='sk-ant-secret-value' bash "$ROOT_DIR/scripts/adapters/claude.sh" \
    'https://anyrouter.top/v1' 'claude-fable-5[1M]' 'Review code' 2>&1)"
  status=$?
  rm -rf "$ADAPTER_TEST_DIR"
  [ "$status" -eq 0 ] && assert_contains "$output" 'status=rate_limited' &&
    assert_contains "$output" 'http_code=503' &&
    assert_contains "$output" 'message=capacity_limited' &&
    assert_not_contains "$output" 'private upstream response'
}

test_claude_adapter_timeout_is_retryable() {
  setup_adapter_fixture || return
  cat > "$ADAPTER_TEST_DIR/bin/claude" <<'SH'
#!/usr/bin/env bash
/usr/bin/sleep 3
printf '%s\n' 'late response that must not be accepted'
SH
  chmod +x "$ADAPTER_TEST_DIR/bin/claude"
  local output status start_epoch elapsed
  start_epoch="$(date +%s)"
  output="$(PATH="$ADAPTER_TEST_DIR/bin:$PATH" HOME="$ADAPTER_TEST_DIR/original-home" \
    REQUEST_TIMEOUT_SEC=1 ANYROUTER_TOKEN='sk-ant-secret-value' bash "$ROOT_DIR/scripts/adapters/claude.sh" \
    'https://anyrouter.top/v1' 'claude-test' 'Review code' 2>&1)"
  status=$?
  elapsed=$(( $(date +%s) - start_epoch ))
  rm -rf "$ADAPTER_TEST_DIR"
  [ "$status" -eq 0 ] && [ "$elapsed" -le 2 ] &&
    assert_contains "$output" 'status=retryable' &&
    assert_contains "$output" 'message=request_timeout' &&
    assert_contains "$output" 'cli_exit_code=124' &&
    assert_not_contains "$output" 'late response' &&
    assert_not_contains "$output" 'sk-ant-secret-value'
}

test_claude_adapter_timeout_classifies_model_error() {
  setup_adapter_fixture || return
  cat > "$ADAPTER_TEST_DIR/bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'unknown model fable[1m] private model detail' >&2
/usr/bin/sleep 3
SH
  chmod +x "$ADAPTER_TEST_DIR/bin/claude"
  local output status start_epoch elapsed
  start_epoch="$(date +%s)"
  output="$(PATH="$ADAPTER_TEST_DIR/bin:$PATH" HOME="$ADAPTER_TEST_DIR/original-home" \
    REQUEST_TIMEOUT_SEC=1 ANYROUTER_TOKEN='sk-ant-secret-value' bash "$ROOT_DIR/scripts/adapters/claude.sh" \
    'https://anyrouter.top/v1' 'fable[1m]' 'Review code' 2>&1)"
  status=$?
  elapsed=$(( $(date +%s) - start_epoch ))
  rm -rf "$ADAPTER_TEST_DIR"
  [ "$status" -eq 0 ] && [ "$elapsed" -le 2 ] &&
    assert_contains "$output" 'status=invalid' &&
    assert_contains "$output" 'http_code=000' &&
    assert_contains "$output" 'message=model_or_protocol_error' &&
    assert_contains "$output" 'cli_exit_code=124' &&
    assert_not_contains "$output" 'private model detail'
}

test_gpt_adapter_structured_errors_are_safe_and_distinct() {
  setup_adapter_fixture || return
  write_fake_codex
  local output status

  export CODEX_TEST_DIR="$ADAPTER_TEST_DIR" CODEX_EXIT=1 CODEX_STDOUT='{"type":"turn.failed","error":{"status_code":503,"message":"private upstream detail"}}' CODEX_STDERR=''
  output="$(PATH="$ADAPTER_TEST_DIR/bin:$PATH" ANYROUTER_TOKEN='sk-ant-secret-value' \
    bash "$ROOT_DIR/scripts/adapters/gpt.sh" \
    'https://anyrouter.top/v1' 'gpt-test' 'Review code' 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && assert_contains "$output" 'status=retryable' &&
    assert_contains "$output" 'http_code=503' &&
    assert_contains "$output" 'message=upstream_error' &&
    assert_not_contains "$output" 'private upstream detail' || {
      rm -rf "$ADAPTER_TEST_DIR"
      return 1
    }

  export CODEX_STDOUT='{"type":"error","message":"failed to load configuration private config detail"}' CODEX_STDERR=''
  output="$(PATH="$ADAPTER_TEST_DIR/bin:$PATH" ANYROUTER_TOKEN='sk-ant-secret-value' \
    bash "$ROOT_DIR/scripts/adapters/gpt.sh" \
    'https://anyrouter.top/v1' 'gpt-test' 'Review code' 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && assert_contains "$output" 'status=invalid' &&
    assert_contains "$output" 'message=cli_configuration_error' &&
    assert_not_contains "$output" 'private config detail' || {
      rm -rf "$ADAPTER_TEST_DIR"
      return 1
    }

  export CODEX_STDOUT='{"type":"error","message":"stream disconnected before completion private stream detail","request":{"prompt":"Explain HTTP 429 handling"}}' CODEX_STDERR='Echoed prompt: Explain HTTP 429 handling, unauthorized errors, and failed to load configuration'
  output="$(PATH="$ADAPTER_TEST_DIR/bin:$PATH" ANYROUTER_TOKEN='sk-ant-secret-value' \
    bash "$ROOT_DIR/scripts/adapters/gpt.sh" \
    'https://anyrouter.top/v1' 'gpt-test' 'Review code' 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && assert_contains "$output" 'status=retryable' &&
    assert_contains "$output" 'http_code=000' &&
    assert_contains "$output" 'message=response_stream_error' &&
    assert_not_contains "$output" 'private stream detail' &&
    assert_not_contains "$output" 'sk-ant-secret-value'
  local assertion_status=$?
  rm -rf "$ADAPTER_TEST_DIR"
  return "$assertion_status"
}

test_both_adapters_classify_fast_cli_startup_failures_safely() {
  local adapter command_name case_line expected exit_code output status
  for adapter in claude gpt; do
    setup_adapter_fixture || return
    command_name=claude
    [ "$adapter" = gpt ] && command_name=codex
    cat > "$ADAPTER_TEST_DIR/bin/$command_name" <<'SH'
#!/usr/bin/env bash
printf '%s' "$CLI_TEST_STDERR" >&2
exit "$CLI_TEST_EXIT"
SH
    chmod +x "$ADAPTER_TEST_DIR/bin/$command_name"
    while IFS='|' read -r exit_code expected case_line; do
      output="$(PATH="$ADAPTER_TEST_DIR/bin:$PATH" CLI_TEST_EXIT="$exit_code" CLI_TEST_STDERR="$case_line" \
        ANYROUTER_TOKEN=sk-ant-secret-value bash "$ROOT_DIR/scripts/adapters/$adapter.sh" \
        https://anyrouter.top/v1 "${adapter}-test" 'private prompt' 2>&1)"
      status=$?
      [ "$status" -eq 0 ] && assert_contains "$output" "message=$expected" &&
        assert_contains "$output" "cli_exit_code=$exit_code" &&
        assert_not_contains "$output" "$case_line" &&
        assert_not_contains "$output" 'private prompt' &&
        assert_not_contains "$output" 'sk-ant-secret-value' || {
          rm -rf "$ADAPTER_TEST_DIR"
          return 1
        }
    done <<'CASES'
127|cli_command_unavailable|command not found private detail
126|cli_command_unavailable|permission denied private detail
2|cli_argument_error|unexpected argument --private-option
1|cli_configuration_error|failed to load configuration private detail
7|transport_error|TLS handshake failed could not resolve host private detail
1|transport_error|Unable to connect to API UNKNOWN_CERTIFICATE_VERIFICATION_ERROR private detail
CASES
    rm -rf "$ADAPTER_TEST_DIR"
  done
}

test_gpt_adapter_maps_codex_500_messages() {
  setup_adapter_fixture || return
  write_fake_codex
  local output
  export CODEX_TEST_DIR="$ADAPTER_TEST_DIR" CODEX_EXIT=1 CODEX_STDERR=''
  export CODEX_STDOUT='{"type":"turn.failed","error":{"message":"We’re currently experiencing high demand, which may cause temporary errors."}}'
  output="$(PATH="$ADAPTER_TEST_DIR/bin:$PATH" ANYROUTER_TOKEN='sk-ant-secret-value' \
    bash "$ROOT_DIR/scripts/adapters/gpt.sh" 'https://anyrouter.top/v1' 'gpt-test' 'Review code' 2>&1)"
  assert_contains "$output" 'status=retryable' && assert_contains "$output" 'http_code=500' &&
    assert_contains "$output" 'message=upstream_error' || { rm -rf "$ADAPTER_TEST_DIR"; return 1; }
  export CODEX_STDOUT='{"type":"error","message":"unexpected status 502 Bad Gateway: private body"}'
  output="$(PATH="$ADAPTER_TEST_DIR/bin:$PATH" ANYROUTER_TOKEN='sk-ant-secret-value' \
    bash "$ROOT_DIR/scripts/adapters/gpt.sh" 'https://anyrouter.top/v1' 'gpt-test' 'Review code' 2>&1)"
  assert_contains "$output" 'http_code=502' && assert_contains "$output" 'message=upstream_error' &&
    assert_not_contains "$output" 'private body'
  local assertion_status=$?
  rm -rf "$ADAPTER_TEST_DIR"
  return "$assertion_status"
}

run_adapter_tests() {
  run_case "GPT adapter maps Codex's fixed 500 message and 'unexpected status' to real HTTP codes" test_gpt_adapter_maps_codex_500_messages
  run_case "GPT adapter uses an isolated token-free Codex Responses provider" test_gpt_adapter_success_and_json
  run_case "GPT Codex adapter maps 429 without exposing CLI output" test_gpt_adapter_rate_limit
  run_case "GPT Codex adapter safely classifies structured upstream and stream errors" test_gpt_adapter_structured_errors_are_safe_and_distinct
  run_case "GPT Codex adapter maps an explicit missing model to invalid" test_gpt_adapter_invalid_model
  run_case "GPT Codex adapter distinguishes authentication failures" test_gpt_adapter_authentication_error_is_distinct
  run_case "GPT Codex adapter maps request configuration errors" test_gpt_adapter_request_configuration_error
  run_case "GPT Codex adapter maps transport failure to retryable" test_gpt_adapter_network_failure
  run_case "GPT Codex adapter bounds a blocked request with timeout" test_gpt_adapter_timeout_is_retryable
  run_case "Claude adapter uses an isolated HOME and root base URL" test_claude_adapter_isolated_success
  run_case "Claude adapter maps 429 without exposing CLI output" test_claude_adapter_rate_limit_is_safe
  run_case "Claude adapter maps 503 capacity failures without exposing CLI output" test_claude_adapter_service_unavailable_is_capacity_limited
  run_case "Claude adapter distinguishes authentication and model failures" test_claude_adapter_error_categories_are_distinct
  run_case "Claude adapter passes bracketed aliases through untouched" test_claude_adapter_passes_alias_through_untouched
  run_case "Claude adapter maps a full model id to a 1M alias plus default-model env" test_claude_adapter_maps_full_id_to_1m_alias
  run_case "Claude adapter bounds a blocked CLI call with timeout" test_claude_adapter_timeout_is_retryable
  run_case "Claude adapter classifies model errors captured before timeout" test_claude_adapter_timeout_classifies_model_error
  run_case "both CLI adapters safely classify fast local startup failures" test_both_adapters_classify_fast_cli_startup_failures_safely
}

setup_worker_fixture() {
  with_common || return
  WORKER_TEST_DIR="$(mktemp -d)" || return
  mkdir -p "$WORKER_TEST_DIR/bin"
  WORKER_RESULTS="$WORKER_TEST_DIR/results"
  WORKER_COUNTER="$WORKER_TEST_DIR/counter"
  WORKER_PROMPTS="$WORKER_TEST_DIR/prompts.txt"
  WORKER_SLEEPS="$WORKER_TEST_DIR/sleeps.log"
  WORKER_EMAIL="$WORKER_TEST_DIR/email.log"
  printf '# ignored\n\nReview this bounded queue implementation and identify one correctness risk.\n' > "$WORKER_PROMPTS"
  export WORKER_TEST_DIR WORKER_RESULTS WORKER_COUNTER WORKER_PROMPTS WORKER_SLEEPS WORKER_EMAIL
cat > "$WORKER_TEST_DIR/bin/fake-adapter" <<'SH'
#!/usr/bin/env bash
count=0
if [ -f "$WORKER_COUNTER" ]; then count="$(cat "$WORKER_COUNTER")"; fi
count=$((count + 1))
printf '%s\n' "$count" > "$WORKER_COUNTER"
result="$(sed -n "${count}p" "$WORKER_RESULTS")"
result="${result:-success}"
status="${result%%|*}"
message=test_result
[ "$result" = "$status" ] || message="${result#*|}"
if [ "$#" -ge 4 ]; then model="$3"; prompt="$4"; else model="$2"; prompt="$3"; fi
printf '%s\n' "$model" >> "$WORKER_TEST_DIR/model.log"
printf '%s\n' "$prompt" >> "$WORKER_TEST_DIR/prompt.log"
printf 'ANYROUTER_TOKEN=%s ANYROUTER_TOKENS=%s GITHUB_TOKEN=%s QQ_EMAIL=%s QQ_SMTP_AUTH_CODE=%s\n' \
  "${ANYROUTER_TOKEN+x}" "${ANYROUTER_TOKENS+x}" "${GITHUB_TOKEN+x}" \
  "${QQ_EMAIL+x}" "${QQ_SMTP_AUTH_CODE+x}" \
  >> "$WORKER_TEST_DIR/adapter.env"
printf 'status=%s\nhttp_code=200\nelapsed_sec=0\ncli_exit_code=%s\nmessage=%s\n' \
  "$status" "${FAKE_CLI_EXIT_CODE:-0}" "$message"
SH
  cat > "$WORKER_TEST_DIR/bin/record-sleep" <<'SH'
#!/usr/bin/env bash
printf 'sleep=%s\n' "$1" >> "$WORKER_SLEEPS"
SH
  chmod +x "$WORKER_TEST_DIR/bin/fake-adapter" "$WORKER_TEST_DIR/bin/record-sleep"
}

run_test_worker() {
  local pool="$1" model="$2" state_file="$3" iterations="$4"
  PATH="$WORKER_TEST_DIR/bin:$PATH" \
  ADAPTER_COMMAND="$WORKER_TEST_DIR/bin/fake-adapter" \
  SLEEP_COMMAND="$WORKER_TEST_DIR/bin/record-sleep" \
  PROMPTS_FILE="$WORKER_PROMPTS" MAX_ITERATIONS="$iterations" MAX_DURATION_SEC=60 \
  PROBE_MIN_SEC=3 PROBE_MAX_SEC=10 KEEPALIVE_MIN_SEC=30 KEEPALIVE_MAX_SEC=120 \
  EMAIL_LOG="$WORKER_EMAIL" CHAIN_ID='chain-test' CHAIN_STARTED_EPOCH=123 \
    ANYROUTER_TOKEN='sk-ant-secret-worker' bash "$ROOT_DIR/scripts/pool-worker.sh" "$pool" \
      'https://anyrouter.top/v1' "$model" "$state_file" 2>&1
}

test_worker_429_then_success_uses_both_intervals() {
  setup_worker_fixture || return
  printf 'rate_limited\nsuccess\n' > "$WORKER_RESULTS"
  local state_file output status first_sleep sleep_count
  state_file="$WORKER_TEST_DIR/gpt.state"
  output="$(run_test_worker gpt gpt-test "$state_file" 2)"
  status=$?
  first_sleep="$(sed -n '1s/^sleep=//p' "$WORKER_SLEEPS")"
  sleep_count="$(wc -l < "$WORKER_SLEEPS")"
  [ "$status" -eq 0 ] && assert_eq keepalive "$(read_state_value "$state_file" phase)" &&
    assert_eq true "$(read_state_value "$state_file" notified)" &&
    [ "$first_sleep" -ge 3 ] && [ "$first_sleep" -le 10 ] &&
    assert_eq 1 "$sleep_count" &&
    assert_eq 1 "$(grep -c '^gpt|success$' "$WORKER_EMAIL")" &&
    assert_eq 'Review this bounded queue implementation and identify one correctness risk.' "$(head -n 1 "$WORKER_TEST_DIR/prompt.log")" &&
    assert_contains "$output" '[GPT池] 阶段=探测中 模型=gpt-test 状态=限流 HTTP=200 耗时=0秒 CLI退出码=0 原因=测试结果' &&
    [[ "$output" =~ \[GPT池\]\ 阶段=探测中\ 下次等待=([3-9]|10)秒 ]] &&
    assert_contains "$output" '[GPT池] 阶段=保活中 模型=gpt-test 状态=成功 HTTP=200 耗时=0秒 CLI退出码=0 原因=测试结果' &&
    assert_not_contains "$output" 'Review this bounded queue' &&
    assert_not_contains "$output" 'sk-ant-secret-worker' &&
    ! grep -q 'sk-ant-secret-worker' "$state_file"
  local assertion_status=$?
  rm -rf "$WORKER_TEST_DIR"
  return "$assertion_status"
}

test_worker_keepalive_429_returns_to_probing() {
  setup_worker_fixture || return
  printf 'rate_limited\n' > "$WORKER_RESULTS"
  local state_file output status
  state_file="$WORKER_TEST_DIR/claude.state"
  printf 'phase=keepalive\nmodel=claude-test\nnotified=true\nchain_id=chain-test\nchain_started_epoch=123\n' > "$state_file"
  output="$(run_test_worker claude claude-test "$state_file" 1)"
  status=$?
  [ "$status" -eq 0 ] && assert_eq probing "$(read_state_value "$state_file" phase)" &&
    assert_eq false "$(read_state_value "$state_file" notified)" &&
    [ ! -e "$WORKER_SLEEPS" ] &&
    assert_not_contains "$output" 'sk-ant-secret-worker'
  local assertion_status=$?
  rm -rf "$WORKER_TEST_DIR"
  return "$assertion_status"
}

test_worker_retryable_keeps_keepalive_phase() {
  setup_worker_fixture || return
  printf 'retryable\n' > "$WORKER_RESULTS"
  local state_file output status
  state_file="$WORKER_TEST_DIR/gpt.state"
  printf 'phase=keepalive\nmodel=gpt-test\nnotified=true\nchain_id=chain-test\nchain_started_epoch=123\n' > "$state_file"
  output="$(run_test_worker gpt gpt-test "$state_file" 1)"
  status=$?
  [ "$status" -eq 0 ] && assert_eq keepalive "$(read_state_value "$state_file" phase)" &&
    assert_eq true "$(read_state_value "$state_file" notified)" &&
    [ ! -e "$WORKER_SLEEPS" ]
  local assertion_status=$?
  rm -rf "$WORKER_TEST_DIR"
  return "$assertion_status"
}

test_worker_success_notification_is_deduplicated() {
  setup_worker_fixture || return
  printf 'success\nsuccess\n' > "$WORKER_RESULTS"
  local state_file output status
  state_file="$WORKER_TEST_DIR/claude.state"
  output="$(run_test_worker claude claude-test "$state_file" 2)"
  status=$?
  [ "$status" -eq 0 ] && assert_eq 1 "$(grep -c '^claude|success$' "$WORKER_EMAIL")"
  local assertion_status=$?
  rm -rf "$WORKER_TEST_DIR"
  return "$assertion_status"
}

test_worker_invalid_becomes_config_error() {
  setup_worker_fixture || return
  printf 'invalid|authentication_error\n' > "$WORKER_RESULTS"
  local state_file output status
  state_file="$WORKER_TEST_DIR/gpt.state"
  output="$(run_test_worker gpt gpt-test "$state_file" 3)"
  status=$?
  [ "$status" -eq 0 ] && assert_eq config_error "$(read_state_value "$state_file" phase)" &&
    assert_eq 1 "$(grep -c '^gpt|config_error$' "$WORKER_EMAIL")" &&
    [ ! -e "$WORKER_SLEEPS" ] && assert_not_contains "$output" 'sk-ant-secret-worker'
  local assertion_status=$?
  rm -rf "$WORKER_TEST_DIR"
  return "$assertion_status"
}

test_worker_invalid_tries_next_ranked_candidate() {
  setup_worker_fixture || return
  printf 'invalid|model_or_protocol_error\nsuccess\n' > "$WORKER_RESULTS"
  printf 'gpt-new\ngpt-fallback\n' > "$WORKER_TEST_DIR/candidates"
  local state_file output status
  state_file="$WORKER_TEST_DIR/gpt.state"
  output="$(PATH="$WORKER_TEST_DIR/bin:$PATH" ADAPTER_COMMAND="$WORKER_TEST_DIR/bin/fake-adapter" \
    SLEEP_COMMAND="$WORKER_TEST_DIR/bin/record-sleep" PROMPTS_FILE="$WORKER_PROMPTS" \
    MODEL_CANDIDATES_FILE="$WORKER_TEST_DIR/candidates" MAX_ITERATIONS=2 MAX_DURATION_SEC=60 \
    EMAIL_LOG="$WORKER_EMAIL" CHAIN_ID=chain-test CHAIN_STARTED_EPOCH=123 \
    ANYROUTER_TOKEN='sk-ant-secret-worker' bash "$ROOT_DIR/scripts/pool-worker.sh" gpt \
      'https://anyrouter.top/v1' gpt-new "$state_file" 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && assert_eq keepalive "$(read_state_value "$state_file" phase)" &&
    assert_eq gpt-fallback "$(read_state_value "$state_file" model)" &&
    assert_eq gpt-new "$(sed -n '1p' "$WORKER_TEST_DIR/model.log")" &&
    assert_eq gpt-fallback "$(sed -n '2p' "$WORKER_TEST_DIR/model.log")" &&
    assert_eq 1 "$(grep -c '^gpt|success$' "$WORKER_EMAIL")" &&
    ! grep -q '^gpt|config_error$' "$WORKER_EMAIL" &&
    assert_contains "$output" '[GPT池] 阶段=探测中 模型=gpt-new 状态=无效 HTTP=200 耗时=0秒 CLI退出码=0 原因=模型不存在或协议不兼容' &&
    assert_contains "$output" '[GPT池] 阶段=保活中 模型=gpt-fallback 状态=成功 HTTP=200 耗时=0秒 CLI退出码=0 原因=测试结果' &&
    assert_not_contains "$output" 'sk-ant-secret-worker'
  local assertion_status=$?
  rm -rf "$WORKER_TEST_DIR"
  return "$assertion_status"
}

test_worker_rediscover_after_inherited_model_becomes_invalid() {
  setup_worker_fixture || return
  printf 'invalid|model_or_protocol_error\nsuccess\n' > "$WORKER_RESULTS"
  printf 'gpt-inherited\n' > "$WORKER_TEST_DIR/candidates"
  cat > "$WORKER_TEST_DIR/bin/fake-discover" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$WORKER_TEST_DIR/discovery.calls"
printf '%s\n' gpt-current gpt-fallback
SH
  chmod +x "$WORKER_TEST_DIR/bin/fake-discover"
  local state_file output status
  state_file="$WORKER_TEST_DIR/gpt.state"
  output="$(PATH="$WORKER_TEST_DIR/bin:$PATH" ADAPTER_COMMAND="$WORKER_TEST_DIR/bin/fake-adapter" \
    SLEEP_COMMAND="$WORKER_TEST_DIR/bin/record-sleep" PROMPTS_FILE="$WORKER_PROMPTS" \
    MODEL_CANDIDATES_FILE="$WORKER_TEST_DIR/candidates" MODEL_DISCOVERY_COMMAND="$WORKER_TEST_DIR/bin/fake-discover" \
    ALLOW_MODEL_REDISCOVERY=true MAX_ITERATIONS=2 MAX_DURATION_SEC=60 EMAIL_LOG="$WORKER_EMAIL" \
    CHAIN_ID=chain-test CHAIN_STARTED_EPOCH=123 ANYROUTER_TOKEN='sk-ant-secret-worker' bash "$ROOT_DIR/scripts/pool-worker.sh" \
      gpt 'https://anyrouter.top/v1' gpt-inherited "$state_file" 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && assert_eq keepalive "$(read_state_value "$state_file" phase)" &&
    assert_eq gpt-current "$(read_state_value "$state_file" model)" &&
    assert_eq gpt "$(cat "$WORKER_TEST_DIR/discovery.calls")" &&
    assert_not_contains "$output" 'sk-ant-secret-worker'
  local assertion_status=$?
  rm -rf "$WORKER_TEST_DIR"
  return "$assertion_status"
}

test_worker_dynamic_crlf_candidate_reaches_adapter_without_carriage_return() {
  setup_worker_fixture || return
  printf 'invalid|model_or_protocol_error\nsuccess\n' > "$WORKER_RESULTS"
  printf 'gpt-inherited\n' > "$WORKER_TEST_DIR/candidates"
  cat > "$WORKER_TEST_DIR/bin/fake-discover-crlf" <<'SH'
#!/usr/bin/env bash
printf 'gpt-test\r\n'
SH
  chmod +x "$WORKER_TEST_DIR/bin/fake-discover-crlf"
  local state_file output status
  state_file="$WORKER_TEST_DIR/gpt.state"
  output="$(PATH="$WORKER_TEST_DIR/bin:$PATH" ADAPTER_COMMAND="$WORKER_TEST_DIR/bin/fake-adapter" \
    SLEEP_COMMAND="$WORKER_TEST_DIR/bin/record-sleep" PROMPTS_FILE="$WORKER_PROMPTS" \
    MODEL_CANDIDATES_FILE="$WORKER_TEST_DIR/candidates" MODEL_DISCOVERY_COMMAND="$WORKER_TEST_DIR/bin/fake-discover-crlf" \
    ALLOW_MODEL_REDISCOVERY=true MAX_ITERATIONS=2 MAX_DURATION_SEC=60 EMAIL_LOG="$WORKER_EMAIL" \
    CHAIN_ID=chain-test CHAIN_STARTED_EPOCH=123 ANYROUTER_TOKEN='sk-ant-secret-worker' bash "$ROOT_DIR/scripts/pool-worker.sh" \
      gpt 'https://anyrouter.top/v1' gpt-inherited "$state_file" 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && assert_eq gpt-test "$(sed -n '2p' "$WORKER_TEST_DIR/model.log")" &&
    assert_eq gpt-test "$(read_state_value "$state_file" model)" &&
    assert_not_contains "$output" 'sk-ant-secret-worker'
  local assertion_status=$?
  rm -rf "$WORKER_TEST_DIR"
  return "$assertion_status"
}

test_worker_authentication_error_never_advances_candidate() {
  setup_worker_fixture || return
  printf 'invalid|authentication_error\nsuccess\n' > "$WORKER_RESULTS"
  printf 'gpt-first\ngpt-must-not-run\n' > "$WORKER_TEST_DIR/candidates"
  local state_file output status
  state_file="$WORKER_TEST_DIR/gpt.state"
  output="$(PATH="$WORKER_TEST_DIR/bin:$PATH" ADAPTER_COMMAND="$WORKER_TEST_DIR/bin/fake-adapter" \
    SLEEP_COMMAND="$WORKER_TEST_DIR/bin/record-sleep" PROMPTS_FILE="$WORKER_PROMPTS" \
    MODEL_CANDIDATES_FILE="$WORKER_TEST_DIR/candidates" MAX_ITERATIONS=2 MAX_DURATION_SEC=60 \
    EMAIL_LOG="$WORKER_EMAIL" CHAIN_ID=chain-test CHAIN_STARTED_EPOCH=123 \
    ANYROUTER_TOKEN='sk-ant-secret-worker' bash "$ROOT_DIR/scripts/pool-worker.sh" gpt \
      'https://anyrouter.top/v1' gpt-first "$state_file" 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && assert_eq config_error "$(read_state_value "$state_file" phase)" &&
    assert_eq 1 "$(wc -l < "$WORKER_TEST_DIR/model.log")" &&
    assert_eq gpt-first "$(cat "$WORKER_TEST_DIR/model.log")" &&
    assert_not_contains "$output" 'sk-ant-secret-worker'
  local assertion_status=$?
  rm -rf "$WORKER_TEST_DIR"
  return "$assertion_status"
}

test_dual_pool_notifications_are_independent() {
  setup_worker_fixture || return
  local claude_adapter="$WORKER_TEST_DIR/bin/claude-success"
  local gpt_adapter="$WORKER_TEST_DIR/bin/gpt-rate-limited"
  local claude_state="$WORKER_TEST_DIR/claude.state"
  local gpt_state="$WORKER_TEST_DIR/gpt.state"
  local claude_pid gpt_pid claude_status=0 gpt_status=0 output=''
  cat > "$claude_adapter" <<'SH'
#!/usr/bin/env bash
printf 'claude-call\n' >> "$WORKER_TEST_DIR/pool-calls.log"
printf 'status=success\nhttp_code=200\nelapsed_sec=0\ncli_exit_code=0\nmessage=non_empty_response\n'
SH
  cat > "$gpt_adapter" <<'SH'
#!/usr/bin/env bash
printf 'gpt-call\n' >> "$WORKER_TEST_DIR/pool-calls.log"
printf 'status=rate_limited\nhttp_code=429\nelapsed_sec=0\ncli_exit_code=1\nmessage=capacity_limited\n'
SH
  chmod +x "$claude_adapter" "$gpt_adapter"
  : > "$WORKER_TEST_DIR/pool-calls.log"
  PATH="$WORKER_TEST_DIR/bin:$PATH" PROMPTS_FILE="$WORKER_PROMPTS" \
    SLEEP_COMMAND=/usr/bin/true MAX_DURATION_SEC=60 MAX_ITERATIONS=1 \
    EMAIL_LOG="$WORKER_EMAIL" CHAIN_ID=chain-test CHAIN_STARTED_EPOCH=123 \
    ANYROUTER_TOKEN=sk-ant-secret-worker ADAPTER_COMMAND="$claude_adapter" \
    bash "$ROOT_DIR/scripts/pool-worker.sh" claude https://anyrouter.top/v1 \
      claude-test "$claude_state" > "$WORKER_TEST_DIR/claude.out" 2>&1 &
  claude_pid=$!
  PATH="$WORKER_TEST_DIR/bin:$PATH" PROMPTS_FILE="$WORKER_PROMPTS" \
    SLEEP_COMMAND=/usr/bin/true MAX_DURATION_SEC=60 MAX_ITERATIONS=2 \
    EMAIL_LOG="$WORKER_EMAIL" CHAIN_ID=chain-test CHAIN_STARTED_EPOCH=123 \
    ANYROUTER_TOKEN=sk-ant-secret-worker ADAPTER_COMMAND="$gpt_adapter" \
    bash "$ROOT_DIR/scripts/pool-worker.sh" gpt https://anyrouter.top/v1 \
      gpt-test "$gpt_state" > "$WORKER_TEST_DIR/gpt.out" 2>&1 &
  gpt_pid=$!
  wait "$claude_pid" || claude_status=$?
  wait "$gpt_pid" || gpt_status=$?
  output="$(cat "$WORKER_TEST_DIR/claude.out" "$WORKER_TEST_DIR/gpt.out")"
  [ "$claude_status" -eq 0 ] && [ "$gpt_status" -eq 0 ] &&
    assert_eq keepalive "$(read_state_value "$claude_state" phase)" &&
    assert_eq true "$(read_state_value "$claude_state" notified)" &&
    assert_eq probing "$(read_state_value "$gpt_state" phase)" &&
    assert_eq false "$(read_state_value "$gpt_state" notified)" &&
    assert_eq 1 "$(grep -c '^claude|success$' "$WORKER_EMAIL")" &&
    [ "$(grep -c '^gpt|success$' "$WORKER_EMAIL" 2>/dev/null || true)" -eq 0 ] &&
    assert_eq 2 "$(grep -c '^gpt-call$' "$WORKER_TEST_DIR/pool-calls.log")" &&
    assert_contains "$output" '[Claude池] 阶段=保活中' &&
    assert_contains "$output" '[GPT池] 阶段=探测中' &&
    assert_not_contains "$output" 'sk-ant-secret-worker'
  local assertion_status=$?
  rm -rf "$WORKER_TEST_DIR"
  return "$assertion_status"
}

test_worker_logs_only_integer_cli_exit_code() {
  setup_worker_fixture || return
  printf 'success\n' > "$WORKER_RESULTS"
  local state_file output status
  state_file="$WORKER_TEST_DIR/gpt.state"
  output="$(FAKE_CLI_EXIT_CODE=not-a-number run_test_worker gpt gpt-test "$state_file" 1)"
  status=$?
  [ "$status" -eq 0 ] && grep -Eq '^\[GPT池\].*CLI退出码=0( |$)' <<< "$output" &&
    ! grep -Eq 'CLI退出码=[^0-9 ]' <<< "$output" &&
    assert_not_contains "$output" 'sk-ant-secret-worker'
  local assertion_status=$?
  rm -rf "$WORKER_TEST_DIR"
  return "$assertion_status"
}

test_worker_logs_bracketed_model_alias_without_stripping_it() {
  setup_worker_fixture || return
  printf 'success\n' > "$WORKER_RESULTS"
  local state_file output status
  state_file="$WORKER_TEST_DIR/claude.state"
  output="$(run_test_worker claude 'fable[1m]' "$state_file" 1)"
  status=$?
  [ "$status" -eq 0 ] &&
    assert_contains "$output" '模型=fable[1m]' &&
    assert_not_contains "$output" 'sk-ant-secret-worker'
  local assertion_status=$?
  rm -rf "$WORKER_TEST_DIR"
  return "$assertion_status"
}

test_worker_runs_non_executable_adapter_with_bash() {
  setup_worker_fixture || return
  local adapter="$WORKER_TEST_DIR/bin/non-executable-adapter"
  local state_file="$WORKER_TEST_DIR/gpt.state"
  local output status
  cat > "$adapter" <<'SH'
#!/usr/bin/env bash
printf 'status=success\nhttp_code=200\nelapsed_sec=0\ncli_exit_code=0\nmessage=non_empty_response\n'
SH
  chmod 0644 "$adapter"
  cat > "$WORKER_TEST_DIR/bin/env" <<'SH'
#!/usr/bin/env bash
args=("$@")
index=0
while [ "$index" -lt "${#args[@]}" ]; do
  case "${args[$index]}" in
    -u|--unset) index=$((index + 2)) ;;
    *=*) index=$((index + 1)) ;;
    --) index=$((index + 1)); break ;;
    *) break ;;
  esac
done
if [ "${args[$index]:-}" = "$NON_EXECUTABLE_ADAPTER" ]; then
  printf '%s: Permission denied\n' "$NON_EXECUTABLE_ADAPTER" >&2
  exit 126
fi
exec /usr/bin/env "$@"
SH
  chmod +x "$WORKER_TEST_DIR/bin/env"
  output="$(PATH="$WORKER_TEST_DIR/bin:$PATH" ADAPTER_COMMAND="$adapter" \
    NON_EXECUTABLE_ADAPTER="$adapter" \
    SLEEP_COMMAND="$WORKER_TEST_DIR/bin/record-sleep" PROMPTS_FILE="$WORKER_PROMPTS" \
    MAX_ITERATIONS=1 MAX_DURATION_SEC=60 EMAIL_LOG="$WORKER_EMAIL" \
    CHAIN_ID=chain-test CHAIN_STARTED_EPOCH=123 ANYROUTER_TOKEN=sk-ant-secret-worker \
    bash "$ROOT_DIR/scripts/pool-worker.sh" gpt https://anyrouter.top/v1 gpt-test "$state_file" 2>&1)"
  status=$?
  [ "$status" -eq 0 ] &&
    assert_eq keepalive "$(read_state_value "$state_file" phase)" &&
    assert_eq true "$(read_state_value "$state_file" notified)" &&
    assert_eq 1 "$(grep -c '^gpt|success$' "$WORKER_EMAIL")" &&
    assert_not_contains "$output" 'Permission denied' &&
    assert_not_contains "$output" 'sk-ant-secret-worker'
  local assertion_status=$?
  rm -rf "$WORKER_TEST_DIR"
  return "$assertion_status"
}

test_worker_adapter_receives_only_required_secret() {
  setup_worker_fixture || return
  printf 'success\n' > "$WORKER_RESULTS"
  local state_file output status
  state_file="$WORKER_TEST_DIR/gpt.state"
  output="$(ANYROUTER_TOKENS=present GITHUB_TOKEN=present QQ_EMAIL=present QQ_SMTP_AUTH_CODE=present \
    run_test_worker gpt gpt-test "$state_file" 1)"
  status=$?
  [ "$status" -eq 0 ] &&
    grep -q '^ANYROUTER_TOKEN=x ANYROUTER_TOKENS= GITHUB_TOKEN= QQ_EMAIL= QQ_SMTP_AUTH_CODE=$' "$WORKER_TEST_DIR/adapter.env" &&
    assert_not_contains "$output" 'sk-ant-secret-worker'
  local assertion_status=$?
  rm -rf "$WORKER_TEST_DIR"
  return "$assertion_status"
}

test_worker_smtp_failure_does_not_change_success() {
  setup_worker_fixture || return
  printf 'success\n' > "$WORKER_RESULTS"
  cat > "$WORKER_TEST_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
exit 7
SH
  chmod +x "$WORKER_TEST_DIR/bin/curl"
  local state_file output status
  state_file="$WORKER_TEST_DIR/claude.state"
  output="$(PATH="$WORKER_TEST_DIR/bin:$PATH" ADAPTER_COMMAND="$WORKER_TEST_DIR/bin/fake-adapter" \
    SLEEP_COMMAND="$WORKER_TEST_DIR/bin/record-sleep" PROMPTS_FILE="$WORKER_PROMPTS" \
    MAX_ITERATIONS=1 MAX_DURATION_SEC=60 QQ_EMAIL='test@qq.com' QQ_SMTP_AUTH_CODE='smtp-secret' \
    ANYROUTER_TOKEN='sk-ant-secret-worker' bash "$ROOT_DIR/scripts/pool-worker.sh" claude \
      'https://anyrouter.top/v1' claude-test "$state_file" 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && assert_eq keepalive "$(read_state_value "$state_file" phase)" &&
    assert_eq true "$(read_state_value "$state_file" notified)" &&
    assert_not_contains "$output" 'smtp-secret'
  local assertion_status=$?
  rm -rf "$WORKER_TEST_DIR"
  return "$assertion_status"
}

test_worker_max_iterations_exits_without_final_sleep() {
  setup_worker_fixture || return
  printf 'success\n' > "$WORKER_RESULTS"
  local state_file output status
  state_file="$WORKER_TEST_DIR/claude.state"
  output="$(run_test_worker claude claude-test "$state_file" 1)"
  status=$?
  [ "$status" -eq 0 ] && [ ! -e "$WORKER_SLEEPS" ] &&
    assert_eq keepalive "$(read_state_value "$state_file" phase)" &&
    assert_not_contains "$output" 'sk-ant-secret-worker'
  local assertion_status=$?
  rm -rf "$WORKER_TEST_DIR"
  return "$assertion_status"
}

test_state_value_reads_independent_files() {
  with_common || return
  local test_dir
  test_dir="$(mktemp -d)" || return
  printf 'phase=keepalive\nmodel=claude-test\nnotified=true\nchain_id=c\nchain_started_epoch=1\n' > "$test_dir/claude.state"
  printf 'phase=probing\nmodel=gpt-test\nnotified=false\nchain_id=c\nchain_started_epoch=1\n' > "$test_dir/gpt.state"
  assert_eq keepalive "$(read_state_value "$test_dir/claude.state" phase)" &&
    assert_eq probing "$(read_state_value "$test_dir/gpt.state" phase)"
  local status=$?
  rm -rf "$test_dir"
  return "$status"
}

test_worker_signal_writes_stopped() {
  setup_worker_fixture || return
  printf 'success\n' > "$WORKER_RESULTS"
  local state_file pid status
  state_file="$WORKER_TEST_DIR/gpt.state"
  PATH="$WORKER_TEST_DIR/bin:$PATH" ADAPTER_COMMAND="$WORKER_TEST_DIR/bin/fake-adapter" \
    SLEEP_COMMAND=/usr/bin/sleep PROMPTS_FILE="$WORKER_PROMPTS" MAX_DURATION_SEC=60 \
    PROBE_MIN_SEC=30 PROBE_MAX_SEC=30 KEEPALIVE_MIN_SEC=30 KEEPALIVE_MAX_SEC=30 \
    ANYROUTER_TOKEN='sk-ant-secret-worker' bash "$ROOT_DIR/scripts/pool-worker.sh" gpt \
      'https://anyrouter.top/v1' gpt-test "$state_file" >"$WORKER_TEST_DIR/worker.out" 2>&1 &
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$state_file" ] && [ "$(read_state_value "$state_file" phase 2>/dev/null || true)" = keepalive ] && break
    /usr/bin/sleep 0.1
  done
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid"
  status=$?
  [ "$status" -eq 0 ] && assert_eq stopped "$(read_state_value "$state_file" phase)"
  local assertion_status=$?
  rm -rf "$WORKER_TEST_DIR"
  return "$assertion_status"
}

test_worker_signal_stops_blocked_adapter() {
  setup_worker_fixture || return
  cat > "$WORKER_TEST_DIR/bin/blocking-adapter" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$WORKER_TEST_DIR/blocking-adapter.pid"
exec /usr/bin/sleep 30
SH
  chmod +x "$WORKER_TEST_DIR/bin/blocking-adapter"
  local state_file worker_pid adapter_pid='' exited=false status=0
  state_file="$WORKER_TEST_DIR/claude.state"
  PATH="$WORKER_TEST_DIR/bin:$PATH" ADAPTER_COMMAND="$WORKER_TEST_DIR/bin/blocking-adapter" \
    SLEEP_COMMAND=/usr/bin/sleep PROMPTS_FILE="$WORKER_PROMPTS" MAX_DURATION_SEC=60 \
    ANYROUTER_TOKEN='sk-ant-secret-worker' bash "$ROOT_DIR/scripts/pool-worker.sh" claude \
      'https://anyrouter.top/v1' claude-test "$state_file" >"$WORKER_TEST_DIR/worker.out" 2>&1 &
  worker_pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [ -s "$WORKER_TEST_DIR/blocking-adapter.pid" ]; then
      adapter_pid="$(cat "$WORKER_TEST_DIR/blocking-adapter.pid")"
      break
    fi
    /usr/bin/sleep 0.1
  done
  if [ -z "$adapter_pid" ]; then
    kill -KILL "$worker_pid" 2>/dev/null || true
    wait "$worker_pid" 2>/dev/null || true
    rm -rf "$WORKER_TEST_DIR"
    return 1
  fi

  kill -TERM "$worker_pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if ! kill -0 "$worker_pid" 2>/dev/null; then
      exited=true
      break
    fi
    /usr/bin/sleep 0.1
  done
  if [ "$exited" = true ]; then
    wait "$worker_pid" || status=$?
  else
    kill -KILL "$worker_pid" 2>/dev/null || true
    kill -KILL "$adapter_pid" 2>/dev/null || true
    wait "$worker_pid" 2>/dev/null || true
    status=124
  fi

  [ "$status" -eq 0 ] && assert_eq stopped "$(read_state_value "$state_file" phase)" &&
    ! kill -0 "$adapter_pid" 2>/dev/null
  local assertion_status=$?
  kill -KILL "$adapter_pid" 2>/dev/null || true
  rm -rf "$WORKER_TEST_DIR"
  return "$assertion_status"
}

test_worker_signal_stops_adapter_descendant_and_cleans_temp() {
  setup_worker_fixture || return
  cat > "$WORKER_TEST_DIR/bin/forking-adapter" <<'SH'
#!/usr/bin/env bash
adapter_tmp="$(mktemp -d)"
printf '%s\n' "$adapter_tmp" > "$WORKER_TEST_DIR/adapter.tmp"
trap 'rm -rf "$adapter_tmp"' EXIT INT TERM
/usr/bin/sleep 30 &
printf '%s\n' "$!" > "$WORKER_TEST_DIR/adapter-child.pid"
wait
SH
  chmod +x "$WORKER_TEST_DIR/bin/forking-adapter"
  local state_file worker_pid child_pid='' adapter_tmp='' exited=false status=0
  state_file="$WORKER_TEST_DIR/claude.state"
  PATH="$WORKER_TEST_DIR/bin:$PATH" ADAPTER_COMMAND="$WORKER_TEST_DIR/bin/forking-adapter" \
    SLEEP_COMMAND=/usr/bin/sleep PROMPTS_FILE="$WORKER_PROMPTS" MAX_DURATION_SEC=60 \
    ANYROUTER_TOKEN='sk-ant-secret-worker' bash "$ROOT_DIR/scripts/pool-worker.sh" \
      claude 'https://anyrouter.top/v1' claude-test "$state_file" >"$WORKER_TEST_DIR/worker.out" 2>&1 &
  worker_pid=$!
  for _ in {1..20}; do
    [ -s "$WORKER_TEST_DIR/adapter-child.pid" ] && child_pid="$(cat "$WORKER_TEST_DIR/adapter-child.pid")" && break
    /usr/bin/sleep 0.1
  done
  adapter_tmp="$(cat "$WORKER_TEST_DIR/adapter.tmp" 2>/dev/null || true)"
  [ -n "$child_pid" ] && [ -n "$adapter_tmp" ] || status=125
  kill -TERM "$worker_pid" 2>/dev/null || true
  for _ in {1..30}; do
    if ! kill -0 "$worker_pid" 2>/dev/null; then exited=true; break; fi
    /usr/bin/sleep 0.1
  done
  if [ "$exited" = true ]; then wait "$worker_pid" || status=$?; else status=124; fi
  [ "$status" -eq 0 ] && assert_eq stopped "$(read_state_value "$state_file" phase)" &&
    ! kill -0 "$child_pid" 2>/dev/null && [ ! -e "$adapter_tmp" ]
  local assertion_status=$?
  kill -KILL "$worker_pid" "$child_pid" 2>/dev/null || true
  wait "$worker_pid" 2>/dev/null || true
  rm -rf "$WORKER_TEST_DIR"
  return "$assertion_status"
}

test_worker_keepalive_off_finishes_after_notify() {
  setup_worker_fixture || return
  printf 'rate_limited\nsuccess\nsuccess\n' > "$WORKER_RESULTS"
  local state_file output status
  state_file="$WORKER_TEST_DIR/gpt.state"
  output="$(KEEPALIVE_SEC=0 PATH="$WORKER_TEST_DIR/bin:$PATH" ADAPTER_COMMAND="$WORKER_TEST_DIR/bin/fake-adapter" \
    SLEEP_COMMAND="$WORKER_TEST_DIR/bin/record-sleep" PROMPTS_FILE="$WORKER_PROMPTS" \
    MAX_ITERATIONS=5 MAX_DURATION_SEC=60 EMAIL_LOG="$WORKER_EMAIL" \
    ANYROUTER_TOKEN='sk-ant-secret-worker' bash "$ROOT_DIR/scripts/pool-worker.sh" gpt \
      'https://anyrouter.top/v1' gpt-test "$state_file" 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && assert_eq done "$(read_state_value "$state_file" phase)" &&
    assert_eq 2 "$(cat "$WORKER_COUNTER")" &&
    assert_eq 1 "$(wc -l < "$WORKER_SLEEPS")" &&
    assert_eq 1 "$(grep -c '^gpt|success$' "$WORKER_EMAIL")" &&
    assert_contains "$output" '[GPT池] 阶段=已完成'
  local assertion_status=$?
  rm -rf "$WORKER_TEST_DIR"
  return "$assertion_status"
}

test_worker_keepalive_sec_accepts_range_and_rejects_garbage() {
  setup_worker_fixture || return
  printf 'success\nsuccess\n' > "$WORKER_RESULTS"
  local state_file sleep_value bad_status=0
  state_file="$WORKER_TEST_DIR/claude.state"
  KEEPALIVE_SEC=7-7 PATH="$WORKER_TEST_DIR/bin:$PATH" ADAPTER_COMMAND="$WORKER_TEST_DIR/bin/fake-adapter" \
    SLEEP_COMMAND="$WORKER_TEST_DIR/bin/record-sleep" PROMPTS_FILE="$WORKER_PROMPTS" \
    MAX_ITERATIONS=2 MAX_DURATION_SEC=60 EMAIL_LOG="$WORKER_EMAIL" \
    ANYROUTER_TOKEN='sk-ant-secret-worker' bash "$ROOT_DIR/scripts/pool-worker.sh" claude \
      'https://anyrouter.top/v1' claude-test "$state_file" >/dev/null 2>&1
  sleep_value="$(sed -n '1s/^sleep=//p' "$WORKER_SLEEPS")"
  KEEPALIVE_SEC=abc ANYROUTER_TOKEN=x PROMPTS_FILE="$WORKER_PROMPTS" \
    bash "$ROOT_DIR/scripts/pool-worker.sh" claude 'https://anyrouter.top/v1' claude-test "$state_file" >/dev/null 2>&1 || bad_status=$?
  assert_eq 7 "$sleep_value" && assert_eq 2 "$bad_status"
  local assertion_status=$?
  rm -rf "$WORKER_TEST_DIR"
  return "$assertion_status"
}

test_worker_rejects_positional_token() {
  local status=0 output
  output="$(env -u ANYROUTER_TOKEN bash "$ROOT_DIR/scripts/pool-worker.sh" gpt 'sk-positional' \
    'https://anyrouter.top/v1' gpt-test /tmp/x.state 2>&1)" || status=$?
  assert_eq 2 "$status" && assert_not_contains "$output" 'sk-positional'
}

test_kill_tree_escalates_to_kill_for_ignored_term() {
  with_common || return
  local parent child='' test_dir
  test_dir="$(mktemp -d)" || return
  bash -c 'trap "" TERM; (trap "" TERM; exec /usr/bin/sleep 30) & printf "%s\n" "$!" > "$1/child.pid"; wait' _ "$test_dir" &
  parent=$!
  for _ in {1..20}; do [ -s "$test_dir/child.pid" ] && break; /usr/bin/sleep 0.05; done
  child="$(cat "$test_dir/child.pid" 2>/dev/null || true)"
  kill_tree "$parent"
  local assertion_status=1
  [ -n "$child" ] && ! kill -0 "$parent" 2>/dev/null && ! kill -0 "$child" 2>/dev/null && assertion_status=0
  kill -KILL "$parent" "$child" 2>/dev/null || true
  rm -rf "$test_dir"
  return "$assertion_status"
}

run_worker_tests() {
  run_case "KEEPALIVE_SEC=0 stops the pool after the first success notification" test_worker_keepalive_off_finishes_after_notify
  run_case "KEEPALIVE_SEC accepts A-B ranges and rejects garbage" test_worker_keepalive_sec_accepts_range_and_rejects_garbage
  run_case "worker refuses a positional token" test_worker_rejects_positional_token
  run_case "kill_tree escalates to KILL for a tree that ignores TERM" test_kill_tree_escalates_to_kill_for_ignored_term
  run_case "429 probing then success uses probe and keepalive intervals" test_worker_429_then_success_uses_both_intervals
  run_case "Claude and GPT notifications remain independent" test_dual_pool_notifications_are_independent
  run_case "429 during keepalive returns only that pool to probing" test_worker_keepalive_429_returns_to_probing
  run_case "retryable failure keeps the current keepalive phase" test_worker_retryable_keeps_keepalive_phase
  run_case "success notification is sent once per available phase" test_worker_success_notification_is_deduplicated
  run_case "invalid adapter result becomes config_error" test_worker_invalid_becomes_config_error
  run_case "invalid model advances to the next ranked candidate" test_worker_invalid_tries_next_ranked_candidate
  run_case "an invalid inherited relay model triggers one safe rediscovery" test_worker_rediscover_after_inherited_model_becomes_invalid
  run_case "a CRLF-discovered model reaches the adapter without a carriage return" test_worker_dynamic_crlf_candidate_reaches_adapter_without_carriage_return
  run_case "authentication errors stop without trying another model" test_worker_authentication_error_never_advances_candidate
  run_case "worker logs a sanitized integer cli exit code" test_worker_logs_only_integer_cli_exit_code
  run_case "worker logs bracketed model aliases without stripping brackets" test_worker_logs_bracketed_model_alias_without_stripping_it
  run_case "worker runs a non-executable adapter through Bash" test_worker_runs_non_executable_adapter_with_bash
  run_case "adapter subprocess receives only the Anyrouter token secret" test_worker_adapter_receives_only_required_secret
  run_case "SMTP failure cannot undo a successful transition" test_worker_smtp_failure_does_not_change_success
  run_case "MAX_ITERATIONS exits without an unnecessary final sleep" test_worker_max_iterations_exits_without_final_sleep
  run_case "read_state_value keeps Claude and GPT files independent" test_state_value_reads_independent_files
  run_case "SIGTERM writes stopped and exits cleanly" test_worker_signal_writes_stopped
  run_case "SIGTERM stops a blocked adapter process promptly" test_worker_signal_stops_blocked_adapter
  run_case "SIGTERM stops adapter descendants and lets traps clean temporary files" test_worker_signal_stops_adapter_descendant_and_cleans_temp
}

with_actions_api() {
  # shellcheck source=../scripts/lib/actions-api.sh
  source "$ROOT_DIR/scripts/lib/actions-api.sh"
}

setup_actions_fixture() {
  ACTIONS_TEST_DIR="$(mktemp -d)" || return
  mkdir -p "$ACTIONS_TEST_DIR/bin"
  ACTIONS_RUNS_FIXTURE="$ACTIONS_TEST_DIR/runs.json"
  ACTIONS_RUNS_SECOND_FIXTURE="$ACTIONS_TEST_DIR/runs-second.json"
  ACTIONS_ARTIFACTS_FIXTURE="$ACTIONS_TEST_DIR/artifacts.json"
  ACTIONS_ARTIFACT_ZIP="$ACTIONS_TEST_DIR/marker.zip"
  CURL_LOG="$ACTIONS_TEST_DIR/curl.log"
  export ACTIONS_TEST_DIR ACTIONS_RUNS_FIXTURE ACTIONS_RUNS_SECOND_FIXTURE \
    ACTIONS_ARTIFACTS_FIXTURE ACTIONS_ARTIFACT_ZIP CURL_LOG
  unset CURL_EXIT
  printf '%s\n' '{"workflow_runs":[{"id":101,"status":"queued"},{"id":102,"status":"pending"},{"id":103,"status":"waiting"},{"id":104,"status":"in_progress"},{"id":105,"status":"completed"},{"id":999,"status":"in_progress"}]}' > "$ACTIONS_RUNS_FIXTURE"
  cp "$ACTIONS_RUNS_FIXTURE" "$ACTIONS_RUNS_SECOND_FIXTURE"
  printf '%s\n' '{"artifacts":[{"id":70,"name":"anyrouter-stop-marker","expired":false,"created_at":"2026-08-18T00:00:00Z"},{"id":77,"name":"anyrouter-stop-marker","expired":false,"created_at":"2026-08-19T00:00:00Z"},{"id":88,"name":"anyrouter-stop-marker","expired":true,"created_at":"2026-08-20T00:00:00Z"}]}' > "$ACTIONS_ARTIFACTS_FIXTURE"
  python - "$ACTIONS_ARTIFACT_ZIP" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("stop.json", '{"stop_before_epoch":200,"workflow_id":"keepalive.yml"}\n')
PY
  cat > "$ACTIONS_TEST_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
method=GET
output_file=''
body=''
url=''
content_type=false
printf '%s\n' "$*" > "$ACTIONS_TEST_DIR/last-curl.argv"
printf 'GITHUB_TOKEN=%s\nANYROUTER_TOKEN=%s\nANYROUTER_TOKENS=%s\nQQ_EMAIL=%s\nQQ_SMTP_AUTH_CODE=%s\n' \
  "${GITHUB_TOKEN+x}" "${ANYROUTER_TOKEN+x}" "${ANYROUTER_TOKENS+x}" \
  "${QQ_EMAIL+x}" "${QQ_SMTP_AUTH_CODE+x}" > "$ACTIONS_TEST_DIR/curl.env"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config|-K)
      printf '%s\n' "$2" > "$ACTIONS_TEST_DIR/config.path"
      stat -c '%a' "$2" > "$ACTIONS_TEST_DIR/config.mode"
      cp "$2" "$ACTIONS_TEST_DIR/config.copy"
      shift 2
      ;;
    -X|--request) method="$2"; shift 2 ;;
    -o|--output) output_file="$2"; shift 2 ;;
    -d|--data|--data-binary) body="${2#@}"; shift 2 ;;
    -H|--header)
      [ "$2" = 'Content-Type: application/json' ] && content_type=true
      shift 2
      ;;
    -f|-s|-S|-fsS|--fail|--silent|--show-error|-L|--location) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [ -n "$body" ] && [ -f "$body" ]; then body="$(cat "$body")"; fi
printf '%s|%s|%s|%s\n' "$method" "$url" "$body" "$content_type" >> "$CURL_LOG"
case "$url" in
  *'/actions/artifacts?name=anyrouter-stop-marker'*) source_file="$ACTIONS_ARTIFACTS_FIXTURE" ;;
  *'/actions/artifacts/77/zip') source_file="$ACTIONS_ARTIFACT_ZIP" ;;
  *'/actions/workflows/keepalive.yml/runs?'*)
    count=0
    [ -f "$ACTIONS_TEST_DIR/list.count" ] && count="$(cat "$ACTIONS_TEST_DIR/list.count")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$ACTIONS_TEST_DIR/list.count"
    if [ "${FAIL_LIST_CALL:-}" = "$count" ]; then exit 22; fi
    if [ "$count" -ge 2 ]; then source_file="$ACTIONS_RUNS_SECOND_FIXTURE"; else source_file="$ACTIONS_RUNS_FIXTURE"; fi
    ;;
  *) source_file='' ;;
esac
if [ -n "${FAIL_CANCEL_RUN:-}" ] && [[ "$url" == *"/actions/runs/$FAIL_CANCEL_RUN/cancel" ]]; then exit 22; fi
if [ -n "${CURL_EXIT:-}" ]; then exit "$CURL_EXIT"; fi
if [ -n "$source_file" ]; then
  if [ -n "$output_file" ]; then cp "$source_file" "$output_file"; else cat "$source_file"; fi
elif [ -n "$output_file" ]; then
  : > "$output_file"
fi
exit 0
SH
  chmod +x "$ACTIONS_TEST_DIR/bin/curl"
}

test_chain_is_stopped_respects_epoch() {
  setup_actions_fixture || return
  with_actions_api || { rm -rf "$ACTIONS_TEST_DIR"; return 1; }
  local marker old_result new_result
  marker="$ACTIONS_TEST_DIR/stop.json"
  printf '{"stop_before_epoch":200,"workflow_id":"keepalive.yml"}\n' > "$marker"
  old_result="$(chain_is_stopped "$marker" 100)"
  new_result="$(chain_is_stopped "$marker" 201)"
  assert_eq true "$old_result" && assert_eq false "$new_result"
  local status=$?
  rm -rf "$ACTIONS_TEST_DIR"
  return "$status"
}

test_latest_marker_download_uses_newest_unexpired_artifact() {
  setup_actions_fixture || return
  with_actions_api || { rm -rf "$ACTIONS_TEST_DIR"; return 1; }
  local marker status
  marker="$ACTIONS_TEST_DIR/downloaded-stop.json"
  PATH="$ACTIONS_TEST_DIR/bin:$PATH" GITHUB_TOKEN='github-test-token' ANYROUTER_TOKEN=present \
    ANYROUTER_TOKENS=present QQ_EMAIL=present QQ_SMTP_AUTH_CODE=present \
    GITHUB_REPOSITORY='owner/repo' download_latest_stop_marker "$marker"
  status=$?
  [ "$status" -eq 0 ] && grep -q '"stop_before_epoch":200' "$marker" &&
    grep -q '/actions/artifacts/77/zip' "$CURL_LOG" &&
    ! grep -q 'github-test-token' "$CURL_LOG" &&
    grep -q '^GITHUB_TOKEN=x$' "$ACTIONS_TEST_DIR/curl.env" &&
    grep -q '^ANYROUTER_TOKEN=$' "$ACTIONS_TEST_DIR/curl.env" &&
    grep -q '^ANYROUTER_TOKENS=$' "$ACTIONS_TEST_DIR/curl.env" &&
    grep -q '^QQ_EMAIL=$' "$ACTIONS_TEST_DIR/curl.env" &&
    grep -q '^QQ_SMTP_AUTH_CODE=$' "$ACTIONS_TEST_DIR/curl.env"
  local assertion_status=$?
  rm -rf "$ACTIONS_TEST_DIR"
  return "$assertion_status"
}

test_github_curl_rejects_invalid_timeout_settings() {
  setup_actions_fixture || return
  with_actions_api || { rm -rf "$ACTIONS_TEST_DIR"; return 1; }
  local status_one status_two
  rm -f "$CURL_LOG"
  set +e
  PATH="$ACTIONS_TEST_DIR/bin:$PATH" GITHUB_TOKEN=x GITHUB_REPOSITORY=owner/repo \
    GITHUB_CONNECT_TIMEOUT_SEC=0 GITHUB_MAX_TIME_SEC=1 github_curl https://api.github.com/test >/dev/null 2>&1
  status_one=$?
  PATH="$ACTIONS_TEST_DIR/bin:$PATH" GITHUB_TOKEN=x GITHUB_REPOSITORY=owner/repo \
    GITHUB_CONNECT_TIMEOUT_SEC=1 GITHUB_MAX_TIME_SEC=invalid github_curl https://api.github.com/test >/dev/null 2>&1
  status_two=$?
  set -e
  [ "$status_one" -eq 2 ] && [ "$status_two" -eq 2 ] && [ ! -e "$CURL_LOG" ]
  local assertion_status=$?
  rm -rf "$ACTIONS_TEST_DIR"
  return "$assertion_status"
}

test_stop_marker_has_only_public_fields() {
  setup_actions_fixture || return
  local marker status
  marker="$ACTIONS_TEST_DIR/stop.json"
  bash "$ROOT_DIR/scripts/stop-chain.sh" write-marker "$marker" 200
  status=$?
  [ "$status" -eq 0 ] && python - "$marker" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data == {"stop_before_epoch": 200, "workflow_id": "keepalive.yml"}
PY
  local assertion_status=$?
  rm -rf "$ACTIONS_TEST_DIR"
  return "$assertion_status"
}

test_stop_scans_twice_and_cancels_active_runs() {
  setup_actions_fixture || return
  local output status
  output="$(PATH="$ACTIONS_TEST_DIR/bin:$PATH" GITHUB_TOKEN='github-test-token' \
    GITHUB_REPOSITORY='owner/repo' GITHUB_RUN_ID=999 STOP_SCAN_DELAY_SEC=0 \
    bash "$ROOT_DIR/scripts/stop-chain.sh" cancel-runs 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && assert_eq 2 "$(grep -c '/actions/workflows/keepalive.yml/runs?' "$CURL_LOG")" &&
    grep -q '/actions/runs/101/cancel' "$CURL_LOG" &&
    grep -q '/actions/runs/102/cancel' "$CURL_LOG" &&
    grep -q '/actions/runs/103/cancel' "$CURL_LOG" &&
    grep -q '/actions/runs/104/cancel' "$CURL_LOG" &&
    ! grep -q '/actions/runs/105/cancel' "$CURL_LOG" &&
    ! grep -q '/actions/runs/999/cancel' "$CURL_LOG" &&
    assert_not_contains "$output" 'github-test-token'
  local assertion_status=$?
  rm -rf "$ACTIONS_TEST_DIR"
  return "$assertion_status"
}

test_relay_payload_is_allowlisted_and_secret_free() {
  setup_actions_fixture || return
  with_actions_api || { rm -rf "$ACTIONS_TEST_DIR"; return 1; }
  local output status body
  output="$(PATH="$ACTIONS_TEST_DIR/bin:$PATH" GITHUB_TOKEN='github-test-token' \
    GITHUB_REPOSITORY='owner/repo' GITHUB_REF_NAME='main' ANYROUTER_TOKENS='sk-ant-never-relay' \
    dispatch_relay probing keepalive claude-test gpt-test false true chain-7 123 2>&1)"
  status=$?
  body="$(awk -F'|' '/\/dispatches/ {print $3}' "$CURL_LOG")"
  [ "$status" -eq 0 ] && python - "$body" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
assert set(payload) == {"ref", "inputs"}
assert set(payload["inputs"]) == {"mode", "claude_phase", "gpt_phase", "claude_model", "gpt_model", "claude_notified", "gpt_notified", "chain_id", "chain_started_epoch"}
assert payload["inputs"]["mode"] == "relay"
assert "token" not in json.dumps(payload).lower()
PY
  local assertion_status=$?
  [ "$assertion_status" -eq 0 ] && assert_not_contains "$body" 'sk-ant-never-relay' &&
    assert_not_contains "$output" 'github-test-token' &&
    grep -q '/dispatches|.*|true$' "$CURL_LOG" &&
    ! grep -q 'github-test-token' "$ACTIONS_TEST_DIR/last-curl.argv" &&
    grep -q 'Authorization: Bearer github-test-token' "$ACTIONS_TEST_DIR/config.copy" &&
    assert_eq 600 "$(cat "$ACTIONS_TEST_DIR/config.mode")"
  assertion_status=$?
  rm -rf "$ACTIONS_TEST_DIR"
  return "$assertion_status"
}

test_stop_cancel_failure_is_not_silenced() {
  setup_actions_fixture || return
  local output status
  output="$(PATH="$ACTIONS_TEST_DIR/bin:$PATH" GITHUB_TOKEN='github-test-token' \
    GITHUB_REPOSITORY='owner/repo' GITHUB_RUN_ID=999 STOP_SCAN_DELAY_SEC=0 CURL_EXIT=22 \
    bash "$ROOT_DIR/scripts/stop-chain.sh" cancel-runs 2>&1)"
  status=$?
  [ "$status" -ne 0 ] && assert_contains "$output" '取消扫描失败' &&
    assert_not_contains "$output" 'github-test-token'
  local assertion_status=$?
  rm -rf "$ACTIONS_TEST_DIR"
  return "$assertion_status"
}

test_stop_second_scan_runs_after_first_list_failure() {
  setup_actions_fixture || return
  local output status
  output="$(PATH="$ACTIONS_TEST_DIR/bin:$PATH" GITHUB_TOKEN='github-test-token' \
    GITHUB_REPOSITORY='owner/repo' GITHUB_RUN_ID=999 STOP_SCAN_DELAY_SEC=0 FAIL_LIST_CALL=1 \
    bash "$ROOT_DIR/scripts/stop-chain.sh" cancel-runs 2>&1)"
  status=$?
  [ "$status" -ne 0 ] && assert_eq 2 "$(grep -c '/actions/workflows/keepalive.yml/runs?' "$CURL_LOG")" &&
    grep -q '/actions/runs/101/cancel' "$CURL_LOG" &&
    assert_contains "$output" '第一次取消扫描失败' &&
    assert_not_contains "$output" 'github-test-token'
  local assertion_status=$?
  rm -rf "$ACTIONS_TEST_DIR"
  return "$assertion_status"
}

test_stop_second_scan_runs_after_cancel_failure_and_catches_new_run() {
  setup_actions_fixture || return
  printf '%s\n' '{"workflow_runs":[{"id":101,"status":"queued"},{"id":106,"status":"in_progress"},{"id":999,"status":"in_progress"}]}' \
    > "$ACTIONS_RUNS_SECOND_FIXTURE"
  local output status
  output="$(PATH="$ACTIONS_TEST_DIR/bin:$PATH" GITHUB_TOKEN='github-test-token' \
    GITHUB_REPOSITORY='owner/repo' GITHUB_RUN_ID=999 STOP_SCAN_DELAY_SEC=0 FAIL_CANCEL_RUN=102 \
    bash "$ROOT_DIR/scripts/stop-chain.sh" cancel-runs 2>&1)"
  status=$?
  [ "$status" -ne 0 ] && assert_eq 2 "$(grep -c '/actions/workflows/keepalive.yml/runs?' "$CURL_LOG")" &&
    grep -q '/actions/runs/106/cancel' "$CURL_LOG" &&
    assert_contains "$output" '第一次取消扫描失败' &&
    assert_not_contains "$output" 'github-test-token'
  local assertion_status=$?
  rm -rf "$ACTIONS_TEST_DIR"
  return "$assertion_status"
}

setup_dual_pool_fixture() {
  DUAL_TEST_DIR="$(mktemp -d)" || return
  mkdir -p "$DUAL_TEST_DIR/bin"
  DUAL_CALLS="$DUAL_TEST_DIR/worker.calls"
  export DUAL_TEST_DIR DUAL_CALLS ROOT_DIR
  cat > "$DUAL_TEST_DIR/bin/fake-worker" <<'SH'
#!/usr/bin/env bash
pool="$1"
if [ "$#" -ge 5 ]; then model="$4"; state_file="$5"; else model="$3"; state_file="$4"; fi
[ "${MAX_ITERATIONS:-}" = 1 ] || exit 7
printf '%s\n' "$pool" >> "$DUAL_CALLS"
printf '%s|%s\n' "$pool" "$model" >> "$DUAL_TEST_DIR/worker.models"
printf '%s|ANYROUTER_TOKEN=%s|ANYROUTER_TOKENS=%s|GITHUB_TOKEN=%s|QQ_EMAIL=%s|QQ_SMTP_AUTH_CODE=%s\n' \
  "$pool" "${ANYROUTER_TOKEN+x}" "${ANYROUTER_TOKENS+x}" "${GITHUB_TOKEN+x}" \
  "${QQ_EMAIL+x}" "${QQ_SMTP_AUTH_CODE+x}" >> "$DUAL_TEST_DIR/worker.env"
: > "$DUAL_TEST_DIR/$pool.started"
other=claude
[ "$pool" = claude ] && other=gpt
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -e "$DUAL_TEST_DIR/$other.started" ] && break
  /usr/bin/sleep 0.05
done
[ -e "$DUAL_TEST_DIR/$other.started" ] || exit 8
printf 'phase=keepalive\nmodel=%s\nnotified=true\nchain_id=%s\nchain_started_epoch=%s\n' \
  "$model" "${CHAIN_ID:-}" "${CHAIN_STARTED_EPOCH:-0}" > "$state_file"
SH
  cat > "$DUAL_TEST_DIR/bin/config-error-worker" <<'SH'
#!/usr/bin/env bash
if [ "$#" -ge 5 ]; then model="$4"; state_file="$5"; else model="$3"; state_file="$4"; fi
printf 'phase=config_error\nmodel=%s\nnotified=false\nchain_id=%s\nchain_started_epoch=%s\n' \
  "$model" "${CHAIN_ID:-}" "${CHAIN_STARTED_EPOCH:-0}" > "$state_file"
SH
  cat > "$DUAL_TEST_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DUAL_TEST_DIR/unexpected-curl.log"
exit 99
SH
  chmod +x "$DUAL_TEST_DIR/bin/"*
}

test_coordinator_force_kills_both_worker_trees_and_state_dir() {
  setup_dual_pool_fixture || return
  mkdir -p "$DUAL_TEST_DIR/tmp"
  cat > "$DUAL_TEST_DIR/bin/ignoring-worker" <<'SH'
#!/usr/bin/env bash
pool="$1"
trap '' TERM INT
printf '%s\n' "$BASHPID" > "$DUAL_TEST_DIR/$pool.worker.pid"
/usr/bin/bash -c 'trap "" TERM INT; while :; do /usr/bin/sleep 1; done' &
printf '%s\n' "$!" > "$DUAL_TEST_DIR/$pool.child.pid"
wait
SH
  cat > "$DUAL_TEST_DIR/bin/mktemp" <<'SH'
#!/usr/bin/env bash
path="$(/usr/bin/mktemp "$@")" || exit
case " $* " in *' -d '*) printf '%s\n' "$path" > "$DUAL_TEST_DIR/state-dir.path" ;; esac
printf '%s\n' "$path"
SH
  chmod +x "$DUAL_TEST_DIR/bin/ignoring-worker" "$DUAL_TEST_DIR/bin/mktemp"
  local coordinator_pid='' claude_pid='' claude_child='' gpt_pid='' gpt_child='' state_dir=''
  local ready=false exited=false status=0
  PATH="$DUAL_TEST_DIR/bin:$PATH" TMPDIR="$DUAL_TEST_DIR/tmp" SKIP_STOP_CHECK=true \
    ANYROUTER_TOKENS='sk-ant-test-only' ANYROUTER_CLAUDE_MODEL='claude-test' \
    ANYROUTER_GPT_MODEL='gpt-test' POOL_WORKER_COMMAND="$DUAL_TEST_DIR/bin/ignoring-worker" \
    MAX_DURATION_SEC=60 bash "$ROOT_DIR/scripts/run-dual-pool.sh" --mode start --once \
    >"$DUAL_TEST_DIR/coordinator.out" 2>&1 &
  coordinator_pid=$!
  for _ in {1..40}; do
    if [ -s "$DUAL_TEST_DIR/claude.worker.pid" ] && [ -s "$DUAL_TEST_DIR/claude.child.pid" ] &&
      [ -s "$DUAL_TEST_DIR/gpt.worker.pid" ] && [ -s "$DUAL_TEST_DIR/gpt.child.pid" ] &&
      [ -s "$DUAL_TEST_DIR/state-dir.path" ]; then
      ready=true
      break
    fi
    /usr/bin/sleep 0.1
  done
  claude_pid="$(cat "$DUAL_TEST_DIR/claude.worker.pid" 2>/dev/null || true)"
  claude_child="$(cat "$DUAL_TEST_DIR/claude.child.pid" 2>/dev/null || true)"
  gpt_pid="$(cat "$DUAL_TEST_DIR/gpt.worker.pid" 2>/dev/null || true)"
  gpt_child="$(cat "$DUAL_TEST_DIR/gpt.child.pid" 2>/dev/null || true)"
  state_dir="$(cat "$DUAL_TEST_DIR/state-dir.path" 2>/dev/null || true)"
  [ "$ready" = true ] && [ -n "$state_dir" ] || status=125
  if [ "$status" -eq 0 ]; then kill -TERM "$coordinator_pid" 2>/dev/null || true; fi
  for _ in {1..50}; do
    if ! kill -0 "$coordinator_pid" 2>/dev/null && ! kill -0 "$claude_pid" 2>/dev/null &&
      ! kill -0 "$claude_child" 2>/dev/null && ! kill -0 "$gpt_pid" 2>/dev/null &&
      ! kill -0 "$gpt_child" 2>/dev/null; then
      exited=true
      break
    fi
    /usr/bin/sleep 0.1
  done
  [ "$exited" = true ] || status=124
  [ "$exited" = false ] || wait "$coordinator_pid" 2>/dev/null || true
  [ "$status" -eq 0 ] && [ ! -e "$state_dir" ] &&
    ! kill -0 "$claude_pid" 2>/dev/null && ! kill -0 "$claude_child" 2>/dev/null &&
    ! kill -0 "$gpt_pid" 2>/dev/null && ! kill -0 "$gpt_child" 2>/dev/null
  local assertion_status=$?
  kill -KILL "$coordinator_pid" "$claude_pid" "$claude_child" "$gpt_pid" "$gpt_child" 2>/dev/null || true
  wait "$coordinator_pid" 2>/dev/null || true
  rm -rf "$DUAL_TEST_DIR"
  return "$assertion_status"
}

setup_formal_dual_fixture() {
  FORMAL_TEST_DIR="$(mktemp -d)" || return
  mkdir -p "$FORMAL_TEST_DIR/bin"
  FORMAL_MODELS="$FORMAL_TEST_DIR/models.json"
  FORMAL_REQUESTS="$FORMAL_TEST_DIR/requests.log"
  export FORMAL_TEST_DIR FORMAL_MODELS FORMAL_REQUESTS
  cat > "$FORMAL_TEST_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
output_file=''
url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config|-K|-H|--header|--connect-timeout|--max-time|--write-out|-w) shift 2 ;;
    --output|-o) output_file="$2"; shift 2 ;;
    --data-binary) shift 2 ;;
    --silent|--show-error|--fail|--location) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  */models)
    printf 'models\n' >> "$FORMAL_REQUESTS"
    if [ -n "$output_file" ]; then cp "$FORMAL_MODELS" "$output_file"; else cat "$FORMAL_MODELS"; fi
    ;;
  *) exit 97 ;;
esac
SH
  cat > "$FORMAL_TEST_DIR/bin/codex" <<'SH'
#!/usr/bin/env bash
model=''
while [ "$#" -gt 0 ]; do
  case "$1" in --model) model="$2"; shift 2 ;; *) shift ;; esac
done
printf 'gpt:%s\n' "$model" >> "$FORMAL_REQUESTS"
case "$model" in
  *-rate) printf 'HTTP 429' >&2; exit 1 ;;
  *-auth) printf 'HTTP 401' >&2; exit 1 ;;
  *-bad|*-stale) printf 'unknown model' >&2; exit 1 ;;
  *) printf 'safe response' ;;
esac
SH
  cat > "$FORMAL_TEST_DIR/bin/claude" <<'SH'
#!/usr/bin/env bash
model=''
while [ "$#" -gt 0 ]; do
  case "$1" in --model) model="$2"; shift 2 ;; *) shift ;; esac
done
printf 'claude:%s\n' "$model" >> "$FORMAL_REQUESTS"
case "$model" in
  *-rate) printf 'HTTP 429' >&2; exit 1 ;;
  *-auth) printf 'HTTP 401' >&2; exit 1 ;;
  *-bad|*-stale) printf 'unknown model' >&2; exit 1 ;;
  *) printf 'safe response' ;;
esac
SH
  chmod +x "$FORMAL_TEST_DIR/bin/curl" "$FORMAL_TEST_DIR/bin/claude" "$FORMAL_TEST_DIR/bin/codex"
}

run_formal_dual() {
  PATH="$FORMAL_TEST_DIR/bin:$PATH" SKIP_STOP_CHECK=true \
    ANYROUTER_TOKENS='sk-ant-formal-test' SLEEP_COMMAND=true \
    PROBE_MIN_SEC=0 PROBE_MAX_SEC=0 KEEPALIVE_MIN_SEC=0 KEEPALIVE_MAX_SEC=0 \
    MAX_DURATION_SEC=30 EMAIL_LOG="$FORMAL_TEST_DIR/email.log" \
    bash "$ROOT_DIR/scripts/run-dual-pool.sh" "$@"
}

test_formal_fresh_discovery_falls_back_to_next_candidate() {
  setup_formal_dual_fixture || return
  printf '%s\n' '{"data":[{"id":"gpt-9.9-bad"},{"id":"gpt-9.8-good"}]}' > "$FORMAL_MODELS"
  local output status
  output="$(
    unset ANYROUTER_GPT_MODEL GPT_MODEL
    ANYROUTER_CLAUDE_MODEL=claude-good MAX_ITERATIONS=2 \
      run_formal_dual --mode start --once 2>&1
  )"
  status=$?
  [ "$status" -eq 0 ] && assert_eq $'gpt:gpt-9.9-bad\ngpt:gpt-9.8-good' \
    "$(grep '^gpt:' "$FORMAL_REQUESTS")" &&
    assert_eq 1 "$(grep -c '^models$' "$FORMAL_REQUESTS")" &&
    assert_not_contains "$output" 'sk-ant-formal-test'
  local assertion_status=$?
  rm -rf "$FORMAL_TEST_DIR"
  return "$assertion_status"
}

test_formal_relay_rediscovery_replaces_stale_inherited_model() {
  setup_formal_dual_fixture || return
  printf '%s\n' '{"data":[{"id":"gpt-10.0-current"},{"id":"gpt-9.8-good"}]}' > "$FORMAL_MODELS"
  local output status
  output="$(
    unset ANYROUTER_GPT_MODEL ANYROUTER_CLAUDE_MODEL
    GPT_MODEL=gpt-inherited-stale CLAUDE_MODEL=claude-good CHAIN_STARTED_EPOCH=123 \
      MAX_ITERATIONS=2 run_formal_dual --mode relay --once 2>&1
  )"
  status=$?
  [ "$status" -eq 0 ] && assert_eq $'gpt:gpt-inherited-stale\ngpt:gpt-10.0-current' \
    "$(grep '^gpt:' "$FORMAL_REQUESTS")" &&
    assert_eq 1 "$(grep -c '^models$' "$FORMAL_REQUESTS")" &&
    assert_not_contains "$output" 'sk-ant-formal-test'
  local assertion_status=$?
  rm -rf "$FORMAL_TEST_DIR"
  return "$assertion_status"
}

test_formal_variable_429_never_switches_model() {
  setup_formal_dual_fixture || return
  printf '%s\n' '{"data":[{"id":"gpt-must-not-run"}]}' > "$FORMAL_MODELS"
  local output status
  output="$(ANYROUTER_CLAUDE_MODEL=claude-good ANYROUTER_GPT_MODEL=gpt-variable-rate \
    MAX_ITERATIONS=1 run_formal_dual --mode start --once 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && assert_eq 'gpt:gpt-variable-rate' "$(grep '^gpt:' "$FORMAL_REQUESTS")" &&
    ! grep -q '^models$' "$FORMAL_REQUESTS" && assert_not_contains "$output" 'sk-ant-formal-test'
  local assertion_status=$?
  rm -rf "$FORMAL_TEST_DIR"
  return "$assertion_status"
}

test_formal_authentication_error_never_switches_or_rediscovers() {
  setup_formal_dual_fixture || return
  printf '%s\n' '{"data":[{"id":"gpt-must-not-run"}]}' > "$FORMAL_MODELS"
  local output status
  output="$(ANYROUTER_CLAUDE_MODEL=claude-good ANYROUTER_GPT_MODEL=gpt-variable-auth \
    MAX_ITERATIONS=2 run_formal_dual --mode start --once 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && assert_eq 'gpt:gpt-variable-auth' "$(grep '^gpt:' "$FORMAL_REQUESTS")" &&
    ! grep -q '^models$' "$FORMAL_REQUESTS" && assert_not_contains "$output" 'sk-ant-formal-test'
  local assertion_status=$?
  rm -rf "$FORMAL_TEST_DIR"
  return "$assertion_status"
}

test_stopped_relay_exits_before_workers_or_token_use() {
  setup_dual_pool_fixture || return
  printf '{"stop_before_epoch":200,"workflow_id":"keepalive.yml"}\n' > "$DUAL_TEST_DIR/stop.json"
  local output status
  output="$(PATH="$DUAL_TEST_DIR/bin:$PATH" STOP_MARKER_FILE="$DUAL_TEST_DIR/stop.json" \
    CHAIN_STARTED_EPOCH=100 ANYROUTER_TOKENS='sk-ant-secret-value' \
    POOL_WORKER_COMMAND="$DUAL_TEST_DIR/bin/fake-worker" \
    bash "$ROOT_DIR/scripts/run-dual-pool.sh" --mode relay 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && [ ! -e "$DUAL_CALLS" ] &&
    assert_not_contains "$output" 'sk-ant-secret-value'
  local assertion_status=$?
  rm -rf "$DUAL_TEST_DIR"
  return "$assertion_status"
}

test_relay_requires_a_valid_inherited_epoch() {
  setup_dual_pool_fixture || return
  local missing_output missing_status invalid_output invalid_status
  missing_output="$(env -u CHAIN_STARTED_EPOCH PATH="$DUAL_TEST_DIR/bin:$PATH" SKIP_STOP_CHECK=true \
    bash "$ROOT_DIR/scripts/run-dual-pool.sh" --mode relay --check-stop 2>&1)"
  missing_status=$?
  invalid_output="$(PATH="$DUAL_TEST_DIR/bin:$PATH" SKIP_STOP_CHECK=true CHAIN_STARTED_EPOCH=not-a-number \
    bash "$ROOT_DIR/scripts/run-dual-pool.sh" --mode relay --check-stop 2>&1)"
  invalid_status=$?
  [ "$missing_status" -ne 0 ] && [ "$invalid_status" -ne 0 ] &&
    assert_contains "$missing_output" 'CHAIN_STARTED_EPOCH' &&
    assert_contains "$invalid_output" 'CHAIN_STARTED_EPOCH' &&
    [ ! -e "$DUAL_CALLS" ]
  local assertion_status=$?
  rm -rf "$DUAL_TEST_DIR"
  return "$assertion_status"
}

test_start_precheck_outputs_are_reused_by_the_run_step() {
  setup_dual_pool_fixture || return
  local output_file status
  output_file="$DUAL_TEST_DIR/github.output"
  GITHUB_OUTPUT="$output_file" SKIP_STOP_CHECK=true CHAIN_STARTED_EPOCH=123 CHAIN_ID=chain-fixed \
    bash "$ROOT_DIR/scripts/run-dual-pool.sh" --mode start --check-stop
  status=$?
  [ "$status" -eq 0 ] && grep -q '^chain_started_epoch=123$' "$output_file" &&
    grep -q '^chain_id=chain-fixed$' "$output_file" &&
    grep -q 'CHAIN_STARTED_EPOCH:.*steps.stop-check.outputs.chain_started_epoch' "$ROOT_DIR/.github/workflows/keepalive.yml" &&
    grep -q 'CHAIN_ID:.*steps.stop-check.outputs.chain_id' "$ROOT_DIR/.github/workflows/keepalive.yml"
  local assertion_status=$?
  rm -rf "$DUAL_TEST_DIR"
  return "$assertion_status"
}

test_once_starts_two_pool_workers_in_parallel_without_relay() {
  setup_dual_pool_fixture || return
  local output status
  output="$(PATH="$DUAL_TEST_DIR/bin:$PATH" ANYROUTER_TOKENS='sk-ant-test-only' \
    ANYROUTER_CLAUDE_MODEL='claude-test' ANYROUTER_GPT_MODEL='gpt-test' \
    POOL_WORKER_COMMAND="$DUAL_TEST_DIR/bin/fake-worker" MAX_DURATION_SEC=5 \
    bash "$ROOT_DIR/scripts/run-dual-pool.sh" --mode start --once 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && assert_eq 2 "$(wc -l < "$DUAL_CALLS")" &&
    grep -q '^claude$' "$DUAL_CALLS" && grep -q '^gpt$' "$DUAL_CALLS" &&
    [ ! -e "$DUAL_TEST_DIR/unexpected-curl.log" ] &&
    assert_not_contains "$output" 'sk-ant-test-only'
  local assertion_status=$?
  rm -rf "$DUAL_TEST_DIR"
  return "$assertion_status"
}

test_formal_workers_receive_only_secrets_they_need() {
  setup_dual_pool_fixture || return
  local output status
  output="$(PATH="$DUAL_TEST_DIR/bin:$PATH" ANYROUTER_TOKENS='sk-ant-test-only' \
    GITHUB_TOKEN='github-test-token' QQ_EMAIL=present QQ_SMTP_AUTH_CODE=present \
    ANYROUTER_CLAUDE_MODEL='claude-test' ANYROUTER_GPT_MODEL='gpt-test' \
    POOL_WORKER_COMMAND="$DUAL_TEST_DIR/bin/fake-worker" MAX_DURATION_SEC=5 SKIP_STOP_CHECK=true \
    bash "$ROOT_DIR/scripts/run-dual-pool.sh" --mode start --once 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && assert_eq 2 "$(grep -c 'ANYROUTER_TOKEN=x|ANYROUTER_TOKENS=|GITHUB_TOKEN=|QQ_EMAIL=x|QQ_SMTP_AUTH_CODE=x$' "$DUAL_TEST_DIR/worker.env")" &&
    assert_not_contains "$output" 'sk-ant-test-only' && assert_not_contains "$output" 'github-test-token'
  local assertion_status=$?
  rm -rf "$DUAL_TEST_DIR"
  return "$assertion_status"
}

test_two_config_errors_end_without_relay() {
  setup_dual_pool_fixture || return
  local output status
  output="$(PATH="$DUAL_TEST_DIR/bin:$PATH" ANYROUTER_TOKENS='sk-ant-test-only' \
    ANYROUTER_CLAUDE_MODEL='claude-test' ANYROUTER_GPT_MODEL='gpt-test' \
    POOL_WORKER_COMMAND="$DUAL_TEST_DIR/bin/config-error-worker" MAX_DURATION_SEC=5 \
    STOP_MARKER_FILE="$DUAL_TEST_DIR/no-stop.json" \
    GITHUB_TOKEN='github-test-token' GITHUB_REPOSITORY='owner/repo' GITHUB_REF_NAME='main' \
    bash "$ROOT_DIR/scripts/run-dual-pool.sh" --mode start 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && [ ! -e "$DUAL_TEST_DIR/unexpected-curl.log" ] &&
    assert_not_contains "$output" 'sk-ant-test-only'
  local assertion_status=$?
  rm -rf "$DUAL_TEST_DIR"
  return "$assertion_status"
}

test_model_discovery_failures_send_safe_config_notifications() {
  setup_dual_pool_fixture || return
  local output status email_log discovery_worker
  email_log="$DUAL_TEST_DIR/email.log"
  discovery_worker="$DUAL_TEST_DIR/bin/discovery-worker"
  cat > "$discovery_worker" <<'SH'
#!/usr/bin/env bash
pool="$1"
model="$3"
state_file="$4"
printf '%s\n' "$pool" >> "$DUAL_CALLS"
printf '%s|%s\n' "$pool" "$model" >> "$DUAL_TEST_DIR/worker.models"
printf 'phase=keepalive\nmodel=%s\nnotified=true\nchain_id=%s\nchain_started_epoch=%s\n' \
  "$model" "${CHAIN_ID:-}" "${CHAIN_STARTED_EPOCH:-0}" > "$state_file"
SH
  chmod +x "$discovery_worker"
  output="$(PATH="$DUAL_TEST_DIR/bin:$PATH" ANYROUTER_TOKENS='sk-ant-test-only' \
    EMAIL_LOG="$email_log" POOL_WORKER_COMMAND="$discovery_worker" \
    MAX_DURATION_SEC=5 SKIP_STOP_CHECK=true \
    bash "$ROOT_DIR/scripts/run-dual-pool.sh" --mode start --once 2>&1)"
  status=$?
  [ "$status" -eq 0 ] &&
    [ "$(grep -c '^claude|config_error$' "$email_log" 2>/dev/null || true)" -eq 0 ] &&
    assert_eq 1 "$(grep -c '^gpt|config_error$' "$email_log")" &&
    assert_eq 1 "$(grep -c '^claude$' "$DUAL_CALLS")" &&
    [ "$(grep -c '^gpt$' "$DUAL_CALLS" 2>/dev/null || true)" -eq 0 ] &&
    grep -q '^claude|opus\[1m\]$' "$DUAL_TEST_DIR/worker.models" &&
    assert_not_contains "$output" 'sk-ant-test-only'
  local assertion_status=$?
  rm -rf "$DUAL_TEST_DIR"
  return "$assertion_status"
}

test_workflows_enforce_stop_and_secret_boundaries() {
  local workflow="$ROOT_DIR/.github/workflows/keepalive.yml"
  grep -q 'cron: "0 18 \* \* \*"' "$workflow" &&
    grep -q 'actions: write' "$workflow" && grep -q 'contents: read' "$workflow" &&
    grep -q 'group: anyrouter-keepalive-chain' "$workflow" &&
    grep -q 'group: anyrouter-keepalive-stop' "$workflow" &&
    grep -q 'retention-days: 1' "$workflow" &&
    grep -q 'actions/upload-artifact@v4' "$workflow" &&
    grep -q 'https://anyrouter.top/v1' "$workflow" &&
    grep -q 'ANYROUTER_CLAUDE_MODEL' "$workflow" &&
    grep -q 'ANYROUTER_GPT_MODEL' "$workflow" &&
    grep -q 'npm install -g @openai/codex' "$workflow" &&
    grep -q 'codex --version' "$workflow" &&
    python - "$workflow" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
stop = text.split("  stop:", 1)[1].split("  chain:", 1)[0]
assert "secrets." not in stop
lines = text.splitlines()
secret_lines = [i for i, line in enumerate(lines) if "secrets." in line]
assert secret_lines
assert all(re.match(r"^ {10}(ANYROUTER_TOKENS|QQ_EMAIL|QQ_SMTP_AUTH_CODE):", lines[i]) for i in secret_lines)
marker_i = next(i for i, line in enumerate(lines) if "Check stop marker" in line)
install_i = next(i for i, line in enumerate(lines) if "Install Claude" in line)
codex_i = next(i for i, line in enumerate(lines) if "Install Codex" in line)
codex_verify_i = next(i for i, line in enumerate(lines) if "Verify Codex exec capabilities" in line)
secret_i = min(secret_lines)
assert marker_i < install_i < codex_i < codex_verify_i < secret_i
verify_start = codex_verify_i
verify_run = next(i for i in range(verify_start + 1, len(lines)) if lines[i].strip() == "run: |")
verify_body = "\n".join(lines[verify_run + 1:secret_i])
assert "codex exec --help" in verify_body
for flag in ("--ephemeral", "--skip-git-repo-check", "--sandbox", "--model"):
    assert flag in verify_body
assert "CHAIN_STARTED_EPOCH: ${{ steps.stop-check.outputs.chain_started_epoch }}" in text
assert "CHAIN_ID: ${{ steps.stop-check.outputs.chain_id }}" in text
PY
}

test_workflow_mode_is_validated_as_data() {
  local workflow="$ROOT_DIR/.github/workflows/keepalive.yml" test_dir marker malicious script status all_rejected=true
  test_dir="$(mktemp -d)" || return
  marker="$test_dir/injected"
  malicious="start\$(touch $marker)"
  mkdir -p "$test_dir/bin"
  cat > "$test_dir/bin/bash" <<'SH'
#!/usr/bin/env bash
touch "$WORKFLOW_MODE_TEST_DIR/bash-called"
exit 0
SH
  chmod +x "$test_dir/bin/bash"
  WORKFLOW_MODE_TEST_DIR="$test_dir" MALICIOUS_MODE="$malicious" python - "$workflow" "$test_dir" <<'PY'
import os, pathlib, sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
lines = text.splitlines()
names = ["Check stop marker before installing Claude", "Run dual pool chain"]
for index, name in enumerate(names):
    start = next(i for i, line in enumerate(lines) if line.strip() == f"- name: {name}")
    run = next(i for i in range(start + 1, len(lines)) if lines[i].strip() == "run: |")
    body = []
    for line in lines[run + 1:]:
        if line and len(line) - len(line.lstrip()) <= 8:
            break
        body.append(line[10:] if line.startswith("          ") else line)
    source = "\n".join(body) + "\n"
    rendered = source.replace("${{ inputs.mode || 'start' }}", os.environ["MALICIOUS_MODE"])
    pathlib.Path(sys.argv[2], f"run-{index}.sh").write_text(rendered, encoding="utf-8")

run_blocks = "\n".join(pathlib.Path(sys.argv[2], f"run-{i}.sh").read_text(encoding="utf-8") for i in range(2))
assert "${{ inputs.mode" not in run_blocks
assert text.count("MODE: ${{ inputs.mode || 'start' }}") == 2
assert run_blocks.count('case "$MODE" in') == 2
PY
  status=$?
  if [ "$status" -ne 0 ]; then
    rm -rf "$test_dir"
    return 1
  fi
  if [ "$status" -eq 0 ]; then
    for script in "$test_dir/run-0.sh" "$test_dir/run-1.sh"; do
      set +e
      MODE="$malicious" WORKFLOW_MODE_TEST_DIR="$test_dir" PATH="$test_dir/bin:$PATH" \
        /usr/bin/bash "$script" >"$test_dir/output" 2>&1
      status=$?
      set -e
      if [ "$status" -eq 0 ]; then all_rejected=false; break; fi
    done
  fi
  [ "$all_rejected" = true ] && [ ! -e "$marker" ] && [ ! -e "$test_dir/bash-called" ]
  local assertion_status=$?
  rm -rf "$test_dir"
  return "$assertion_status"
}

test_every_checkout_disables_persisted_credentials() {
  local workflow checkout_count safe_count
  for workflow in \
    "$ROOT_DIR/.github/workflows/keepalive.yml" \
    "$ROOT_DIR/.github/workflows/keepalive-once.yml"; do
    checkout_count="$(grep -c 'uses: actions/checkout@v4' "$workflow")"
    safe_count="$(grep -c 'persist-credentials: false' "$workflow")"
    [ "$checkout_count" -gt 0 ] && assert_eq "$checkout_count" "$safe_count" || return
  done
}

test_once_and_legacy_workflows_use_new_entrypoints() {
  local once="$ROOT_DIR/.github/workflows/keepalive-once.yml"
  grep -q 'https://anyrouter.top/v1' "$once" &&
    grep -q 'run-dual-pool.sh.*--once' "$once" &&
    grep -q 'ANYROUTER_CLAUDE_MODEL' "$once" &&
    grep -q 'ANYROUTER_GPT_MODEL' "$once" &&
    grep -q 'npm install -g @openai/codex' "$once" &&
    grep -q 'codex --version' "$once" &&
    python - "$once" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
lines = text.splitlines()
verify_i = next(i for i, line in enumerate(lines) if "Verify Codex exec capabilities" in line)
secret_i = next(i for i, line in enumerate(lines) if "secrets.ANYROUTER_TOKENS" in line)
assert verify_i < secret_i
verify_run = next(i for i in range(verify_i + 1, len(lines)) if lines[i].strip() == "run: |")
verify_body = "\n".join(lines[verify_run + 1:secret_i])
assert "codex exec --help" in verify_body
for flag in ("--ephemeral", "--skip-git-repo-check", "--sandbox", "--model"):
    assert flag in verify_body
PY
}

test_auxiliary_workflows_use_minimum_permissions() {
  local once="$ROOT_DIR/.github/workflows/keepalive-once.yml"
  grep -q 'contents: read' "$once" &&
    ! grep -q 'actions: write' "$once" &&
    [ ! -e "$ROOT_DIR/.github/workflows/monitor-recovery.yml" ]
}

test_debug_log_names_are_ignored() {
  local ignored
  grep -qxF 'common-debug.log' "$ROOT_DIR/.gitignore" &&
    grep -qxF 'model-debug.log' "$ROOT_DIR/.gitignore" &&
    grep -qxF 'model-debug2.log' "$ROOT_DIR/.gitignore" &&
    ! grep -qxF 'model-debug*.log' "$ROOT_DIR/.gitignore" || return 1
  ignored="$(printf '%s\n' common-debug.log model-debug.log model-debug2.log | git -c safe.directory="$ROOT_DIR" -C "$ROOT_DIR" check-ignore --stdin)"
  assert_eq $'common-debug.log\nmodel-debug.log\nmodel-debug2.log' "$ignored"
}

test_prompt_pool_is_professional_and_bounded() {
  local prompts="$ROOT_DIR/scripts/prompts.txt" count
  count="$(grep -cve '^[[:space:]]*$' -e '^[[:space:]]*#' "$prompts")"
  [ "$count" -ge 66 ] && [ "$count" -le 72 ] &&
    ! grep -Eiq 'avoid detection|capital of|boiling point|2 \+ 2|hello world|what is 15|atomic number|square root of 64|seconds are in an hour' "$prompts" &&
    assert_eq "$count" "$(grep -Eic '100.?300[[:space:]]*token' "$prompts")" &&
    python - "$prompts" <<'PY'
import pathlib, sys
lines = [line for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip() and not line.lstrip().startswith("#")]
assert sum(len(line) >= 200 for line in lines) >= 50
assert sum(len(line.split()) >= 300 for line in lines) >= 3
assert all(len(line) <= 2400 for line in lines)
PY
}

test_readme_and_env_describe_dual_pool_controls() {
  grep -q 'ANYROUTER_BASE_URL="https://anyrouter.top/v1"' "$ROOT_DIR/.env.example" &&
    grep -q 'ANYROUTER_CLAUDE_MODEL' "$ROOT_DIR/.env.example" &&
    grep -q 'ANYROUTER_GPT_MODEL' "$ROOT_DIR/.env.example" &&
    grep -q 'ANYROUTER_KEEPALIVE_SEC' "$ROOT_DIR/.env.example" &&
    grep -Fq 'opus[1m]' "$ROOT_DIR/.env.example" &&
    grep -q '3.*10.*秒' "$ROOT_DIR/README.md" &&
    grep -q '180.*300.*秒' "$ROOT_DIR/README.md" &&
    grep -q 'ANYROUTER_KEEPALIVE_SEC' "$ROOT_DIR/README.md" &&
    grep -q '4.*小时.*50.*分钟' "$ROOT_DIR/README.md" &&
    grep -q 'mode.*stop' "$ROOT_DIR/README.md" &&
    grep -q 'Cancel' "$ROOT_DIR/README.md" &&
    grep -q '次日' "$ROOT_DIR/README.md" &&
    grep -q 'Variables' "$ROOT_DIR/README.md" &&
    grep -q 'Claude Code CLI' "$ROOT_DIR/README.md" &&
    grep -q 'Codex CLI' "$ROOT_DIR/README.md" &&
    grep -q 'Responses' "$ROOT_DIR/README.md" &&
    grep -Fq 'opus[1m]' "$ROOT_DIR/README.md" &&
    grep -Fq 'ANTHROPIC_DEFAULT_OPUS_MODEL' "$ROOT_DIR/README.md" &&
    grep -q 'CLI退出码' "$ROOT_DIR/README.md" &&
    grep -q 'model_or_protocol_error' "$ROOT_DIR/README.md" &&
    grep -q '假.*codex' "$ROOT_DIR/README.md" &&
    grep -q '无法自动感知.*本地.*mode=stop' "$ROOT_DIR/README.md"
}

test_workflows_use_approved_endpoint_and_keepalive_variable() {
  local workflow
  for workflow in keepalive.yml keepalive-once.yml; do
    grep -q 'https://anyrouter.top/v1' "$ROOT_DIR/.github/workflows/$workflow" &&
      grep -q 'KEEPALIVE_SEC: ${{ vars.ANYROUTER_KEEPALIVE_SEC }}' "$ROOT_DIR/.github/workflows/$workflow" || return
  done
}

run_relay_tests() {
  run_case "workflows use the approved endpoint and pass ANYROUTER_KEEPALIVE_SEC" test_workflows_use_approved_endpoint_and_keepalive_variable
  run_case "stop marker blocks only older chain epochs" test_chain_is_stopped_respects_epoch
  run_case "latest unexpired stop artifact is downloaded without credential logging" test_latest_marker_download_uses_newest_unexpired_artifact
  run_case "GitHub API timeout settings must be positive integers" test_github_curl_rejects_invalid_timeout_settings
  run_case "stop marker JSON contains only public fields" test_stop_marker_has_only_public_fields
  run_case "stop scans twice and cancels every active run except itself" test_stop_scans_twice_and_cancels_active_runs
  run_case "stop reaches the second scan after the first list request fails" test_stop_second_scan_runs_after_first_list_failure
  run_case "stop reaches the second scan after a cancel failure and catches a new run" test_stop_second_scan_runs_after_cancel_failure_and_catches_new_run
  run_case "relay dispatch body contains only allowlisted state" test_relay_payload_is_allowlisted_and_secret_free
  run_case "stop reports a failed list or cancel scan" test_stop_cancel_failure_is_not_silenced
  run_case "stopped relay exits before workers and token use" test_stopped_relay_exits_before_workers_or_token_use
  run_case "relay rejects a missing or invalid chain epoch" test_relay_requires_a_valid_inherited_epoch
  run_case "start precheck outputs are reused by the formal run step" test_start_precheck_outputs_are_reused_by_the_run_step
  run_case "once mode starts both pool workers concurrently and never relays" test_once_starts_two_pool_workers_in_parallel_without_relay
  run_case "coordinator force-kills both ignored worker trees and removes state" test_coordinator_force_kills_both_worker_trees_and_state_dir
  run_case "pool workers receive only the single Anyrouter token plus mail credentials" test_formal_workers_receive_only_secrets_they_need
  run_case "two config_error pools finish instead of relaying forever" test_two_config_errors_end_without_relay
  run_case "model discovery failures send safe per-pool configuration notifications" test_model_discovery_failures_send_safe_config_notifications
  run_case "formal coordinator falls back across fresh discovered candidates" test_formal_fresh_discovery_falls_back_to_next_candidate
  run_case "formal coordinator rediscovery replaces a stale inherited relay model" test_formal_relay_rediscovery_replaces_stale_inherited_model
  run_case "formal coordinator keeps a Variable model on HTTP 429" test_formal_variable_429_never_switches_model
  run_case "formal coordinator stops on authentication without model switching" test_formal_authentication_error_never_switches_or_rediscovers
  run_case "keepalive workflow has separate concurrency and step-local Secrets" test_workflows_enforce_stop_and_secret_boundaries
  run_case "workflow mode is validated as inert data before shell use" test_workflow_mode_is_validated_as_data
  run_case "every checkout disables persisted Git credentials" test_every_checkout_disables_persisted_credentials
  run_case "once and legacy workflows use the new safe defaults" test_once_and_legacy_workflows_use_new_entrypoints
  run_case "auxiliary workflows request only read permissions" test_auxiliary_workflows_use_minimum_permissions
  run_case "debug log names are ignored without requiring local log files" test_debug_log_names_are_ignored
  run_case "prompt pool contains 66-72 professional bounded prompts" test_prompt_pool_is_professional_and_bounded
  run_case "README and env example document dual-pool operation" test_readme_and_env_describe_dual_pool_controls
}

case "${1:-all}" in
  all) run_common_tests; run_model_tests; run_adapter_tests; run_worker_tests; run_relay_tests ;;
  common) run_common_tests ;;
  models) run_model_tests ;;
  adapters) run_adapter_tests ;;
  worker) run_worker_tests ;;
  relay) run_relay_tests ;;
  *) printf 'Unknown test group: %s\n' "$1" >&2; exit 2 ;;
esac

printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
