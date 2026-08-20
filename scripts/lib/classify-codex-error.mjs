#!/usr/bin/env node

import { readFileSync } from "node:fs";

const [stdoutPath, stderrPath, exitCodeArg] = process.argv.slice(2);

function readPrivateFile(path) {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return "";
  }
}

const diagnosticKeys = new Set([
  "cause",
  "code",
  "detail",
  "details",
  "error",
  "http_code",
  "message",
  "reason",
  "status",
  "status_code",
]);

function collectDiagnosticFields(value, output, key = "") {
  if (typeof value === "string" || typeof value === "number") {
    output.push(key ? `${key}=${value}` : String(value));
    return;
  }
  if (Array.isArray(value)) {
    for (const item of value) collectDiagnosticFields(item, output, key);
    return;
  }
  if (value && typeof value === "object") {
    for (const [key, item] of Object.entries(value)) {
      if (diagnosticKeys.has(key)) collectDiagnosticFields(item, output, key);
    }
  }
}

const stdout = readPrivateFile(stdoutPath);
const stderr = readPrivateFile(stderrPath);
const errorStrings = [];

for (const line of stdout.split(/\r?\n/)) {
  if (!line.trim()) continue;
  try {
    const event = JSON.parse(line);
    if (event?.type === "error" || event?.type === "turn.failed") {
      collectDiagnosticFields(event, errorStrings);
    }
  } catch {}
}

// Codex can fail before its JSONL writer starts. Keep stderr private, but use
// it for the same allowlisted classification as structured JSON events.
const structuredDiagnostic = errorStrings.join("\n");
const privateDiagnostic = structuredDiagnostic || stderr;
const exitCode = /^\d+$/.test(exitCodeArg ?? "") ? Number(exitCodeArg) : 1;
const codePatterns = [
  /\bHTTP(?:\s+(?:status(?:\s+code)?|code))?\s*[:=]?\s*([1-5]\d{2})\b/i,
  /\bstatus(?:\s+code)?\s*[:=]\s*([1-5]\d{2})\b/i,
  /\b(?:code|http_code|status_code)\s*[:=]\s*([1-5]\d{2})\b/i,
  /"(?:status|status_code|http_code)"\s*:\s*([1-5]\d{2})\b/i,
];

let httpCode = "000";
for (const pattern of codePatterns) {
  const match = privateDiagnostic.match(pattern);
  if (match && Number(match[1]) >= 400) {
    httpCode = match[1];
    break;
  }
}

let status = "retryable";
let message = "cli_or_upstream_error";
const code = Number(httpCode);

if (exitCode === 126 || exitCode === 127) {
  message = "cli_command_unavailable";
} else if (exitCode === 2) {
  status = "invalid";
  message = "cli_argument_error";
} else if (code === 429 || /rate[ _-]*limit|too many requests|capacity/i.test(privateDiagnostic)) {
  status = "rate_limited";
  message = "capacity_limited";
} else if (code === 401 || code === 403 || /unauthorized|forbidden|authentication|invalid[ _-]*(token|api[ _-]*key)/i.test(privateDiagnostic)) {
  status = "invalid";
  message = "authentication_error";
} else if ([404, 405, 415, 501].includes(code) || /unknown[ _-]*model|model.*(not found|does not exist|unsupported|not supported)|unsupported.*(model|protocol)|protocol.*(unsupported|not supported)/i.test(privateDiagnostic)) {
  status = "invalid";
  message = "model_or_protocol_error";
} else if (/stream disconnected before completion|stream.*(closed|ended|disconnect)|failed to decode.*stream|SSE.*(error|closed)/i.test(privateDiagnostic)) {
  message = "response_stream_error";
} else if (/failed to (load|read|parse) (config|configuration|settings)|invalid (config|configuration|settings)|configuration (error|failed)|settings? (error|failed)|toml parse/i.test(privateDiagnostic)) {
  status = "invalid";
  message = "cli_configuration_error";
} else if (/tls|ssl|handshake|certificate.*(verify|verification)|cert[_ -]*(verify|verification)|dns|could not resolve|error sending request|failed to send request|request failed|connection (refused|reset|failed)|network|transport/i.test(privateDiagnostic)) {
  message = "transport_error";
} else if (code === 400 || code === 422 || /bad request|invalid[ _-]*(request|argument|parameter)|missing[ _-]*(argument|parameter)/i.test(privateDiagnostic)) {
  status = "invalid";
  message = "request_configuration_error";
} else if (code === 408 || code === 425 || code >= 500 || /retries exhausted|upstream (error|unavailable)/i.test(privateDiagnostic)) {
  message = "upstream_error";
}

process.stdout.write(`status=${status}\nhttp_code=${httpCode}\nmessage=${message}\n`);
