// route.mjs — shared per-chat session state + the forward to my-ai-api.
//
// Owns the chat state map (agent/model/history/plugin toggles) and the
// hermes-pattern HTTP forward to the local OpenAI-compat front (see the
// redeploy note in gateway.mjs for why this goes over HTTP rather than
// spawning the goose binary). Shared by commands.mjs (slash commands read
// and mutate state) and both bot transports (telegram.mjs, mattermost.mjs)
// via routeToGoose.

export const MYAI_LOCAL_URL = process.env.MYAI_LOCAL_URL || "http://127.0.0.1:3217";

// ── Per-chat state ──────────────────────────────────────────────────────────
// null in toggles/model/ponytail means "use server default" (no header sent).
export const HISTORY_CAP = 20; // ~10 turns
const chatState = new Map(); // chatKey -> state
export const getState = (chatKey, defaultAgent = "goose") => {
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
export const routeToGoose = async (text, chatKey = "default", defaultAgent = "goose") => {
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
