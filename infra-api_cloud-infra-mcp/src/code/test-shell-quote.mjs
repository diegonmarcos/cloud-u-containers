// Tests the REAL quoting chain behind every sshExec / containerExecCmd call,
// and the two maddy SQL tools that broke on it (obs.health.mail_distribution,
// obs.health.mail_ingest): the remote login shell on oci-mail is fish, which
// read the old '\'' quoting differently from POSIX and stripped the SQL's
// single quotes ("near ||: syntax error").
// Run: node --experimental-strip-types test-shell-quote.mjs
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, chmodSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  anyShellQuote, posixQuote, remoteShellWrap, dockerExecShell, sqliteReadonlyCmd,
} from "./shared/libs/shell-quote.ts";
import { MAIL_DB, DISTRIBUTION_SQL, INGEST_SQL } from "./mcp/tools/mail-sql.ts";

let n = 0;
const t = (name, fn) => { fn(); n++; console.log(`ok - ${name}`); };

// The pre-fix wrapper, kept only to prove these tests catch the bug.
const legacyWrap = (c) => `bash -c '${c.replace(/'/g, "'\\''")}'`;
const legacyDockerExec = (ct, c) => `docker exec ${ct} sh -c '${c.replace(/'/g, "'\\''")}'`;

// Split a command line into words the way fish 3.x does (quoting only — no
// expansion is reachable inside the quotes we emit). Single quotes: `\'` and
// `\\` are escapes. Double quotes: `\"` `\\` `\$` and backslash-newline.
function fishWords(s) {
  const words = [];
  let cur = null;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c === " " || c === "\t" || c === "\n") { if (cur !== null) words.push(cur); cur = null; continue; }
    cur ??= "";
    if (c === "'") {
      for (i++; i < s.length && s[i] !== "'"; i++) {
        if (s[i] === "\\" && (s[i + 1] === "'" || s[i + 1] === "\\")) i++;
        cur += s[i];
      }
      assert.ok(i < s.length, "fish: unterminated single quote");
    } else if (c === '"') {
      for (i++; i < s.length && s[i] !== '"'; i++) {
        if (s[i] === "\\" && '"\\$\n'.includes(s[i + 1])) { i++; if (s[i] === "\n") continue; }
        else assert.ok(s[i] !== "$", "fish: $ would expand inside double quotes");
        cur += s[i];
      }
      assert.ok(i < s.length, "fish: unterminated double quote");
    } else if (c === "\\") {
      cur += s[++i];
    } else {
      assert.ok(!"<>|;&$()*?{}~#".includes(c), `fish: unquoted metachar ${c}`);
      cur += c;
    }
  }
  if (cur !== null) words.push(cur);
  return words;
}

const NASTY = [
  "", "plain", "it's", "''", "a\\b", "\\'", "'\\''", "$HOME `id` $(id)", "x\ny", "\"q\" \\\" '",
  "sed 's/\\x1b\\[[0-9;]*m//g' | awk '{print $2, \"n=\" $1}'",
];

t("anyShellQuote: fish reads every string back verbatim", () => {
  for (const s of NASTY) assert.deepEqual(fishWords(anyShellQuote(s)), [s], JSON.stringify(s));
});

t("remoteShellWrap: fish login shell sees exactly `bash -c <body>`", () => {
  for (const s of NASTY.filter(Boolean)) assert.deepEqual(fishWords(remoteShellWrap(s)), ["bash", "-c", s]);
});

t("mail tools: fish keeps the SQL's quotes (the old wrap did not)", () => {
  for (const sql of [DISTRIBUTION_SQL, INGEST_SQL]) {
    const body = dockerExecShell("maddy", sqliteReadonlyCmd(MAIL_DB, sql));
    assert.deepEqual(fishWords(remoteShellWrap(body)), ["bash", "-c", body]);
    // Regression proof: the pre-fix chain is mangled by fish.
    const old = legacyDockerExec("maddy", `sqlite3 -readonly /data/imapsql.db "${sql}"`);
    let w; try { w = fishWords(legacyWrap(old)); } catch { w = null; }
    assert.notDeepEqual(w, ["bash", "-c", old], "legacy quoting should be caught as broken");
  }
  assert.ok(DISTRIBUTION_SQL.includes("'inbox_total='") && INGEST_SQL.includes("'  <-- NO MAIL'"));
});

// ── Real shells: login shell -> bash -c -> docker exec (fake) -> sh -c -> sqlite3 ──
const have = (bin) => spawnSync("sh", ["-c", `command -v ${bin}`], { encoding: "utf-8" }).stdout.trim();
const LOGIN_SHELLS = ["sh", "bash", "dash", "fish"].filter(have);
const SQLITE = have("sqlite3");

t(`real shells (${LOGIN_SHELLS.join(",")}) round-trip every string`, () => {
  for (const sh of LOGIN_SHELLS) for (const s of NASTY) {
    const r = spawnSync(sh, ["-c", remoteShellWrap(`printf %s ${posixQuote(s)}`)], { encoding: "utf-8" });
    assert.equal(r.stdout, s, `${sh}: ${JSON.stringify(s)} -> ${JSON.stringify(r.stdout)} ${r.stderr}`);
  }
});

if (!SQLITE) {
  console.log("SKIP - sqlite3 not installed: real-chain SQL checks not run (fish-quoting checks above still ran)");
} else {
  const dir = mkdtempSync(join(tmpdir(), "c3-shq-"));
  try {
    const db = join(dir, "imapsql.db");
    const now = Math.floor(Date.now() / 1000);
    const seed = spawnSync(SQLITE, [db], { encoding: "utf-8", input: `
      CREATE TABLE mboxes(id INTEGER, name TEXT);
      CREATE TABLE msgs(mboxId INTEGER, msgId INTEGER, date INTEGER);
      CREATE TABLE flags(mboxId INTEGER, msgId INTEGER, flag TEXT);
      INSERT INTO mboxes VALUES (1,'INBOX'),(2,'Archive');
      INSERT INTO msgs VALUES (1,1,${now - 120}),(1,2,${now - 60}),(1,3,${now}),(2,9,${now});
      INSERT INTO flags VALUES (1,1,'$distributed'),(1,2,'\\Seen');` });
    assert.equal(seed.status, 0, seed.stderr);
    // docker stand-in: `docker exec <ct> sh -c X` -> `sh -c X`; sqlite3 stand-in maps the maddy DB path.
    writeFileSync(join(dir, "docker"), `#!/bin/sh\n[ "$1" = exec ] || exit 99\nshift 2\nexec "$@"\n`);
    writeFileSync(join(dir, "sqlite3"),
      `#!/bin/sh\n[ "$2" = ${posixQuote(MAIL_DB)} ] || { echo "bad db arg: $2" >&2; exit 98; }\n` +
      `exec ${posixQuote(SQLITE)} "$1" ${posixQuote(db)} "$3"\n`);
    chmodSync(join(dir, "docker"), 0o755); chmodSync(join(dir, "sqlite3"), 0o755);
    const env = { ...process.env, PATH: `${dir}:${process.env.PATH}` };
    const run = (sh, sql) => spawnSync(sh, ["-c", remoteShellWrap(dockerExecShell("maddy", sqliteReadonlyCmd(MAIL_DB, sql)))], { encoding: "utf-8", env });

    t(`mail_distribution via ${LOGIN_SHELLS.join(",")} returns real counts`, () => {
      for (const sh of LOGIN_SHELLS) {
        const r = run(sh, DISTRIBUTION_SQL);
        assert.equal(r.status, 0, `${sh}: ${r.stderr}`);
        const lines = r.stdout.trim().split("\n");
        assert.equal(lines[0], "inbox_total=3", sh);
        assert.equal(lines[1], "undistributed=2", sh);
        assert.match(lines[2], /^oldest_undistributed=\d{4}-\d\d-\d\d \S+\|newest_undistributed=\d{4}-/, sh);
      }
    });

    t(`mail_ingest via ${LOGIN_SHELLS.join(",")} returns freshness + 21-day map`, () => {
      for (const sh of LOGIN_SHELLS) {
        const r = run(sh, INGEST_SQL);
        assert.equal(r.status, 0, `${sh}: ${r.stderr}`);
        const lines = r.stdout.trim().split("\n");
        assert.match(lines[0], /^newest_delivery=\d{4}-\d\d-\d\d \S+ age_hours=0$/, sh);
        assert.equal(lines.length, 22, sh);
        const days = lines.slice(1).map((l) => l.match(/^\d{4}-\d\d-\d\d (\d+)(  <-- NO MAIL)?$/));
        assert.ok(days.every(Boolean), `${sh}: ${lines.join(" / ")}`);
        assert.equal(days.reduce((a, m) => a + Number(m[1]), 0), 3, sh);
        assert.ok(days.filter((m) => m[2]).length >= 19, sh);
      }
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

console.log(`\n${n} passed`);
