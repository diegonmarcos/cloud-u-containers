#!/usr/bin/env node
// kg-bridge — a tiny OpenAI-compatible shim in front of the Claude
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
// Ollama mimic — a SECOND listener on localhost:11434 (Ollama's default host) so
// octocode's `ollama:` provider reaches the bridge with zero config. /api/tags
// advertises these model names (octocode validates its model exists there).
const OLLAMA_PORT  = parseInt(process.env.BRIDGE_OLLAMA_PORT || "11434", 10);
const OLLAMA_BIND  = process.env.BRIDGE_OLLAMA_BIND || "127.0.0.1";
const OLLAMA_MODELS = (process.env.BRIDGE_OLLAMA_MODELS || `${DEFAULT_MODEL},${DEFAULT_MODEL}:latest,claude,claude:latest,claude-sonnet,claude-sonnet:latest`)
  .split(",").map((s) => s.trim()).filter(Boolean);

// Auth is NOT taken from env/secret (public repo). It lives in the mounted
// ~/.claude volume — log in once with `docker exec -it kg-bridge claude`.
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

// ── cumulative accounting (for measuring index/graphrag cost via /health) ─────
const stats = { calls: 0, errors: 0, prompt_tokens: 0, completion_tokens: 0, since: Math.floor(Date.now() / 1000) };

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

// The bridge ALWAYS serves BRIDGE_DEFAULT_MODEL. Clients send arbitrary/partial
// names (octocode openai: "gpt-4o-mini"; ollama: "claude-sonnet", "claude") — none
// guaranteed valid `claude --model` ids ("claude-sonnet" → claude -p exit 1), so the
// requested model is ignored. Override only via BRIDGE_DEFAULT_MODEL.
const mapModel = () => DEFAULT_MODEL;

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

  const isOllama = req.url.startsWith("/api/");

  // ── health + model discovery (both shapes) ────────────────────────────────
  if (req.method === "GET" && (req.url === "/health" || req.url === "/")) return send(200, { status: "ok", active, max: MAX_CONC, stats });
  if (req.method === "GET" && req.url.startsWith("/v1/models"))
    return send(200, { object: "list", data: [{ id: DEFAULT_MODEL, object: "model", owned_by: "anthropic-subscription-bridge" }] });
  if (req.method === "GET" && req.url.startsWith("/api/version")) return send(200, { version: "0.5.7" });
  if (req.method === "GET" && req.url.startsWith("/api/tags"))
    return send(200, { models: OLLAMA_MODELS.map((n) => ({
      name: n, model: n, modified_at: new Date().toISOString(), size: 0, digest: "",
      details: { format: "gguf", family: "claude", families: ["claude"], parameter_size: "", quantization_level: "" },
    })) });

  // ── chat completion: ANY POST carrying `messages` → claude -p. Response shape
  //    is Ollama (/api/*) or OpenAI (everything else) — octocode's openai provider
  //    builds its own URL from OPENAI_API_URL, so we stay path-agnostic there.
  if (req.method === "POST") {
    let payload;
    try { payload = JSON.parse(await readBody(req)); }
    catch { return send(400, { error: { message: "invalid JSON body" } }); }
    if (!Array.isArray(payload.messages)) return send(404, { error: { message: "no messages in body" } });
    const { system, prompt } = toPrompt(payload.messages);
    const model = payload.model || DEFAULT_MODEL;
    await acquire();
    try {
      const { text, usage } = await withRetry(() => callClaude({ system, prompt, model }));
      stats.calls++;
      stats.prompt_tokens += usage.input_tokens ?? 0;
      stats.completion_tokens += usage.output_tokens ?? 0;
      const pe = usage.input_tokens ?? 0, ec = usage.output_tokens ?? 0;
      if (isOllama) {
        const now = new Date().toISOString();
        const done = { model, created_at: now, message: { role: "assistant", content: payload.stream ? "" : text }, done: true, done_reason: "stop", total_duration: 0, prompt_eval_count: pe, eval_count: ec };
        if (payload.stream) {
          res.writeHead(200, { "content-type": "application/x-ndjson" });
          res.write(JSON.stringify({ model, created_at: now, message: { role: "assistant", content: text }, done: false }) + "\n");
          res.write(JSON.stringify(done) + "\n");
          res.end();
        } else { send(200, done); }
      } else if (payload.stream) {
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
      stats.errors++;
      send(502, { error: { message: String(e.message || e), type: "bridge_claude_error" } });
    } finally { release(); }
    return;
  }
  send(404, { error: { message: "not found" } });
});

const handler = server.listeners("request")[0];
server.listen(PORT, BIND, () =>
  console.error(`[bridge] API (OpenAI /v1 + Ollama /api) on http://${BIND}:${PORT} (model=${DEFAULT_MODEL}, conc=${MAX_CONC})`));

// Second listener: Ollama's default host localhost:11434, so octocode's `ollama:`
// provider reaches us with zero config override. Same handler, both shapes.
if (OLLAMA_PORT && !(OLLAMA_BIND === BIND && OLLAMA_PORT === PORT)) {
  const ollama = http.createServer(handler);
  ollama.on("error", (e) =>
    console.error(`[bridge] Ollama mimic listener on ${OLLAMA_BIND}:${OLLAMA_PORT} disabled (${e.code || e.message}); /v1 API still up`));
  ollama.listen(OLLAMA_PORT, OLLAMA_BIND, () =>
    console.error(`[bridge] Ollama mimic on http://${OLLAMA_BIND}:${OLLAMA_PORT} (/api/chat, /api/tags)`));
}
