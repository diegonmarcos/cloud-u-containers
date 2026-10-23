// Tests the REAL script + parsers behind devops.caddy.cert_repair. The script
// is run locally under bash against a temp /data tree holding real openssl
// keypairs, so "key matches cert" is decided by openssl, not by a mock.
// Incident 2026-10-15: caddy on gcp-proxy crash-looped on "tls: private key
// does not match public key" for mesh-CA certs. The scan is ASYNC (detached on the host,
// result file), so the tests really start it, wait for the result file, and call again.
// Run: node --experimental-strip-types test-caddy-cert-repair.mjs
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, existsSync, readdirSync, rmSync, statSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  buildRepairScript, buildScanScript, parseScanOutput, parseResult, parseDataMount, tsStamp, mismatchLines, mismatchDomains,
  lastStartupError, parseState, formatReport, certDomain, CONTAINER_RE, CERT_RE,
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
const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
const fresh = (label) => { const d = join(tmp, label); mkdirSync(join(d, "caddy/certificates"), { recursive: true }); mkdirSync(join(d, "state")); return d; };
const J = (d) => join(d, "state/caddy-cert-scan.json");
const ctl = (data, o = {}) => {
  const r = spawnSync("bash", ["-s"], { input: buildRepairScript({ dataDir: data, allMesh: false, dryRun: true, ts: TS, stateDir: join(data, "state"), ...o }), encoding: "utf8", env: o.env ? { ...process.env, ...o.env } : process.env });
  return { ...r, p: parseScanOutput(r.stdout) };
};
/** Wait until a scan started after now has published its result and released the lock. */
const waitScan = (d) => {
  for (let i = 0; i < 400; i++) {
    if (existsSync(J(d)) && Date.now() - statSync(J(d)).mtimeMs < 60_000 && !existsSync(join(d, "state/caddy-cert-scan.lock"))) return;
    sleep(100);
  }
  assert.fail("scan did not finish");
};
const backdate = (d) => sh(`touch -d '2 hours ago' '${J(d)}'`, d);
/** Start a scan (asserts the async contract), wait for it, return the fresh dry-run result. */
const scanNow = (d, o = {}) => {
  const first = ctl(d, { ...o, dryRun: true });
  assert.equal(first.p.status, "running"); assert.ok(first.p.started, first.stdout);
  waitScan(d);
  return ctl(d, { ...o, dryRun: true });
};
const rpt = (d, p, o = {}) => formatReport({ vm: "gcp-proxy", container: "caddy", dataDir: d, dryRun: true, allMesh: false, scan: p, restarted: null, state: null, remaining: [], startupErrors: [], lastError: null, ...o });

t("first call returns at once with 'scan started' (status running); next call returns the result", () => {
  const d = fresh("healthy");
  mk(d, "mesh", "filebrowser.mesh.diegonmarcos.com"); mk(d, "acme-v02.api.letsencrypt.org-directory", "example.com");
  const first = ctl(d);
  assert.equal(first.status, 0, first.stderr);
  assert.equal(first.p.status, "running"); assert.ok(first.p.started); assert.equal(first.p.result, null);
  assert.match(rpt(d, first.p), /^status: running$/m); assert.match(rpt(d, first.p), /scan started/);
  waitScan(d);
  const r = ctl(d);
  assert.equal(r.p.status, "complete"); assert.ok(!r.p.started);
  assert.ok(r.p.age >= 0 && r.p.age < 60);
  assert.equal(r.p.result.ok, 2); assert.deepEqual(r.p.result.bad, []); assert.equal(r.p.result.checked, 2); assert.equal(r.p.result.incremental, false);
  assert.match(rpt(d, r.p), /^status: complete$/m); assert.match(rpt(d, r.p), /nothing to repair/);
  assert.equal(readFileSync(join(d, "state/caddy-cert-scan.bad"), "utf8"), "");
});

t("dry run flags only the mismatched dir and moves nothing", () => {
  const d = fresh("dry");
  mk(d, "mesh", "good.mesh.diegonmarcos.com"); mk(d, "mesh", "filebrowser.mesh.diegonmarcos.com", { mismatch: true });
  const r = scanNow(d);
  assert.deepEqual(r.p.result.bad, ["mesh/filebrowser.mesh.diegonmarcos.com"]);
  assert.deepEqual(r.p.moved, []);
  assert.ok(existsSync(join(d, "caddy/certificates/mesh/filebrowser.mesh.diegonmarcos.com")));
  assert.doesNotMatch(r.stdout, /PRIVATE KEY|BEGIN /);
  const rep = rpt(d, r.p);
  assert.doesNotMatch(rep, /nothing to repair/); assert.match(rep, /MISMATCH mesh\/filebrowser\.mesh\.diegonmarcos\.com \(would move\)/); assert.match(rep, /1 mismatched/);
});

t("live run acts on the fresh result: moves only mismatched dirs, restarts, clears the result", () => {
  const d = fresh("live");
  mk(d, "mesh", "good.mesh.diegonmarcos.com"); mk(d, "mesh", "photoprism.mesh.diegonmarcos.com", { mismatch: true }); mk(d, "other", "c3-services-mcp.mesh.diegonmarcos.com", { mismatch: true });
  scanNow(d);
  const live = ctl(d, { dryRun: false });
  assert.equal(live.p.status, "complete");
  assert.deepEqual(live.p.moved.map((m) => m.cert).sort(), ["mesh/photoprism.mesh.diegonmarcos.com", "other/c3-services-mcp.mesh.diegonmarcos.com"]);
  assert.ok(existsSync(join(d, `caddy/bad-cert-photoprism.mesh.diegonmarcos.com-${TS}/photoprism.mesh.diegonmarcos.com.key`)), "files preserved, not deleted");
  assert.ok(existsSync(join(d, `caddy/bad-cert-c3-services-mcp.mesh.diegonmarcos.com-${TS}`)));
  assert.ok(!existsSync(join(d, "caddy/certificates/mesh/photoprism.mesh.diegonmarcos.com")));
  assert.ok(existsSync(join(d, "caddy/certificates/mesh/good.mesh.diegonmarcos.com")), "matching cert untouched");
  assert.ok(!existsSync(J(d)), "acted-on result is consumed");
  const again = scanNow(d);
  assert.deepEqual(again.p.result.bad, [], "second pass is clean");
  assert.match(rpt(d, live.p, { dryRun: false }), /moved mesh\/photoprism\.mesh\.diegonmarcos\.com -> /);
});

t("live run never acts without a fresh result: first call only starts the scan", () => {
  const d = fresh("livefirst");
  mk(d, "mesh", "bad.mesh.diegonmarcos.com", { mismatch: true });
  const r = ctl(d, { dryRun: false });
  assert.equal(r.p.status, "running"); assert.deepEqual(r.p.moved, []); assert.ok(!r.p.restarting);
  waitScan(d);
  assert.ok(existsSync(join(d, "caddy/certificates/mesh/bad.mesh.diegonmarcos.com")));
});

t("live run re-probes: a cert that was re-issued correctly since the scan is left in place", () => {
  const d = fresh("reissued");
  mk(d, "mesh", "x.mesh.diegonmarcos.com", { mismatch: true });
  scanNow(d);
  mk(d, "mesh", "x.mesh.diegonmarcos.com"); // caddy re-issued a good pair
  const live = ctl(d, { dryRun: false });
  assert.deepEqual(live.p.moved, []); assert.equal(live.p.leftInPlace.length, 1);
  assert.ok(existsSync(join(d, "caddy/certificates/mesh/x.mesh.diegonmarcos.com")));
});

t("stale result (> max age) is never used: a new scan starts and the old age is reported", () => {
  const d = fresh("stale");
  mk(d, "mesh", "a.mesh.diegonmarcos.com");
  scanNow(d);
  backdate(d);
  const r = ctl(d, { dryRun: false });
  assert.equal(r.p.status, "running"); assert.ok(r.p.started); assert.ok(r.p.prevAge > 3600); assert.equal(r.p.result, null);
  assert.match(rpt(d, r.p), /stale, not used/);
  waitScan(d);
});

t("lock: a live scan is reported as running and a second scan is not started", () => {
  const d = fresh("lock");
  mk(d, "mesh", "a.mesh.diegonmarcos.com");
  const holder = spawn("bash", ["-c", "sleep 30; :", "caddy-cert-scan"], { stdio: "ignore" });
  try {
    mkdirSync(join(d, "state/caddy-cert-scan.lock")); writeFileSync(join(d, "state/caddy-cert-scan.lock/pid"), String(holder.pid));
    const r = ctl(d);
    assert.equal(r.p.status, "running"); assert.ok(!r.p.started); assert.ok(r.p.startedAgo >= 0);
    assert.match(rpt(d, r.p), /scan still running/);
    const direct = spawnSync("bash", ["-s", d], { input: buildScanScript({ stateDir: join(d, "state") }), encoding: "utf8" });
    assert.equal(direct.status, 0); assert.ok(!existsSync(J(d)), "second scan backs off");
  } finally { holder.kill(); }
  // dead pid => stale lock is taken over
  writeFileSync(join(d, "state/caddy-cert-scan.lock/pid"), "999999");
  const r2 = ctl(d); assert.ok(r2.p.started); waitScan(d);
});

t("incremental: dirs unchanged since the last good scan are not re-probed, bad stay bad", () => {
  const d = fresh("incr");
  mk(d, "mesh", "a.mesh.diegonmarcos.com"); mk(d, "mesh", "b.mesh.diegonmarcos.com", { mismatch: true }); mk(d, "mesh", "c.mesh.diegonmarcos.com");
  const full = scanNow(d);
  assert.equal(full.p.result.checked, 3); assert.equal(full.p.result.incremental, false);
  backdate(d);
  const inc = scanNow(d, { maxAgeSec: 60 });
  assert.equal(inc.p.result.incremental, true); assert.equal(inc.p.result.checked, 0); assert.equal(inc.p.result.unchanged, 3);
  assert.deepEqual(inc.p.result.bad, ["mesh/b.mesh.diegonmarcos.com"], "unchanged bad cert is still reported");
  assert.equal(inc.p.result.ok, 2);
  sleep(50); mk(d, "mesh", "c.mesh.diegonmarcos.com", { mismatch: true }); // modified since the last good scan
  backdate(d);
  const inc2 = scanNow(d, { maxAgeSec: 60 });
  assert.equal(inc2.p.result.checked, 1); assert.equal(inc2.p.result.unchanged, 2);
  assert.deepEqual(inc2.p.result.bad.sort(), ["mesh/b.mesh.diegonmarcos.com", "mesh/c.mesh.diegonmarcos.com"]);
  assert.match(rpt(d, inc2.p), /incremental: 2 unchanged/);
});

t("all_mesh dry run reports, live run moves the whole mesh dir at once (no scan); other issuers stay", () => {
  const d = fresh("mesh");
  mk(d, "mesh", "a.mesh.diegonmarcos.com"); mk(d, "mesh", "b.mesh.diegonmarcos.com", { mismatch: true }); mk(d, "le", "keep.com");
  const dry = ctl(d, { allMesh: true });
  assert.equal(dry.p.mesh, 2); assert.equal(dry.p.status, "complete");
  assert.ok(existsSync(join(d, "caddy/certificates/mesh")) && !existsSync(J(d)));
  const live = ctl(d, { allMesh: true, dryRun: false });
  assert.ok(live.p.meshMoved);
  assert.ok(!existsSync(join(d, "caddy/certificates/mesh")));
  assert.ok(existsSync(join(d, `caddy/bad-cert-mesh-${TS}/b.mesh.diegonmarcos.com/b.mesh.diegonmarcos.com.key`)));
  assert.deepEqual(readdirSync(join(d, "caddy/certificates")), ["le"]);
  assert.match(rpt(d, live.p, { dryRun: false, allMesh: true }), /mesh dir: 2 entries -> moved to /);
});

t("incomplete / unreadable dirs are skipped, never moved", () => {
  const d = fresh("skip");
  mkdirSync(join(d, "caddy/certificates/mesh/nokey.mesh.diegonmarcos.com"), { recursive: true });
  sh(`touch caddy/certificates/mesh/nokey.mesh.diegonmarcos.com/nokey.mesh.diegonmarcos.com.crt`, d);
  mkdirSync(join(d, "caddy/certificates/mesh/junk.mesh.diegonmarcos.com"), { recursive: true });
  sh(`echo x > caddy/certificates/mesh/junk.mesh.diegonmarcos.com/junk.mesh.diegonmarcos.com.crt; echo y > caddy/certificates/mesh/junk.mesh.diegonmarcos.com/junk.mesh.diegonmarcos.com.key`, d);
  scanNow(d);
  const r = ctl(d, { dryRun: false });
  assert.deepEqual(r.p.result.skip.map((x) => x.cert).sort(), ["mesh/junk.mesh.diegonmarcos.com", "mesh/nokey.mesh.diegonmarcos.com"]);
  assert.deepEqual(r.p.moved, []);
  assert.ok(existsSync(join(d, "caddy/certificates/mesh/junk.mesh.diegonmarcos.com")) && existsSync(join(d, "caddy/certificates/mesh/nokey.mesh.diegonmarcos.com")));
});

t("odd directory names are never probed or emitted", () => {
  const d = fresh("odd");
  mk(d, "mesh", "ok.mesh.diegonmarcos.com"); mkdirSync(join(d, "caddy/certificates/mesh/-weird name"), { recursive: true });
  const r = scanNow(d);
  assert.equal(r.p.result.ok, 1); assert.deepEqual(r.p.result.bad, []);
  assert.ok(r.p.result.skip.every((x) => CERT_RE.test(x.cert)));
});

t("scan that cannot start reports status stale; missing certificates dir is an ERR", () => {
  const d = fresh("nostart"); mk(d, "mesh", "a.mesh.diegonmarcos.com");
  mkdirSync(join(d, "state/caddy-cert-scan.sh")); // writing the script fails
  const r = ctl(d);
  assert.equal(r.p.status, "stale"); assert.ok(r.p.errs.length);
  assert.match(rpt(d, r.p), /^status: stale$/m);
  const e = join(tmp, "empty"); mkdirSync(e);
  const x = ctl(e, { stateDir: e });
  assert.equal(x.p.status, "stale"); assert.ok(x.p.errs.some((m) => /no certificates dir/.test(m)));
});

t("container mode resolves the mount; fresh dry run shows state+logs, live restarts async", () => {
  const d = fresh("ctr"); mk(d, "mesh", "a.mesh.diegonmarcos.com", { mismatch: true });
  const bin = join(tmp, "bin"); mkdirSync(bin, { recursive: true });
  sh(`printf '#!/bin/bash\\ncase "$1" in inspect) case "$*" in *Mounts*) echo ${d};; *) echo "running|false|0|t";; esac;; logs) echo "serving";; restart) echo "$*" >> ${join(tmp, "calls")};; esac\\n' > docker; chmod +x docker`, bin);
  const go = (dryRun) => {
    const r = spawnSync("bash", ["-s"], { input: buildRepairScript({ container: "caddy", allMesh: false, dryRun, ts: TS, stateDir: join(d, "state") }), encoding: "utf8", env: { ...process.env, PATH: `${bin}:${process.env.PATH}` } });
    return { ...r, p: parseScanOutput(r.stdout.split("===LOGS===\n")[0]) };
  };
  const first = go(true);
  assert.equal(first.p.data, d); assert.ok(first.p.started); assert.doesNotMatch(first.stdout, /===LOGS===/, "no logs while only starting the scan");
  waitScan(d);
  const dry = go(true);
  assert.match(dry.stdout, new RegExp(`^DATA ${d}$`, "m")); assert.match(dry.stdout, /^STATE running\|false\|0\|t$/m); assert.match(dry.stdout, /===LOGS===\nserving/);
  const live = go(false);
  assert.match(live.stdout, /^MOVED mesh\/a\.mesh\.diegonmarcos\.com /m); assert.match(live.stdout, /^RESTARTING$/m); assert.doesNotMatch(live.stdout, /===LOGS===/);
});

t("script inputs are validated (no injection through data dir, state dir, container or ts)", () => {
  for (const dataDir of ["/data; rm -rf /", "relative", "/a/../etc", "/a b", "/a'b", "", "/a$(id)"])
    assert.throws(() => buildRepairScript({ dataDir, allMesh: false, dryRun: true, ts: TS }), /Invalid data dir/, dataDir);
  for (const stateDir of ["/v;id", "rel", "/a/../b", "/a b", "/a'b"]) {
    assert.throws(() => buildRepairScript({ dataDir: "/data", allMesh: false, dryRun: true, ts: TS, stateDir }), /Invalid state dir/, stateDir);
    assert.throws(() => buildScanScript({ stateDir }), /Invalid state dir/, stateDir);
  }
  for (const ts of ["", "x", "20261015T120000Z;id", "2026-10-15"])
    assert.throws(() => buildRepairScript({ dataDir: "/data", allMesh: false, dryRun: true, ts }), /Invalid timestamp/, ts);
  assert.throws(() => buildRepairScript({ allMesh: false, dryRun: true, ts: TS }), /Invalid data dir/);
  assert.throws(() => buildRepairScript({ container: "caddy;id", allMesh: false, dryRun: true, ts: TS }), /Invalid container/);
  assert.ok(CONTAINER_RE.test("caddy") && !CONTAINER_RE.test("caddy;id") && !CONTAINER_RE.test("-x") && !CONTAINER_RE.test(""));
});

t("parseResult / parseScanOutput never trust the host's JSON", () => {
  const r = parseResult('{"data":"/d","started":1,"finished":3,"checked":2,"ok":1,"unchanged":0,"incremental":false,"bad":["mesh/a.mesh.diegonmarcos.com","x; rm -rf /","../x/y","mesh/b.mesh.diegonmarcos.com"],"skip":[{"cert":"mesh/z","why":"no .key"},{"cert":5}],"mesh":0}');
  assert.deepEqual(r.bad, ["mesh/a.mesh.diegonmarcos.com", "mesh/b.mesh.diegonmarcos.com"]); assert.equal(r.skip.length, 1);
  assert.equal(parseResult("not json"), null); assert.equal(parseResult("[]").bad.length, 0);
  assert.equal(parseScanOutput("STATUS bogus\nRESULT {oops}\n").status, null);
  assert.equal(parseScanOutput("STATUS running\nSTARTED\n").started, true);
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

const JSON_LOG = '{"level":"error","ts":1.7e9,"logger":"tls","msg":"unable to get certificate","identifier":"filebrowser.mesh.diegonmarcos.com","error":"caching certificate: tls: private key does not match public key"}';
const LOGS = [
  '{"level":"info","ts":1.7e9,"msg":"serving initial configuration"}',
  JSON_LOG,
  "Error: loading initial config: loading new config: tls: private key does not match public key for photoprism.mesh.diegonmarcos.com",
  '{"level":"error","msg":"other failure","error":"dial tcp: lookup example.org: no such host"}',
].join("\n");

t("mismatchLines / mismatchDomains", () => {
  assert.equal(mismatchLines(LOGS).length, 2);
  assert.equal(mismatchLines("all good\n").length, 0);
  assert.equal(mismatchLines(Array(30).fill(JSON_LOG).join("\n")).length, 10);
  const doms = mismatchDomains(LOGS);
  assert.ok(doms.includes("filebrowser.mesh.diegonmarcos.com") && doms.includes("photoprism.mesh.diegonmarcos.com"), doms.join());
  assert.ok(!doms.some((x) => x.startsWith("tls.")));
});

t("lastStartupError for a named domain and overall", () => {
  assert.match(lastStartupError(LOGS, "filebrowser.mesh.diegonmarcos.com"), /^error \| tls \| unable to get certificate \| caching certificate: tls: private key does not match public key$/);
  assert.match(lastStartupError(LOGS, "PHOTOPRISM.mesh.diegonmarcos.com"), /^Error: loading initial config/);
  assert.equal(lastStartupError(LOGS, "nosuch.mesh.diegonmarcos.com"), null);
  assert.match(lastStartupError(LOGS), /other failure/);
  assert.equal(lastStartupError('{"level":"info","msg":"ok"}\n'), null);
});

t("parseState", () => {
  assert.deepEqual(parseState("running|false|0|2026-10-15T12:00:01.5Z\n"), { status: "running", restarting: false, restartCount: 0, startedAt: "2026-10-15T12:00:01.5Z" });
  assert.equal(parseState("restarting|true|42|x").restarting, true);
  assert.equal(parseState("Error: no such container"), null);
});

t("formatReport: live run lists moves, restart, remaining lines and errors", () => {
  const scan = parseScanOutput('STATUS complete\nAGE 5\nRESULT {"data":"/d","started":1,"finished":4,"checked":2,"ok":1,"unchanged":0,"incremental":false,"bad":["mesh/filebrowser.mesh.diegonmarcos.com"],"skip":[{"cert":"mesh/z","why":"no .key"}],"mesh":0}\nMOVED mesh/filebrowser.mesh.diegonmarcos.com /d/caddy/bad-cert-filebrowser.mesh.diegonmarcos.com-X\nRESTARTING\n');
  const rep = formatReport({
    vm: "gcp-proxy", container: "caddy", dataDir: "/d", dryRun: false, allMesh: false, scan,
    restarted: "restarted (async, not waited); re-run dry_run to confirm", state: parseState("running|false|0|t"), remaining: mismatchLines(LOGS),
    startupErrors: [{ domain: "filebrowser.mesh.diegonmarcos.com", error: lastStartupError(LOGS, "filebrowser.mesh.diegonmarcos.com") }], lastError: lastStartupError(LOGS),
  });
  for (const re of [/LIVE/, /^status: complete$/m, /1 mismatched/, /moved mesh\/filebrowser\.mesh\.diegonmarcos\.com -> \/d\/caddy\/bad-cert-/, /skipped mesh\/z/, /restart: restarted .*re-run dry_run/, /container: running/])
    assert.match(rep, re);
  assert.doesNotMatch(rep, /nothing to repair|remaining/);
  const dry = formatReport({ vm: "gcp-proxy", container: "caddy", dataDir: "/d", dryRun: true, allMesh: false, scan, restarted: null, state: parseState("running|false|0|t"), remaining: mismatchLines(LOGS), startupErrors: [{ domain: "filebrowser.mesh.diegonmarcos.com", error: lastStartupError(LOGS, "filebrowser.mesh.diegonmarcos.com") }], lastError: lastStartupError(LOGS) });
  for (const re of [/remaining .* \(2\)/, /last log error for filebrowser\.mesh\.diegonmarcos\.com: error \| tls/, /last startup error:/]) assert.match(dry, re);
  assert.equal(certDomain("mesh/filebrowser.mesh.diegonmarcos.com"), "filebrowser.mesh.diegonmarcos.com");
});

rmSync(tmp, { recursive: true, force: true });
console.log(`${n} passed`);
