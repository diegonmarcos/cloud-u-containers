// gateway.mjs — messaging gateway: Telegram + Mattermost → goose (via local /v1).
//
// Zero npm dependencies: uses Node 22 global fetch + global WebSocket.
// Reads env at startup; each platform starts independently (both can run together).
//
// Env vars:
//   TELEGRAM_BOT_TOKEN      — if set, Telegram long-poll starts
//   TELEGRAM_ALLOW_FROM     — comma-separated numeric chat/user ids (empty = allow all)
//   MATTERMOST_ENABLED      — "true" to enable Mattermost WS bridge
//   MATTERMOST_URL          — e.g. http://10.0.0.6:8065
//   MATTERMOST_TOKEN        — bot user token (from .secrets env_file)
//   MYAI_LOCAL_URL          — default "http://127.0.0.1:3217"

const MYAI_LOCAL_URL = process.env.MYAI_LOCAL_URL || "http://127.0.0.1:3217";

// ── Shared: route a text prompt through the local goose pipeline ──────────────
const routeToGoose = async (text) => {
  try {
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
  } catch (err) {
    return `[gateway error] ${err.message}`;
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
            const reply = await routeToGoose(msg.text);
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
      const reply = await routeToGoose(post.message);
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
startMattermost();
