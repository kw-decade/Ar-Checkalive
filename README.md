# Anyrouter 

本项目只面向 GitHub Actions。它使用一个 Anyrouter key，同时维护两个互不通用的请求池：Claude 池和 GPT 池。一个池拿到 429，不代表另一个池也能用，所以两边分别计时、重试、通知和保存阶段。

## 它会做什么

1. 每天 UTC 18:00（北京时间/新加坡时间次日 02:00）启动；也可以在 Actions 页面手动运行 `start`。
2. Claude 和 GPT 各自每次请求完成后随机等待 3–10 秒，直到该池成功。
3. 某个池成功后发 QQ 邮件提醒“可以使用”，并切换为每次 30–120 秒的随机保活。
4. 保活持续到你手动停止；约 4 小时 50 分钟时自动 relay 下一棒，避免 GitHub Actions 的单次时长上限。
5. relay 只传阶段、模型名、通知标记和链路时间，不传 key、邮箱或 SMTP 授权码。

## 请求是怎样发出的

两个池不仅计时独立，调用工具也不同：

- Claude 池通过 Claude Code CLI 请求 Anyrouter，并使用临时隔离的配置目录。
- GPT 池通过 Codex CLI 请求 Anyrouter 的 Responses 接口。脚本会临时创建一个只写有 `https://anyrouter.top/v1`、模型名和 `wire_api = "responses"` 的 Codex 配置；key 只放进 Codex 子进程的 `OPENAI_API_KEY` 环境变量，不写进该配置，也不放进命令参数。

临时目录在每次请求结束或被停止时清理，因此不会读取或覆盖运行环境原有的 Claude Code/Codex 用户配置。

## 正式停止方式

在 `Actions -> Anyrouter Keepalive -> Run workflow` 中选择 `mode=stop`。stop job 会写一个保存一天的无 Secret marker，并两次扫描、取消同一工作流里排队或运行中的旧链。

直接点击某个 run 的 **Cancel** 只能作为兜底：它不会写 marker，已经 dispatch 但尚未启动的下一棒可能重新运行。第二天的 cron 会生成新的链路时间，因此不会被前一天的 stop marker 永久挡住；永久停用请在 Actions 页面禁用 workflow。

GitHub Actions 无法自动感知你是否已经在本地开始使用 Anyrouter。即使你打开了 Claude 或 GPT，云端保活也不会自己停；用完后仍要手动运行 `mode=stop`。

## 配置

进入 `Settings -> Secrets and variables -> Actions`：

| 名称 | 类型 | 用途 |
| --- | --- | --- |
| `ANYROUTER_TOKENS` | Secret | 一个 key；兼容读取多行格式，但正式请求只使用第一条非空行 |
| `QQ_EMAIL` | Secret | 可选，接收成功和配置错误提醒 |
| `QQ_SMTP_AUTH_CODE` | Secret | 可选，QQ 邮箱 SMTP 授权码，不是登录密码 |
| `ANYROUTER_CLAUDE_MODEL` | Variable | 可选覆盖；留空固定使用已验证的 Claude CLI 别名 `opus[1m]` |
| `ANYROUTER_GPT_MODEL` | Variable | 可选覆盖；留空自动发现最新 GPT 文本模型 |

默认地址是 `https://anyrouter.top/v1`。手动输入 `base_url` 时也会去掉多余的末尾斜杠，避免出现 `/v1/v1`。

GPT 模型会从 `/models` 过滤 GPT 家族，排除 embedding、image、audio、tts、transcribe、realtime 等非聊天模型，并按可识别版本确定性排序。Claude 默认不从 `/models` 选择别名，而是使用已验证的 `opus[1m]`；只有填写 `ANYROUTER_CLAUDE_MODEL` 时才使用你的覆盖值。Variables 只在你想固定 GPT 模型或改用其他 Claude 别名时填写。

## 工作流

| 工作流 | 用途 |
| --- | --- |
| `Anyrouter Keepalive` | 定时双池挤号、保活、relay、`mode=stop` |
| `Anyrouter Keepalive (Once)` | 手动各请求一次，不 relay，适合离线或短测 |
| `Anyrouter Recovery Monitor (Legacy)` | 旧入口（legacy），仅保留兼容；新部署使用主工作流 |

## 怎么看 Actions 日志

主循环每次请求只输出经过筛选的状态，不输出 prompt、key、模型回答或 CLI 原始报错。请求日志包含 `pool`（Claude/GPT 池）、`phase`（`probing` 挤号或 `keepalive` 保活）、`model`、`status`、`http_code`、`elapsed_sec`、`cli_exit_code` 和 `message`；等待日志还会显示 `next_delay_sec`。例如看到 `status=rate_limited message=capacity_limited`，表示该池仍在排队，稍后会继续尝试。`cli_exit_code` 始终是非负整数；超时为 `124`，参数尚未启动 CLI 的本地校验结果为 `0`。

Claude 和 GPT 的状态、`notified` 标记及成功邮件彼此独立：哪个池先从挤号进入保活，就立即只发送哪个池的邮件；另一个池继续自己的挤号或保活。邮件发送失败只记一条安全错误，不会回退池状态，也不会终止另一池或整个工作流。

快速启动失败会只记录白名单诊断：`cli_command_unavailable`（命令不存在/不可执行）、`cli_argument_error`（CLI 参数错误）、`cli_configuration_error`（CLI 配置错误）或 `transport_error`（TLS/DNS/连接错误）。

GPT 经 Codex CLI 调用时通常无法可靠取到上游 HTTP 状态码，所以日志中的 `http_code=000` 表示“CLI 没有提供可安全记录的状态码”，不是一次 HTTP 000 请求。`message=model_or_protocol_error` 表示当前模型不存在/不受支持，或者 Anyrouter 当前不兼容 Codex 使用的 Responses 协议。自动发现模型时会继续尝试下一个候选；如果你用 Variable 固定了模型，则应检查模型名，必要时清空 Variable 让它重新自动发现。若模型名确认无误却持续出现这个消息，需要确认 Anyrouter 的 `/v1/responses` 支持情况。

## 安全与本地测试

真实 key 只在 GitHub Secret 中使用，不放 workflow input、relay body、artifact 名称、邮件正文、日志或主运行链的命令参数。Claude adapter 通过临时隔离 `HOME` 调用 CLI，不覆盖调用者现有 `.claude/settings.json`；GPT adapter 同样使用隔离的 Codex 配置目录。旧的 legacy `scripts/keepalive.sh TOKEN ...` 仅为兼容保留；正式双池链通过环境变量传递 token。本地测试使用假 `claude`、假 `codex`、假 `curl`、假 key 和临时 HOME，分别模拟两个 CLI 和辅助 HTTP 请求；不会访问真实 Anyrouter。

项目不承诺请求一定能提高 Anyrouter 优先级，只报告实际观察到的成功、429、网络故障或配置错误。请遵守 Anyrouter 的服务条款和 GitHub Actions 使用限制。
