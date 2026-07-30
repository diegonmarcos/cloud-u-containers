#!/usr/bin/env node
// my-ai-api — front multiplexer. One process speaks three API shapes, all
// routed through one of three agent backends, with a plugin pipeline in front:
//
//   OpenAI    /v1/chat/completions   ─┐
//   Ollama    /api/chat, /api/tags    ├─→ RTK → Caveman → Headroom → agent backend
//   Anthropic /v1/messages           ─┘
//
// Plugins (all degrade to passthrough on error):
//   RTK       — strips ANSI + truncates noisy tool-result blobs before compression
//   Caveman   — filler-phrase stripping in the Python sidecar (CAVEMAN_ENABLED)
//   Ponytail  — per-request compression aggressiveness (X-Ponytail-Mode: off|lite|full|ultra)
//   Headroom  — token compression via Python sidecar (always on by default)
//
// Agent modes (X-Agent-Mode header, or model-name prefix):
//   claude-cli — forward to claude-superset-api (CLAUDE_CLI_BASE_URL, WG-only)
//   goose      — invoke goose binary with the prompt (non-stream)
//   hermes     — OpenRouter with HERMES_MODEL (Nous Hermes, default nousresearch/hermes-3-llama-3.1-405b)
//   (default)  — OpenRouter with the requested model
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

const PORT          = parseInt(process.env.BRIDGE_PORT || "3217", 10);
const BIND          = process.env.BRIDGE_BIND || "127.0.0.1";
const MAX_CONC      = parseInt(process.env.BRIDGE_MAX_CONCURRENCY || "12", 10);
const CALL_TIMEOUT  = parseInt(process.env.BRIDGE_CALL_TIMEOUT_MS || "180000", 10);
const DEFAULT_MODEL = process.env.BRIDGE_DEFAULT_MODEL || "z-ai/glm-5";
const MODEL_ALIASES = JSON.parse(process.env.BRIDGE_MODEL_ALIASES || "{}");

// ── OpenRouter upstream ───────────────────────────────────────────────────────
const UP_BASE  = process.env.UPSTREAM_BASE_URL || "https://openrouter.ai/api/v1";
const UP_CHAT  = process.env.UPSTREAM_CHAT_PATH || "/chat/completions";
const UP_MODELS= process.env.UPSTREAM_MODELS_PATH || "/models";
const UP_KEY   = process.env.OPENROUTER_API_KEY || process.env.UPSTREAM_API_KEY || "";
const UP_PASSTHROUGH_AUTH = (process.env.UPSTREAM_PASSTHROUGH_AUTH ?? "0") === "1";
const UP_REFERER = process.env.UPSTREAM_HTTP_REFERER || "https://my-ai-api.app";
const UP_TITLE   = process.env.UPSTREAM_HTTP_TITLE   || "my-ai-api";
if (!UP_KEY) console.error("[my-ai-api] WARNING: OPENROUTER_API_KEY unset — chat requests will 502 until the secret is wired (src/secrets.yaml)");

// ── Agent mode backends ───────────────────────────────────────────────────────
// claude-cli: route to claude-superset-api (speaks OpenAI shape, WG-only)
const CLAUDE_CLI_BASE = process.env.CLAUDE_CLI_BASE_URL || "";
const CLAUDE_CLI_CHAT = process.env.CLAUDE_CLI_CHAT_PATH || "/v1/chat/completions";
// goose: path to the goose binary (baked into the image alongside the server)
const GOOSE_BIN = process.env.GOOSE_BIN || "/usr/local/bin/goose";
const GOOSE_TIMEOUT = parseInt(process.env.GOOSE_TIMEOUT_MS || "120000", 10);
// hermes: OpenRouter model slug for Nous Hermes
const HERMES_MODEL = process.env.HERMES_MODEL || "nousresearch/hermes-3-llama-3.1-405b:free";

// ── cross-device session store ─────────────────────────────────────────────
const SESSIONS_DIR  = process.env.BRIDGE_SESSIONS_DIR ||
  path.join(process.env.HOME || ".", ".goose-sessions");
const SESSIONS_KEEP = parseInt(process.env.BRIDGE_SESSIONS_KEEP || "20", 10);
const safeSeg = (s) => /^[A-Za-z0-9._-]+$/.test(s || "");

const OLLAMA_PORT   = parseInt(process.env.BRIDGE_OLLAMA_PORT || "12436", 10);
const OLLAMA_BIND   = process.env.BRIDGE_OLLAMA_BIND || "127.0.0.1";
const OLLAMA_MODELS = (process.env.BRIDGE_OLLAMA_MODELS ||
  [...new Set([DEFAULT_MODEL, ...Object.keys(MODEL_ALIASES)]
    .flatMap((n) => [n, `${n}:latest`]))].join(","))
  .split(",").map((s) => s.trim()).filter(Boolean);

// ── Plugin: Headroom compression sidecar ────────────────────────────────────
const HR_ENABLED = (process.env.HEADROOM_ENABLED ?? "1") !== "0";
const HR_HOST    = process.env.HEADROOM_HOST || "127.0.0.1";
const HR_PORT    = parseInt(process.env.HEADROOM_PORT || "8890", 10);
const HR_PROFILE = process.env.HEADROOM_SAVINGS_PROFILE || "agent-90";
const HR_URL     = `http://${HR_HOST}:${HR_PORT}/compress`;

// ── Plugin: RTK — tool-result noise stripping ────────────────────────────────
const RTK_ENABLED   = (process.env.RTK_ENABLED ?? "1") !== "0";
const RTK_MAX_CHARS = parseInt(process.env.RTK_MAX_TOOL_CHARS || "8000", 10);

// ── Plugin: Caveman — linguistic filler stripping (lives in the Python sidecar)
const CAVEMAN_ENABLED = (process.env.CAVEMAN_ENABLED ?? "1") !== "0";

// ── Plugin: Ponytail — per-request compression aggressiveness ────────────────
// off→no compression, lite→agent-50, full→agent-90 (default), ultra→agent-95
// Override per-request via X-Ponytail-Mode header.
const PONYTAIL_PROFILES = { off: null, lite: "agent-50", full: "agent-90", ultra: "agent-95" };
const PONYTAIL_DEFAULT  = process.env.PONYTAIL_DEFAULT_MODE || "full";

// ── Plugin: Principles — system-prompt injection ──────────────────────────────
// Agents-principles: agent role definitions; Cloud-principles: infra rules.
// Baked into the image at /app/principles/; loaded once at startup.
const AGENTS_PRINCIPLES_ENABLED = (process.env.AGENTS_PRINCIPLES_ENABLED ?? "1") !== "0";
const CLOUD_PRINCIPLES_ENABLED  = (process.env.CLOUD_PRINCIPLES_ENABLED  ?? "1") !== "0";
const PRINCIPLES_DIR = process.env.PRINCIPLES_DIR || "/app/principles";
const _loadPrinciple = (name) => { try { return fs.readFileSync(path.join(PRINCIPLES_DIR, name), "utf8").trim(); } catch { return ""; } };
const AGENTS_PRINCIPLES = AGENTS_PRINCIPLES_ENABLED ? _loadPrinciple("agents.md") : "";
const CLOUD_PRINCIPLES  = CLOUD_PRINCIPLES_ENABLED  ? _loadPrinciple("cloud.md")  : "";

// ── concurrency semaphore ────────────────────────────────────────────────────
let active = 0;
const waiters = [];
const acquire = () =>
  active < MAX_CONC
    ? ((active++), Promise.resolve())
    : new Promise((res) => waiters.push(res)).then(() => { active++; });
const release = () => { active--; const w = waiters.shift(); if (w) w(); };

// ── cumulative accounting ────────────────────────────────────────────────────
const stats = {
  calls: 0, errors: 0,
  prompt_tokens: 0, completion_tokens: 0,
  tokens_before: 0, tokens_after: 0, tokens_saved: 0, compressions: 0,
  upstream: "openrouter", model: DEFAULT_MODEL,
  since: Math.floor(Date.now() / 1000),
};

// ── Plugin: Principles — prepend system context ───────────────────────────────
const injectPrinciples = (messages) => {
  const parts = [];
  if (CLOUD_PRINCIPLES)  parts.push(CLOUD_PRINCIPLES);
  if (AGENTS_PRINCIPLES) parts.push(AGENTS_PRINCIPLES);
  if (parts.length === 0) return messages;
  const principles = parts.join("\n\n---\n\n");
  const sys = messages.find((m) => m.role === "system");
  if (sys) {
    return messages.map((m) =>
      m.role === "system" ? { ...m, content: `${principles}\n\n---\n\n${typeof m.content === "string" ? m.content : JSON.stringify(m.content)}` } : m
    );
  }
  return [{ role: "system", content: principles }, ...messages];
};

// ── Plugin: RTK implementation ───────────────────────────────────────────────
const ANSI_RE = /\x1b\[[0-9;]*[a-zA-Z]/g;
const applyRTK = (messages) => {
  if (!RTK_ENABLED || !Array.isArray(messages)) return messages;
  return messages.map((msg) => {
    if (!msg) return msg;
    const isToolMsg = msg.role === "tool" ||
      (Array.isArray(msg.content) && msg.content.some((b) => b?.type === "tool_result"));
    if (!isToolMsg) return msg;
    const clean = (text) => {
      if (typeof text !== "string") return text;
      let t = text.replace(ANSI_RE, "");
      t = t.replace(/\r\n/g, "\n").replace(/[ \t]+$/gm, "").replace(/\n{3,}/g, "\n\n");
      if (t.length > RTK_MAX_CHARS) {
        const head = Math.floor(RTK_MAX_CHARS * 0.7);
        const tail = RTK_MAX_CHARS - head;
        t = `${t.slice(0, head)}\n…[RTK: ${text.length - RTK_MAX_CHARS} chars trimmed]…\n${t.slice(-tail)}`;
      }
      return t;
    };
    if (typeof msg.content === "string") return { ...msg, content: clean(msg.content) };
    if (Array.isArray(msg.content)) {
      return {
        ...msg,
        content: msg.content.map((b) => {
          if (!b) return b;
          if (b.type === "tool_result") {
            if (typeof b.content === "string") return { ...b, content: clean(b.content) };
            if (Array.isArray(b.content))
              return { ...b, content: b.content.map((i) => i?.type === "text" ? { ...i, text: clean(i.text) } : i) };
          }
          if (b.type === "text") return { ...b, text: clean(b.text) };
          return b;
        }),
      };
    }
    return msg;
  });
};

// ── Plugin: Ponytail profile resolver ────────────────────────────────────────
const getPonytailProfile = (headers) => {
  const mode = ((headers?.["x-ponytail-mode"] || "") || PONYTAIL_DEFAULT).toLowerCase().trim();
  return (mode in PONYTAIL_PROFILES) ? PONYTAIL_PROFILES[mode] : HR_PROFILE;
};

// ── Plugin: Headroom compress (calls Python sidecar) ─────────────────────────
const compress = async (messages, model, savingsProfile) => {
  const profile = savingsProfile !== undefined ? savingsProfile : HR_PROFILE;
  if (profile === null) return messages; // Ponytail "off"
  if (!HR_ENABLED || !Array.isArray(messages) || messages.length === 0) return messages;
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 30000);
    const r = await fetch(HR_URL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ messages, model, savings_profile: profile, caveman_enabled: CAVEMAN_ENABLED }),
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
    console.error(`[my-ai-api] compress passthrough (${e.message})`);
    return messages;
  }
};

// ── full plugin pipeline: Principles → RTK → Headroom (Caveman in sidecar) ───
const pipeline = async (messages, model, headers) => {
  const withPrinciples = injectPrinciples(messages);
  const rtkd = applyRTK(withPrinciples);
  return compress(rtkd, model, getPonytailProfile(headers));
};

// ── Agent mode detection ──────────────────────────────────────────────────────
// Priority: X-Agent-Mode header > model prefix > DEFAULT_MODEL mapping
const getAgentMode = (headers, model) => {
  const hdr = (headers?.["x-agent-mode"] || "").toLowerCase().trim();
  if (hdr === "claude-cli" || hdr === "claude") return "claude-cli";
  if (hdr === "goose") return "goose";
  if (hdr === "hermes") return "hermes";
  const m = String(model || "").toLowerCase();
  if (m === "goose" || m.startsWith("goose/") || m.startsWith("goose:")) return "goose";
  if (m === "hermes" || m.startsWith("hermes/") || m.startsWith("nous/")) return "hermes";
  if (m === "claude" || m.startsWith("claude/") || m.startsWith("claude-")) {
    if (CLAUDE_CLI_BASE) return "claude-cli";
  }
  return "openrouter";
};

const mapModel = (requested) =>
  MODEL_ALIASES[String(requested || "").replace(/:latest$/, "")] || requested || DEFAULT_MODEL;

// ── Backend: OpenRouter ───────────────────────────────────────────────────────
const forward = async ({ messages, model, stream, extra }) => {
  if (!UP_KEY) throw new Error("OPENROUTER_API_KEY unset on the container — wire src/secrets.yaml and re-ship");
  const body = { ...extra, model: mapModel(model), messages, stream: !!stream };
  const headers = {
    "content-type": "application/json",
    "authorization": `Bearer ${UP_KEY}`,
    "http-referer": UP_REFERER,
    "x-title": UP_TITLE,
  };
  if (UP_PASSTHROUGH_AUTH && extra?._clientAuth) headers["authorization"] = extra._clientAuth;
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), CALL_TIMEOUT);
  try {
    const r = await fetch(`${UP_BASE}${UP_CHAT}`, {
      method: "POST", headers, body: JSON.stringify(body), signal: ctrl.signal,
    }).finally(() => clearTimeout(t));
    if (!r.ok) {
      const txt = await r.text().catch(() => "");
      throw new Error(`openrouter ${r.status}: ${txt.slice(0, 500)}`);
    }
    return r;
  } catch (e) {
    if (e.name === "AbortError") throw new Error("openrouter timeout");
    throw e;
  }
};

const callOpenRouter = async ({ messages, model, extra }) => {
  const r = await forward({ messages, model, stream: false, extra });
  const j = await r.json();
  const text = j.choices?.[0]?.message?.content ?? "";
  const usage = { input_tokens: j.usage?.prompt_tokens ?? 0, output_tokens: j.usage?.completion_tokens ?? 0 };
  stats.calls++;
  stats.prompt_tokens += usage.input_tokens;
  stats.completion_tokens += usage.output_tokens;
  return { text, usage, raw: j };
};

// ── Backend: claude-cli (forward to claude-superset-api) ─────────────────────
const callClaudeCLI = async ({ messages, model, extra }) => {
  if (!CLAUDE_CLI_BASE) throw new Error("CLAUDE_CLI_BASE_URL unset — set it to your claude-superset-api WG endpoint");
  const body = { ...extra, model, messages, stream: false };
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), CALL_TIMEOUT);
  try {
    const r = await fetch(`${CLAUDE_CLI_BASE}${CLAUDE_CLI_CHAT}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
      signal: ctrl.signal,
    }).finally(() => clearTimeout(t));
    if (!r.ok) {
      const txt = await r.text().catch(() => "");
      throw new Error(`claude-cli ${r.status}: ${txt.slice(0, 500)}`);
    }
    const j = await r.json();
    const text = j.choices?.[0]?.message?.content ?? "";
    const usage = { input_tokens: j.usage?.prompt_tokens ?? 0, output_tokens: j.usage?.completion_tokens ?? 0 };
    stats.calls++;
    stats.prompt_tokens += usage.input_tokens;
    stats.completion_tokens += usage.output_tokens;
    return { text, usage, raw: j };
  } catch (e) {
    if (e.name === "AbortError") throw new Error("claude-cli timeout");
    throw e;
  }
};

// ── Backend: goose binary ─────────────────────────────────────────────────────
const callGoose = ({ messages }) => {
  // Extract the last user message as the prompt; prepend system if present.
  const system = messages.find((m) => m.role === "system")?.content || "";
  const userMsgs = messages.filter((m) => m.role === "user");
  const lastUser = userMsgs[userMsgs.length - 1];
  const prompt = [system, typeof lastUser?.content === "string" ? lastUser.content : ""].filter(Boolean).join("\n\n");
  if (!prompt.trim()) throw new Error("goose: no user prompt found in messages");
  const result = spawnSync(GOOSE_BIN, ["run", "--text", prompt], {
    timeout: GOOSE_TIMEOUT,
    encoding: "utf8",
    env: { ...process.env },
  });
  if (result.error) throw new Error(`goose spawn error: ${result.error.message}`);
  if (result.status !== 0) throw new Error(`goose exit ${result.status}: ${(result.stderr || "").slice(0, 400)}`);
  const text = (result.stdout || "").trim();
  stats.calls++;
  return { text, usage: { input_tokens: 0, output_tokens: 0 }, raw: null };
};

// ── Dispatch to the right backend ─────────────────────────────────────────────
const dispatch = async ({ messages, model, extra, agentMode }) => {
  if (agentMode === "claude-cli") return callClaudeCLI({ messages, model, extra });
  if (agentMode === "goose")      return callGoose({ messages });
  if (agentMode === "hermes")     return callOpenRouter({ messages, model: HERMES_MODEL, extra });
  return callOpenRouter({ messages, model, extra });
};

// ── Full pipeline + dispatch ──────────────────────────────────────────────────
const run = async (messages, model, extra = {}, headers = {}) => {
  const agentMode = getAgentMode(headers, model);
  const compressed = await pipeline(messages, model, headers);
  return { ...(await dispatch({ messages: compressed, model, extra, agentMode })), agentMode };
};

// ── Response envelopes ────────────────────────────────────────────────────────
const openaiEnvelope = (model, text, usage, raw) => {
  if (raw && raw.choices && raw.id) return raw;
  return {
    id: `chatcmpl-myai-${Date.now() % 1e9}`,
    object: "chat.completion",
    created: Math.floor(Date.now() / 1000),
    model,
    choices: [{ index: 0, message: { role: "assistant", content: text }, finish_reason: "stop" }],
    usage: {
      prompt_tokens: usage.input_tokens ?? 0,
      completion_tokens: usage.output_tokens ?? 0,
      total_tokens: (usage.input_tokens ?? 0) + (usage.output_tokens ?? 0),
    },
  };
};

const anthropicEnvelope = (model, text, usage) => ({
  id: `msg_myai_${Date.now() % 1e9}`,
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

// ── Anthropic /v1/messages ────────────────────────────────────────────────────
const handleAnthropic = async (payload, res, reqHeaders) => {
  const messages = [];
  if (payload.system) {
    const sysText = Array.isArray(payload.system)
      ? payload.system.map((b) => (typeof b === "string" ? b : b.text || "")).join("\n\n")
      : payload.system;
    messages.push({ role: "system", content: sysText });
  }
  for (const m of payload.messages || []) messages.push(m);
  const model = payload.model || DEFAULT_MODEL;
  const extra = {
    max_tokens: payload.max_tokens,
    temperature: payload.temperature,
    top_p: payload.top_p,
    stop: payload.stop_sequences,
  };
  const wantStream = !!payload.stream;

  if (!wantStream) {
    const { text, usage } = await run(messages, model, extra, reqHeaders);
    res.writeHead(200, { "content-type": "application/json" });
    return res.end(JSON.stringify(anthropicEnvelope(model, text, usage)));
  }
  const { text, usage } = await run(messages, model, extra, reqHeaders);
  res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache", connection: "keep-alive" });
  const ev = (event, data) => res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
  const id = `msg_myai_${Date.now() % 1e9}`;
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

  // ── session store ──────────────────────────────────────────────────────────
  if (req.url === "/sessions" || req.url.startsWith("/sessions/")) {
    const parts = req.url.split("?")[0].split("/").filter(Boolean);
    try {
      if (req.method === "GET" && parts.length === 1) {
        const out = [];
        for (const device of fs.existsSync(SESSIONS_DIR) ? fs.readdirSync(SESSIONS_DIR) : []) {
          const ddir = path.join(SESSIONS_DIR, device);
          if (!fs.statSync(ddir).isDirectory()) continue;
          for (const f of fs.readdirSync(ddir)) {
            if (!f.endsWith(".jsonl")) continue;
            const st = fs.statSync(path.join(ddir, f));
            out.push({ device, id: f.slice(0, -6), mtime: st.mtimeMs, size: st.size });
          }
        }
        return send(200, out);
      }
      if (parts.length === 3) {
        const [, device, id] = parts;
        if (!safeSeg(device) || !safeSeg(id)) return send(400, { error: { message: "bad device/id" } });
        const ddir = path.join(SESSIONS_DIR, device);
        const file = path.join(ddir, `${id}.jsonl`);
        if (req.method === "GET") {
          if (!fs.existsSync(file)) return send(404, { error: { message: "no such session" } });
          res.writeHead(200, { "content-type": "application/x-ndjson" });
          return res.end(fs.readFileSync(file));
        }
        if (req.method === "PUT") {
          const body = await readBody(req);
          fs.mkdirSync(ddir, { recursive: true });
          fs.writeFileSync(file, body);
          const files = fs.readdirSync(ddir).filter((f) => f.endsWith(".jsonl"))
            .map((f) => ({ f, m: fs.statSync(path.join(ddir, f)).mtimeMs }))
            .sort((a, b) => b.m - a.m);
          for (const { f } of files.slice(SESSIONS_KEEP)) fs.rmSync(path.join(ddir, f), { force: true });
          return send(200, { ok: true, device, id });
        }
      }
    } catch (e) { return send(500, { error: { message: String(e.message || e) } }); }
    return send(404, { error: { message: "not found" } });
  }

  // ── health + model discovery ───────────────────────────────────────────────
  if (req.method === "GET" && (req.url === "/health" || req.url === "/readyz" || req.url === "/livez" || req.url === "/"))
    return send(200, {
      status: "ok", active, max: MAX_CONC,
      plugins: { headroom: HR_ENABLED, rtk: RTK_ENABLED, caveman: CAVEMAN_ENABLED, ponytail: PONYTAIL_DEFAULT, agents_principles: !!AGENTS_PRINCIPLES, cloud_principles: !!CLOUD_PRINCIPLES },
      agents: { openrouter: !!UP_KEY, claude_cli: !!CLAUDE_CLI_BASE, goose: fs.existsSync(GOOSE_BIN), hermes: HERMES_MODEL },
      stats,
    });
  if (req.method === "GET" && req.url.startsWith("/v1/models")) {
    if (!UP_KEY) return send(200, { object: "list", data: [{ id: DEFAULT_MODEL, object: "model", owned_by: "my-ai-api" }] });
    try {
      const r = await fetch(`${UP_BASE}${UP_MODELS}`, { headers: { "authorization": `Bearer ${UP_KEY}` } });
      if (!r.ok) throw new Error(`openrouter models ${r.status}`);
      return send(200, await r.json());
    } catch (e) {
      return send(200, { object: "list", data: [{ id: DEFAULT_MODEL, object: "model", owned_by: "my-ai-api" }], warning: String(e.message || e) });
    }
  }
  if (req.method === "GET" && req.url.startsWith("/api/version")) return send(200, { version: "0.5.7" });
  if (req.method === "GET" && req.url.startsWith("/api/tags"))
    return send(200, { models: OLLAMA_MODELS.map((n) => ({
      name: n, model: n, modified_at: new Date().toISOString(), size: 0, digest: "",
      details: { format: "gguf", family: "openrouter", families: ["openrouter"], parameter_size: "", quantization_level: "" },
    })) });

  if (req.method === "POST") {
    let payload;
    try { payload = JSON.parse(await readBody(req)); }
    catch { return send(400, { error: { message: "invalid JSON body" } }); }

    await acquire();
    try {
      if (req.url.startsWith("/v1/messages")) return await handleAnthropic(payload, res, req.headers);

      if (!Array.isArray(payload.messages)) return send(404, { error: { message: "no messages in body" } });
      const model = payload.model || DEFAULT_MODEL;
      const extra = { ...payload };
      delete extra.messages; delete extra.model; delete extra.stream;
      const wantStream = !!payload.stream;
      const agentMode = getAgentMode(req.headers, model);

      const compressed = await pipeline(payload.messages, model, req.headers);

      if (wantStream && !isOllama && agentMode === "openrouter") {
        // SSE passthrough — only for OpenRouter (other backends don't stream)
        const r = await forward({ messages: compressed, model, stream: true, extra });
        res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache", connection: "keep-alive" });
        let lastUsage = null;
        for await (const chunk of r.body) {
          res.write(chunk);
          const s = chunk.toString("utf8");
          const m = s.match(/"usage":\s*\{[^}]*\}/);
          if (m) lastUsage = m[0];
        }
        res.end();
        stats.calls++;
        if (lastUsage) {
          try {
            const u = JSON.parse(`{${lastUsage}}`).usage;
            stats.prompt_tokens += u.prompt_tokens ?? 0;
            stats.completion_tokens += u.completion_tokens ?? 0;
          } catch {}
        }
        return;
      }

      const { text, usage, raw } = await dispatch({ messages: compressed, model, extra, agentMode });
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
      } else {
        send(200, openaiEnvelope(model, text, usage, raw));
      }
    } catch (e) {
      stats.errors++;
      send(502, { error: { message: String(e.message || e), type: "my_ai_openrouter_error" } });
    } finally { release(); }
    return;
  }
  send(404, { error: { message: "not found" } });
});

const handler = server.listeners("request")[0];
server.listen(PORT, BIND, () =>
  console.error(`[my-ai-api] API on http://${BIND}:${PORT} (model=${DEFAULT_MODEL}, conc=${MAX_CONC}, headroom=${HR_ENABLED}, rtk=${RTK_ENABLED}, caveman=${CAVEMAN_ENABLED}, ponytail=${PONYTAIL_DEFAULT}, agents=openrouter+${CLAUDE_CLI_BASE ? "claude-cli" : ""}+goose+hermes)`));

if (OLLAMA_PORT && !(OLLAMA_BIND === BIND && OLLAMA_PORT === PORT)) {
  const ollama = http.createServer(handler);
  ollama.on("error", (e) =>
    console.error(`[my-ai-api] Ollama mimic on ${OLLAMA_BIND}:${OLLAMA_PORT} disabled (${e.code || e.message})`));
  ollama.listen(OLLAMA_PORT, OLLAMA_BIND, () =>
    console.error(`[my-ai-api] Ollama mimic on http://${OLLAMA_BIND}:${OLLAMA_PORT} (/api/chat, /api/tags)`));
}
