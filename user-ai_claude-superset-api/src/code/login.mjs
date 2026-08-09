// login.mjs — drive `claude setup-token` over HTTP so the Telegram bot can
// log this container in without anyone opening a shell on the VM.
//
// Why this exists: the subscription CLI authenticates by browser OAuth. The
// credential lands in ~/.claude/.credentials.json, which is persisted in the
// claude_home named volume — so it only has to be done once, but it *does*
// have to be done interactively, and nobody can reach the VM from a phone.
// This splits the flow into two HTTP calls so a chat client can carry the
// human half:
//
//   POST /auth/login/start        → { session_id, url }   (bot sends url to user)
//   POST /auth/login/code {code}  → { ok, message }       (user pastes code back)
//
// The hard part is that the CLI is one long-lived interactive process: it
// prints the URL, then blocks on stdin waiting for the code. It cannot be
// restarted between the two calls or the OAuth state (PKCE verifier) is lost —
// which is exactly how earlier attempts died. So `start` leaves the child
// running, parked on its stdin pipe, and `code` writes into that same child.
//
// `claude setup-token` also insists on a TTY. Node's spawn gives pipes, not a
// pty, and this service is deliberately dependency-free (no node-pty), so we
// borrow util-linux `script` to allocate one:
//     script -qfec "claude setup-token" /dev/null
// -q quiet, -f flush after each write (so we see the URL immediately rather
// than when a block buffer fills), -e propagate the child's exit status,
// -c run this command.

import { spawn } from "node:child_process";

// A login attempt is a singleton: two concurrent OAuth flows would race on
// ~/.claude/.credentials.json and there is exactly one human doing this.
let pending = null;

const TTL_MS = 10 * 60 * 1000;   // OAuth codes expire; don't hold a pty forever.
const URL_WAIT_MS = 60 * 1000;   // how long to wait for the CLI to print its url.

const clear = () => {
  if (!pending) return;
  clearTimeout(pending.timer);
  try { pending.child.kill("SIGKILL"); } catch { /* already gone */ }
  pending = null;
};

// The CLI prints a claude.ai authorize link; grab the first one we see.
// Trailing punctuation/quotes/ANSI resets get stripped by the char class.
const findUrl = (buf) => {
  const m = buf.match(/https:\/\/[^\s"'`]*(?:oauth|authorize)[^\s"'`]*/i);
  return m ? m[0] : null;
};

const stripAnsi = (s) => s.replace(/\[[0-9;?]*[A-Za-z]/g, "");

export const startLogin = ({ claudeBin = "claude" } = {}) =>
  new Promise((resolve) => {
    clear();

    // script -c takes ONE string, so the inner command is a shell word list.
    const child = spawn(
      "script",
      ["-qfec", `${claudeBin} setup-token`, "/dev/null"],
      { stdio: ["pipe", "pipe", "pipe"], env: { ...process.env } },
    );

    let out = "";
    let settled = false;

    const finish = (payload) => {
      if (settled) return;
      settled = true;
      resolve(payload);
    };

    const onData = (chunk) => {
      out += stripAnsi(chunk.toString());
      const url = findUrl(out);
      if (url) finish({ ok: true, session_id: pending?.id, url });
    };

    child.stdout.on("data", onData);
    child.stderr.on("data", onData);

    // If the CLI exits before printing a url it is already broken (missing
    // binary, no network) — surface its own output rather than a timeout.
    child.on("exit", (code) => {
      if (!settled) {
        clear();
        finish({ ok: false, error: `setup-token exited ${code} before printing a url`, output: out.slice(-800) });
      }
    });
    child.on("error", (err) => {
      if (!settled) { clear(); finish({ ok: false, error: `spawn failed: ${err.message}` }); }
    });

    pending = {
      id: `login-${Date.now().toString(36)}`,
      child,
      out: () => out,
      timer: setTimeout(clear, TTL_MS),
    };

    setTimeout(() => {
      if (!settled) finish({ ok: false, error: "no url after 60s", output: out.slice(-800) });
    }, URL_WAIT_MS).unref?.();
  });

export const submitCode = (code) =>
  new Promise((resolve) => {
    if (!pending) return resolve({ ok: false, error: "no login in progress — run /login first" });

    const { child } = pending;
    const before = pending.out().length;

    // The CLI is blocked on a read; a bare newline-terminated code answers it.
    child.stdin.write(`${code.trim()}\n`);

    // Success is the process exiting 0 after consuming the code.
    const done = (payload) => {
      clearTimeout(guard);
      child.removeListener("exit", onExit);
      clear();
      resolve(payload);
    };
    const onExit = (exitCode) => {
      const tail = pending ? pending.out().slice(before) : "";
      done(exitCode === 0
        ? { ok: true, message: "logged in — credentials written to ~/.claude/.credentials.json" }
        : { ok: false, error: `setup-token exited ${exitCode}`, output: tail.slice(-800) });
    };
    child.on("exit", onExit);

    const guard = setTimeout(() => {
      const tail = pending ? pending.out().slice(before) : "";
      done({ ok: false, error: "timed out waiting for setup-token to finish", output: tail.slice(-800) });
    }, 90 * 1000);
  });

export const loginStatus = () => ({ pending: Boolean(pending), session_id: pending?.id ?? null });
