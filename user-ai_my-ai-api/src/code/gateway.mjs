// gateway.mjs — messaging gateway: Telegram + Mattermost → goose (via local /v1).
//
// Zero npm dependencies: uses Node 22 global fetch + global WebSocket.
// Reads env at startup; each platform starts independently (both can run together).
//
// Env vars:
//   TELEGRAM_BOT_TOKEN          — if set, Telegram long-poll starts
//   TELEGRAM_ALLOW_FROM         — comma-separated numeric chat/user ids (empty = allow all)
//   MATTERMOST_ENABLED          — "true" to enable Mattermost WS bridge
//   MATTERMOST_URL              — e.g. http://10.0.0.6:8065
//   MATTERMOST_TOKEN            — bot user token (from .secrets env_file)
//   MYAI_LOCAL_URL              — default "http://127.0.0.1:3217"
//   GOOSE_PORT                  — goosed REST+SSE port, default 3227
//   GOOSE_SERVER__SECRET_KEY    — shared secret for X-Secret-Key header

const MYAI_LOCAL_URL    = process.env.MYAI_LOCAL_URL || "http://127.0.0.1:3217";
const GOOSE_PORT        = process.env.GOOSE_PORT || "3227";
const GOOSE_SECRET_KEY  = process.env.GOOSE_SERVER__SECRET_KEY || "";
const GOOSED_BASE       = `http://127.0.0.1:${GOOSE_PORT}`;

// ── Session cache: platform+chatId → goosed session id ────────────────────────
// Keyed by a string like "telegram:12345" or "mattermost:channelId".
// Sessions are created lazily on first message and reused for the conversation.
const goosedSessionCache = new Map();

// ── goosed: create or retrieve a session id for a conversation key ─────────────
const getOrCreateGoosedSession = async (conversationKey) => {
  if (goosedSessionCache.has(conversationKey)) {
    return goosedSessionCache.get(conversationKey);
  }
  const res = await fetch(`${GOOSED_BASE}/sessions`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "X-Secret-Key": GOOSE_SECRET_KEY,
    },
    body: JSON.stringify({}),
  });
  if (!res.ok) {
    throw new Error(`goosed POST /sessions returned ${res.status}`);
  }
  const data = await res.json();
  // Defensive: accept id, session_id, or any field whose value is a non-empty string.
  const sessionId = data?.id ?? data?.session_id
    ?? Object.values(data).find((v) => typeof v === "string" && v.length > 0);
  if (!sessionId) {
    throw new Error(`goosed /sessions response has no id field: ${JSON.stringify(data)}`);
  }
  goosedSessionCache.set(conversationKey, sessionId);
  return sessionId;
};

// ── goosed: send a prompt and accumulate the SSE reply ────────────────────────
const sendToGoosedSession = async (sessionId, text) => {
  const res = await fetch(`${GOOSED_BASE}/sessions/${sessionId}/reply`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "X-Secret-Key": GOOSE_SECRET_KEY,
    },
    // ponytail: try "content" first (goosed v0.x); some builds use "message" — both
    // are sent so the server picks whichever field it recognises; extra fields ignored.
    body: JSON.stringify({ content: text, message: text }),
  });
  if (!res.ok) {
    throw new Error(`goosed POST /sessions/${sessionId}/reply returned ${res.status}`);
  }

  // Read the SSE stream and accumulate assistant text deltas.
  // ponytail: defensive SSE parse — goosed schema may vary by version; we extract
  // any of {delta, text, content, message} string fields that look like assistant
  // output; malformed or non-data lines are silently skipped; an empty accumulation
  // is treated as a failure so the caller can fall back to the one-shot path.
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let accumulated = "";

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split("\n");
    buffer = lines.pop(); // keep the incomplete trailing line
    for (const line of lines) {
      if (!line.startsWith("data:")) continue;
      const raw = line.slice(5).trim();
      if (raw === "" || raw === "[DONE]") continue;
      let parsed;
      try { parsed = JSON.parse(raw); } catch { continue; }
      // Accept any string field that carries assistant text.
      const piece = parsed?.delta ?? parsed?.text ?? parsed?.content ?? parsed?.message ?? "";
      if (typeof piece === "string" && piece.length > 0) {
        accumulated += piece;
      }
    }
  }

  return accumulated.trim();
};

// ── One-shot fallback: the original /v1/chat/completions path ─────────────────
const routeToGooseOneShotFallback = async (text) => {
  const res = await fetch(`${MYAI_LOCAL_URL}/v1/chat/completions`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "X-Agent-Mode": "goose",
    },
    body: JSON.stringify({
      model: "goose",
      messages: [{ role: "user", content: text }],
    }),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    return `[gateway error ${res.status}] ${body.slice(0, 200)}`;
  }
  const json = await res.json();
  return json?.choices?.[0]?.message?.content ?? "[gateway: empty reply]";
};

// ── Shared: route a text prompt through the local goose pipeline ──────────────
// Primary path: goosed persistent session (REST+SSE at 127.0.0.1:GOOSE_PORT).
// Fallback path: one-shot POST to MYAI_LOCAL_URL/v1/chat/completions (X-Agent-Mode: goose).
// conversationKey identifies the chat so sessions are reused across turns.
const routeToGoose = async (text, conversationKey = "default") => {
  try {
    const sessionId = await getOrCreateGoosedSession(conversationKey);
    const reply = await sendToGoosedSession(sessionId, text);
    if (reply.length === 0) {
      throw new Error("goosed returned empty text — falling back");
    }
    console.log(`[gateway] routed via goosed session (key=${conversationKey} sid=${sessionId})`);
    return reply;
  } catch (goosedErr) {
    console.warn(`[gateway] goosed unavailable or failed (${goosedErr.message}); falling back to one-shot path`);
    // Evict the cached session so the next call tries a fresh one.
    goosedSessionCache.delete(conversationKey);
    try {
      const reply = await routeToGooseOneShotFallback(text);
      console.log("[gateway] routed via one-shot fallback (X-Agent-Mode: goose)");
      return reply;
    } catch (fallbackErr) {
      return `[gateway error] ${fallbackErr.message}`;
    }
  }
};

// ── Telegram: offset-based long-poll ─────────────────────────────────────────
const startTelegram = () => {
  const token = process.env.TELEGRAM_BOT_TOKEN;
  if (!token) { console.log("[gateway] telegram: TELEGRAM_BOT_TOKEN not set — skipping"); return; }
  console.log("[gateway] telegram: starting long-poll");

  const allowFrom = (process.env.TELEGRAM_ALLOW_FROM || "")
    .split(",").map((s) => s.trim()).filter(Boolean);

  const tgApi = (method, params = {}) => {
    const url = new URL(`https://api.telegram.org/bot${token}/${method}`);
    for (const [k, v] of Object.entries(params)) url.searchParams.set(k, String(v));
    return fetch(url.toString()).then((r) => r.json());
  };

  const sendMessage = (chat_id, text) =>
    fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ chat_id, text }),
    }).then((r) => r.json());

  let offset = 0;

  const poll = async () => {
    // eslint-disable-next-line no-constant-condition
    while (true) {
      try {
        const data = await tgApi("getUpdates", { timeout: 50, offset });
        if (!data.ok) {
          console.error("[gateway] telegram: getUpdates not ok:", JSON.stringify(data));
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
              console.log(`[gateway] telegram: denied from ${from_id}`);
              continue;
            }
            const conversationKey = `telegram:${msg.chat.id}`;
            const reply = await routeToGoose(msg.text, conversationKey);
            await sendMessage(msg.chat.id, reply);
          } catch (innerErr) {
            console.error("[gateway] telegram: error processing update:", innerErr.message);
          }
        }
      } catch (loopErr) {
        console.error("[gateway] telegram: network error:", loopErr.message);
        await new Promise((r) => setTimeout(r, 5000));
      }
    }
  };

  poll().catch((err) => console.error("[gateway] telegram: poll died:", err.message));
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
console.log("[gateway] starting — MYAI_LOCAL_URL:", MYAI_LOCAL_URL, "GOOSED_BASE:", GOOSED_BASE);
startTelegram();
startMattermost();
