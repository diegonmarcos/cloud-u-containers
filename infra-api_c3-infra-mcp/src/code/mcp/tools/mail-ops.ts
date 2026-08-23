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
}
