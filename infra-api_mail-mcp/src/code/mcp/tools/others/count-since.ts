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
// Credentials: reused exactly as mail-mcp's own tools read them — see
// ../../shared/config.ts getAccount(). Set MADDY_ME_USER/MADDY_ME_PASSWORD
// (or MAIL_USER/MAIL_PASSWORD, the maddy/me back-compat fallback) and
// STALWART_ME_USER/STALWART_ME_PASSWORD in the environment this runs in —
// same env vars the mail-mcp container already has via its .secrets file
// (see ../../../compose.nix), so this is meant to run via `docker exec
// mail-mcp ...` on oci-apps, not standalone.

import { withImap } from "../../shared/imap.js";
import { getServer, getAccount } from "../../shared/config.js";

function authHeader(user: string, pass: string): string {
  return "Basic " + Buffer.from(`${user}:${pass}`).toString("base64");
}

async function countMaddy(sinceDate: Date): Promise<number> {
  return withImap("maddy", "me", async (client) => {
    // IMAP SEARCH SINCE is date-granularity only (no time-of-day) — fine for
    // the loose (multi-message / percentage) tolerance the caller applies.
    const uids = await client.search({ since: sinceDate }, { uid: true });
    return Array.isArray(uids) ? uids.length : 0;
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
  return result?.ids?.length ?? 0;
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
