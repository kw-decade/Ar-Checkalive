# Anyrouter 双池挤号与持续保活设计

**日期：** 2026-08-19
**状态：** 已获用户批准，进入实施计划阶段
**部署边界：** 仅 GitHub Actions

## 1. 背景与问题

现有项目只有 Claude 健康检查：它把一次真实问题交给 Claude CLI，按固定的长间隔轮询，并在接近 GitHub Actions 六小时上限时退出。用户需要的是两个相互独立的调度池：Claude 池和 GPT 池。一个 key 在 GPT 池排到可用，不代表 Claude 池也可用；因此两个池必须分别挤号、分别保活、分别通知。

GitHub Actions 单次运行有时长上限。工作流需要在约 4 小时 50 分钟时启动下一棒，避免等待平台强制终止。用户起床后通过手动 `mode=stop` 写入短期停止标记，并取消当前运行和已排队的 relay。Actions 无法读取用户电脑是否已经开始使用，因此系统不自动猜测停止时机；直接点击某一个 run 的 Cancel 只能作为不可靠兜底，因为已经 dispatch 的 relay 可能随后启动。

## 2. 已确认的需求

1. 使用一个 Anyrouter key；Claude 和 GPT 请求使用同一个 Secret 中的 key，但状态和计时完全分开。
2. 默认调用地址改为 `https://anyrouter.top/v1`，所有路径拼接都必须避免重复 `/v1`。
3. Claude 和 GPT 分别运行在两个独立 GitHub Jobs 或两个独立后台进程中；两者在挤号阶段各自在请求完成后随机等待 3–10 秒。一个池的请求或等待不得暂停另一个池。
4. 某个池首次得到有效成功响应后，立即发送 QQ 邮件提醒该池可以使用，然后切换到保活阶段。
5. 保活阶段每次请求完成后随机等待 30–120 秒，持续到用户手动停止；保活中再次遇到 429 时，该池回到挤号阶段。
6. 单次运行约 4 小时 50 分钟时自动 relay 下一棒，继承非敏感的池状态和已选模型，避免每棒重复发送成功提醒。
7. 手动停止使用独立于保活链的 concurrency group，写入不含 Secret 的短期 stop marker，并两次扫描、取消同一 workflow 中其他仍处于 `queued`、`pending`、`waiting`、`in_progress` 的 run；新 start 或次日 cron 使用新的链路 epoch，不受旧标记影响。
8. 模型默认自动从 `/models` 发现：Claude 只从 Claude 家族中选，GPT 只从 GPT 家族中选，并尽量选择最新稳定文本模型。GitHub Variables 可覆盖自动发现结果；不把某个 GPT 名称永久写死。
9. Claude 与 GPT 使用独立适配器。Claude 适配器封装 Claude CLI/Anthropic 兼容调用；GPT 适配器封装 OpenAI 兼容的 `chat/completions` 调用；两者向状态机返回统一结果。
10. Prompt 池全部是专业编程或软件工程问题，保留并扩充到 60 条以上。大部分输入约 50–300 token，少数复杂题约 300–600 token，并明确要求回答约 100–300 token；删除轻量常识题。每次请求随机选择一条。

## 3. 目标与非目标

### 目标

- 在一个 Action 中可靠地并行维护两个独立池。
- 清楚区分“还在排队”“已经可用”“临时网络故障”“配置错误”。
- 成功通知只对每个池发送一次，relay 后不重复轰炸邮箱；状态从保活退回挤号时可再次通知恢复。
- 不把完整凭据泄露到日志、邮件、workflow input、artifact 或 relay 参数。
- 可用假命令和短时间参数离线测试，不依赖真实 Anyrouter。
- 最终验证只使用临时 HOME、假 Claude CLI、假 curl 和假 token，并以配置哨兵证明用户真实 `.claude/settings.json` 在验证前后完全不变；任何无法隔离的真实调用都不执行。

### 非目标

- 不判断 Anyrouter 是否真的会因请求而提升优先级；项目只报告观察到的 HTTP/CLI 结果。
- 不读取用户本地编辑器、桌面或网络流量来推断“用户开始使用”。
- 不增加数据库、网页控制台、常驻服务器或新的全局依赖。
- 不在本次改造中管理多个不同账号；旧多行 token 格式仅作为兼容输入，不改变单 key 的正式行为。

## 4. 用户操作流程

### 自动启动

每天 UTC 18:00（北京时间/新加坡时间次日 02:00）由 cron 启动 `mode=start`。用户也可以在 Actions 页面手动启动同一个工作流。启动时读取 `ANYROUTER_TOKENS`、邮件 Secret、可选模型 Variables 和可选 base URL input；未提供 base URL 时使用 `https://anyrouter.top/v1`。

### 双池运行

工作流启动一个双池协调器，再由协调器创建两个真正独立的执行单元：Claude worker 和 GPT worker。实现可以选择两个独立 GitHub Jobs，或在同一 Job 中运行两个互不串行等待的后台进程；本设计的 Bash 实施方案使用两个后台进程。协调器为 Claude、GPT 各维护一份状态：

```text
discovering -> probing -> keepalive -> probing (遇到 429)
     |              |           |
  config_error   stopped     stopped
```

- `discovering`：优先使用对应 Variable；没有覆盖值时请求 `/models`，按家族过滤并排序，选择一个候选模型。候选模型不存在或协议不兼容时尝试下一个；没有候选时将该池标为 `config_error` 并邮件告警。
- `probing`：执行该池的适配器调用。2xx 且响应体包含可解析的非空回答视为成功；429 保持 `probing` 并在 3–10 秒后重试；网络错误、超时和 5xx 也重试；401、403、模型不存在或参数错误标为配置错误。
- `keepalive`：以 30–120 秒随机间隔发送下一条专业编程 prompt。2xx 继续保活；429 回到该池自己的 `probing`，不影响另一池；认证或模型错误停止该池并通知。
- `stopped`：收到 stop 或 relay 截止后清理临时文件并退出。

两个池的下一次执行时间各自计算。协调器不能使用“Claude 完成后再等 GPT”的串行循环；Claude worker 与 GPT worker 各自完成请求后独立抽取 3–10 秒的挤号等待或 30–120 秒的保活等待，并各自维护状态文件、进程和计时器。

### 成功邮件

首次从 `probing` 进入 `keepalive` 时发送一封 QQ 邮件，主题包含池名（Claude 或 GPT）和“可以使用”，正文包含模型名、时间、当前 Actions 链接和手动停止提示。正文不包含 token 或完整响应。邮件发送失败只记录告警，不得让池停止。

如果 `keepalive` 因 429 回到 `probing`，下一次成功可以再次发送“恢复可用”提醒，但同一状态期间只发一次；脚本需在进程状态中记录通知去重标记，并在 relay input 中传递该标记。

## 5. 模型发现与覆盖

统一的 `normalize_base_url` 先去掉末尾 `/`。模型接口为 `${BASE_URL}/models`，使用 Bearer key，响应按 OpenAI 风格读取 `data[].id`；无法解析时把具体原因归类为发现失败，不打印认证头。

筛选规则：

- Claude 候选的 ID（不区分大小写）包含 `claude`，且不包含 `embedding`、`image`、`audio`、`tts`、`transcribe`、`realtime`。
- GPT 候选的 ID 以 `gpt-` 开头，使用同一排除列表。
- 先按可识别的日期和数字版本降序，再按家族偏好排序；无法解析版本时使用稳定文本模型优先和字典序作为确定性兜底。日志输出候选数量、最终模型名和选择原因。
- `ANYROUTER_CLAUDE_MODEL`、`ANYROUTER_GPT_MODEL` 非空时优先使用对应值，并通过一次最小调用验证；验证返回 429 说明模型存在但容量不足，应继续挤号，不能换成另一个模型。

relay 只传模型名、池阶段、通知标记、链路标识和原始 `chain_started_epoch`，不传 token。下一棒若继承的模型连续返回“模型不存在”，才重新发现模型。

## 6. 适配器接口

两个适配器都输出以下规范化字段给协调器：

```text
status=success|rate_limited|retryable|invalid
http_code=<integer or 0>
elapsed_sec=<integer>
message=<short safe diagnostic>
```

Claude 适配器调用 `claude -p` 或同等 Anthropic 兼容请求，传入选定模型和随机 prompt；配置必须通过临时隔离环境变量/目录完成，不覆盖使用者原有的 Claude 配置。GPT 适配器向 `${BASE_URL}/chat/completions` 发送 Bearer key、`model`、单条 user message 和受控的输出上限。适配器只返回截断后的安全诊断，原始回答留在临时文件并在退出时删除。

## 7. Relay 与 Stop

### Relay

工作流设置 `timeout-minutes: 360`，协调器的 `MAX_DURATION_SEC` 默认 17,400 秒（4 小时 50 分钟），并预留 dispatch 和清理时间。保活链固定使用 `anyrouter-keepalive-chain` concurrency group。截止前通过 runner 已有的 `curl` 调用 GitHub Actions REST API dispatch 同一 workflow，传入：

- `mode=relay`；
- `claude_phase`、`gpt_phase`，值仅允许 `probing` 或 `keepalive`；
- `claude_model`、`gpt_model`，只含模型 ID；
- `claude_notified`、`gpt_notified`，值为 `true`/`false`；
- `chain_id`，用于日志关联，不含 Secret；
- `chain_started_epoch`，由最初的手动 start 或 cron 生成，后续每棒原样继承。

任何 `mode=relay` run 在模型发现和发送模型请求之前，必须先通过 Actions API 查询最新 stop marker。marker 记录 `stop_before_epoch`；当 `chain_started_epoch <= stop_before_epoch` 时，该 relay 直接退出，不读取 Anyrouter token、不调用模型。新的手动 start 或次日 cron 生成当前 Unix epoch，必然晚于旧 marker，因此可以建立新链路。

工作流显式声明最小的 `actions: write` 权限。dispatch 失败时发送 relay 失败邮件并让当前棒继续运行至清理点；不能通过把 Secret 写入 input 来“修复”relay。

### Stop

`workflow_dispatch` 提供 `mode=start|relay|stop`。`start` 和 `relay` 使用固定的 `anyrouter-keepalive-chain` concurrency group；`stop` 使用独立的 `anyrouter-keepalive-stop` concurrency group，确保停止任务不会排在保活链后面。

stop job 不读取 Anyrouter token，也不执行模型请求。它先以当前 Unix epoch 创建 JSON stop marker，例如 `{"stop_before_epoch": 1787110200, "workflow_id": "keepalive.yml"}`，使用 `actions/upload-artifact` 保存一天，artifact 名称不含 Secret。随后使用 GitHub Actions REST API 列出同一 workflow 的所有 run，排除 stop 自己，对 `queued`、`pending`、`waiting`、`in_progress` 状态逐个调用 cancel API；等待一个短暂固定间隔后再扫描并取消一次，覆盖第一次扫描后才进入队列的 relay。直接点击 Cancel 不写 marker，也不做第二次扫描，所以只作为兜底。

所有 start/relay 在读取 Secret 或发送模型请求前都查询一天内最新 stop marker，并比较自己的 `chain_started_epoch`。最初的 start 和每天 cron 生成新的 `chain_started_epoch`；relay 继承原 epoch。这样 stop 只压住停止时已经存在的链，不永久关闭次日定时启动。README 必须把 `mode=stop` 说明为正式停止方式；永久停用仍需用户在 GitHub Actions 中禁用 workflow。

## 8. 错误与安全处理

| 结果 | 池动作 | 邮件 |
|---|---|---|
| 2xx + 非空可解析回答 | `probing -> keepalive`，开始保活 | 首次成功提醒 |
| 429 | 保持/返回 `probing` | 不每次重试都发 |
| 网络、超时、5xx | 按当前阶段随机等待后重试 | 连续达到阈值时发摘要，不中断另一池 |
| 401、403、模型不存在、参数错误 | `config_error`，停止该池 | 立即告警 |
| 邮件 SMTP 失败 | 保持池状态 | 日志记录脱敏错误，不能改变池状态 |
| relay dispatch 失败 | 当前棒清理退出 | 告警并包含 Actions 链接 |
| stop marker 命中当前链 | relay 不读取 token、不发送模型请求；运行中的两池由 cancel API 终止 | 可选停止确认 |

所有退出路径都通过 `trap` 删除临时响应、临时 Claude 配置和子进程；收到 SIGTERM/SIGINT 时先停止子 worker 再退出。

## 9. 验收标准

- 默认日志显示 `https://anyrouter.top/v1`，不会出现 `/v1/v1`。
- 假模型列表同时包含多个 Claude/GPT 与非聊天模型时，两个池各选对家族且排序确定；Variables 覆盖时不调用错误的候选。
- 测试能证明 Claude 429 不改变 GPT 阶段，GPT 429 不改变 Claude 阶段；两个等待计时器互不共享。
- 测试能证明成功邮件每个阶段只发一次、relay 不重复发、429 恢复后可再次发。
- 测试能证明保活链和 stop 使用不同 concurrency group；stop marker 不含 Secret；stop 两次扫描并取消同 workflow 的 `queued`、`pending`、`waiting`、`in_progress` run。
- 测试能证明 relay 在发送模型请求前检查 `chain_started_epoch`：旧链被 marker 阻止，新 start/次日 cron 的新 epoch 不受旧 marker 影响。
- 测试能证明日志、邮件和 relay 输入没有完整 token。
- 测试能在真实用户 HOME 外创建配置哨兵，运行 Claude adapter 后确认原 `.claude/settings.json` 的内容与哈希均未改变。
- `bash -n scripts/*.sh` 通过；安装了 BATS 时 `bats tests` 全部通过；`git diff --check` 无输出。
