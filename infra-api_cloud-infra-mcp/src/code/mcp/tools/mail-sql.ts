/**
 * The maddy SQLite queries behind obs.health.mail_distribution and
 * obs.health.mail_ingest. Pure — no imports — so test-shell-quote.mjs runs
 * these exact strings through the real ssh -> fish -> bash -> docker exec ->
 * sh -> sqlite3 quoting chain against a fixture DB.
 */

export const MAIL_DB = "/data/imapsql.db";

// SQLite char(36) is '$'. Building the $distributed literal this way keeps the
// dollar out of the shell entirely.
const DISTRIBUTED = "char(36) || 'distributed'";

export const DISTRIBUTION_SQL = [
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

export const INGEST_SQL = [
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
