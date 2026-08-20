# Anyrouter 双池挤号与保活

本项目只面向 GitHub Actions。它使用一个 Anyrouter key，同时维护两个互不通用的请求池：Claude 池和 GPT 池。一个池拿到 429，不代表另一个池也能用，所以两边分别计时、重试、通知和保存阶段。

## 它会做什么

1. 每天 UTC 18:00（北京时间/新加坡时间次日 02:00）启动；也可以在 Actions 页面手动运行 `start`。
2. Claude 和 GPT 各自每次请求完成后随机等待 3–10 秒，直到该池成功。
3. 某个池成功后发 QQ 邮件提醒“可以使用”，并切换为每次 30–120 秒的随机保活。
4. 保活持续到你手动停止；约 4 小时 50 分钟时自动 relay 下一棒，避免 GitHub Actions 的单次时长上限。
5. relay 只传阶段、模型名、通知标记和链路时间，不传 key、邮箱或 SMTP 授权码。

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
| `ANYROUTER_CLAUDE_MODEL` | Variable | 可选覆盖；留空自动发现最新 Claude 文本模型 |
| `ANYROUTER_GPT_MODEL` | Variable | 可选覆盖；留空自动发现最新 GPT 文本模型 |

默认地址是 `https://anyrouter.top/v1`。手动输入 `base_url` 时也会去掉多余的末尾斜杠，避免出现 `/v1/v1`。

模型发现会从 `/models` 过滤 Claude/GPT 家族，排除 embedding、image、audio、tts、transcribe、realtime 等非聊天模型，并按可识别版本确定性排序。Variables 只在你想固定模型时填写。

## 工作流

| 工作流 | 用途 |
| --- | --- |
| `Anyrouter Keepalive` | 定时双池挤号、保活、relay、`mode=stop` |
| `Anyrouter Keepalive (Once)` | 手动各请求一次，不 relay，适合离线或短测 |
| `Anyrouter Recovery Monitor (Legacy)` | 旧入口（legacy），仅保留兼容；新部署使用主工作流 |

## 安全与本地测试

真实 key 只在 GitHub Secret 中使用，不放 workflow input、relay body、artifact 名称、邮件正文、日志或主运行链的命令参数。Claude adapter 通过临时隔离 `HOME` 调用 CLI，不覆盖调用者现有 `.claude/settings.json`。旧的 legacy `scripts/keepalive.sh TOKEN ...` 仅为兼容保留；正式双池链通过环境变量传递 token。本地测试使用假 `claude`、假 `curl`、假 key 和临时 HOME；不会访问真实 Anyrouter。

项目不承诺请求一定能提高 Anyrouter 优先级，只报告实际观察到的成功、429、网络故障或配置错误。请遵守 Anyrouter 的服务条款和 GitHub Actions 使用限制。
