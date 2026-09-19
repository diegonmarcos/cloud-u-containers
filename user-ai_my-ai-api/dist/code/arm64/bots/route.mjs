// route.mjs — shared per-chat session state + the forward to my-ai-api.
//
// Owns the chat state map (agent/model/history/plugin toggles) and the
// hermes-pattern HTTP forward to the local OpenAI-compat front (see the
// redeploy note in gateway.mjs for why this goes over HTTP rather than
// spawning the goose binary). Shared by commands.mjs (slash commands read
// and mutate state) and both bot transports (telegram.mjs, mattermost.mjs)
// via routeToGoose.
//
// PERSISTENCE (ticket #507): telegram chat history is written to the SAME
// cross-device session store server.mjs serves (/sessions) — declared once in
// sessions-store.mjs — so a gateway/container restart no longer wipes a chat
// and /resume can find it. Only telegram chats persist; mattermost and other
// transports keep their in-memory history. A failed write logs and continues,
// never takes the turn down.

import {
  saveTelegramHistory,
  loadTelegramHistory,
  clearTelegramHistory,
  isTelegramChat,
} from "../sessions-store.mjs";

export const MYAI_LOCAL_URL = process.env.MYAI_LOCAL_URL || "http://127.0.0.1:3217";

// ── Per-chat state ──────────────────────────────────────────────────────────
// null in toggles/model/ponytail means "use server default" (no header sent).
//
// HISTORY_CAP is the SEND WINDOW and nothing more — a token-budget concern.
// It caps how much of the conversation is forwarded UPSTREAM per turn. It must
// NOT cap what is persisted: the on-disk session file is the durable memory and
// keeps the full history, and state.history below stays uncapped for the same
// reason. Do not delete the slice below to "let the model remember more", and
// do not cap the file writes in sessions-store.mjs to "match" this value.
export const HISTORY_CAP = 20; // ~10 turns
const chatState = new Map(); // chatKey -> state
export const getState = (chatKey, defaultAgent = "goose") => {
  let s = chatState.get(chatKey);
  if (!s) {
    s = { agent: defaultAgent, model: null, history: [], ponytail: null,
          toggles: { headroom: null, rtk: null, caveman: null, principles: null },
          busy: false };
    chatState.set(chatKey, s);
    // First touch after a restart: reload the telegram chat's persisted history
    // so the conversation continues where it left off instead of starting blank.
    if (isTelegramChat(chatKey)) {
      const saved = loadTelegramHistory(chatKey);
      if (Array.isArray(saved) && saved.length) s.history = saved;
    }
  }
  return s;
};

// Claude agent model: sent explicitly for the claude agent (when the chat has
// no per-chat /model override) so server.mjs never substitutes its OWN OpenRouter
// DEFAULT_MODEL and the superset never echoes a foreign OpenRouter name. A single
// declaration in config: build.json runtime.claude_model → compose.nix CLAUDE_MODEL
// (the same env/config mechanism the rest of this file uses for MYAI_LOCAL_URL /
// CLAUDE_CLI_BASE_URL). Not a literal buried here.
const CLAUDE_MODEL = process.env.CLAUDE_MODEL;

// ── Shared: forward a text prompt to the local OpenAI-compat front ──────────
// Builds messages from the chat's rolling history + the new user turn, and
// applies the chat's per-chat header overrides (agent mode, model, ponytail,
// plugin toggles). Appends the turn to history on success, then persists the
// chat's full history to the telegram session store.
export const routeToGoose = async (text, chatKey = "default", defaultAgent = "goose", platformContext = undefined) => {
  const state = getState(chatKey, defaultAgent);
  // Send window: only the last HISTORY_CAP history entries go upstream (token
  // budget). The persistence below writes the FULL state.history, not this slice.
  const messages = [...state.history.slice(-HISTORY_CAP), { role: "user", content: text }];
  // Tell the model where it is speaking (group/topic/channel). Regenerated fresh
  // every turn from the incoming update, never persisted into state.history.
  if (typeof platformContext === "string" && platformContext.length > 0) {
    messages.unshift({ role: "system", content: platformContext });
  }
  const headers = { "content-type": "application/json", "x-agent-mode": state.agent };
  if (state.ponytail !== null) headers["x-ponytail-mode"] = state.ponytail;
  if (state.toggles.rtk !== null) headers["x-rtk"] = state.toggles.rtk ? "on" : "off";
  if (state.toggles.headroom !== null) headers["x-headroom"] = state.toggles.headroom ? "on" : "off";
  if (state.toggles.caveman !== null) headers["x-caveman"] = state.toggles.caveman ? "on" : "off";
  if (state.toggles.principles !== null) headers["x-principles"] = state.toggles.principles ? "on" : "off";
  const body = { messages };
  if (state.model) {
    body.model = state.model;
  } else if (CLAUDE_MODEL && (state.agent === "claude" || state.agent === "claude-cli")) {
    // Explicit model for the claude agent so the OpenRouter default is never
    // substituted (see CLAUDE_MODEL note above).
    body.model = CLAUDE_MODEL;
  }
  try {
    const res = await fetch(`${MYAI_LOCAL_URL}/v1/chat/completions`, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
    });
    if (!res.ok) {
      // If the upstream failure is claude-cli being logged out, kick off the OAuth
      // login handshake automatically and hand the user the link instead of just
      // surfacing the opaque gateway error.
      const errText = (await res.text()).slice(0, 300);
      if (/superset_claude_auth_required|auth required|not logged in/i.test(errText)) {
        // The claude backend address comes from the ONE declaration — the
        // CLAUDE_CLI_BASE_URL env in the service's compose.nix (#539). No
        // literal fallback here: a backend whose address is undeclared must
        // tell the user so in words, never silently aim at a guessed host.
        const base = process.env.CLAUDE_CLI_BASE_URL;
        if (!base) return "claude backend is logged out but CLAUDE_CLI_BASE_URL is unset — the claude backend address is not declared. Check the my-ai-api compose.nix declaration and redeploy.";
        try {
          const login = await fetch(`${base}/auth/login/start`, { method: "POST", headers: { "content-type": "application/json" }, body: "{}" }).then((r) => r.json());
          if (login?.url) return `claude backend is logged out. Open this link, approve, then send the code back as:\n/code <the-code>\n\n${login.url}\n\n(link expires in a few minutes)`;
          return `claude backend is logged out and auto-login failed: ${login?.error || "no url"} — try /login`;
        } catch (loginErr) {
          return `claude backend is logged out and auto-login failed: ${loginErr.message} — try /login`;
        }
      }
      return `[gateway error ${res.status}] ${errText.slice(0, 200)}`;
    }
    const json = await res.json();
    const reply = json?.choices?.[0]?.message?.content ?? "[gateway: empty reply]";
    state.history.push({ role: "user", content: text }, { role: "assistant", content: reply });
    // Persist the chat's FULL history (state.history is uncapped; HISTORY_CAP is
    // only the send window above). Failed writes log and continue — a broken
    // store must never take the turn down.
    if (isTelegramChat(chatKey)) saveTelegramHistory(chatKey, state.history);
    return reply;
  } catch (err) {
    return `[gateway error] ${err.message}`;
  }
};

// Used by /new so a cleared telegram chat is cleared on disk too (otherwise it
// resurrects from the session store on the next restart).
export const clearChatHistory = (chatKey) => {
  if (isTelegramChat(chatKey)) clearTelegramHistory(chatKey);
};