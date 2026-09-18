// sessions-store.mjs — SINGLE declaration of the cross-device session store.
//
// server.mjs serves /sessions from SESSIONS_DIR and route.mjs persists telegram
// chat history into the SAME store, so the directory is declared HERE once and
// both derive from it — route.mjs never restates the path as a literal.
//
// On-disk format is NDJSON, and the store holds TWO shapes — this module is the
// single owner of BOTH, via normalizeSessionRecord below:
//
//   a) what saveTelegramHistory writes: one flat `{role, content}` per line.
//   b) what a device syncs in: a Claude Code transcript, one record per line
//      shaped `{type, message:{role, content}}`, where content is EITHER a
//      plain string OR an array of typed blocks, and where most lines are not
//      messages at all.
//
// server.mjs's /sessions/<device>/<id> GET serves either back verbatim and
// /resume reads either — there is ONE parser for both and it lives here. Do not
// grow a second one next to a call site (that is exactly the #513 defect).
//
// HISTORY is NOT capped here: route.mjs's HISTORY_CAP is only the SEND WINDOW
// (token budget). The file on disk is the durable memory and keeps the whole
// conversation. Do not "helpfully" cap writes in this module to match.
import fs from "node:fs";
import path from "node:path";

export const SESSIONS_DIR = process.env.BRIDGE_SESSIONS_DIR ||
  path.join(process.env.HOME || ".", ".goose-sessions");

// Resume bound (#513). The live store holds a 127,487,011-byte session: reading
// it whole and assigning every message to state.history is an OOM or an
// unusable context, not a resume. /resume takes the TAIL — at most
// RESUME_MAX_BYTES off the end of the file, at most RESUME_MAX_MESSAGES out of
// that window — and always reports what it skipped. Declared once in
// build.json runtime.sessions.resume and exported by compose.nix; both halves
// live here so server.mjs (which does the tail read) and commands.mjs (which
// applies the message cap) share ONE declaration.
export const RESUME_MAX_BYTES = parseInt(process.env.BRIDGE_RESUME_MAX_BYTES || "1048576", 10);
export const RESUME_MAX_MESSAGES = parseInt(process.env.BRIDGE_RESUME_MAX_MESSAGES || "120", 10);
// How many sessions /resume and /sessions list. Must cover the WHOLE store, not
// a round number: measured live, Diego's session is rank 18 of the 40 the store
// holds, so the old hardcoded 10 hid the one session #513 exists to offer him.
export const RESUME_MAX_LISTED = parseInt(process.env.BRIDGE_RESUME_MAX_LISTED || "40", 10);

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

// ── The ONE session-record parser ───────────────────────────────────────────
// Measured on the real store (#513), Diego's live session is 9,006 lines that
// split like this:
//
//   assistant / array content   3698      last-prompt                538
//   user      / array content   1905      mode                       533
//   user      / string content    86      custom-title               534
//                                         attachment                1373
//                                         system / file-history /
//                                         queue-operation             221
//
// So a parser that only accepts `{role, content}` yields ZERO messages from a
// Claude Code transcript — the "session had no readable messages" dead end —
// and one that assumes content is a string mangles 5,603 of the 5,689 messages.

// Flatten one content block to text. Unknown and unsendable block types (a
// `thinking` block is a signature blob that cannot be replayed) contribute
// nothing rather than JSON noise.
const blockToText = (b) => {
  if (typeof b === "string") return b;
  if (!b || typeof b !== "object") return "";
  if (b.type === "text") return typeof b.text === "string" ? b.text : "";
  if (b.type === "tool_use") {
    let input = "";
    try { input = JSON.stringify(b.input ?? {}); } catch { input = "(uninspectable input)"; }
    return `[tool_use ${b.name || "?"}] ${input}`;
  }
  if (b.type === "tool_result") return flattenContent(b.content);
  return "";
};

// Content may be a plain string (both shapes produce these) or an array of
// typed blocks (Claude Code). Anything else flattens to "".
export const flattenContent = (content) => {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.map(blockToText).filter((t) => t !== "").join("\n");
};

// One record (already JSON.parsed) -> `{role, content}` or null when the record
// is not a message. Accepts BOTH on-disk shapes: the nested Claude Code
// `{type, message:{role, content}}` and this module's own flat `{role, content}`.
// Records with no role at all (last-prompt, mode, attachment, custom-title,
// system, file-history-*, queue-operation) are skipped, never thrown on.
export const normalizeSessionRecord = (rec) => {
  if (!rec || typeof rec !== "object") return null;
  const m = rec.message && typeof rec.message === "object" ? rec.message : rec;
  if (typeof m.role !== "string" || m.content === undefined) return null;
  const content = flattenContent(m.content);
  if (content === "") return null;
  return { role: m.role, content };
};

// NDJSON text -> messages. `limit > 0` keeps only the LAST `limit` of them:
// /resume resumes the tail of a conversation, and the newest messages are the
// ones worth the context budget. Malformed lines are skipped, never thrown.
export const parseSessionMessages = (text, limit = 0) => {
  const msgs = [];
  for (const line of String(text ?? "").split("\n")) {
    if (!line.trim()) continue;
    let rec;
    try { rec = JSON.parse(line); } catch { continue; }
    const m = normalizeSessionRecord(rec);
    if (m) msgs.push(m);
  }
  return limit > 0 && msgs.length > limit ? msgs.slice(-limit) : msgs;
};

// Read the last `bytes` of a file WITHOUT pulling the whole thing into memory —
// the point of the #513 bound. The first line of that window is almost always
// cut in half, so it is dropped and the caller only ever sees whole NDJSON
// records. `bytes <= 0` or a window bigger than the file reads the file whole.
export const readTailBytes = (file, bytes) => {
  const size = fs.statSync(file).size;
  if (!(bytes > 0) || bytes >= size) return fs.readFileSync(file, "utf8");
  const buf = Buffer.alloc(bytes);
  const fd = fs.openSync(file, "r");
  try { fs.readSync(fd, buf, 0, bytes, size - bytes); } finally { fs.closeSync(fd); }
  const window = buf.toString("utf8");
  const nl = window.indexOf("\n");
  return nl === -1 ? "" : window.slice(nl + 1);
};

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
  return parseSessionMessages(raw);
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