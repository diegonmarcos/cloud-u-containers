// claude-resume.mjs — the ONE place the claude backend turns a *resolved*
// session into `claude -p --resume <session> --cwd <dir>` spawn arguments, and
// the ONE place that answers "is the mounted task store reachable?".
//
// Ticket #548: the claude backend returned "0 tasks" because a fresh `claude
// -p` spawn lands in a brand-new session uuid whose `~/.claude/tasks/<uuid>/`
// directory is empty — Claude keeps the *task store* (keyed by session uuid) in
// a separate tree from the transcript store (`~/.claude/projects/...`), and the
// teleport shipped only the transcript half. The bot therefore asked a session
// that had no task files, and Claude's TaskList legitimately returned zero.
//
// The fix has two halves and BOTH are declared here, not scattered:
//
//  1. SPAWN: when a caller supplies a resolved session id + its project cwd
//     (already resolved by name upstream — see #525's resolveResumeAddress in
//     the goose gateway's sessions-store.mjs), pass `--resume <id>` AND spawn
//     with `--cwd` set to the session's project slug. Claude then lands in the
//     session whose task directory was just mounted, so TaskList reads the
//     real files instead of an empty fresh dir.
//
//     This module does NOT resolve names to ids. Resolution is #525's job and
//     lives in ONE place (sessions-store.mjs). A caller that hands this module
//     a raw uuid it guessed instead of a session the resolver returned is a
//     bug upstream, and this module refuses to be a second resolver — it only
//     trusts ids that resolve against the mounted store.
//
//  2. ABSENCE-IS-LOUD: "the store is unreachable" must never render as a
//     number. If a resume was requested but the mounted task store for that
//     session cannot be read, callers get an EXPLICIT error object. A bot
//     that relays "0" when the real answer is unknowable is the exact failure
//     family #400/#509/#548 is about.
//
// Pure / side-effect-free: import this from server.mjs and from tests.
import fs from "node:fs";
import path from "node:path";

// #525's resolver (goose gateway, sessions-store.mjs) turns a NAME into a
// session id. This module RECEIVES the resolved id — it never resolves a name
// itself (that would be the second resolver the ticket forbids). It accepts a
// value ONLY if it is an already-resolved session id (or absent). A caller that
// hands it a name ("cloud-mail") or a guessed literal uuid instead of the
// resolver's answer is rejected, so the spawn can never land in a session the
// store did not declare. This is what keeps the "pasted vs resolved" contract
// testable in isolation.
const RESOLVED_ID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const isResolvedSessionId = (s) =>
  typeof s === "string" && RESOLVED_ID_RE.test(s.trim());

// Where a session's Claude task files live, relative to a claude home (the
// mounted store). Keyed by session uuid — NOT by cwd — which is the whole
// reason a fresh spawn saw nothing.
export const taskStoreDir = (claudeHome, sessionId) =>
  path.join(claudeHome, ".claude", "tasks", String(sessionId || ""));

// Number of task JSON files in a session's store. Returns a number >= 0 when
// readable; null when the store is unreachable (missing dir / unreadable).
// Callers MUST check `=== null` and surface an error — a null is NOT zero.
export const countTaskFiles = (claudeHome, sessionId) => {
  const dir = taskStoreDir(claudeHome, sessionId);
  try {
    const st = fs.statSync(dir);
    if (!st.isDirectory()) return null;
    const entries = fs.readdirSync(dir);
    let n = 0;
    for (const e of entries) {
      const p = path.join(dir, e);
      try { if (fs.statSync(p).isFile() && e.endsWith(".json")) n++; } catch { /* unreadable single file: still count reachable dir */ }
    }
    return n;
  } catch {
    return null; // absent or unreadable → UNREACHABLE, never 0
  }
};

// Human-readable reason the store is unreachable (or "" when reachable).
// DELIBERATELY digit-free: this string is relayed verbatim into the chat, and a
// count may never be emitted from a store that was not read. The session id is
// NOT embedded — a uuid carries digits, and "no digit in the reply" is the
// #400/#509/#548 contract. The path may be logged elsewhere for an operator; the
// user-visible reason only says WHICH store and WHY, never a number.
export const taskStoreUnreachableReason = (claudeHome, sessionId) => {
  const dir = taskStoreDir(claudeHome, sessionId);
  if (!sessionId) return "the task store is unreachable because no session was addressed";
  try {
    const st = fs.statSync(dir);
    if (!st.isDirectory()) return "the mounted task store for this session is not a directory";
    return ""; // dir exists → reachable (an empty dir is a legitimate 0-task read, not absence)
  } catch (e) {
    if (e.code === "ENOENT") return "the task store for this session is missing — is the agi-memory store mounted into this container?";
    return `the task store is unreadable: ${e.code || e.message}`;
  }
};

// Build the `claude -p` argument vector for a (possibly resumed) call.
//   - session: resolved session id (from #525's resolver) — optional.
//   - cwd:     the project directory that session's transcript lives under.
// Returns { argv, spawnOpts } where argv is the full argument list for
// spawn(claude, argv, spawnOpts) and spawnOpts carries the cwd when set.
export const buildClaudeArgv = ({ baseArgs, session, cwd }) => {
  const argv = [...(baseArgs || [])];
  const spawnOpts = {};
  if (session) {
    // session is a RESOLVED id only — never a name, never a guessed uuid.
    if (!isResolvedSessionId(session)) {
      throw new Error(
        `refusing to spawn with an unresolved session ref "${session}" — ` +
        "resume sessions must come from the #525 resolver, not a pasted name/uuid");
    }
    argv.push("--resume", session.trim());
  }
  if (cwd) {
    spawnOpts.cwd = String(cwd);
  }
  return { argv, spawnOpts };
};

// Guard used by server.mjs BEFORE a resumed spawn: if the request asked to
// resume a session but its task store is unreachable, return the error object
// so the caller surfaces an explicit message instead of a number.
export const assertTaskStoreReachable = ({ claudeHome, session }) => {
  if (!session) return null; // not a resumed call — nothing to verify
  const reason = taskStoreUnreachableReason(claudeHome, session);
  if (reason) {
    return {
      ok: false,
      type: "superset_task_store_unreachable",
      message: `cannot resume: ${reason}`,
    };
  }
  return null;
};