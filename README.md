# Anyrouter Checkalive

本项目只面向 GitHub Actions。它使用一个 Anyrouter key，同时维护两个互不通用的请求池：Claude 池和 GPT 池。一个池拿到 429，不代表另一个池也能用，所以两边分别计时、重试、通知和保存阶段。

## 它会做什么

1. 每天 UTC 18:00（北京时间/新加坡时间次日 02:00）启动；也可以在 Actions 页面手动运行 `start`。
2. Claude 和 GPT 各自每次请求完成后随机等待 3–10 秒，直到该池成功（探测阶段）。
3. 某个池成功后发 QQ 邮件提醒"可以使用"，然后按 `ANYROUTER_KEEPALIVE_SEC` 决定：
   - 留空：默认每次 180–300 秒随机保活；
   - `0`：不保活，该池发完邮件就结束；两池都结束后整条链停止，不再 relay；
   - `N` 或 `A-B`：固定 N 秒，或 A 到 B 秒随机。
4. 保活持续到你手动停止；约 4 小时 50 分钟时自动 relay 下一棒，避免 GitHub Actions 的单次时长上限。
5. relay 只传阶段、模型名、通知标记和链路时间，不传 key、邮箱或 SMTP 授权码。

## 配置

进入 `Settings -> Secrets and variables -> Actions`：

| 名称 | 类型 | 用途 |
| --- | --- | --- |
| `ANYROUTER_TOKENS` | Secret | 一个 key；兼容多行格式，只使用第一条非空行 |
| `QQ_EMAIL` | Secret | 可选，接收成功和配置错误提醒 |
| `QQ_SMTP_AUTH_CODE` | Secret | 可选，QQ 邮箱 SMTP 授权码，不是登录密码 |
| `ANYROUTER_CLAUDE_MODEL` | Variable | 可选；留空使用 `opus[1m]`；支持语义写法，见下 |
| `ANYROUTER_GPT_MODEL` | Variable | 可选；留空自动选最新 GPT 文本模型；支持语义写法 |
| `ANYROUTER_KEEPALIVE_SEC` | Variable | 可选；保活间隔，见上 |

模型名要放在 **Variables** 而不是 Secrets：Secret 的值会在日志里被打码成 `***`，比如写 `5.5` 会让 `gpt-5.5` 在日志里显示成 `gpt-***`。

### 模型选择器（语义选模）

| 写法 | 效果 |
| --- | --- |
| 留空 | Claude 用 `opus[1m]`；GPT 从 `/models` 选最新 |
| `5.5` | 从 `/models` 找 id 里含 `5.5`（`5-5`、`5.5`、`55` 都算）的模型，Claude 优先 fable > opus > sonnet > haiku，同级取日期最新 |
| `sonnet 5.5` | 多个关键词须全部命中，例如只要 sonnet 的 5.5 |
| `fable51` / `fable 5.1` | 只要 fable 5.1；`fable5` 则取 fable 5.x 里最新的 |
| `claude-opus-5-5-20260301` / `gpt-5.5` | 完整 id，原样使用，不请求 `/models` |
| `opus[1m]` | Claude Code CLI 别名，原样传给 CLI |

语义写法匹配不到时：Claude 池退回 `opus[1m]` 并在日志中警告；GPT 池进入配置错误并发邮件。

### Claude 的 1M 上下文

Anyrouter 的 Claude 通道要求 1M 上下文。脚本拿到完整 id（如 `claude-opus-5-5-20260301`）时，会自动：

- 按 id 判断档位（fable / opus / sonnet / haiku），设置 `ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-5-5-20260301[1M]` 这类环境变量；
- 以 `--model opus[1m]` 调用 Claude Code CLI，让 CLI 走 1M 分支。

所以 Variable 里不需要自己写 `[1m]`。调用前会清掉运行环境里已有的 `ANTHROPIC_DEFAULT_*_MODEL`，避免被外部配置覆盖。

默认地址是 `https://anyrouter.top/v1`，手动输入 `base_url` 时会去掉多余末尾斜杠。

## 请求是怎样发出的

- Claude 池通过 Claude Code CLI 请求 Anyrouter，使用临时隔离的 HOME 和配置目录。
- GPT 池通过 Codex CLI 请求 Anyrouter 的 Responses 接口。脚本临时生成只含地址、模型名和 `wire_api = "responses"` 的 Codex 配置；key 只放进子进程的 `OPENAI_API_KEY` 环境变量，不写进配置、不放进命令参数。

临时目录在每次请求结束或被停止时清理，不会读取或覆盖运行环境原有的 Claude Code / Codex 用户配置。

## 正式停止方式

在 `Actions -> Anyrouter Keepalive -> Run workflow` 中选择 `mode=stop`。stop job 会写一个保存一天的 stop marker，并两次扫描、取消同一工作流里排队或运行中的旧链。

直接点某个 run 的 **Cancel** 只能兜底：它不会写 marker，已经 dispatch 但尚未启动的下一棒可能重新运行。第二天的 cron 会生成新的链路时间，不会被前一天的 stop marker 永久挡住；永久停用请在 Actions 页面禁用 workflow。

GitHub Actions 无法自动感知你是否已经在本地开始使用 Anyrouter；用完后仍要手动运行 mode=stop。或者把 `ANYROUTER_KEEPALIVE_SEC` 设成 `0`，可用即通知、通知完即停。

## 工作流

| 工作流 | 用途 |
| --- | --- |
| `Anyrouter Keepalive` | 定时双池探测、保活、relay、`mode=stop` |
| `Anyrouter Keepalive (Once)` | 手动各请求一次，不 relay，适合短测 |

旧的 legacy 入口（`keepalive.sh`、`run-all.sh`、`monitor-recovery`）已删除。

## 怎么看 Actions 日志

日志是中文的，每次请求一行，不输出 prompt、key、模型回答或 CLI 原始报错：

```
[Claude池] 阶段=探测中 模型=claude-opus-5-5-20260301 状态=限流 HTTP=429 耗时=3秒 CLI退出码=1 原因=容量受限
[Claude池] 阶段=探测中 下次等待=7秒
[GPT池] 阶段=保活中 模型=gpt-5.5 状态=成功 HTTP=000 耗时=12秒 CLI退出码=0 原因=收到回复
```

| 字段 | 含义 |
| --- | --- |
| 阶段 | 探测中 / 保活中 / 配置错误 / 已完成 / 已停止 |
| 状态 | 成功 / 限流 / 可重试 / 无效 |
| HTTP | CLI 能安全提供的状态码；`000` 表示 CLI 没给，不是真的 HTTP 000 |
| CLI退出码 | 始终是非负整数；超时为 `124` |
| 原因 | 见下表 |

| 原因 | 内部代码 | 说明 |
| --- | --- | --- |
| 容量受限 | `capacity_limited` | 429/503/529，继续探测 |
| 鉴权失败 | `authentication_error` | key 无效，池进入配置错误 |
| 模型不存在或协议不兼容 | `model_or_protocol_error` | 自动换下一个候选模型，没有候选则配置错误 |
| 请求超时 | `request_timeout` | 继续重试 |
| 网络错误 | `transport_error` | TLS/DNS/连接问题，继续重试 |
| 响应流中断 | `response_stream_error` | Codex Responses 流提前断开 |
| 上游错误 | `upstream_error` | 5xx；Codex 显示的 "We’re currently experiencing high demand" 就是上游 500，继续探测 |
| CLI命令不可用 / CLI参数错误 / CLI配置错误 | `cli_*` | 本地安装或参数问题 |

内部代码（右列）是 state 文件和 relay 用的英文值，日志只显示中文。Claude 子进程关闭了 CLI 自带重试（`CLAUDE_CODE_MAX_RETRIES=0`），由池 worker 统一控制 3–10 秒的重试节奏。

两个池的状态、通知标记和邮件彼此独立；邮件发送失败只记一条错误，不会回退池状态。

## 安全与本地测试

真实 key 只在 GitHub Secret 中使用，只通过环境变量传给子进程，不出现在命令参数、workflow input、relay body、artifact、邮件或日志里。

本地测试：

```
bash tests/run-tests.sh
```

测试使用假 `claude`、假 codex、假 `curl`、假 key 和临时 HOME，不会访问真实 Anyrouter。需要 bash、python3、GNU `timeout`。

项目不承诺请求一定能提高 Anyrouter 优先级，只报告实际观察到的成功、429、网络故障或配置错误。请遵守 Anyrouter 的服务条款和 GitHub Actions 使用限制。
