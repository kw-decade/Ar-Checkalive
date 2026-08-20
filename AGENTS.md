# Anyrouter Checkalive 项目规则

## 项目边界

本项目只部署在 GitHub Actions 中运行。仓库里的 Bash 脚本可以在本地做语法检查和使用假 CLI 的测试，但不得把真实 token 放到本地测试、截图、日志、artifact 或提交记录里，也不把本项目当作常驻本地服务。

当前正式场景是一个 Anyrouter key 同时用于 Claude 池和 GPT 池。两个池必须独立计时、独立判断状态、独立处理模型；一个池的 429 不得阻塞另一个池。旧的多 token 输入格式可以为了兼容而解析，但新增逻辑不得把 token 打印出来或扩大请求账号数量。

## 目录与命名约定

- `.github/workflows/` 只放工作流编排、权限、输入和环境变量映射；业务循环放在 `scripts/`。
- `scripts/` 中每个脚本只负责一个清楚的边界：配置与模型发现、协议适配、池状态机、邮件和 relay 分开；共享函数放在 `scripts/lib/`。
- `tests/` 使用 BATS；测试用假 token、假 `curl`、假 `claude` 和短时间参数，不访问真实 Anyrouter。
- `docs/superpowers/specs/` 保存已批准设计，`docs/superpowers/plans/` 保存可执行计划；文件名使用 `YYYY-MM-DD-topic-design.md` 或 `YYYY-MM-DD-topic.md`。
- 代码、shell 命令、函数名、变量名使用英文；面向用户的说明和注释可以使用中文。
- 临时文件使用 `mktemp`，脚本退出时通过 `trap` 清理；不得把临时状态写到仓库目录。

## API、模型与调度规则

- 默认 Anyrouter 地址必须是 `https://anyrouter.top/v1`。写入环境变量或拼接路径前先去掉末尾 `/`，禁止产生 `/v1/v1`。
- Claude 和 GPT 使用独立 adapter。Claude adapter 负责 Claude CLI/Anthropic 兼容调用，GPT adapter 负责 OpenAI 兼容的 `chat/completions` 调用；两者都返回统一的成功、429、认证错误、模型错误、网络/超时结果。
- 模型默认自动从 `/models` 发现并按家族筛选：Claude 名称含 `claude`，GPT 名称以 `gpt-` 开头；排除 embedding、image、audio、tts、transcribe、realtime 等非文本聊天模型。排序尽量选择最新稳定版本，但不把某一个 GPT 名称写死。
- GitHub Variables 可以覆盖自动发现结果，推荐变量名为 `ANYROUTER_CLAUDE_MODEL` 和 `ANYROUTER_GPT_MODEL`；变量为空时才自动发现。覆盖值必须在日志中显示模型名但不得显示 token。
- 挤号阶段两个池各自在每次请求完成后随机等待 3–10 秒；成功后各自切换到保活阶段，每次请求完成后随机等待 30–120 秒。等待由池自身计时，不得用一个全局 sleep 串行化两个池。
- 单次 Actions 运行约 4 小时 50 分钟时必须安全 relay 下一棒；relay 只能传递非敏感状态和模型名，绝不传递 token。保活链使用固定 concurrency group，`mode=stop` 使用独立 concurrency group，避免停止任务被保活链排队阻塞。stop 必须写入一个不含 Secret、可由 Actions API 读取、保存不超过一天的停止标记，并分两次扫描取消同一 workflow 中其他 `queued`、`pending`、`waiting`、`in_progress` run。所有 relay 在发送模型请求前都要核对停止标记及 `chain_started_epoch`；新的手动 start 或次日 cron 生成新 epoch，不受旧标记影响。直接点击 Cancel 只能作为不可靠兜底。
- 无法从 GitHub Actions 可靠感知用户是否已经在本地开始使用，因此成功邮件只提醒“可以使用”，不会自动猜测并停止保活。

## Secret 与日志安全

- `ANYROUTER_TOKENS`、`QQ_EMAIL`、`QQ_SMTP_AUTH_CODE` 只能来自 GitHub Secrets 或测试进程内的假值。任何日志只允许显示固定长度的短预览（例如前 4 个字符加省略号），不允许完整 token、授权码或带认证信息的 URL。
- 不把 token 放进 workflow input、relay 参数、artifact 名称、邮件正文、错误栈或 `set -x` 输出。涉及 token 的命令必须关闭 shell tracing。
- 不覆盖用户本地的 `~/.claude/settings.json`。GitHub runner 中若需要配置，使用隔离临时目录或环境变量，并在 `trap` 中清理。
- 任何本地验证都不得让真实 `claude` 进程继承用户的实际 `HOME`、`USERPROFILE` 或 `.claude` 目录。测试必须使用 `mktemp -d` 创建临时 HOME，并用假 `claude`、假 `curl` 和假 token；最终验证前后要用配置文件内容或哈希哨兵证明用户原有 `.claude/settings.json` 未被创建、修改或删除。无法安全隔离的验证项必须跳过并明确报告，不能冒险执行。
- 邮件正文只放池名称、模型名、时间、状态和 Actions 链接；请求响应正文只用于内存中的成功判断，不能原样发邮件或写 artifact。

## Prompt 规则

- `scripts/prompts.txt` 的每个有效条目都必须是专业编程/软件工程问题，禁止数学、常识、天气、问候等无关题目。
- Prompt 池目标为 60 条以上；大部分输入控制在约 50–300 token，少数需要上下文的复杂题控制在约 300–600 token，并要求模型输出约 100–300 token。优先清晰、专业、可在一次请求中完成的代码审查、调试、架构、数据库、网络、测试或安全问题。不得为了凑长度加入无意义背景。
- 以单行保存 prompt；空行和 `#` 注释不参与随机选择。修改 prompt 后必须检查条目数、空条目和非编程条目。

## 测试与验证

每次改动后先运行独立的语法门禁，再运行测试：

```bash
bash -n scripts/*.sh
if command -v bats >/dev/null 2>&1; then bats tests; fi
git diff --check
```

测试不能依赖真实网络、真实 Claude CLI、Anyrouter 或 QQ SMTP。不可为了测试安装新的全局依赖；没有 BATS 时使用仓库内无依赖测试运行器并完成 `bash -n`。对 relay、stop、429、模型发现、token 脱敏和用户 `.claude` 配置不变性必须有可重复的假命令测试。

## 红线操作

未经用户明确同意，不得删除文件或目录、删除 Git 历史、修改 `.env`/密钥/token/CI/CD 配置、执行 `git push`、`git rebase`、`git reset --hard`、强制推送、公开发布、安装全局依赖或修改系统配置。需要调整本规则时，先修改本文件并获得确认，再改变实践。

## 变更纪律

- 先写失败测试，再写最小实现；每个行为变化都要能说明对应测试和失败证据。
- 不通过注释掉报错、放宽断言或吞掉退出码来“让测试变绿”；区分 429（继续挤号）、401/403/模型不存在（配置错误）和网络/5xx（可重试故障）。
- 完成前汇报实际修改文件、验证命令和结果；本项目的自动 relay 不等于 Git 操作，任何 push 仍需单独获得用户许可。
