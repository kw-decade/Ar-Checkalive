# Anyrouter-Checkalive 项目约定

只面向 GitHub Actions 部署的双池（Claude / GPT）挤号 + 保活脚本。

## 技术栈

- **bash** 写全部逻辑；**python3** 只用于 JSON 解析（`py` helper in `scripts/lib/common.sh`）。不用 node、jq。
- 外部 CLI：`claude`（Claude Code）、`codex`、`curl`、`timeout`。

## 目录

```
scripts/
  run-dual-pool.sh   协调器：选模、起两个 worker、结束后 relay
  pool-worker.sh     单池循环：请求 → 睡 → 状态机 → 中文日志
  stop-chain.sh      mode=stop 用：写 marker、取消旧 run
  adapters/{claude,gpt}.sh   各调一次 CLI，输出 5 行 key=value（英文，机器读）
  lib/common.sh      normalize_base_url / kill_tree / py / state 文件 / 发邮件
  lib/model-discovery.sh     /models 拉取 + 语义选模 + 排序
  lib/actions-api.sh         GitHub Actions REST（marker、cancel、dispatch）
  lib/classify_codex_error.py  Codex JSONL 错误分类
  prompts.txt        66–72 条随机 prompt
tests/run-tests.sh   唯一测试入口，无框架，假 claude/codex/curl
```

## 硬约束

- token 只能通过环境变量 `ANYROUTER_TOKEN` 传给子进程，**禁止**出现在位置参数、日志、邮件、relay body。
- 日志分两层：adapter 输出 `status=/message=` 英文白名单（机器读）；`pool-worker.sh` 翻成中文打到 Actions 日志（人读）。新增 message 必须同时加进 adapter 白名单和 worker 的中文映射表。
- 子进程清理统一用 `kill_tree`，不要再复制进程树逻辑。
- 文件行尾 LF（`.gitattributes` 已锁）。

## 验证

```
bash tests/run-tests.sh
```
改脚本必跑；本机（git-bash）无 setsid，走 `DISABLE_SETSID` 回退分支属正常。
