#!/usr/bin/env python3
"""把 Codex 的 JSONL 事件流 / stderr 归类成安全的 status / http_code / message。

用法: classify_codex_error.py STDOUT_FILE STDERR_FILE EXIT_CODE
输出三行: status=... http_code=... message=...
原始内容只在本地读，不打印。
"""
import json
import re
import sys


def read_private(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


DIAGNOSTIC_KEYS = {
    "cause", "code", "detail", "details", "error", "http_code",
    "message", "reason", "status", "status_code",
}


def collect(value, output, key=""):
    if isinstance(value, (str, int, float)) and not isinstance(value, bool):
        output.append(f"{key}={value}" if key else str(value))
    elif isinstance(value, list):
        for item in value:
            collect(item, output, key)
    elif isinstance(value, dict):
        for k, item in value.items():
            if k in DIAGNOSTIC_KEYS:
                collect(item, output, k)


def main():
    stdout_path, stderr_path = sys.argv[1], sys.argv[2]
    exit_arg = sys.argv[3] if len(sys.argv) > 3 else ""
    exit_code = int(exit_arg) if re.fullmatch(r"\d+", exit_arg) else 1

    strings = []
    for line in read_private(stdout_path).splitlines():
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if isinstance(event, dict) and event.get("type") in ("error", "turn.failed"):
            collect(event, strings)

    # Codex 可能在 JSONL 写出前就挂掉，此时用 stderr 做同样的白名单分类。
    diag = "\n".join(strings) or read_private(stderr_path)

    code_patterns = [
        r"\bHTTP(?:\s+(?:status(?:\s+code)?|code))?\s*[:=]?\s*([1-5]\d{2})\b",
        r"\bstatus(?:\s+code)?\s*[:=]\s*([1-5]\d{2})\b",
        r"\b(?:code|http_code|status_code)\s*[:=]\s*([1-5]\d{2})\b",
        r"\"(?:status|status_code|http_code)\"\s*:\s*([1-5]\d{2})\b",
        # Codex 原文: "unexpected status 502 Bad Gateway: ..."
        r"\bunexpected status\s+([1-5]\d{2})\b",
    ]
    http_code = "000"
    for pattern in code_patterns:
        match = re.search(pattern, diag, re.I)
        if match and int(match.group(1)) >= 400:
            http_code = match.group(1)
            break
    # Codex 把上游 HTTP 500 固定显示成这句话，不带状态码
    # （codex-rs/protocol/src/error.rs 的 InternalServerError）。
    if http_code == "000" and re.search(r"currently experiencing high demand", diag, re.I):
        http_code = "500"
    code = int(http_code)

    def has(pattern):
        return re.search(pattern, diag, re.I) is not None

    status, message = "retryable", "cli_or_upstream_error"
    if exit_code in (126, 127):
        message = "cli_command_unavailable"
    elif exit_code == 2:
        status, message = "invalid", "cli_argument_error"
    elif code == 429 or has(r"rate[ _-]*limit|too many requests|capacity"):
        status, message = "rate_limited", "capacity_limited"
    elif code in (401, 403) or has(r"unauthorized|forbidden|authentication|invalid[ _-]*(token|api[ _-]*key)"):
        status, message = "invalid", "authentication_error"
    elif code in (404, 405, 415, 501) or has(
        r"unknown[ _-]*model|model.*(not found|does not exist|unsupported|not supported)"
        r"|unsupported.*(model|protocol)|protocol.*(unsupported|not supported)"
    ):
        status, message = "invalid", "model_or_protocol_error"
    elif has(r"stream disconnected before completion|stream.*(closed|ended|disconnect)|failed to decode.*stream|SSE.*(error|closed)"):
        message = "response_stream_error"
    elif has(
        r"failed to (load|read|parse) (config|configuration|settings)|invalid (config|configuration|settings)"
        r"|configuration (error|failed)|settings? (error|failed)|toml parse"
    ):
        status, message = "invalid", "cli_configuration_error"
    elif has(
        r"tls|ssl|handshake|certificate.*(verify|verification)|cert[_ -]*(verify|verification)|dns|could not resolve"
        r"|error sending request|failed to send request|request failed|connection (refused|reset|failed)|network|transport"
    ):
        message = "transport_error"
    elif code in (400, 422) or has(r"bad request|invalid[ _-]*(request|argument|parameter)|missing[ _-]*(argument|parameter)"):
        status, message = "invalid", "request_configuration_error"
    elif code in (408, 425) or code >= 500 or has(r"retries exhausted|upstream (error|unavailable)"):
        message = "upstream_error"

    sys.stdout.write(f"status={status}\nhttp_code={http_code}\nmessage={message}\n")


if __name__ == "__main__":
    main()
