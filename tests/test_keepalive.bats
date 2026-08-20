setup_file() {
  cd "$(dirname "$BATS_TEST_FILENAME")/.."
}

setup() {
  export TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR/home"
  export USERPROFILE="$HOME"
  export PATH="$TEST_DIR/bin:$PATH"
  mkdir -p "$HOME/.claude" "$TEST_DIR/bin"
  printf '%s\n' '{"sentinel":"keep-me"}' > "$HOME/.claude/settings.json"
  cat > "$TEST_DIR/bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'Mock Claude response'
SH
  chmod +x "$TEST_DIR/bin/claude"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "keepalive fails without a token" {
  run bash scripts/keepalive.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
}

@test "keepalive preserves the caller Claude configuration" {
  before="$(sha256sum "$HOME/.claude/settings.json" | cut -d' ' -f1)"
  run bash scripts/keepalive.sh sk-ant-test-only https://anyrouter.top/v1 claude-test
  [ "$status" -eq 0 ]
  after="$(sha256sum "$HOME/.claude/settings.json" | cut -d' ' -f1)"
  [ "$before" = "$after" ]
  grep -q 'keep-me' "$HOME/.claude/settings.json"
  [[ "$output" != *"sk-ant-test-only"* ]]
}

@test "prompt pool contains 66 to 72 professional entries" {
  count="$(grep -cve '^[[:space:]]*$' -e '^[[:space:]]*#' scripts/prompts.txt)"
  [ "$count" -ge 66 ]
  [ "$count" -le 72 ]
  ! grep -Eiq 'avoid detection|capital of|boiling point|2 \+ 2|hello world|atomic number' scripts/prompts.txt
}

@test "run-all fails safely without a token" {
  unset ANYROUTER_TOKENS
  run bash scripts/run-all.sh --once
  [ "$status" -ne 0 ]
  [[ "$output" == *"No token configured"* ]]
}

@test "new workflows use the approved endpoint" {
  grep -q 'https://anyrouter.top/v1' .github/workflows/keepalive.yml
  grep -q 'https://anyrouter.top/v1' .github/workflows/keepalive-once.yml
  grep -q 'https://anyrouter.top/v1' .github/workflows/monitor-recovery.yml
}
