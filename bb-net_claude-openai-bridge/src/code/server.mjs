#!/usr/bin/env node
// claude-openai-bridge — a tiny OpenAI-compatible shim in front of the Claude
// Code CLI running on the *subscription* (CLAUDE_CODE_OAUTH_TOKEN), so octocode's
// GraphRAG LLM-extraction pass can be served by Claude WITHOUT a metered API key.
//
//   octocode  --(OPENAI_BASE_URL=http://127.0.0.1:PORT/v1)-->  THIS  -->  claude -p
//
// No npm deps: built-in http + child_process only. Concurrency-capped + 1 retry,
// because the GraphRAG pass fires one call per code chunk (thousands) and the
// subscription must not be hammered. Bind is 127.0.0.1 (host-network sidecar) —
// never publicly reachable; the only caller is the cgc/octocode container.
import http from "node:http";
import { spawn } from "node:child_process";

const PORT        = parseInt(process.env.BRIDGE_PORT || "3110", 10);
const BIND        = process.env.BRIDGE_BIND || "127.0.0.1";
const CLAUDE_BIN  = process.env.CLAUDE_BIN || "claude";
const MAX_CONC    = parseInt(process.env.BRIDGE_MAX_CONCURRENCY || "3", 10);
const CALL_TIMEOUT= parseInt(process.env.BRIDGE_CALL_TIMEOUT_MS || "180000", 10);
const DEFAULT_MODEL = process.env.BRIDGE_DEFAULT_MODEL || "claude-sonnet-4-6";

// Auth is NOT taken from env/secret (public repo). It lives in the mounted
// ~/.claude volume — log in once with `docker exec -it claude-openai-bridge claude`.
// We don't hard-fail here: the server starts regardless, and /v1 calls return a
// clear 502 until the volume holds a valid login.

// ── concurrency semaphore ────────────────────────────────────────────────────
let active = 0;
const waiters = [];
const acquire = () =>
  active < MAX_CONC
    ? ((active++), Promise.resolve())
    : new Promise((res) => waiters.push(res)).then(() => { active++; });
const release = () => { active--; const w = waiters.shift(); if (w) w(); };

// ── OpenAI messages[] → (system prompt, user prompt) ─────────────────────────
const toPrompt = (messages = []) => {
  const sys = [];
  const turns = [];
  for (const m of messages) {
    const content = Array.isArray(m.content)
      ? m.content.map((c) => (typeof c === "string" ? c : c.text || "")).join("")
      : (m.content ?? "");
    if (m.role === "system") sys.push(content);
    else turns.push(`${(m.role || "user").toUpperCase()}: ${content}`);
  }
  return { system: sys.join("\n\n"), prompt: turns.join("\n\n") };
};

// The bridge ALWAYS serves Claude. Clients (octocode via its `openai` provider)
// send arbitrary model names like "gpt-4o-mini" — those are NOT valid `claude
// --model` ids and make claude -p exit 1. So: honor an explicit Claude request
// (strip an "anthropic/" prefix), otherwise fall back to BRIDGE_DEFAULT_MODEL.
const mapModel = (m) => {
  if (!m) return DEFAULT_MODEL;
  const s = String(m).replace(/^anthropic\//, "");
  return /claude/i.test(s) ? s : DEFAULT_MODEL;
};

// ── one claude -p invocation ─────────────────────────────────────────────────
const callClaude = ({ system, prompt, model }) =>
  new Promise((resolve, reject) => {
    const args = ["-p", "--output-format", "json", "--max-turns", "1", "--model", mapModel(model)];
    if (system) args.push("--append-system-prompt", system);
    const child = spawn(CLAUDE_BIN, args, {
      env: { ...process.env, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1" },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let out = "", err = "";
    const timer = setTimeout(() => { child.kill("SIGKILL"); reject(new Error("claude -p timeout")); }, CALL_TIMEOUT);
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("error", (e) => { clearTimeout(timer); reject(e); });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code !== 0) return reject(new Error(`claude -p exit ${code}: ${err.slice(0, 500)}`));
      try {
        const j = JSON.parse(out);
        // headless json: { type:"result", subtype:"success", result:"<text>", usage:{...} }
        resolve({ text: j.result ?? "", usage: j.usage ?? {} });
      } catch (e) { reject(new Error(`bad claude json: ${e.message}: ${out.slice(0, 300)}`)); }
    });
    child.stdin.write(prompt);
    child.stdin.end();
  });

const withRetry = async (fn) => {
  try { return await fn(); }
  catch (e) { return await fn(); /* one retry; let it throw on 2nd */ }
};

// ── OpenAI response envelope ─────────────────────────────────────────────────
const envelope = (model, text, usage) => ({
  id: `chatcmpl-bridge-${active}-${Date.now() % 1e9}`,
  object: "chat.completion",
  created: Math.floor(Date.now() / 1000),
  model,
  choices: [{ index: 0, message: { role: "assistant", content: text }, finish_reason: "stop" }],
  usage: {
    prompt_tokens: usage.input_tokens ?? 0,
    completion_tokens: usage.output_tokens ?? 0,
    total_tokens: (usage.input_tokens ?? 0) + (usage.output_tokens ?? 0),
  },
});

const readBody = (req) =>
  new Promise((res, rej) => { let b = ""; req.on("data", (c) => (b += c)); req.on("end", () => res(b)); req.on("error", rej); });

const server = http.createServer(async (req, res) => {
  const send = (code, obj, headers = {}) => {
    res.writeHead(code, { "content-type": "application/json", ...headers });
    res.end(typeof obj === "string" ? obj : JSON.stringify(obj));
  };

  if (req.method === "GET" && (req.url === "/health" || req.url === "/")) return send(200, { status: "ok", active, max: MAX_CONC });
  if (req.method === "GET" && req.url.startsWith("/v1/models"))
    return send(200, { object: "list", data: [{ id: DEFAULT_MODEL, object: "model", owned_by: "anthropic-subscription-bridge" }] });

  if (req.method === "POST" && req.url.startsWith("/v1/chat/completions")) {
    let payload;
    try { payload = JSON.parse(await readBody(req)); }
    catch { return send(400, { error: { message: "invalid JSON body" } }); }
    const { system, prompt } = toPrompt(payload.messages);
    const model = payload.model || DEFAULT_MODEL;
    await acquire();
    try {
      const { text, usage } = await withRetry(() => callClaude({ system, prompt, model }));
      if (payload.stream) {
        res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache", connection: "keep-alive" });
        const base = { id: `chatcmpl-bridge-${Date.now() % 1e9}`, object: "chat.completion.chunk", created: Math.floor(Date.now() / 1000), model };
        res.write(`data: ${JSON.stringify({ ...base, choices: [{ index: 0, delta: { role: "assistant", content: text }, finish_reason: null }] })}\n\n`);
        res.write(`data: ${JSON.stringify({ ...base, choices: [{ index: 0, delta: {}, finish_reason: "stop" }] })}\n\n`);
        res.write("data: [DONE]\n\n");
        res.end();
      } else {
        send(200, envelope(model, text, usage));
      }
    } catch (e) {
      send(502, { error: { message: String(e.message || e), type: "bridge_claude_error" } });
    } finally { release(); }
    return;
  }
  send(404, { error: { message: "not found" } });
});

server.listen(PORT, BIND, () =>
  console.error(`[bridge] OpenAI→claude -p on http://${BIND}:${PORT}/v1 (model=${DEFAULT_MODEL}, conc=${MAX_CONC})`));
