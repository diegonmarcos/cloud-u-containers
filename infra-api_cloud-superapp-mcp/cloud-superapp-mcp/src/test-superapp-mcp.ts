/**
 * Self-check: `npx tsx test-superapp-mcp.ts`
 *
 * Covers the two things that fail silently and expensively — the shell
 * escaping (the model supplies `app`, `path` and every query value, and they
 * all end up inside a script piped to `ssh ... sh -s`) and the app resolver's
 * ambiguity rules. The live half runs only when the phone answers, so this
 * passes on a laptop with the phone off, in CI, and on a plane.
 */
import { strict as assert } from "node:assert";
import { execFileSync } from "node:child_process";
import { PORT_DEVCONTROL, run, scan, sq } from "../../lib-mcp/src/device.js";
import { ROUTE_RE, label, resolve } from "../../lib-mcp/src/tools.js";

let n = 0;
const ok = (what: string) => {
  n++;
  process.stdout.write(`  ok ${what}\n`);
};

// ── shell escaping ───────────────────────────────────────────────────────────
assert.equal(sq("plain"), "'plain'");
ok("sq wraps a plain word");

// The injection that matters: close the quote, run something, reopen.
assert.equal(sq("a'; rm -rf /; echo '"), `'a'\\''; rm -rf /; echo '\\'''`);
ok("sq neutralises a quote-break injection");

// The property that actually matters, checked against a real shell rather
// than by eyeballing the quoting: whatever goes in comes back out verbatim,
// having executed nothing. `a'b` legitimately contains quotes once escaped —
// an earlier version of this test asserted "no inner quote" and was simply
// wrong about POSIX.
for (const evil of ["$(id)", "`id`", "; id", "a'b", "\n id \n", "'; rm -rf /; '", "$HOME"]) {
  const back = execFileSync("sh", ["-c", `printf %s ${sq(evil)}`], { encoding: "utf8" });
  assert.equal(back, evil, `sq did not round-trip ${JSON.stringify(evil)}`);
}
ok("sq round-trips every metacharacter payload through a real shell");

// ── route allowlist ──────────────────────────────────────────────────────────
for (const good of ["news/latest", "/fleet/peers", "docs", "system/info", "a_b-c/d"]) {
  assert.ok(ROUTE_RE.test(good), `should accept ${good}`);
}
ok("ROUTE_RE accepts real routes");

for (const bad of ["../../etc/passwd", "news;id", "news latest", "http://x/y", "a/../b", "news?n=1", ""]) {
  assert.equal(ROUTE_RE.test(bad), false, `should reject ${bad}`);
}
ok("ROUTE_RE rejects traversal, metacharacters and URLs");

// ── app resolution ───────────────────────────────────────────────────────────
const fleet = [
  { port: PORT_DEVCONTROL, pkg: "" },
  { port: 38090, pkg: "com.diegonmarcos.superapp" },
  { port: 38091, pkg: "com.diegonmarcos.comms.mail" },
  { port: 38092, pkg: "com.diegonmarcos.superapp" },
];

assert.equal(label(fleet[0]), "devcontrol");
ok("the tokenless 38080 ping is labelled devcontrol");

assert.equal(resolve(fleet, "38091").pkg, "com.diegonmarcos.comms.mail");
ok("a bare port resolves");

assert.equal(resolve(fleet, "mail").port, 38091);
ok("a substring resolves");

// One pkg, two processes (an engine gets its own server) — take the lowest
// port rather than refusing, or every superapp query becomes an error.
assert.equal(resolve(fleet, "com.diegonmarcos.superapp").port, 38090);
assert.equal(resolve(fleet, "superapp").port, 38090);
ok("a pkg on two ports resolves to the lowest, not an error");

assert.throws(() => resolve(fleet, "com"), /be specific/);
ok("a substring spanning two different pkgs is refused");

assert.throws(() => resolve(fleet, "nope"), /no app matches/);
assert.throws(() => resolve(fleet, "39000"), /nothing on port/);
assert.throws(() => resolve([], "mail"), /no app is serving/);
ok("misses name what is actually live");

// ── live, only if the phone answers ──────────────────────────────────────────
const reachable = await run("echo up").then((s) => s.trim() === "up").catch(() => false);
if (!reachable) {
  process.stdout.write(`\n${n} checks passed (live half skipped — phone unreachable)\n`);
} else {
  ok("phone reachable");
  const live = await scan();
  assert.ok(live.length > 0, "no app answered /api/system/ping");
  ok(`scan found ${live.length}: ${live.map((a) => `${label(a)}@${a.port}`).join(", ")}`);
  assert.ok(live.every((a) => a.port >= PORT_DEVCONTROL && a.port <= 38139));
  ok("every discovered port is in range");
  process.stdout.write(`\n${n} checks passed (live)\n`);
}
