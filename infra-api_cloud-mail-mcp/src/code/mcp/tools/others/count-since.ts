#!/usr/bin/env tsx
// count-since.ts — read-only: count messages received since a given
// timestamp on maddy (IMAP SEARCH SINCE) and Stalwart (JMAP Email/query
// filter.after). Cross-store reconciliation helper for the mail health
// check (1_cicd/src/ops/cloud-health-mail-full.sh) — NOT an MCP tool, not
// wired into the MCP server. Sibling of gws_missing_backfill.py: one-off
// operator/CI script, run by hand or via `docker exec` the same way.
//
// Why this exists: the 7-phase cloud-mail-health-full Rust derive is a
// liveness/e2e PROBE (send a test message, check it round-trips) — it does
// NOT compare historical message counts across stores, so a store silently
// falling behind (e.g. maddy's dual-write to Stalwart failing) goes
// undetected. This script gives the ops script something to diff.
//
// Usage:
//   tsx count-since.ts --since 2026-08-21T00:00:00Z
// Prints: {"maddy":<N>,"stalwart":<M>}  (either count is -1 on error, with
// the reason on stderr — the caller decides how to treat a -1).
//
// Credentials: reused exactly as cloud-mail-mcp's own tools read them — see
// ../../shared/config.ts getAccount(). Set MADDY_ME_USER/MADDY_ME_PASSWORD
// (or MAIL_USER/MAIL_PASSWORD, the maddy/me back-compat fallback) and
// STALWART_ME_USER/STALWART_ME_PASSWORD in the environment this runs in —
// same env vars the cloud-mail-mcp container already has via its .secrets file
// (see ../../../compose.nix), so this is meant to run via `docker exec
// cloud-mail-mcp ...` on oci-apps, not standalone.

import { withImap } from "../../shared/imap.js";
import { getServer, getAccount } from "../../shared/config.js";

function authHeader(user: string, pass: string): string {
  return "Basic " + Buffer.from(`${user}:${pass}`).toString("base64");
}

async function countMaddy(sinceDate: Date): Promise<number> {
  return withImap("maddy", "me", async (client) => {
    // Three traps here, all of which used to collapse into a silent 0 — the
    // one value this script must never invent, because the caller reads 0 as
    // data loss and raises a mail-outage alarm.
    //
    //  1. withImap connects but never SELECTs a mailbox, and imapflow's
    //     search() returns `undefined` (not []) with none selected. The old
    //     `Array.isArray(uids) ? uids.length : 0` turned that into 0
    //     unconditionally, for any amount of real mail, forever. INBOX alone
    //     holds 10152 messages. An absent result set is now a throw, which
    //     main()'s .catch converts to the -1 "unavailable" sentinel.
    //  2. Sieve sorts incoming mail out of INBOX into the F* folders, so a
    //     single-mailbox count structurally undercounts — over 7 days INBOX
    //     saw 801 of 1602 messages, half the total. Count every selectable
    //     mailbox.
    //  3. IMAP SEARCH SINCE is date-granularity, and maddy's imapsql treats
    //     it as INTERNALDATE > <the whole day> rather than RFC 3501's ">=":
    //     `SINCE 2026-09-04` returned 0 while 76 messages carried that exact
    //     INTERNALDATE. Prefilter deliberately wide, then compare real
    //     timestamps so the window is honest.
    const prefilter = new Date(sinceDate.getTime() - 3 * 86400000);
    let total = 0;
    for (const box of await client.list()) {
      if (box.flags?.has("\\Noselect")) continue;
      const lock = await client.getMailboxLock(box.path);
      try {
        const uids = await client.search({ since: prefilter }, { uid: true });
        if (!Array.isArray(uids)) {
          throw new Error(`IMAP SEARCH returned no result set for ${box.path} (mailbox not selected?)`);
        }
        if (uids.length === 0) continue;
        for await (const msg of client.fetch(uids, { uid: true, internalDate: true }, { uid: true })) {
          if (msg.internalDate && msg.internalDate >= sinceDate) total++;
        }
      } finally {
        lock.release();
      }
    }
    return total;
  });
}

async function countStalwart(sinceIso: string): Promise<number> {
  const srv = getServer("stalwart");
  const creds = getAccount("stalwart", "me");
  if (!srv.jmap) throw new Error("STALWART_JMAP_URL not configured");
  const auth = authHeader(creds.user, creds.password);

  // Session discovery — same direct-session-resource pattern as jmap.ts
  // (avoids depending on the /.well-known/jmap redirect).
  const sessionUrl = new URL("/jmap/session", srv.jmap).toString();
  const sres = await fetch(sessionUrl, { headers: { Authorization: auth } });
  if (!sres.ok) throw new Error(`JMAP session ${sres.status}: ${await sres.text()}`);
  const session = (await sres.json()) as { apiUrl: string; primaryAccounts: Record<string, string> };
  const accountId = session.primaryAccounts?.["urn:ietf:params:jmap:mail"];
  if (!accountId) throw new Error("JMAP: no primary mail account in session");
  // Rebase advertised apiUrl PATH onto the configured origin (public edge vs
  // WG-direct backend port) — same rebase jmap.ts does before POSTing.
  const base = new URL(srv.jmap);
  const adv = new URL(session.apiUrl, base);
  const apiUrl = base.origin + adv.pathname + adv.search;

  const res = await fetch(apiUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: auth },
    body: JSON.stringify({
      using: ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
      methodCalls: [
        ["Email/query", { accountId, filter: { after: sinceIso }, calculateTotal: true }, "q1"],
      ],
    }),
  });
  if (!res.ok) throw new Error(`JMAP Email/query ${res.status}: ${await res.text()}`);
  const body = (await res.json()) as { methodResponses?: [string, Record<string, unknown>, string][] };
  const result = body.methodResponses?.[0]?.[1] as { total?: number; ids?: string[] } | undefined;
  if (typeof result?.total === "number") return result.total;
  if (Array.isArray(result?.ids)) return result.ids.length;
  // Neither total nor ids came back: the query did not answer. Returning 0
  // here would be the same lie countMaddy used to tell — throw so the caller
  // gets the -1 "unavailable" sentinel instead of a fake "no mail".
  throw new Error(`JMAP Email/query returned neither total nor ids: ${JSON.stringify(body).slice(0, 300)}`);
}

async function main() {
  const args = process.argv.slice(2);
  const idx = args.indexOf("--since");
  const sinceArg = idx >= 0 ? args[idx + 1] : undefined;
  if (!sinceArg) {
    process.stderr.write("usage: count-since.ts --since <ISO8601>\n");
    process.exit(2);
  }
  const sinceDate = new Date(sinceArg);
  if (Number.isNaN(sinceDate.getTime())) {
    process.stderr.write(`invalid --since date: ${sinceArg}\n`);
    process.exit(2);
  }

  const [maddy, stalwart] = await Promise.all([
    countMaddy(sinceDate).catch((e) => {
      process.stderr.write(`maddy count failed: ${e instanceof Error ? e.message : e}\n`);
      return -1;
    }),
    countStalwart(sinceDate.toISOString()).catch((e) => {
      process.stderr.write(`stalwart count failed: ${e instanceof Error ? e.message : e}\n`);
      return -1;
    }),
  ]);

  process.stdout.write(JSON.stringify({ maddy, stalwart }) + "\n");
}

main().catch((e) => {
  process.stderr.write(`fatal: ${e instanceof Error ? e.message : e}\n`);
  process.exit(1);
});
