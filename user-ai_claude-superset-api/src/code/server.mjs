#!/usr/bin/env node
// claude-api-superset — front multiplexer. One process speaks three API shapes,
// all backed by the *subscription* Claude CLI (no metered key), with a Headroom
// compression hop in front of every call:
//
//   OpenAI    /v1/chat/completions   ─┐
//   Ollama    /api/chat, /api/tags    ├─→ compress(messages) ─→ claude -p
//   Anthropic /v1/messages           ─┘        (Python sidecar)
//
//   octocode (OpenAI/Ollama) and Claude Code (ANTHROPIC_BASE_URL=…) both work.
//
// Successor to kg-bridge: same no-deps design (node:http + child_process), same
// /health {calls,…} stats shape (octocode reindex.sh depends on it), same dual
// listener + named-volume OAuth login. The only new moving part is the compress
// hop, which degrades to passthrough if the sidecar is unreachable.
import http from "node:http";
import { spawn } from "node:child_process";

const PORT          = parseInt(process.env.BRIDGE_PORT || "3107", 10);
const BIND          = process.env.BRIDGE_BIND || "127.0.0.1";
const CLAUDE_BIN    = process.env.CLAUDE_BIN || "claude";
const MAX_CONC      = parseInt(process.env.BRIDGE_MAX_CONCURRENCY || "12", 10);
const CALL_TIMEOUT  = parseInt(process.env.BRIDGE_CALL_TIMEOUT_MS || "180000", 10);
const DEFAULT_MODEL = process.env.BRIDGE_DEFAULT_MODEL || "claude-sonnet-4-6";
// Requested-id → real `claude --model` id. Data-driven (compose wires it from
// build.json runtime.model_aliases); unknown/absent ids fall back to DEFAULT_MODEL,
// so arbitrary client model strings keep working exactly as before.
const MODEL_ALIASES = JSON.parse(process.env.BRIDGE_MODEL_ALIASES || "{}");

const OLLAMA_PORT   = parseInt(process.env.BRIDGE_OLLAMA_PORT || "11434", 10);
const OLLAMA_BIND   = process.env.BRIDGE_OLLAMA_BIND || "127.0.0.1";
const OLLAMA_MODELS = (process.env.BRIDGE_OLLAMA_MODELS ||
  [...new Set([DEFAULT_MODEL, "claude", "claude-sonnet", ...Object.keys(MODEL_ALIASES)]
    .flatMap((n) => [n, `${n}:latest`]))].join(","))
  .split(",").map((s) => s.trim()).filter(Boolean);

// ── Headroom compression hop (Python sidecar) ────────────────────────────────
const HR_ENABLED = (process.env.HEADROOM_ENABLED ?? "1") !== "0";
const HR_HOST    = process.env.HEADROOM_HOST || "127.0.0.1";
const HR_PORT    = parseInt(process.env.HEADROOM_PORT || "8787", 10);
const HR_PROFILE = process.env.HEADROOM_SAVINGS_PROFILE || "agent-90";
const HR_URL     = `http://${HR_HOST}:${HR_PORT}/compress`;

// ── concurrency semaphore ────────────────────────────────────────────────────
let active = 0;
const waiters = [];
const acquire = () =>
  active < MAX_CONC
    ? ((active++), Promise.resolve())
    : new Promise((res) => waiters.push(res)).then(() => { active++; });
const release = () => { active--; const w = waiters.shift(); if (w) w(); };

// ── cumulative accounting (cost + savings, surfaced via /health) ─────────────
const stats = {
  calls: 0, errors: 0,
  prompt_tokens: 0, completion_tokens: 0,
  tokens_before: 0, tokens_after: 0, tokens_saved: 0, compressions: 0,
  since: Math.floor(Date.now() / 1000),
};

// ── compress messages[] via the sidecar; degrade to passthrough on any failure ─
const compress = async (messages, model) => {
  if (!HR_ENABLED || !Array.isArray(messages) || messages.length === 0) return messages;
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 30000);
    const r = await fetch(HR_URL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ messages, model, savings_profile: HR_PROFILE }),
      signal: ctrl.signal,
    }).finally(() => clearTimeout(t));
    if (!r.ok) throw new Error(`compress ${r.status}`);
    const j = await r.json();
    if (Array.isArray(j.messages)) {
      stats.compressions++;
      stats.tokens_before += j.tokens_before ?? 0;
      stats.tokens_after  += j.tokens_after ?? 0;
      stats.tokens_saved  += j.tokens_saved ?? 0;
      return j.messages;
    }
    return messages;
  } catch (e) {
    console.error(`[superset] compress passthrough (${e.message})`);
    return messages;
  }
};

// ── messages[] → (system prompt, user prompt) for `claude -p` ─────────────────
const toPrompt = (messages = []) => {
  const sys = [], turns = [];
  for (const m of messages) {
    const content = Array.isArray(m.content)
      ? m.content.map((c) => (typeof c === "string" ? c : c.text || "")).join("")
      : (m.content ?? "");
    if (m.role === "system") sys.push(content);
    else turns.push(`${(m.role || "user").toUpperCase()}: ${content}`);
  }
  return { system: sys.join("\n\n"), prompt: turns.join("\n\n") };
};

// Serve BRIDGE_DEFAULT_MODEL unless the requested id (sans :latest) is a declared
// alias in BRIDGE_MODEL_ALIASES — lets a caller pick e.g. haiku for bulk indexing
// while arbitrary/garbage client ids still land on the default.
const mapModel = (requested) =>
  MODEL_ALIASES[String(requested || "").replace(/:latest$/, "")] || DEFAULT_MODEL;

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
        resolve({ text: j.result ?? "", usage: j.usage ?? {} });
      } catch (e) { reject(new Error(`bad claude json: ${e.message}: ${out.slice(0, 300)}`)); }
    });
    child.stdin.write(prompt);
    child.stdin.end();
  });

const withRetry = async (fn) => { try { return await fn(); } catch { return await fn(); } };

// run the full pipeline (compress → claude) and tally cost stats
const run = async (messages, model) => {
  const compressed = await compress(messages, model);
  const { system, prompt } = toPrompt(compressed);
  const { text, usage } = await withRetry(() => callClaude({ system, prompt, model }));
  stats.calls++;
  stats.prompt_tokens += usage.input_tokens ?? 0;
  stats.completion_tokens += usage.output_tokens ?? 0;
  return { text, usage };
};

// ── response envelopes ───────────────────────────────────────────────────────
const openaiEnvelope = (model, text, usage) => ({
  id: `chatcmpl-superset-${Date.now() % 1e9}`,
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

const anthropicEnvelope = (model, text, usage) => ({
  id: `msg_superset_${Date.now() % 1e9}`,
  type: "message",
  role: "assistant",
  model,
  content: [{ type: "text", text }],
  stop_reason: "end_turn",
  stop_sequence: null,
  usage: { input_tokens: usage.input_tokens ?? 0, output_tokens: usage.output_tokens ?? 0 },
});

const readBody = (req) =>
  new Promise((res, rej) => { let b = ""; req.on("data", (c) => (b += c)); req.on("end", () => res(b)); req.on("error", rej); });

// ── Anthropic /v1/messages (so `ANTHROPIC_BASE_URL=<superset> claude` works) ──
const handleAnthropic = async (payload, res) => {
  // system may be a string or an array of content blocks; fold into a system msg.
  const messages = [];
  if (payload.system) {
    const sysText = Array.isArray(payload.system)
      ? payload.system.map((b) => (typeof b === "string" ? b : b.text || "")).join("\n\n")
      : payload.system;
    messages.push({ role: "system", content: sysText });
  }
  for (const m of payload.messages || []) messages.push(m);
  const model = payload.model || DEFAULT_MODEL;
  const { text, usage } = await run(messages, model);

  if (!payload.stream) {
    res.writeHead(200, { "content-type": "application/json" });
    return res.end(JSON.stringify(anthropicEnvelope(model, text, usage)));
  }
  // Minimal valid Anthropic SSE: full text delivered in one content_block_delta.
  res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache", connection: "keep-alive" });
  const ev = (event, data) => res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
  const id = `msg_superset_${Date.now() % 1e9}`;
  ev("message_start", { type: "message_start", message: { id, type: "message", role: "assistant", model, content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: usage.input_tokens ?? 0, output_tokens: 0 } } });
  ev("content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } });
  ev("content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } });
  ev("content_block_stop", { type: "content_block_stop", index: 0 });
  ev("message_delta", { type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: null }, usage: { output_tokens: usage.output_tokens ?? 0 } });
  ev("message_stop", { type: "message_stop" });
  res.end();
};

const server = http.createServer(async (req, res) => {
  const send = (code, obj, headers = {}) => {
    res.writeHead(code, { "content-type": "application/json", ...headers });
    res.end(typeof obj === "string" ? obj : JSON.stringify(obj));
  };
  const isOllama = req.url.startsWith("/api/");

  // ── health + model discovery (all shapes) ─────────────────────────────────
  if (req.method === "GET" && (req.url === "/health" || req.url === "/"))
    return send(200, { status: "ok", active, max: MAX_CONC, headroom: HR_ENABLED, stats });
  if (req.method === "GET" && req.url.startsWith("/v1/models"))
    return send(200, { object: "list", data: [{ id: DEFAULT_MODEL, object: "model", owned_by: "claude-superset-api" }] });
  if (req.method === "GET" && req.url.startsWith("/api/version")) return send(200, { version: "0.5.7" });
  if (req.method === "GET" && req.url.startsWith("/api/tags"))
    return send(200, { models: OLLAMA_MODELS.map((n) => ({
      name: n, model: n, modified_at: new Date().toISOString(), size: 0, digest: "",
      details: { format: "gguf", family: "claude", families: ["claude"], parameter_size: "", quantization_level: "" },
    })) });

  if (req.method === "POST") {
    let payload;
    try { payload = JSON.parse(await readBody(req)); }
    catch { return send(400, { error: { message: "invalid JSON body" } }); }

    await acquire();
    try {
      // Anthropic Messages API — branch first (it's also a POST with messages).
      if (req.url.startsWith("/v1/messages")) return await handleAnthropic(payload, res);

      if (!Array.isArray(payload.messages)) return send(404, { error: { message: "no messages in body" } });
      const model = payload.model || DEFAULT_MODEL;
      const { text, usage } = await run(payload.messages, model);
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
        const base = { id: `chatcmpl-superset-${Date.now() % 1e9}`, object: "chat.completion.chunk", created: Math.floor(Date.now() / 1000), model };
        res.write(`data: ${JSON.stringify({ ...base, choices: [{ index: 0, delta: { role: "assistant", content: text }, finish_reason: null }] })}\n\n`);
        res.write(`data: ${JSON.stringify({ ...base, choices: [{ index: 0, delta: {}, finish_reason: "stop" }] })}\n\n`);
        res.write("data: [DONE]\n\n");
        res.end();
      } else {
        send(200, openaiEnvelope(model, text, usage));
      }
    } catch (e) {
      stats.errors++;
      send(502, { error: { message: String(e.message || e), type: "superset_claude_error" } });
    } finally { release(); }
    return;
  }
  send(404, { error: { message: "not found" } });
});

const handler = server.listeners("request")[0];
server.listen(PORT, BIND, () =>
  console.error(`[superset] API (OpenAI /v1 + Ollama /api + Anthropic /v1/messages) on http://${BIND}:${PORT} (model=${DEFAULT_MODEL}, conc=${MAX_CONC}, headroom=${HR_ENABLED})`));

// Second listener: Ollama's default host (11434) so an `ollama:` provider reaches
// us with zero config. Same handler, all shapes.
if (OLLAMA_PORT && !(OLLAMA_BIND === BIND && OLLAMA_PORT === PORT)) {
  const ollama = http.createServer(handler);
  ollama.on("error", (e) =>
    console.error(`[superset] Ollama mimic listener on ${OLLAMA_BIND}:${OLLAMA_PORT} disabled (${e.code || e.message}); /v1 API still up`));
  ollama.listen(OLLAMA_PORT, OLLAMA_BIND, () =>
    console.error(`[superset] Ollama mimic on http://${OLLAMA_BIND}:${OLLAMA_PORT} (/api/chat, /api/tags)`));
}
