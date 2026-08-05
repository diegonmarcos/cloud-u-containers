// gateway.mjs — messaging gateway: Telegram + Mattermost → my-ai-api (via local /v1).
//
// redeploy 2026-07-31: force goose-hermes-parity image (ffb3a8450) into the
// running container — the fix (drop hanging spawnSync /usr/local/bin/goose,
// forward goose over HTTP like hermes) was committed but never rolled out, so
// Telegram→goose still 502'd with `spawnSync ... ETIMEDOUT` on the stale image.
// Zero npm dependencies: uses Node 22 global fetch + global WebSocket.
// Reads env at startup; each platform starts independently (both can run together).
//
// Env vars:
//   TELEGRAM_BOT_TOKEN          — if set, Telegram long-poll starts (default agent: goose)
//   TELEGRAM_CLAUDE_BOT_TOKEN   — if set, second Telegram long-poll starts (default agent: claude)
//   TELEGRAM_ALLOW_FROM         — comma-separated numeric chat/user ids (empty = allow all)
//   MATTERMOST_ENABLED          — "true" to enable Mattermost WS bridge
//   MATTERMOST_URL              — e.g. http://10.0.0.6:8065
//   MATTERMOST_TOKEN            — bot user token (from .secrets env_file)
//   MYAI_LOCAL_URL              — default "http://127.0.0.1:3217"

const MYAI_LOCAL_URL = process.env.MYAI_LOCAL_URL || "http://127.0.0.1:3217";

// ── Per-chat state ──────────────────────────────────────────────────────────
// null in toggles/model/ponytail means "use server default" (no header sent).
const HISTORY_CAP = 20; // ~10 turns
const chatState = new Map(); // chatKey -> state
const getState = (chatKey, defaultAgent = "goose") => {
  let s = chatState.get(chatKey);
  if (!s) {
    s = { agent: defaultAgent, model: null, history: [], ponytail: null,
          toggles: { headroom: null, rtk: null, caveman: null, principles: null },
          busy: false };
    chatState.set(chatKey, s);
  }
  return s;
};

// ── Shared: forward a text prompt to the local OpenAI-compat front ──────────
// Builds messages from the chat's rolling history + the new user turn, and
// applies the chat's per-chat header overrides (agent mode, model, ponytail,
// plugin toggles). Appends the turn to history on success.
const routeToGoose = async (text, chatKey = "default", defaultAgent = "goose") => {
  const state = getState(chatKey, defaultAgent);
  const messages = [...state.history, { role: "user", content: text }];
  const headers = { "content-type": "application/json", "x-agent-mode": state.agent };
  if (state.ponytail !== null) headers["x-ponytail-mode"] = state.ponytail;
  if (state.toggles.rtk !== null) headers["x-rtk"] = state.toggles.rtk ? "on" : "off";
  if (state.toggles.headroom !== null) headers["x-headroom"] = state.toggles.headroom ? "on" : "off";
  if (state.toggles.caveman !== null) headers["x-caveman"] = state.toggles.caveman ? "on" : "off";
  if (state.toggles.principles !== null) headers["x-principles"] = state.toggles.principles ? "on" : "off";
  const body = { messages };
  if (state.model) body.model = state.model;
  try {
    const res = await fetch(`${MYAI_LOCAL_URL}/v1/chat/completions`, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
    });
    if (!res.ok) {
      return `[gateway error ${res.status}] ${(await res.text()).slice(0, 200)}`;
    }
    const json = await res.json();
    const reply = json?.choices?.[0]?.message?.content ?? "[gateway: empty reply]";
    state.history.push({ role: "user", content: text }, { role: "assistant", content: reply });
    if (state.history.length > HISTORY_CAP) state.history.splice(0, state.history.length - HISTORY_CAP);
    return reply;
  } catch (err) {
    return `[gateway error] ${err.message}`;
  }
};

// ── Slash commands ───────────────────────────────────────────────────────────
const COMMANDS = [
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

const handleCommand = async (cmdIn, arg, chatKey, meta = {}, defaultAgent = "goose") => {
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
    default:
      return "unknown command, try /help";
  }
};

// ── Telegram: offset-based long-poll ─────────────────────────────────────────
const startTelegram = ({ tokenEnvVar = "TELEGRAM_BOT_TOKEN", chatKeyPrefix = "telegram", logLabel = "telegram", defaultAgent = "goose" } = {}) => {
  const token = process.env[tokenEnvVar];
  if (!token) { console.log(`[gateway] ${logLabel}: ${tokenEnvVar} not set — skipping`); return; }
  console.log(`[gateway] ${logLabel}: starting long-poll (default agent: ${defaultAgent})`);

  const allowFrom = (process.env.TELEGRAM_ALLOW_FROM || "")
    .split(",").map((s) => s.trim()).filter(Boolean);

  const tgApi = (method, params = {}) => {
    const url = new URL(`https://api.telegram.org/bot${token}/${method}`);
    for (const [k, v] of Object.entries(params)) url.searchParams.set(k, String(v));
    return fetch(url.toString()).then((r) => r.json());
  };

  const tgPost = (method, body) =>
    fetch(`https://api.telegram.org/bot${token}/${method}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    }).then((r) => r.json());

  const sendMessage = (chat_id, text) =>
    tgPost("sendMessage", { chat_id, text });

  tgPost("setMyCommands", { commands: COMMANDS }).catch((err) =>
    console.error(`[gateway] ${logLabel}: setMyCommands failed:`, err.message));

  let offset = 0;

  const poll = async () => {
    // eslint-disable-next-line no-constant-condition
    while (true) {
      try {
        const data = await tgApi("getUpdates", { timeout: 50, offset });
        if (!data.ok) {
          console.error(`[gateway] ${logLabel}: getUpdates not ok:`, JSON.stringify(data));
          await new Promise((r) => setTimeout(r, 5000));
          continue;
        }
        for (const update of data.result || []) {
          offset = update.update_id + 1;
          try {
            const msg = update.message;
            if (!msg?.text) continue;
            const from_id = String(msg.from?.id ?? "");
            if (allowFrom.length > 0 && !allowFrom.includes(from_id)) {
              console.log(`[gateway] ${logLabel}: denied from ${from_id}`);
              continue;
            }
            const conversationKey = `${chatKeyPrefix}:${msg.chat.id}`;
            let reply;
            if (msg.text.startsWith("/")) {
              const [cmdRaw, ...argParts] = msg.text.trim().split(/\s+/);
              const cmd = cmdRaw.slice(1).split("@")[0].toLowerCase();
              const arg = argParts.join(" ");
              reply = await handleCommand(cmd, arg, conversationKey, { fromId: from_id, allowFrom }, defaultAgent);
            } else {
              reply = await routeToGoose(msg.text, conversationKey, defaultAgent);
            }
            await sendMessage(msg.chat.id, reply);
          } catch (innerErr) {
            console.error(`[gateway] ${logLabel}: error processing update:`, innerErr.message);
          }
        }
      } catch (loopErr) {
        console.error(`[gateway] ${logLabel}: network error:`, loopErr.message);
        await new Promise((r) => setTimeout(r, 5000));
      }
    }
  };

  poll().catch((err) => console.error(`[gateway] ${logLabel}: poll died:`, err.message));
};

// ── Mattermost: WebSocket bridge ──────────────────────────────────────────────
const startMattermost = () => {
  const enabled = process.env.MATTERMOST_ENABLED;
  const mmUrl   = process.env.MATTERMOST_URL;
  const mmToken = process.env.MATTERMOST_TOKEN;

  if (enabled !== "true") { console.log("[gateway] mattermost: MATTERMOST_ENABLED != true — skipping"); return; }
  if (!mmToken)           { console.log("[gateway] mattermost: MATTERMOST_TOKEN not set — skipping"); return; }
  if (!mmUrl)             { console.log("[gateway] mattermost: MATTERMOST_URL not set — skipping"); return; }
  console.log("[gateway] mattermost: connecting to", mmUrl);

  // Resolve the bot's own user id so we can skip self-echo.
  // ponytail: we do a one-shot REST call at connect time; if it fails we log and
  // set botUserId to null (posts will still be processed but self-echo may loop once).
  let botUserId = null;
  const fetchBotUserId = async () => {
    try {
      const res = await fetch(`${mmUrl}/api/v4/users/me`, {
        headers: { Authorization: `Bearer ${mmToken}` },
      });
      const user = await res.json();
      botUserId = user.id;
      console.log(`[gateway] mattermost: bot user id = ${botUserId}`);
    } catch (err) {
      console.error("[gateway] mattermost: could not fetch bot user id:", err.message);
    }
  };

  const postReply = (channel_id, message) =>
    fetch(`${mmUrl}/api/v4/posts`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        Authorization: `Bearer ${mmToken}`,
      },
      body: JSON.stringify({ channel_id, message }),
    }).catch((err) => console.error("[gateway] mattermost: post reply error:", err.message));

  let backoff = 1000;

  const connect = async () => {
    await fetchBotUserId();
    const wsUrl = mmUrl.replace(/^http/, "ws") + "/api/v4/websocket";
    const ws = new WebSocket(wsUrl);

    ws.addEventListener("open", () => {
      backoff = 1000;
      console.log("[gateway] mattermost: websocket open, authenticating");
      ws.send(JSON.stringify({
        seq: 1,
        action: "authentication_challenge",
        data: { token: mmToken },
      }));
    });

    ws.addEventListener("message", async (ev) => {
      let payload;
      try { payload = JSON.parse(ev.data); } catch { return; }
      if (payload.event !== "posted") return;
      let post;
      try { post = JSON.parse(payload.data?.post ?? "{}"); } catch { return; }
      // Skip self-echo (author check).
      // If botUserId was not available at connect time, re-fetch it now (cheap: only
      // runs when null).  If it is still null after the retry, skip this post entirely
      // rather than risk an infinite echo loop.
      if (botUserId === null) await fetchBotUserId();
      if (botUserId === null || post.user_id === botUserId) return;
      if (!post.message) return;
      const conversationKey = `mattermost:${post.channel_id}`;
      const reply = await routeToGoose(post.message, conversationKey);
      await postReply(post.channel_id, reply);
    });

    ws.addEventListener("error", (ev) => {
      console.error("[gateway] mattermost: websocket error:", ev.message ?? "(no message)");
    });

    ws.addEventListener("close", () => {
      console.log(`[gateway] mattermost: websocket closed — reconnecting in ${backoff}ms`);
      setTimeout(() => { backoff = Math.min(backoff * 2, 30000); connect(); }, backoff);
    });
  };

  connect().catch((err) => console.error("[gateway] mattermost: connect failed:", err.message));
};

// ── Startup ───────────────────────────────────────────────────────────────────
console.log("[gateway] starting — MYAI_LOCAL_URL:", MYAI_LOCAL_URL);
startTelegram();
startTelegram({ tokenEnvVar: "TELEGRAM_CLAUDE_BOT_TOKEN", chatKeyPrefix: "telegram-claude", logLabel: "telegram-claude", defaultAgent: "claude" });
startMattermost();
