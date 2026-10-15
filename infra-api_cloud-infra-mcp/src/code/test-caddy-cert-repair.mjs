// Tests the REAL script + parsers behind devops.caddy.cert_repair. The script
// is run locally under bash against a temp /data tree holding real openssl
// keypairs, so "key matches cert" is decided by openssl, not by a mock.
// Incident 2026-10-15: caddy on gcp-proxy crash-looped on "tls: private key
// does not match public key" for mesh-CA certs.
// Run: node --experimental-strip-types test-caddy-cert-repair.mjs
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, existsSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  buildRepairScript, parseScanOutput, parseDataMount, tsStamp, mismatchLines, mismatchDomains,
  lastStartupError, parseState, formatReport, certDomain, CONTAINER_RE,
} from "./shared/libs/caddy-cert-repair.ts";

let n = 0;
const t = (name, fn) => { fn(); n++; console.log(`ok - ${name}`); };
const sh = (cmd, cwd) => { const r = spawnSync("bash", ["-c", cmd], { cwd, encoding: "utf8" }); assert.equal(r.status, 0, r.stderr); return r; };

const TS = "20261015T120000Z";
const tmp = mkdtempSync(join(tmpdir(), "caddy-cert-repair-"));
const mk = (data, issuer, name, { mismatch = false } = {}) => {
  const dir = join(data, "caddy/certificates", issuer, name);
  mkdirSync(dir, { recursive: true });
  // cert for key A; key file holds key A (match) or an unrelated key B (mismatch)
  sh(`openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out a.key 2>/dev/null && openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out b.key 2>/dev/null && openssl req -new -x509 -key a.key -subj /CN=${name} -days 2 -out '${join(dir, name + ".crt")}'`, dir);
  sh(`mv ${mismatch ? "b.key" : "a.key"} '${join(dir, name + ".key")}'; rm -f a.key b.key`, dir);
};
const run = (data, o) => {
  const r = spawnSync("bash", ["-s"], { input: buildRepairScript({ dataDir: data, allMesh: false, dryRun: true, ts: TS, ...o }), encoding: "utf8" });
  return { ...r, lines: parseScanOutput(r.stdout) };
};
const fresh = (label) => { const d = join(tmp, label); mkdirSync(join(d, "caddy/certificates"), { recursive: true }); return d; };

t("healthy tree: all match, nothing to repair", () => {
  const d = fresh("healthy");
  mk(d, "mesh", "filebrowser.app"); mk(d, "acme-v02.api.letsencrypt.org-directory", "example.com");
  const r = run(d);
  assert.deepEqual(r.lines.map((l) => l.kind).sort(), ["done", "ok", "ok"]);
  assert.match(formatReport({ vm: "gcp-proxy", container: "caddy", dataDir: d, dryRun: true, allMesh: false, scan: r.lines, restarted: null, state: null, remaining: [], startupErrors: [], lastError: null }), /nothing to repair/);
});

t("dry run flags only the mismatched dir and moves nothing", () => {
  const d = fresh("dry");
  mk(d, "mesh", "good.app"); mk(d, "mesh", "filebrowser.app", { mismatch: true });
  const r = run(d);
  assert.deepEqual(r.lines.filter((l) => l.kind === "bad"), [{ kind: "bad", cert: "mesh/filebrowser.app" }]);
  assert.ok(!r.lines.some((l) => l.kind === "moved"));
  assert.ok(existsSync(join(d, "caddy/certificates/mesh/filebrowser.app")));
  const rep = formatReport({ vm: "v", container: "caddy", dataDir: d, dryRun: true, allMesh: false, scan: r.lines, restarted: null, state: null, remaining: [], startupErrors: [], lastError: null });
  assert.doesNotMatch(rep, /nothing to repair/); assert.match(rep, /MISMATCH mesh\/filebrowser\.app \(would move\)/);
});

t("live run moves only the mismatched dir to bad-cert-<name>-<ts>", () => {
  const d = fresh("live");
  mk(d, "mesh", "good.app"); mk(d, "mesh", "photoprism.app", { mismatch: true }); mk(d, "other", "c3-services-mcp.app", { mismatch: true });
  const r = run(d, { dryRun: false });
  assert.deepEqual(r.lines.filter((l) => l.kind === "moved").map((l) => l.cert).sort(), ["mesh/photoprism.app", "other/c3-services-mcp.app"]);
  assert.ok(existsSync(join(d, `caddy/bad-cert-photoprism.app-${TS}/photoprism.app.key`)), "files preserved, not deleted");
  assert.ok(existsSync(join(d, `caddy/bad-cert-c3-services-mcp.app-${TS}`)));
  assert.ok(!existsSync(join(d, "caddy/certificates/mesh/photoprism.app")));
  assert.ok(existsSync(join(d, "caddy/certificates/mesh/good.app")), "matching cert untouched");
  assert.equal(run(d, { dryRun: true }).lines.filter((l) => l.kind === "bad").length, 0, "second pass is clean");
});

t("all_mesh dry run reports, live run moves the whole mesh dir; other issuers stay", () => {
  const d = fresh("mesh");
  mk(d, "mesh", "a.app"); mk(d, "mesh", "b.app", { mismatch: true }); mk(d, "le", "keep.com");
  const dry = run(d, { allMesh: true });
  assert.deepEqual(dry.lines.find((l) => l.kind === "mesh"), { kind: "mesh", entries: 2 });
  assert.ok(existsSync(join(d, "caddy/certificates/mesh")));
  assert.ok(!dry.lines.some((l) => l.kind === "bad"), "mesh not probed individually under all_mesh");
  const live = run(d, { allMesh: true, dryRun: false });
  assert.ok(live.lines.some((l) => l.kind === "mesh_moved"));
  assert.ok(!existsSync(join(d, "caddy/certificates/mesh")));
  assert.ok(existsSync(join(d, `caddy/bad-cert-mesh-${TS}/b.app/b.app.key`)));
  assert.deepEqual(readdirSync(join(d, "caddy/certificates")), ["le"]);
});

t("incomplete / unreadable dirs are skipped, never moved", () => {
  const d = fresh("skip");
  mkdirSync(join(d, "caddy/certificates/mesh/nokey.app"), { recursive: true });
  sh(`touch caddy/certificates/mesh/nokey.app/nokey.app.crt`, d);
  mkdirSync(join(d, "caddy/certificates/mesh/junk.app"), { recursive: true });
  sh(`echo x > caddy/certificates/mesh/junk.app/junk.app.crt; echo y > caddy/certificates/mesh/junk.app/junk.app.key`, d);
  const r = run(d, { dryRun: false });
  assert.deepEqual(r.lines.filter((l) => l.kind === "skip").map((l) => l.cert).sort(), ["mesh/junk.app", "mesh/nokey.app"]);
  assert.ok(existsSync(join(d, "caddy/certificates/mesh/junk.app")) && existsSync(join(d, "caddy/certificates/mesh/nokey.app")));
});

t("missing certificates dir is an ERR, not a crash", () => {
  const d = join(tmp, "empty"); mkdirSync(d);
  const r = run(d);
  assert.ok(r.lines.some((l) => l.kind === "err") && !r.lines.some((l) => l.kind === "done"));
});

t("script inputs are validated (no injection through data dir or ts)", () => {
  for (const dataDir of ["/data; rm -rf /", "relative", "/a/../etc", "/a b", "/a'b", "", "/a$(id)"])
    assert.throws(() => buildRepairScript({ dataDir, allMesh: false, dryRun: true, ts: TS }), /Invalid data dir/, dataDir);
  for (const ts of ["", "x", "20261015T120000Z;id", "2026-10-15"])
    assert.throws(() => buildRepairScript({ dataDir: "/data", allMesh: false, dryRun: true, ts }), /Invalid timestamp/, ts);
  assert.ok(CONTAINER_RE.test("caddy") && !CONTAINER_RE.test("caddy;id") && !CONTAINER_RE.test("-x") && !CONTAINER_RE.test(""));
});

t("script never prints key material", () => {
  const d = fresh("quiet"); mk(d, "mesh", "x.app", { mismatch: true });
  const r = run(d);
  assert.doesNotMatch(r.stdout + r.stderr, /PRIVATE KEY|BEGIN /);
});

t("parseDataMount", () => {
  assert.equal(parseDataMount("/var/lib/docker/volumes/caddy_data/_data\n"), "/var/lib/docker/volumes/caddy_data/_data");
  assert.equal(parseDataMount("/opt/caddy/data/"), "/opt/caddy/data");
  for (const bad of ["", "\n", "/", "relative/p", "/a/../b", "/a b", "/a;b", "<no value>"]) assert.equal(parseDataMount(bad), null, bad);
});

t("tsStamp is filesystem-safe", () => {
  assert.equal(tsStamp(new Date("2026-10-15T12:00:00.123Z")), "20261015T120000Z");
  assert.match(tsStamp(), /^\d{8}T\d{6}Z$/);
});

const JSON_LOG = '{"level":"error","ts":1.7e9,"logger":"tls","msg":"unable to get certificate","identifier":"filebrowser.app","error":"caching certificate: tls: private key does not match public key"}';
const LOGS = [
  '{"level":"info","ts":1.7e9,"msg":"serving initial configuration"}',
  JSON_LOG,
  "Error: loading initial config: loading new config: tls: private key does not match public key for photoprism.app",
  '{"level":"error","msg":"other failure","error":"dial tcp: lookup example.org: no such host"}',
].join("\n");

t("mismatchLines / mismatchDomains", () => {
  assert.equal(mismatchLines(LOGS).length, 2);
  assert.equal(mismatchLines("all good\n").length, 0);
  assert.equal(mismatchLines(Array(30).fill(JSON_LOG).join("\n")).length, 10);
  const doms = mismatchDomains(LOGS);
  assert.ok(doms.includes("filebrowser.app") && doms.includes("photoprism.app"), doms.join());
  assert.ok(!doms.some((x) => x.startsWith("tls.")));
});

t("lastStartupError for a named domain and overall", () => {
  assert.match(lastStartupError(LOGS, "filebrowser.app"), /^error \| tls \| unable to get certificate \| caching certificate: tls: private key does not match public key$/);
  assert.match(lastStartupError(LOGS, "PHOTOPRISM.app"), /^Error: loading initial config/);
  assert.equal(lastStartupError(LOGS, "nosuch.app"), null);
  assert.match(lastStartupError(LOGS), /other failure/);
  assert.equal(lastStartupError('{"level":"info","msg":"ok"}\n'), null);
});

t("parseState", () => {
  assert.deepEqual(parseState("running|false|0|2026-10-15T12:00:01.5Z\n"), { status: "running", restarting: false, restartCount: 0, startedAt: "2026-10-15T12:00:01.5Z" });
  assert.equal(parseState("restarting|true|42|x").restarting, true);
  assert.equal(parseState("Error: no such container"), null);
});

t("formatReport: live run lists moves, restart, remaining lines and errors", () => {
  const scan = parseScanOutput("OK mesh/a.app\nBAD mesh/filebrowser.app\nMOVED mesh/filebrowser.app /d/caddy/bad-cert-filebrowser.app-X\nSKIP mesh/z no .key\nDONE\n");
  const rep = formatReport({
    vm: "gcp-proxy", container: "caddy", dataDir: "/d", dryRun: false, allMesh: false, scan,
    restarted: "restarted, waited 15s", state: parseState("running|false|0|t"), remaining: mismatchLines(LOGS),
    startupErrors: [{ domain: "filebrowser.app", error: lastStartupError(LOGS, "filebrowser.app") }], lastError: lastStartupError(LOGS),
  });
  for (const re of [/LIVE/, /1 mismatched/, /moved mesh\/filebrowser\.app -> \/d\/caddy\/bad-cert-/, /skipped mesh\/z/, /restart: restarted/, /container: running/, /remaining .* \(2\)/, /last log error for filebrowser\.app: error \| tls/, /last startup error:/])
    assert.match(rep, re);
  assert.doesNotMatch(rep, /nothing to repair/);
  assert.equal(certDomain("mesh/filebrowser.app"), "filebrowser.app");
});

rmSync(tmp, { recursive: true, force: true });
console.log(`${n} passed`);
