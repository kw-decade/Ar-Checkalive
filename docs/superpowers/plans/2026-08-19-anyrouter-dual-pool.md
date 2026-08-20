# Anyrouter Dual Pool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将现有 Claude 单池健康检查改造成 GitHub Actions 中并行运行的 Claude/GPT 双池挤号、持续保活和 4 小时 50 分钟自动 relay 系统，并保留可验证的 stop 入口。

**Architecture:** 用共享 Bash 库统一读取 Secret、规范化 base URL、模型发现、随机等待、邮件脱敏和状态文件格式；用两个独立 adapter 分别调用 Claude CLI/Anthropic 兼容接口与 GPT `chat/completions` 接口；Claude、GPT 各自由一个独立后台 worker 管理 `probing/keepalive/config_error/stopped` 状态，协调器并发启动两者，在截止前通过 GitHub Actions REST API dispatch relay。保活链使用固定 concurrency group；`mode=stop` 使用独立 group，写一天有效的无 Secret stop marker，并两次扫描取消旧链，防止已排队 relay 复活。

**Tech Stack:** Bash 5、GitHub Actions、`curl`、`jq` 与 `unzip`（runner 自带）、Claude Code CLI、BATS（若环境已安装）、GitHub Actions REST API。

---

## 文件地图

实施时只修改下列业务文件，其他文件保持不动：

- Create: `scripts/lib/common.sh` — 配置、URL、token 脱敏、随机数、链路 epoch、状态序列化和安全邮件。
- Create: `scripts/lib/model-discovery.sh` — `/models` 请求、家族过滤、稳定排序和 Variable 覆盖验证。
- Create: `scripts/lib/actions-api.sh` — 使用 `curl` 查询 stop marker、dispatch relay、列出并取消 workflow runs。
- Create: `scripts/adapters/claude.sh` — 单次 Claude 调用和结果归一化。
- Create: `scripts/adapters/gpt.sh` — 单次 GPT `chat/completions` 调用和结果归一化。
- Create: `scripts/pool-worker.sh` — 一个池的发现、挤号、保活、状态文件和状态转换。
- Create: `scripts/run-dual-pool.sh` — 两个独立 worker 进程的并发编排、stop marker 检查、REST relay dispatch 和清理。
- Create: `scripts/stop-chain.sh` — 写一天有效的停止标记，并对同一 workflow 做两轮取消扫描。
- Modify: `.github/workflows/keepalive.yml` — cron、`start|relay|stop` 输入、权限、环境变量和约 4 小时 50 分钟运行参数。
- Modify: `.github/workflows/keepalive-once.yml` — 默认地址和一次性双池验证入口。
- Modify: `.github/workflows/monitor-recovery.yml` — 默认地址与共享配置保持一致，避免旧入口继续调用旧 FC 地址。
- Modify: `scripts/prompts.txt` — 全部替换为专业编程 prompt，保持 60 条以上并清除常识题。
- Modify: `.env.example` — 只记录非敏感变量名称和新的默认地址，不放真实值。
- Modify: `README.md` — 解释单 key、双池、模型 Variables、成功邮件、relay 和 stop 操作。
- Create: `tests/test_common.bats` — 共享配置与脱敏测试。
- Create: `tests/test_model_discovery.bats` — 模型筛选、排序、覆盖和错误分类测试。
- Create: `tests/test_adapters.bats` — Claude/GPT adapter 的成功、429、认证错误和空响应测试。
- Create: `tests/test_pool_worker.bats` — 独立状态机、间隔和通知去重测试。
- Create: `tests/test_relay.bats` — relay 参数脱敏、dispatch 失败和 stop 模式测试。
- Modify: `tests/test_keepalive.bats` — 将旧的单池假设改成新默认值和兼容入口测试。

所有新 Bash 文件都使用 `set -euo pipefail`，通过 `SCRIPT_DIR` 解析仓库内路径，不依赖当前工作目录。

## Task 1: 建立共享配置和安全边界

**Files:**
- Create: `scripts/lib/common.sh`
- Test: `tests/test_common.bats`

- [ ] **Step 1: 写失败测试，先锁定 URL、单 key 和日志脱敏行为**

在 `tests/test_common.bats` 写入以下测试。测试只使用假值，不访问网络：

```bash
setup() {
  export TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR/home"
  mkdir -p "$HOME"
  source scripts/lib/common.sh
}

teardown() { rm -rf "$TEST_DIR"; }

@test "normalize_base_url removes trailing slash without duplicating v1" {
  run normalize_base_url "https://anyrouter.top/v1///"
  [ "$status" -eq 0 ]
  [ "$output" = "https://anyrouter.top/v1" ]
}

@test "load_single_token takes the first non-empty secret line" {
  export ANYROUTER_TOKENS=$'\n\nsk-ant-test-one\nsk-ant-test-two'
  run load_single_token
  [ "$status" -eq 0 ]
  [ "$output" = "sk-ant-test-one" ]
}

@test "safe_token_preview never prints the full token" {
  run safe_token_preview "sk-ant-1234567890"
  [ "$status" -eq 0 ]
  [ "$output" = "sk-a..." ]
  [[ "$output" != *"1234567890"* ]]
}

@test "random_between returns an integer in inclusive bounds" {
  run random_between 3 10 7
  [ "$status" -eq 0 ]
  [ "$output" -ge 3 ]
  [ "$output" -le 10 ]
}
```

- [ ] **Step 2: 运行测试确认它因函数不存在而失败**

运行：

```bash
bats tests/test_common.bats
```

预期：测试失败并报告 `normalize_base_url`、`load_single_token` 或 `safe_token_preview` 未定义，而不是因为网络或语法错误。

- [ ] **Step 3: 写最小共享实现**

在 `scripts/lib/common.sh` 实现以下接口：

```bash
#!/usr/bin/env bash
set -euo pipefail

DEFAULT_BASE_URL="https://anyrouter.top/v1"

normalize_base_url() {
  local value="${1:-$DEFAULT_BASE_URL}"
  value="${value%/}"
  value="${value%/}"
  value="${value%/}"
  printf '%s\n' "$value"
}

load_single_token() {
  local line
  while IFS= read -r line; do
    line="${line//$'\r'/}"
    [ -n "${line//[[:space:]]/}" ] || continue
    printf '%s\n' "$line"
    return 0
  done <<< "${ANYROUTER_TOKENS:-}"
  printf '%s\n' "No token configured" >&2
  return 1
}

safe_token_preview() {
  local token="$1"
  printf '%s...\n' "${token:0:4}"
}

random_between() {
  local min="$1" max="$2" seed="${3:-$RANDOM}"
  [ "$max" -ge "$min" ] || return 2
  printf '%s\n' "$((min + (seed % (max - min + 1))))"
}
```

共享库还要提供 `write_state_file`、`read_state_value` 和 `send_email_safe`；邮件函数必须在临时文件上使用 `curl smtps://smtp.qq.com:465`，失败时返回非零但由调用者用 `|| true` 隔离，不打印授权码。状态文件只允许 `phase`、`model`、`notified`、`chain_id`、`chain_started_epoch` 五个键。

- [ ] **Step 4: 运行测试确认通过并做语法检查**

运行：

```bash
bats tests/test_common.bats
bash -n scripts/lib/common.sh
```

预期：新增测试全部 PASS，语法检查无输出。

## Task 2: 实现模型发现和覆盖

**Files:**
- Create: `scripts/lib/model-discovery.sh`
- Test: `tests/test_model_discovery.bats`

- [ ] **Step 1: 写假 `curl` 和失败测试**

测试先把假 `curl` 放在 `PATH` 前面，让 `/models` 返回固定 JSON：

```bash
setup() {
  export TEST_DIR="$(mktemp -d)"
  export PATH="$TEST_DIR/bin:$PATH"
  mkdir -p "$TEST_DIR/bin"
  cat > "$TEST_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"data":[{"id":"text-embedding-3-small"},{"id":"claude-sonnet-4-20250514"},{"id":"claude-opus-4-20250601"},{"id":"gpt-9.1-mini"},{"id":"gpt-9.2-example"},{"id":"gpt-audio-example"}]}
JSON
SH
  chmod +x "$TEST_DIR/bin/curl"
  source scripts/lib/common.sh
  source scripts/lib/model-discovery.sh
}

teardown() { rm -rf "$TEST_DIR"; }

@test "discover_model selects the newest Claude family model" {
  run discover_model claude "https://anyrouter.top/v1" "sk-ant-test" ""
  [ "$status" -eq 0 ]
  [ "$output" = "claude-opus-4-20250601" ]
}

@test "discover_model selects the newest GPT family model and excludes audio" {
  run discover_model gpt "https://anyrouter.top/v1" "sk-ant-test" ""
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-9.2-example" ]
}

@test "discover_model honors a non-empty Variable override" {
  run discover_model gpt "https://anyrouter.top/v1" "sk-ant-test" "gpt-override-example"
  [ "$status" -eq 0 ]
  [ "$output" = "gpt-override-example" ]
}
```

- [ ] **Step 2: 运行测试确认模型发现接口尚不存在**

运行 `bats tests/test_model_discovery.bats`，预期因 `discover_model` 未定义而失败。

- [ ] **Step 3: 实现确定性的发现、过滤和排序**

在 `scripts/lib/model-discovery.sh` 实现：

```bash
discover_model() {
  local family="$1" base_url="$2" token="$3" override="${4:-}"
  if [ -n "$override" ]; then
    printf '%s\n' "$override"
    return 0
  fi
  local json
  json="$(curl -fsS --max-time 20 -H "Authorization: Bearer $token" "$(normalize_base_url "$base_url")/models")" || return 3
  printf '%s\n' "$json" | jq -r --arg family "$family" '
    .data[]?.id
    | select((ascii_downcase | contains("embedding") or contains("image") or contains("audio") or contains("tts") or contains("transcribe") or contains("realtime")) | not)
    | select(if $family == "claude" then (ascii_downcase | contains("claude")) else startswith("gpt-") end)
  ' | sort -V -r | head -n 1
}
```

实现必须检查空候选并返回专用错误码；测试环境无 `jq` 时不要安装全局包，而是在 workflow 安装步骤中使用 runner 自带版本并在测试报告中说明依赖。覆盖值只在非空时生效；验证调用的 429 归类为“模型存在但容量不足”。

- [ ] **Step 4: 运行模型测试和语法门禁**

```bash
bats tests/test_model_discovery.bats
bash -n scripts/lib/model-discovery.sh
```

预期：三个测试 PASS，且 `embedding`、audio 模型从未被选中。

## Task 3: 建立 Claude 与 GPT 独立 adapter

**Files:**
- Create: `scripts/adapters/claude.sh`
- Create: `scripts/adapters/gpt.sh`
- Test: `tests/test_adapters.bats`

- [ ] **Step 1: 写失败测试，使用假 CLI 和假 curl**

每个 adapter 接口固定为：

```text
bash scripts/adapters/claude.sh TOKEN BASE_URL MODEL PROMPT
bash scripts/adapters/gpt.sh TOKEN BASE_URL MODEL PROMPT
```

成功时 stdout 只输出 `status=success`, `http_code=200`, `message=non_empty_response` 等安全字段；429 输出 `status=rate_limited`；401/403 输出 `status=invalid`；空响应输出 `status=retryable`。测试脚本必须断言 token 不出现在 stdout/stderr：

```bash
@test "gpt adapter maps HTTP 429 without exposing token" {
  cat > "$TEST_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"error":{"message":"busy"}}'
exit 22
SH
  chmod +x "$TEST_DIR/bin/curl"
  run bash scripts/adapters/gpt.sh "sk-ant-secret-value" "https://anyrouter.top/v1" "gpt-example" "Review this function"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=rate_limited"* ]]
  [[ "$output" != *"sk-ant-secret-value"* ]]
}

@test "claude adapter maps a successful fake CLI response" {
  cat > "$TEST_DIR/bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'Use a bounded queue and add a timeout.'
exit 0
SH
  chmod +x "$TEST_DIR/bin/claude"
  run bash scripts/adapters/claude.sh "sk-ant-secret-value" "https://anyrouter.top/v1" "claude-opus-4-20250601" "Review this function"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=success"* ]]
  [[ "$output" != *"sk-ant-secret-value"* ]]
}
```

- [ ] **Step 2: 运行测试确认 adapter 尚不存在**

运行 `bats tests/test_adapters.bats`，预期因两个脚本不存在而失败。

- [ ] **Step 3: 实现最小 adapter 和统一结果分类**

Claude adapter 使用临时 `HOME`/环境变量调用 Claude CLI，不能写入或删除真实用户的 `~/.claude/settings.json`。GPT adapter 向 `${BASE_URL}/chat/completions` 发送如下 JSON，并把响应写入 `mktemp` 文件后立即删除：

```json
{
  "model": "gpt-example",
  "messages": [{"role": "user", "content": "Review this function"}],
  "max_tokens": 600
}
```

实际模型由参数传入，不把示例名写死。HTTP 429 映射到 `rate_limited`；401/403 和明确的 `model_not_found` 映射到 `invalid`；连接失败、超时、5xx 映射到 `retryable`。诊断只保留状态码和固定短语，不回显服务器响应原文。

- [ ] **Step 4: 运行 adapter 测试、shellcheck 可选检查和语法门禁**

```bash
bats tests/test_adapters.bats
bash -n scripts/adapters/*.sh
if command -v shellcheck >/dev/null 2>&1; then shellcheck scripts/adapters/*.sh; fi
```

没有 `shellcheck` 时不安装全局依赖，报告中写明跳过原因。

## Task 4: 实现单池 worker 状态机和随机节奏

**Files:**
- Create: `scripts/pool-worker.sh`
- Test: `tests/test_pool_worker.bats`

- [ ] **Step 1: 写状态转换和独立计时测试**

测试用 `ADAPTER_COMMAND` 假命令返回预设序列，用 `SLEEP_COMMAND` 只记录秒数不真正等待。至少覆盖：

```bash
@test "429 keeps a pool in probing and uses a 3-10 second delay" {
  export ADAPTER_RESULTS=$'status=rate_limited\nstatus=success'
  export SLEEP_COMMAND="$TEST_DIR/record-sleep.sh"
  export PROBE_MIN_SEC=3 PROBE_MAX_SEC=10 MAX_DURATION_SEC=1 DRY_RUN=true
  run bash scripts/pool-worker.sh gpt "$TEST_TOKEN" "$BASE_URL" "gpt-example" "$TEST_DIR/gpt.state"
  [ "$status" -eq 0 ]
  grep -Eq '^phase=keepalive$' "$TEST_DIR/gpt.state"
  grep -Eq '^sleep=([3-9]|10)$' "$TEST_DIR/sleeps.log"
}

@test "Claude and GPT state files do not share notification flags" {
  printf 'phase=keepalive\nmodel=claude-opus\nnotified=true\n' > "$TEST_DIR/claude.state"
  printf 'phase=probing\nmodel=gpt-example\nnotified=false\n' > "$TEST_DIR/gpt.state"
  run state_value "$TEST_DIR/claude.state" phase
  [ "$output" = "keepalive" ]
  run state_value "$TEST_DIR/gpt.state" phase
  [ "$output" = "probing" ]
}

@test "successful transition sends one notification before keepalive" {
  export ADAPTER_RESULTS=$'status=success\nstatus=success'
  export EMAIL_LOG="$TEST_DIR/email.log" DRY_RUN=true MAX_DURATION_SEC=1
  run bash scripts/pool-worker.sh claude "$TEST_TOKEN" "$BASE_URL" "claude-opus" "$TEST_DIR/claude.state"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^claude|success$' "$EMAIL_LOG")" -eq 1 ]
}
```

- [ ] **Step 2: 运行测试确认 worker 尚未实现**

运行 `bats tests/test_pool_worker.bats`，预期因 `scripts/pool-worker.sh` 和 `state_value` 尚不存在而失败。

- [ ] **Step 3: 实现最小状态机**

`pool-worker.sh` 接受 `pool token base_url model state_file` 五个参数，支持环境变量 `PROBE_MIN_SEC=3`、`PROBE_MAX_SEC=10`、`KEEPALIVE_MIN_SEC=30`、`KEEPALIVE_MAX_SEC=120`、`MAX_DURATION_SEC=17400`、`DRY_RUN` 和测试用的 `ADAPTER_COMMAND`。核心循环必须按以下顺序执行：

```bash
while ! deadline_reached; do
  result="$(call_adapter "$pool" "$token" "$base_url" "$model" "$(pick_prompt)")"
  status="$(result_value "$result" status)"
  case "$status" in
    success) transition_to_keepalive_and_notify_once ;;
    rate_limited|retryable) transition_to_probing ;;
    invalid) transition_to_config_error_and_exit ;;
  esac
  sleep_random_for_current_phase
done
```

状态文件使用原子写入，只包含 `phase`, `model`, `notified`, `chain_id`, `chain_started_epoch`；任何 token 都不落盘。收到 SIGTERM/SIGINT 时写 `phase=stopped` 并退出 0。邮件函数失败不改变状态。进入 `keepalive` 后间隔范围必须是 30–120 秒，不能复用 3–10 秒的挤号范围。

- [ ] **Step 4: 运行 worker 测试并检查边界**

```bash
bats tests/test_pool_worker.bats
bash -n scripts/pool-worker.sh
```

预期：状态转换、通知去重和两个阶段的间隔测试全部 PASS；失败输出不得包含测试 token 的完整值。

## Task 5: 实现双池协调、relay 和 stop 状态传递

**Files:**
- Create: `scripts/run-dual-pool.sh`
- Create: `tests/test_relay.bats`

- [ ] **Step 1: 写 relay/stop 的失败测试**

测试用本地 marker 和假 `curl` 记录 REST 请求，不调用真实 GitHub：

```bash
@test "stopped relay exits before either model adapter" {
  printf '{"stop_before_epoch":200}\n' > "$TEST_DIR/stop.json"
  export STOP_MARKER_FILE="$TEST_DIR/stop.json" CHAIN_STARTED_EPOCH=100
  export ADAPTER_CALLS="$TEST_DIR/adapter.calls" ANYROUTER_TOKENS="sk-ant-secret-value"
  run bash scripts/run-dual-pool.sh --mode relay
  [ "$status" -eq 0 ]
  [ ! -s "$ADAPTER_CALLS" ]
  [[ "$output" != *"sk-ant-secret-value"* ]]
}

@test "a new chain epoch is not blocked by an older marker" {
  printf '{"stop_before_epoch":200}\n' > "$TEST_DIR/stop.json"
  source scripts/lib/actions-api.sh
  run chain_is_stopped "$TEST_DIR/stop.json" 201
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "stop marker contains only the cutoff epoch and workflow id" {
  run bash scripts/stop-chain.sh write-marker "$TEST_DIR/stop.json" 200
  [ "$status" -eq 0 ]
  jq -e '.stop_before_epoch == 200 and .workflow_id == "keepalive.yml"' "$TEST_DIR/stop.json"
  ! grep -q 'sk-ant-' "$TEST_DIR/stop.json"
}

@test "stop scans twice and cancels every active status except itself" {
  export ACTIONS_RUNS_FIXTURE="$TEST_DIR/runs.json" CURL_LOG="$TEST_DIR/curl.log"
  export GITHUB_RUN_ID=999 STOP_SCAN_DELAY_SEC=0
  run bash scripts/stop-chain.sh cancel-runs
  [ "$status" -eq 0 ]
  [ "$(grep -c '/actions/runs?' "$CURL_LOG")" -eq 2 ]
  grep -q '/actions/runs/101/cancel' "$CURL_LOG"
  grep -q '/actions/runs/102/cancel' "$CURL_LOG"
  grep -q '/actions/runs/103/cancel' "$CURL_LOG"
  grep -q '/actions/runs/104/cancel' "$CURL_LOG"
  ! grep -q '/actions/runs/999/cancel' "$CURL_LOG"
}
```

`runs.json` 固定包含 ID 101–104，状态依次为 `queued`、`pending`、`waiting`、`in_progress`；另含一个 `completed` run 和当前 stop run 999。假 `curl` 对列表请求返回该 fixture，对 cancel/dispatch 请求只把 URL 与 JSON body 写入 `CURL_LOG`，不记录 Authorization header。

- [ ] **Step 2: 运行测试确认协调器尚不存在**

运行 `bats tests/test_relay.bats`，预期因协调器脚本不存在而失败。

- [ ] **Step 3: 实现 stop marker、双扫描取消和安全 relay**

协调器必须：

1. `scripts/stop-chain.sh write-marker PATH EPOCH` 只写 `stop_before_epoch` 和 `workflow_id`。workflow 随后用 `actions/upload-artifact@v4` 上传为 `anyrouter-stop-marker-${{ github.run_id }}`，设置 `retention-days: 1`。
2. `scripts/stop-chain.sh cancel-runs` 使用 REST API 列出同一 workflow 的 runs，排除 `GITHUB_RUN_ID`，取消 `queued`、`pending`、`waiting`、`in_progress`；等待 `STOP_SCAN_DELAY_SEC`（生产值 5 秒）后完整重复一次。
3. `mode=start` 和 cron 生成新的 `chain_started_epoch=$(date +%s)`；`mode=relay` 必须继承原值。relay 在加载 Anyrouter Secret、发现模型或启动 worker 之前下载一天内最新 stop marker；当 `chain_started_epoch <= stop_before_epoch` 时立即退出。
4. 未命中 marker 时，协调器准备独立的 Claude/GPT state 文件，并分别后台启动两个 `pool-worker.sh`。使用 `trap` 在退出和 SIGTERM 时杀掉两个子进程并等待，避免孤儿请求。
5. 在 `MAX_DURATION_SEC=17400` 之前读取两份状态，用 GitHub REST API dispatch 同一 workflow，白名单字段为 `mode`, 两个 phase、两个 model、两个 notified、`chain_id`, `chain_started_epoch`。relay 成功后清理退出；失败时发送安全告警，绝不把 token 写进请求 body。

REST dispatch 的请求形态：

```bash
payload="$(jq -n \
  --arg ref "$GITHUB_REF_NAME" --arg mode relay \
  --arg cp "$claude_phase" --arg gp "$gpt_phase" \
  --arg cm "$claude_model" --arg gm "$gpt_model" \
  --arg cn "$claude_notified" --arg gn "$gpt_notified" \
  --arg cid "$chain_id" --arg epoch "$chain_started_epoch" \
  '{ref:$ref,inputs:{mode:$mode,claude_phase:$cp,gpt_phase:$gp,claude_model:$cm,gpt_model:$gm,claude_notified:$cn,gpt_notified:$gn,chain_id:$cid,chain_started_epoch:$epoch}}')"
curl -fsS -X POST \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/$GITHUB_REPOSITORY/actions/workflows/keepalive.yml/dispatches" \
  -d "$payload"
```

`scripts/lib/actions-api.sh` 集中实现 artifact 查询/下载、`chain_is_stopped`、dispatch 和 cancel。工作流权限使用 `permissions: actions: write` 和读取仓库所需的最小权限；不要申请 `contents: write`。`chain_id` 使用当前 run ID 加随机短后缀，不能包含 Secret。

- [ ] **Step 4: 运行 relay/stop 测试与语法检查**

```bash
bats tests/test_relay.bats
bash -n scripts/run-dual-pool.sh scripts/stop-chain.sh scripts/lib/actions-api.sh
```

预期：旧链 relay 在任何模型请求前退出；新 epoch 不受旧 marker 影响；stop 做两轮扫描；REST relay 参数只有白名单状态且不包含完整 token。

## Task 6: 接入 GitHub Actions 工作流

**Files:**
- Modify: `.github/workflows/keepalive.yml`
- Modify: `.github/workflows/keepalive-once.yml`
- Modify: `.github/workflows/monitor-recovery.yml`

- [ ] **Step 1: 写工作流静态检查测试**

在 `tests/test_relay.bats` 增加文本断言：

```bash
@test "keepalive workflow has approved default and stop input" {
  grep -q 'https://anyrouter.top/v1' .github/workflows/keepalive.yml
  grep -q 'mode:' .github/workflows/keepalive.yml
  grep -q 'stop' .github/workflows/keepalive.yml
  grep -q 'actions: write' .github/workflows/keepalive.yml
  grep -q 'anyrouter-keepalive-chain' .github/workflows/keepalive.yml
  grep -q 'anyrouter-keepalive-stop' .github/workflows/keepalive.yml
  grep -q 'retention-days: 1' .github/workflows/keepalive.yml
}
```

- [ ] **Step 2: 运行静态测试确认旧 workflow 不满足要求**

运行 `bats tests/test_relay.bats`，预期该测试因旧 FC 地址和缺少 `mode/stop` 输入而失败。

- [ ] **Step 3: 修改 workflow 编排**

`keepalive.yml` 必须保留每日 UTC 18:00 cron，并增加 `workflow_dispatch.inputs.mode`，允许 `start`, `relay`, `stop`；增加 relay 状态字段与 `chain_started_epoch` 输入并设置安全默认值。`start`/`relay` job 使用固定 `anyrouter-keepalive-chain` concurrency group，stop job 使用独立 `anyrouter-keepalive-stop` group，不能让 stop 排在保活链后面。工作流设置 `timeout-minutes: 360`，运行脚本使用 `MAX_DURATION_SEC=17400`。

环境变量统一映射：

```yaml
permissions:
  actions: write
  contents: read

env:
  ANYROUTER_BASE_URL: ${{ inputs.base_url || 'https://anyrouter.top/v1' }}
  ANYROUTER_CLAUDE_MODEL: ${{ vars.ANYROUTER_CLAUDE_MODEL }}
  ANYROUTER_GPT_MODEL: ${{ vars.ANYROUTER_GPT_MODEL }}
```

Secret 只放在实际 `start`/`relay` 运行步骤的 `env` 中；`mode=stop` job 不注入 `ANYROUTER_TOKENS`、QQ 授权码或模型变量。stop job 依次执行：写 marker、用 `actions/upload-artifact@v4` 上传且 `retention-days: 1`、运行两轮取消扫描。所有 relay 在安装 Claude CLI 和发送模型请求之前核对 marker 与 `chain_started_epoch`。新 start 与 cron 生成新 epoch，relay 继承原 epoch。安装 Claude CLI 的步骤只在未命中 stop marker 的非 stop 模式执行。一次性 workflow 调用 `run-dual-pool.sh --once` 并使用新的默认地址；恢复监控至少改掉旧 FC 默认地址，避免用户从旧入口误调用。

- [ ] **Step 4: 运行 YAML 文本检查和全部语法门禁**

```bash
bats tests/test_relay.bats
bash -n scripts/*.sh
git diff --check
```

若 runner 没有 `actionlint`，不安装全局包；用 YAML 解析器或 GitHub Actions 页面做最终 workflow 验证，并在交付报告中标明。

## Task 7: 更新专业 prompt、配置模板和用户文档

**Files:**
- Modify: `scripts/prompts.txt`
- Modify: `.env.example`
- Modify: `README.md`
- Modify: `tests/test_keepalive.bats`

- [ ] **Step 1: 写 prompt 约束测试**

在 `tests/test_keepalive.bats` 增加：

```bash
@test "prompt pool has at least 60 professional programming entries" {
  count=$(grep -cve '^\s*$' -e '^#' scripts/prompts.txt)
  [ "$count" -ge 60 ]
  if grep -Eiq 'capital of|boiling point|2 \+ 2|hello world|what is 15' scripts/prompts.txt; then
    false
  fi
}

@test "prompt pool has no empty effective entries" {
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    [ -n "${line//[[:space:]]/}" ]
  done < scripts/prompts.txt
}
```

- [ ] **Step 2: 运行测试确认旧的轻量题会被捕获**

运行 `bats tests/test_keepalive.bats`，预期新增测试因旧的常识题而失败。

- [ ] **Step 3: 替换 prompt 池并更新配置说明**

将轻量常识题全部替换为代码审查、并发、错误处理、SQL、HTTP、Linux、CI、测试、安全和系统设计问题。每行一个 prompt，条目总数保持 60 条以上；大部分输入约 50–300 token，少数复杂题约 300–600 token，并在题目中要求回答约 100–300 token。不要把 token、邮箱或服务器密钥写入 prompt。`.env.example` 改为 `ANYROUTER_BASE_URL="https://anyrouter.top/v1"`、`ANYROUTER_CLAUDE_MODEL` 和 `ANYROUTER_GPT_MODEL` 可选覆盖，并说明真实值只放 GitHub Secrets/Variables。README 要用中文解释：两个池互不通用且各自 3–10 秒挤号、30–120 秒保活、成功邮件、约 4 小时 50 分钟 relay，以及系统不能自动感知本地开始使用。README 必须把 Actions 页面运行 `mode=stop` 写成正式停止方式，并说明直接 Cancel 只是不写 marker、可能漏掉已排队 relay 的不可靠兜底。

- [ ] **Step 4: 运行 prompt、语法和 diff 检查**

```bash
bats tests/test_keepalive.bats
bash -n scripts/*.sh
git diff --check
```

预期：prompt 约束测试 PASS，且旧的 FC 地址和轻量常识题不再出现在用户文档/配置示例中。

## Task 8: 全量验证与交付检查

**Files:**
- Verify: all files listed above

- [ ] **Step 0: 建立用户配置保护哨兵**

最终验证不得调用用户真实 Claude 配置。先记录真实配置是否存在及其哈希，但不读取或打印内容；所有后续测试把 `HOME` 和 `USERPROFILE` 指向 `mktemp -d`，并把假 `claude`、假 `curl` 放在临时 `PATH` 最前。验证结束后再次计算哈希并断言与开始时一致；若真实配置原本不存在，结束后也必须仍不存在。任何不能满足此隔离条件的验证命令直接跳过并报告。

- [ ] **Step 1: 运行独立语法门禁**

```bash
bash -n scripts/*.sh
```

预期：所有脚本退出码为 0；此命令必须独立运行，不能被后续命令掩盖失败。

- [ ] **Step 2: 运行 BATS（若可用）**

```bash
if command -v bats >/dev/null 2>&1; then bats tests; else echo 'BATS unavailable; skipped without installing global dependencies'; fi
```

预期：可运行时所有测试 PASS；不可运行时保留明确的跳过记录，不把跳过误报为通过。

- [ ] **Step 3: 做安全与配置静态扫描**

```bash
rg -n --glob '*.sh' --glob '*.yml' --glob '*.md' 'a-ocnfniawgw|settings\.json|echo .*TOKEN|set -x|sk-ant-[A-Za-z0-9]' .
rg -n 'https://anyrouter\.top/v1/v1|ANYROUTER_TOKENS.*workflow|QQ_SMTP_AUTH_CODE.*echo' .
git diff --check
```

预期：第一条只允许在历史说明或测试假值中出现已解释的安全匹配；第二条无输出。若发现完整 token、旧默认地址或重复 `/v1`，先修复再继续。

- [ ] **Step 4: 用假命令做端到端短跑**

用假 `curl`、假 `claude`、`DRY_RUN=true`、`MAX_DURATION_SEC=3` 运行：

```bash
ANYROUTER_TOKENS='sk-ant-test-only' \
ANYROUTER_BASE_URL='https://anyrouter.top/v1' \
DRY_RUN=true MAX_DURATION_SEC=3 \
bash scripts/run-dual-pool.sh --mode start
```

预期：日志显示 Claude/GPT 两个独立池、模型名和状态转换，不出现完整假 token；退出时没有残留临时状态或子进程。

- [ ] **Step 5: 汇报并由主 Agent 创建最终 commit**

汇报实际测试输出、未运行的工具及原因、修改文件和已知限制。确认所有门禁通过后，由主 Agent 按项目约定创建本地 Git commit；本前置 Worker 不执行 commit、push 或任何红线操作。

## 自审清单

- 设计中的单 key、独立 3–10 秒挤号、30–120 秒持续保活、成功邮件、4 小时 50 分 relay、手动 stop、自动模型发现/Variables 覆盖、双 adapter 和专业 prompt 均有对应任务。
- 计划没有依赖真实网络或真实 Secret；每个行为变化先写失败测试，再写实现，再运行通过测试。
- 默认 URL 在 workflow、脚本和 `.env.example` 的责任边界已明确，且有重复 `/v1` 检查。
- relay 参数白名单和 token 脱敏有独立测试；stop 模式不注入 Secret，也不发 Anyrouter 请求。
