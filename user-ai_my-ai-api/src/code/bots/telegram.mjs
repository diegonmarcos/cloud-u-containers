// telegram.mjs — Telegram bot transport: offset-based long-poll.
//
// One instance per bot token (see bots.json — each roster entry gets its own
// startTelegram() call from gateway.mjs). Zero npm dependencies: Node 22
// global fetch.
//
// Group/mention gate: Telegram's default bot Privacy Mode already hides most
// ordinary group messages from bots at the API level — only /commands,
// @mentions, and replies to the bot are delivered to getUpdates in the first
// place. The gate below mostly mirrors what Telegram already enforces; it
// exists so this code never assumes it is seeing every group message, and so
// a group admin who later disables Privacy Mode doesn't turn this bot into a
// reply-to-everything group member.
import { handleCommand, COMMANDS } from "./commands.mjs";
import { routeToGoose } from "./route.mjs";

export const startTelegram = ({
  tokenEnvVar = "TELEGRAM_BOT_TOKEN",
  chatKeyPrefix = "telegram",
  logLabel = "telegram",
  defaultAgent = "goose",
  requireMention = true,
} = {}) => {
  const token = process.env[tokenEnvVar];
  if (!token) { console.log(`[gateway] ${logLabel}: ${tokenEnvVar} not set — skipping`); return; }
  console.log(`[gateway] ${logLabel}: starting long-poll (default agent: ${defaultAgent})`);

  const allowFrom = (process.env.TELEGRAM_ALLOW_FROM || "")
    .split(",").map((s) => s.trim()).filter(Boolean);

  // Fail-closed: this is a private bot, not a public one — an empty allowlist
  // must mean "nobody", not "everybody". Warn loudly once at startup so a
  // missing/misconfigured TELEGRAM_ALLOW_FROM is visible in logs instead of
  // silently exposing the bot to any Telegram user who finds it (in a DM, or
  // worse, any member of a group it gets added to). The same list is used
  // for both DMs and groups — there is no separate group allowlist.
  if (allowFrom.length === 0) {
    console.warn(`[gateway] ${logLabel}: TELEGRAM_ALLOW_FROM empty — refusing all traffic (fail-closed)`);
  }

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

  // message_thread_id threads the reply back into the forum topic (or DM
  // topic) the message was asked in; omitted entirely for non-topic chats.
  const sendMessage = (chat_id, text, message_thread_id) =>
    tgPost("sendMessage", {
      chat_id,
      text,
      ...(message_thread_id !== undefined ? { message_thread_id } : {}),
    });

  tgPost("setMyCommands", { commands: COMMANDS }).catch((err) =>
    console.error(`[gateway] ${logLabel}: setMyCommands failed:`, err.message));

  // Resolved once at startup via getMe; used by the group @mention gate
  // below. If it fails, botUsername stays null and the gate fails OPEN in
  // groups (see isAddressedInGroup) so a getMe hiccup never makes the bot
  // go silently mute in a group it's already in.
  let botUsername = null;
  const resolveBotUsername = async () => {
    try {
      const data = await tgApi("getMe");
      if (data.ok && data.result?.username) {
        botUsername = data.result.username;
      } else {
        console.warn(`[gateway] ${logLabel}: getMe returned no username — group mention gate disabled (fail-open)`);
      }
    } catch (err) {
      console.warn(`[gateway] ${logLabel}: getMe failed (${err.message}) — group mention gate disabled (fail-open)`);
    }
  };

  // Is this group message addressed to the bot? Slash commands and replies
  // to the bot always count; a bare @mention counts only if we know our own
  // username (see resolveBotUsername's fail-open note).
  const isAddressedInGroup = (msg, text) => {
    if (text.startsWith("/")) return true;
    if (msg.reply_to_message?.from?.is_bot === true) return true;
    if (botUsername === null) return true;
    return text.toLowerCase().includes(`@${botUsername.toLowerCase()}`);
  };

  // Strip a leading "@botusername" mention so the model doesn't see the
  // mention noise. Only applied to non-command group text.
  const stripLeadingMention = (text) => {
    if (!botUsername) return text;
    const token = `@${botUsername.toLowerCase()}`;
    return text.toLowerCase().startsWith(token) ? text.slice(token.length).trim() : text;
  };

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
            // Forum service messages (forum_topic_created/closed/...) have no
            // .text, so they're already skipped here — nothing else needed.
            if (!msg?.text) continue;
            const from_id = String(msg.from?.id ?? "");
            if (allowFrom.length === 0 || !allowFrom.includes(from_id)) {
              console.log(`[gateway] ${logLabel}: denied from ${from_id}`);
              continue;
            }
            // Group mention gate: in a group/supergroup, only answer messages
            // addressed to the bot (command, @mention, or reply-to-bot) —
            // otherwise every group message would get a reply. DMs are
            // always answered. Silent continue (no log spam) when ungated.
            const isGroup = msg.chat.type === "group" || msg.chat.type === "supergroup";
            if (isGroup && requireMention && !isAddressedInGroup(msg, msg.text)) continue;
            const text = isGroup && !msg.text.startsWith("/") ? stripLeadingMention(msg.text) : msg.text;
            // Forum groups and DM topics carry message_thread_id — fold it
            // into the session key so each topic gets its own conversation
            // instead of sharing the chat's single "General" session. Chats
            // without topics are unaffected (key unchanged), so existing
            // sessions keep their key.
            const conversationKey = msg.message_thread_id !== undefined
              ? `${chatKeyPrefix}:${msg.chat.id}:${msg.message_thread_id}`
              : `${chatKeyPrefix}:${msg.chat.id}`;
            let reply;
            if (text.startsWith("/")) {
              const [cmdRaw, ...argParts] = text.trim().split(/\s+/);
              const cmd = cmdRaw.slice(1).split("@")[0].toLowerCase();
              const arg = argParts.join(" ");
              reply = await handleCommand(cmd, arg, conversationKey, { fromId: from_id, allowFrom }, defaultAgent);
            } else {
              reply = await routeToGoose(text, conversationKey, defaultAgent);
            }
            await sendMessage(msg.chat.id, reply, msg.message_thread_id);
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

  const init = async () => {
    await resolveBotUsername();
    await poll();
  };
  init().catch((err) => console.error(`[gateway] ${logLabel}: poll died:`, err.message));
};
