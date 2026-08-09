// commands.mjs — Telegram slash commands (/help, /new, /status, ...).
//
// Shared across all Telegram bots in the roster (see bots.json) — each bot
// gets its own per-chat state via route.mjs's getState, keyed by the
// conversationKey the caller passes in (which already encodes chat + topic).
import { getState, routeToGoose, MYAI_LOCAL_URL, HISTORY_CAP } from "./route.mjs";

// ── Slash commands ───────────────────────────────────────────────────────────
export const COMMANDS = [
  { command: "start",      description: "welcome message + capability summary" },
  { command: "help",       description: "list all commands" },
  { command: "new",        description: "clear this chat's conversation history" },
  { command: "health",     description: "show my-ai-api health" },
  { command: "usage",      description: "show usage stats" },
  { command: "model",      description: "show/set the model" },
  { command: "agent",      description: "show/set the agent mode (goose|hermes|claude|openrouter)" },
  { command: "mcp",        description: "show MCP server/tool status" },
  { command: "tools",      description: "search available MCP tools" },
  { command: "ponytail",   description: "show/set compression mode (off|lite|full|ultra)" },
  { command: "headroom",   description: "show/set headroom compression (on|off)" },
  { command: "rtk",        description: "show/set RTK tool-noise stripping (on|off)" },
  { command: "caveman",    description: "show/set caveman filler stripping (on|off)" },
  { command: "principles", description: "show/set principles injection (on|off)" },
  { command: "status",     description: "show current agent/model/history/plugin state" },
  { command: "statusline", description: "one-line compact status" },
  { command: "context",    description: "token/context gauge (alias /ctx)" },
  { command: "resume",     description: "list or resume a cross-device session" },
  { command: "sessions",   description: "list previous sessions (optional: search <q>)" },
  { command: "compress",   description: "summarize + compress this chat's history (alias /compact)" },
  { command: "retry",      description: "re-run your last message" },
  { command: "undo",       description: "remove the last user+assistant exchange" },
  { command: "stop",       description: "best-effort ack — interrupt the current turn" },
  { command: "whoami",     description: "show your Telegram id and access tier" },
  { command: "login",      description: "log the claude agent in — returns an OAuth link" },
  { command: "code",       description: "finish /login by sending the code from the link" },
];

// Aliases: alias command -> canonical command handled in the switch.
const ALIASES = { commands: "help", reset: "new", ctx: "context", compact: "compress" };

const HELP_TEXT = "Commands:\n" + COMMANDS.map((c) => `/${c.command} — ${c.description}`).join("\n") +
  "\n\nAliases: /commands=/help /reset=/new /ctx=/context /compact=/compress";

const onOff = (v) => (v === null || v === undefined ? "server default" : v ? "on" : "off");
const parseOnOff = (arg) => {
  const v = (arg || "").toLowerCase().trim();
  if (v === "on") return true;
  if (v === "off") return false;
  return undefined;
};

const jget = async (url) => {
  const res = await fetch(url);
  const text = await res.text();
  try { return { ok: res.ok, status: res.status, json: JSON.parse(text) }; }
  catch { return { ok: res.ok, status: res.status, text }; }
};

// Same shape as jget, for the login handshake. Network errors are returned
// rather than thrown so a chat command answers instead of going silent.
const jpost = async (url, body) => {
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body ?? {}),
    });
    const text = await res.text();
    try { return { ok: res.ok, status: res.status, json: JSON.parse(text) }; }
    catch { return { ok: res.ok, status: res.status, text }; }
  } catch (e) { return { ok: false, status: 0, text: String(e.message || e) }; }
};

// WG-only claude-superset-api endpoint (same env the gateway routes chat to).
const CLAUDE_CLI_BASE = process.env.CLAUDE_CLI_BASE_URL || "";

export const handleCommand = async (cmdIn, arg, chatKey, meta = {}, defaultAgent = "goose") => {
  const cmd = ALIASES[cmdIn] || cmdIn;
  const state = getState(chatKey, defaultAgent);
  switch (cmd) {
    case "start":
      return "👋 my-ai-api gateway. I route your messages to an LLM agent (goose by default) with a compression/plugin pipeline in front. Try /help for the full command list.";
    case "help":
      return HELP_TEXT;
    case "new":
      state.history = [];
      return "🧹 fresh conversation";
    case "health": {
      const r = await jget(`${MYAI_LOCAL_URL}/health`);
      if (!r.ok && !r.json) return `[error] ${r.status}: ${r.text || ""}`.slice(0, 300);
      const j = r.json || {};
      return `status=${j.status} active=${j.active}/${j.max} agents=${JSON.stringify(j.agents)} plugins=${JSON.stringify(j.plugins)}`;
    }
    case "usage": {
      const r = await jget(`${MYAI_LOCAL_URL}/health`);
      if (r.json?.stats) {
        const s = r.json.stats;
        return `calls=${s.calls} errors=${s.errors} prompt_tokens=${s.prompt_tokens} completion_tokens=${s.completion_tokens} tokens_saved=${s.tokens_saved}`;
      }
      return "usage stats endpoint not available";
    }
    case "model":
      if (!arg) return `model: ${state.model || "(server default)"}`;
      state.model = arg;
      return `model set to ${arg}`;
    case "agent":
      if (!arg) return `agent: ${state.agent}`;
      if (!["goose", "hermes", "claude", "openrouter"].includes(arg)) return "invalid agent — choose one of: goose, hermes, claude, openrouter";
      state.agent = arg;
      return `agent set to ${arg}`;
    case "mcp": {
      const r = await jget(`${MYAI_LOCAL_URL}/v1/mcp/status`);
      if (r.json?.enabled === false) return "MCP disabled on the server";
      if (Array.isArray(r.json)) return r.json.map((s) => `${s.server}: ${s.count} tools`).join("\n") || "(no servers)";
      return `mcp status unavailable: ${JSON.stringify(r.json || r.text)}`.slice(0, 300);
    }
    case "tools": {
      if (!arg) return "usage: /tools <query>";
      const r = await jget(`${MYAI_LOCAL_URL}/v1/mcp/search?q=${encodeURIComponent(arg)}`);
      if (r.json?.enabled === false) return "MCP disabled on the server";
      if (Array.isArray(r.json)) return r.json.length ? r.json.map((t) => `${t.name} — ${t.description || ""}`).join("\n") : "(no matches)";
      return `tools search unavailable: ${JSON.stringify(r.json || r.text)}`.slice(0, 300);
    }
    case "ponytail": {
      const valid = ["off", "lite", "full", "ultra"];
      if (!arg) return `ponytail: ${state.ponytail || "(server default)"}`;
      if (!valid.includes(arg)) return `invalid — choose one of: ${valid.join(", ")}`;
      state.ponytail = arg;
      return `ponytail set to ${arg}`;
    }
    case "headroom": case "rtk": case "caveman": case "principles": {
      const key = cmd;
      if (!arg) return `${key}: ${onOff(state.toggles[key])}`;
      const b = parseOnOff(arg);
      if (b === undefined) return "usage: on|off";
      state.toggles[key] = b;
      return `${key} set to ${b ? "on" : "off"}`;
    }
    case "status": {
      const t = state.toggles;
      return [
        `agent: ${state.agent}`,
        `model: ${state.model || "(server default)"}`,
        `history: ${state.history.length} messages (~${Math.floor(state.history.length / 2)} turns)`,
        `ponytail: ${state.ponytail || "(server default)"}`,
        `plugins: headroom=${onOff(t.headroom)} rtk=${onOff(t.rtk)} caveman=${onOff(t.caveman)} principles=${onOff(t.principles)}`,
      ].join("\n");
    }
    case "statusline": {
      const r = await jget(`${MYAI_LOCAL_URL}/health`);
      const s = r.json?.stats || {};
      const t = state.toggles;
      const flags = `hr:${onOff(t.headroom)},rtk:${onOff(t.rtk)},cm:${onOff(t.caveman)},pr:${onOff(t.principles)}`;
      return `${state.model || "(default)"} · ${state.agent} · ${s.prompt_tokens ?? "?"}tok in/${s.completion_tokens ?? "?"}tok out · ponytail:${state.ponytail || "default"} · plugins:${flags}`;
    }
    case "context": {
      const r = await jget(`${MYAI_LOCAL_URL}/health`);
      const s = r.json?.stats || {};
      const pt = s.prompt_tokens ?? 0, ct = s.completion_tokens ?? 0;
      return `tokens in=${pt} out=${ct} total=${pt + ct} model=${state.model || "(server default)"}\n` +
        `(note: this is my-ai-api server's own cumulative accounting, not Claude Code's context window)`;
    }
    case "resume": {
      if (!arg) {
        const r = await jget(`${MYAI_LOCAL_URL}/sessions`);
        if (!Array.isArray(r.json)) return `sessions list unavailable: ${JSON.stringify(r.json || r.text)}`.slice(0, 300);
        const mine = r.json.filter((s) => s.device === "telegram").sort((a, b) => b.mtime - a.mtime).slice(0, 10);
        if (mine.length === 0) return "(no saved sessions for this device)";
        return mine.map((s) => `${s.id} — ${new Date(s.mtime).toISOString()}`).join("\n") + "\n\nuse /resume <id>";
      }
      const r = await jget(`${MYAI_LOCAL_URL}/sessions/telegram/${encodeURIComponent(arg)}`);
      if (!r.ok) return `[error] could not load session ${arg}: ${r.status}`;
      const lines = String(r.text ?? JSON.stringify(r.json ?? "")).split("\n").filter(Boolean);
      const msgs = [];
      for (const line of lines) {
        try {
          const m = JSON.parse(line);
          if (m?.role && m?.content !== undefined) msgs.push({ role: m.role, content: m.content });
        } catch { /* skip malformed line */ }
      }
      if (msgs.length === 0) return `session ${arg} had no readable messages`;
      state.history = msgs.slice(-HISTORY_CAP);
      return `▶️ resumed session ${arg} (${msgs.length} messages loaded)`;
    }
    case "sessions": {
      const [sub, ...rest] = (arg || "").split(/\s+/);
      const r = await jget(`${MYAI_LOCAL_URL}/sessions`);
      if (!Array.isArray(r.json)) return `sessions list unavailable: ${JSON.stringify(r.json || r.text)}`.slice(0, 300);
      const mine = r.json.filter((s) => s.device === "telegram").sort((a, b) => b.mtime - a.mtime);
      if (sub === "search") {
        const q = rest.join(" ").trim();
        if (!q) return "usage: /sessions search <q>";
        const matched = mine.filter((s) => s.id.includes(q));
        return matched.length ? matched.map((s) => s.id).join("\n") : `(no matches for "${q}")`;
      }
      if (sub) return "search isn't available for this argument — showing plain list instead:\n" +
        (mine.length ? mine.slice(0, 10).map((s) => s.id).join("\n") : "(no saved sessions)");
      return mine.length ? mine.slice(0, 10).map((s) => s.id).join("\n") : "(no saved sessions)";
    }
    case "compress": {
      const n = state.history.length;
      if (n === 0) return "🗜️ nothing to compress (history is empty)";
      const transcript = state.history.map((m) => `${m.role}: ${typeof m.content === "string" ? m.content : JSON.stringify(m.content)}`).join("\n");
      const summaryPrompt = `Summarize the following conversation concisely, preserving important facts, decisions, and open questions. Reply with just the summary text.\n\n${transcript}`;
      state.history = [];
      const summary = await routeToGoose(summaryPrompt, chatKey);
      state.history = [{ role: "assistant", content: summary }];
      return `🗜️ compressed (${n}→1)`;
    }
    case "retry": {
      if (state.history.length && state.history[state.history.length - 1].role === "assistant") state.history.pop();
      let lastUser = null;
      for (let i = state.history.length - 1; i >= 0; i--) {
        if (state.history[i].role === "user") { lastUser = state.history[i].content; state.history.splice(i, 1); break; }
      }
      if (lastUser === null) return "no previous user message to retry";
      return await routeToGoose(lastUser, chatKey);
    }
    case "undo": {
      if (state.history.length === 0) return "↩️ nothing to undo";
      state.history.splice(-2, 2);
      return "↩️ undone";
    }
    case "stop": {
      state.busy = false;
      return "⏹️ ack — current turn interrupted (requests are short-lived; nothing long-running to stop)";
    }
    case "whoami": {
      const id = meta.fromId ?? "(unknown)";
      const tier = meta.allowFrom && meta.allowFrom.length > 0 && meta.allowFrom.includes(String(id)) ? "admin" : "open-access";
      return `your Telegram id: ${id}\naccess tier: ${tier}`;
    }

    // ── claude-superset-api interactive login ────────────────────────────────
    // The subscription CLI authenticates by browser OAuth, and nobody can open
    // a shell on the VM from a phone. /login starts `claude setup-token` in
    // the superset container and hands back its authorize URL; /code carries
    // the pasted code to the *same still-running* process (restarting it would
    // void the PKCE state). See claude-superset-api/src/code/login.mjs.
    case "login": {
      if (!CLAUDE_CLI_BASE) return "CLAUDE_CLI_BASE_URL unset — cannot reach claude-superset-api";
      const r = await jpost(`${CLAUDE_CLI_BASE}/auth/login/start`, {});
      const j = r.json || {};
      if (!r.ok || !j.url) return `login failed: ${j.error || r.text || r.status}${j.output ? `\n${j.output}` : ""}`;
      return `Open this link, approve, then send the code back as:\n/code <the-code>\n\n${j.url}\n\n(the link expires in a few minutes — the login process is held open until then)`;
    }
    case "code": {
      if (!CLAUDE_CLI_BASE) return "CLAUDE_CLI_BASE_URL unset — cannot reach claude-superset-api";
      if (!arg || !arg.trim()) return "usage: /code <the-code-from-the-login-link>";
      const r = await jpost(`${CLAUDE_CLI_BASE}/auth/login/code`, { code: arg.trim() });
      const j = r.json || {};
      return r.ok && j.ok
        ? `✅ ${j.message || "logged in"} — the claude agent should answer now.`
        : `login failed: ${j.error || r.text || r.status}${j.output ? `\n${j.output}` : ""}`;
    }
    default:
      return "unknown command, try /help";
  }
};
