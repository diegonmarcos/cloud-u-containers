// sessions-store.mjs — SINGLE declaration of the cross-device session store.
//
// server.mjs serves /sessions from SESSIONS_DIR and route.mjs persists telegram
// chat history into the SAME store, so the directory is declared HERE once and
// both derive from it — route.mjs never restates the path as a literal.
//
// On-disk format is NDJSON: one `{role, content}` object per line — the exact
// shape commands.mjs's `/resume` parses and server.mjs's /sessions/<device>/<id>
// GET serves back verbatim. No third format: the file written here is readable
// by /resume unchanged, and a line written here is a line /resume sees.
//
// HISTORY is NOT capped here: route.mjs's HISTORY_CAP is only the SEND WINDOW
// (token budget). The file on disk is the durable memory and keeps the whole
// conversation. Do not "helpfully" cap writes in this module to match.
import fs from "node:fs";
import path from "node:path";

export const SESSIONS_DIR = process.env.BRIDGE_SESSIONS_DIR ||
  path.join(process.env.HOME || ".", ".goose-sessions");

// Telegram bot chatKeys carry ':' (chat:id and chat:id:thread) which FAIL
// server.mjs's safeSeg (/^[A-Za-z0-9._-]+$/) on the /sessions/<device>/<id>
// endpoint. Sanitise deterministically so the same chat maps to the same file
// across restarts AND /resume's round-trip (listing → GET) still works.
export const safeSessionId = (chatKey) =>
  String(chatKey || "").replace(/[^A-Za-z0-9._-]/g, "_");

export const telegramSessionPath = (chatKey) =>
  path.join(SESSIONS_DIR, "telegram", `${safeSessionId(chatKey)}.jsonl`);

// Serialise history to NDJSON exactly as /resume expects: one JSON object per
// line, each carrying role + content (the fields /resume filters on).
export const serializeHistory = (history) =>
  (history || [])
    .map((m) => JSON.stringify({ role: m.role, content: m.content }))
    .join("\n");

// Persist a chat's FULL history, overwriting the previous file. A failed write
// logs and returns false — callers must continue, never take the turn down.
export const saveTelegramHistory = (chatKey, history) => {
  try {
    const p = telegramSessionPath(chatKey);
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, serializeHistory(history) + "\n");
    return true;
  } catch (e) {
    console.error(`[gateway] session write failed for ${chatKey}: ${e.message}`);
    return false;
  }
};

// Read a chat's full persisted history back (the survival-on-restart path).
// null when no file exists. Malformed lines are skipped, never thrown.
export const loadTelegramHistory = (chatKey) => {
  let raw;
  try {
    const p = telegramSessionPath(chatKey);
    if (!fs.existsSync(p)) return null;
    raw = fs.readFileSync(p, "utf8");
  } catch (e) {
    console.error(`[gateway] session read failed for ${chatKey}: ${e.message}`);
    return null;
  }
  const msgs = [];
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    try {
      const m = JSON.parse(line);
      if (m?.role && m?.content !== undefined) msgs.push({ role: m.role, content: m.content });
    } catch { /* skip malformed line */ }
  }
  return msgs;
};

// Remove a chat's persisted history (used by /new so a cleared chat stays
// cleared across a restart, not resurrected from disk).
export const clearTelegramHistory = (chatKey) => {
  try {
    const p = telegramSessionPath(chatKey);
    if (fs.existsSync(p)) fs.rmSync(p);
  } catch (e) {
    console.error(`[gateway] session clear failed for ${chatKey}: ${e.message}`);
  }
};

// Does this chatKey name a telegram chat (as opposed to mattermost or other
// transports)? Both telegram bots use the "telegram"/"telegram-claude" key
// prefix, so a leading "telegram" identifies them. Used to scope persistence —
// only telegram chats are part of the /sessions store.
export const isTelegramChat = (chatKey) =>
  typeof chatKey === "string" && (chatKey === "telegram" || chatKey.startsWith("telegram:") || chatKey.startsWith("telegram-claude:"));