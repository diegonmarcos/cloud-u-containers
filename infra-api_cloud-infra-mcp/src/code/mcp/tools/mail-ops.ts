import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { containerExecCmd } from "../../shared/libs/docker.js";
import { sshExec } from "../../shared/libs/ssh.js";

const MAIL_VM = "oci-mail";
const MAIL_CONTAINER = "maddy";
const POST_HOC = "/usr/local/bin/mail-sieve-subset-post-hoc";

// A large apply-rules catch-up runs well past containerExecCmd's 30s budget
// (the 2026-08-23 backfill of 1335 messages took minutes), so post-hoc goes
// through sshExec with its own timeout instead of the shared docker helper.
const POST_HOC_TIMEOUT_MS = 900_000;

// SQLite char(36) is '$'. Building the $distributed literal this way keeps the
// dollar out of the shell entirely — no escaping to get wrong across the
// ssh -> docker exec -> sqlite3 quoting layers.
const DISTRIBUTED = "char(36) || 'distributed'";

export function registerMailOpsTools(server: McpServer): void {
  // ── devops.mail.post_hoc — maddy maintenance runner ──────────────────────
  server.tool(
    "devops.mail.post_hoc",
    "Run a maddy post-hoc maintenance subcommand on oci-mail. 'apply-rules' is the INBOX -> category-folder distributor that the filtering system depends on; it COPIES (never moves) and is idempotent via the $distributed keyword, so re-running is always safe. Defaults to dry_run — pass dry_run:false to actually write.",
    {
      subcommand: z
        .enum([
          "apply-rules",
          "integrity-check",
          "integrity-fix",
          "dedupe",
          "cleanup-mailboxes",
          "reseed-inbox-archive",
          "all",
        ])
        .describe("post-hoc subcommand to run"),
      dry_run: z
        .boolean()
        .default(true)
        .describe("Preview without writing. Always dry-run first on a large backlog."),
    },
    async ({ subcommand, dry_run }) => {
      const flag = dry_run ? " --dry-run" : "";
      const result = sshExec(
        MAIL_VM,
        `docker exec ${MAIL_CONTAINER} ${POST_HOC} ${subcommand}${flag}`,
        POST_HOC_TIMEOUT_MS,
      );
      // post-hoc writes its progress lines to stderr, so report both streams.
      const out = [result.stdout, result.stderr].filter(Boolean).join("\n").trim();
      return result.ok
        ? { content: [{ type: "text" as const, text: out || "(no output)" }] }
        : {
            content: [
              {
                type: "text" as const,
                text: result.timedOut
                  ? `Error: timed out after ${POST_HOC_TIMEOUT_MS / 1000}s. The transaction may still be running inside maddy \u2014 re-run obs.health.mail_distribution to check.\n${out}`
                  : `Error: ${out}`,
              },
            ],
            isError: true,
          };
    },
  );

  // ── obs.health.mail_distribution — the check that was missing ────────────
  // INBOX distribution silently stopped 2026-06-20 and went unnoticed for 64
  // days (1335 of 1536 messages never distributed) because nothing ever
  // reported the backlog. A non-zero, growing count here means apply-rules is
  // not running — see the ops_maddy-apply-rules Dagu DAG.
  server.tool(
    "obs.health.mail_distribution",
    "INBOX distribution backlog: how many messages still lack the $distributed keyword, plus the oldest and newest undistributed dates. A growing backlog means the apply-rules scheduler has stopped.",
    {},
    async () => {
      const sql = [
        "SELECT 'inbox_total=' || COUNT(*) FROM msgs m",
        "  JOIN mboxes b ON b.id = m.mboxId WHERE b.name = 'INBOX';",
        "SELECT 'undistributed=' || COUNT(*) FROM msgs m",
        "  JOIN mboxes b ON b.id = m.mboxId WHERE b.name = 'INBOX'",
        "  AND NOT EXISTS (SELECT 1 FROM flags f WHERE f.mboxId = m.mboxId",
        `    AND f.msgId = m.msgId AND f.flag = ${DISTRIBUTED});`,
        "SELECT 'oldest_undistributed=' || COALESCE(datetime(MIN(m.date),'unixepoch'),'none'),",
        "       'newest_undistributed=' || COALESCE(datetime(MAX(m.date),'unixepoch'),'none')",
        "  FROM msgs m JOIN mboxes b ON b.id = m.mboxId WHERE b.name = 'INBOX'",
        "  AND NOT EXISTS (SELECT 1 FROM flags f WHERE f.mboxId = m.mboxId",
        `    AND f.msgId = m.msgId AND f.flag = ${DISTRIBUTED});`,
      ].join(" ");
      const result = containerExecCmd(
        MAIL_VM,
        MAIL_CONTAINER,
        `sqlite3 -readonly /data/imapsql.db "${sql}"`,
      );
      return result.ok
        ? { content: [{ type: "text" as const, text: result.output }] }
        : {
            content: [{ type: "text" as const, text: `Error: ${result.output}` }],
            isError: true,
          };
    },
  );

  // ── obs.health.mail_ingest — the blackout detector ───────────────────────
  // Leg B (Cloudflare Worker -> http-to-smtp -> maddy) died 2026-08-13 and
  // stayed dead until 2026-08-21. Nine days, zero inbound, and nothing noticed:
  // every existing check asked "is the service up?", none asked "is mail still
  // ARRIVING?". A live maddy with an empty INBOX looks perfectly healthy.
  // age_hours is the alarm; the day map shows the shape of the hole.
  server.tool(
    "obs.health.mail_ingest",
    "Inbound freshness for maddy INBOX: hours since the last delivery, plus a 21-day per-day delivery map. A large age_hours or a run of 0-delivery days means inbound is broken (leg B down) even though every container still reports healthy.",
    {},
    async () => {
      const sql = [
        "SELECT 'newest_delivery=' || COALESCE(datetime(MAX(m.date),'unixepoch'),'none')",
        "    || ' age_hours=' || COALESCE(CAST((strftime('%s','now') - MAX(m.date))/3600 AS INT),-1)",
        "  FROM msgs m JOIN mboxes b ON b.id = m.mboxId WHERE b.name = 'INBOX';",
        "WITH RECURSIVE d(x) AS (",
        "  SELECT date('now','-20 days')",
        "  UNION ALL SELECT date(x,'+1 day') FROM d WHERE x < date('now'))",
        "SELECT d.x || ' ' || COALESCE(c.n,0) ||",
        "       CASE WHEN COALESCE(c.n,0) = 0 THEN '  <-- NO MAIL' ELSE '' END",
        "  FROM d LEFT JOIN (SELECT date(m.date,'unixepoch') dd, COUNT(*) n",
        "    FROM msgs m JOIN mboxes b ON b.id = m.mboxId",
        "    WHERE b.name = 'INBOX' GROUP BY dd) c ON c.dd = d.x",
        "  ORDER BY d.x;",
      ].join(" ");
      const result = containerExecCmd(
        MAIL_VM,
        MAIL_CONTAINER,
        `sqlite3 -readonly /data/imapsql.db "${sql}"`,
      );
      return result.ok
        ? { content: [{ type: "text" as const, text: result.output }] }
        : {
            content: [{ type: "text" as const, text: `Error: ${result.output}` }],
            isError: true,
          };
    },
  );

  // ── obs.health.mail_puller — the safety net's own health ─────────────────
  // mail-puller is the reconciliation leg: it pulls the Gmail/Workspace copy
  // back into maddy, so anything leg B drops still lands. gws-primary — the
  // connector covering the Workspace mailbox — had been failing every ~30s with
  // "invalid_client" for thousands of cycles. That is why the Aug 13-21 blackout
  // never self-healed: the net that exists to catch exactly this was itself
  // down, and failing silently, for the entire outage.
  server.tool(
    "obs.health.mail_puller",
    "Per-source health of the mail-puller reconciliation legs (gmail-primary / gws-primary / live-primary). Reports failing cycles per source in the recent log window. ANY source failing means lost mail will NOT be recovered automatically.",
    {},
    async () => {
      const result = sshExec(
        MAIL_VM,
        "docker logs --since 15m mail-puller 2>&1 | sed 's/\\x1b\\[[0-9;]*m//g' " +
          "| grep 'cycle failed' | grep -oE 'source=[a-z-]+' | sort | uniq -c " +
          "| awk '{print $2, \"failed_cycles_15m=\" $1}'; " +
          "echo '---'; docker logs --since 15m mail-puller 2>&1 " +
          "| sed 's/\\x1b\\[[0-9;]*m//g' " +
          "| grep -oE '\"error\": ?\"[a-zA-Z_]+\"' | sort -u",
        60_000,
      );
      const raw = [result.stdout, result.stderr].filter(Boolean).join("\n").trim();
      const text = raw.replace(/^---$/m, "").trim();
      return result.ok
        ? {
            content: [
              {
                type: "text" as const,
                text: text
                  ? `${text}\n\nNOTE: any source listed above is FAILING. A healthy source logs no errors.`
                  : "all pull sources healthy (no error cycles in the last 15m)",
              },
            ],
          }
        : {
            content: [{ type: "text" as const, text: `Error: ${raw}` }],
            isError: true,
          };
    },
  );
}
