// node --test kg-ingest.test.mjs — drives the real kg-ingest.mjs against a fake SurrealDB
// /sql endpoint that drops connections, as the private surface did mid edge-ingest (#888).
import test from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { spawn } from "node:child_process";
import { writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), "kg-ingest.mjs");
const N_EDGES = 25;

function delta() {
  const nodes = [0, 1, 2, 3].map((i) => ({ table: "file", id: `f${i}`, key: `k${i}`, properties: { repo: "r" } }));
  const edges = Array.from({ length: N_EDGES }, (_, i) => ({ from: `k${i % 4}`, to: `k${(i + 1) % 4}`, table: "imports", properties: {} }));
  return { nodes, edges };
}

// `plan(n, body)` returns "ok" | "drop-before" (socket killed, nothing applied) |
// "drop-after" (applied, reply lost) for the n-th request carrying an INSERT RELATION.
async function run(plan, extraEnv = {}, stored = 0) {
  const edgeIds = new Map(), stmts = [];
  let edgeReq = 0;
  const srv = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      stmts.push(body.split("\n")[0].slice(0, 40));
      const ins = body.startsWith("INSERT RELATION");
      const mode = ins ? plan(++edgeReq, body) : "ok";
      if (body.startsWith("SELECT count()")) { res.setHeader("Content-Type", "application/json"); return res.end(JSON.stringify([{ status: "OK", result: stored ? [{ count: stored }] : [] }])); }
      if (mode === "drop-before") return req.socket.destroy();
      if (ins) for (const m of body.matchAll(/\{id:"([0-9a-f]+)"/g)) edgeIds.set(m[1], (edgeIds.get(m[1]) || 0) + 1);
      if (mode === "drop-after") return req.socket.destroy();
      res.setHeader("Content-Type", "application/json");
      res.end("[]");
    });
  });
  await new Promise((r) => srv.listen(0, "127.0.0.1", r));
  const dir = mkdtempSync(join(tmpdir(), "kgi-"));
  writeFileSync(join(dir, "d.json"), JSON.stringify(delta()));
  const env = {
    ...process.env, KG_STORE_URL: `http://127.0.0.1:${srv.address().port}`, KG_STORE_PASS: "x",
    KG_DELTA: join(dir, "d.json"), KG_INGEST_BATCH: "5", KG_INGEST_BACKOFF_MS: "5", KG_INGEST_RETRIES: "4", ...extraEnv,
  };
  const out = await new Promise((resolve) => {
    const p = spawn(process.execPath, [SCRIPT], { env });
    let err = ""; p.stderr.on("data", (c) => (err += c));
    p.on("close", (code) => resolve({ code, err }));
  });
  srv.close(); rmSync(dir, { recursive: true });
  return { ...out, edgeIds, stmts };
}

test("a dropped connection mid edge-ingest is retried and every edge lands exactly once", async () => {
  // batch 2 loses its connection before applying, batch 4 after applying (reply lost)
  const r = await run((n) => (n === 2 ? "drop-before" : n === 4 ? "drop-after" : "ok"));
  assert.equal(r.code, 0, r.err);
  assert.equal(r.edgeIds.size, N_EDGES);
  assert.ok([...r.edgeIds.values()].every((c) => c >= 1));
  assert.match(r.err, /transport error/);
});

test("a server that stays down aborts loudly (non-zero) and says how to resume", async () => {
  const r = await run((n) => (n >= 2 ? "drop-before" : "ok"));
  assert.equal(r.code, 1);
  assert.match(r.err, /lost the connection after 5\/25 edges/);
  assert.match(r.err, /KG_INGEST_RESUME=1/);
});

test("KG_INGEST_RESUME=1 skips the repo-scoped delete", async () => {
  const r = await run(() => "ok", { KG_INGEST_RESUME: "1" });
  assert.equal(r.code, 0, r.err);
  assert.ok(!r.stmts.some((s) => s.startsWith("DELETE")));
  const d = await run(() => "ok");
  assert.ok(d.stmts.some((s) => s.startsWith("DELETE")));
});

test("shrink guard: a delta far smaller than the stored repo writes nothing", async () => {
  const r = await run(() => "ok", {}, 3155);
  assert.equal(r.code, 1, r.err);
  assert.match(r.err, /shrink guard/);
  assert.ok(!r.stmts.some((x) => x.startsWith("DELETE") || x.startsWith("UPSERT")), r.stmts.join("|"));
});

test("shrink guard: KG_INGEST_ALLOW_SHRINK=1 lets a real shrink through", async () => {
  const r = await run(() => "ok", { KG_INGEST_ALLOW_SHRINK: "1" }, 3155);
  assert.equal(r.code, 0, r.err);
  assert.ok(r.stmts.some((x) => x.startsWith("DELETE")));
});

test("shrink guard: a comparable delta replaces normally", async () => {
  const r = await run(() => "ok", {}, 6);
  assert.equal(r.code, 0, r.err);
});

// The repo-scoped delete must never be one unbounded statement: a single
// `DELETE FROM imports WHERE in.repo = ...` over cloud-u-containers' ~461k edges ran
// kg-store-pub (SurrealDB, 1G memcg) out of memory on 2026-10-10 (#888). Nodes go in LIMITed
// batches; edges (#1061) are reached from the repo's own nodes through the graph index, one
// NODE_PAGE of nodes per request, never by scanning the edge table with in.repo/out.repo.
// The fake store holds 12 nodes and answers each node page with the edges it "removed".
test("the repo-scoped delete runs in bounded batches until the scope is empty", async () => {
  const left = new Map([["file", 12]]), deletes = [], pages = [];
  const srv = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      res.setHeader("Content-Type", "application/json");
      if (body.startsWith("LET $n")) {
        pages.push(body);
        const start = Number(body.match(/START (\d+)/)[1]), lim = Number(body.match(/LIMIT (\d+)/)[1]);
        const n = Math.max(0, Math.min(lim, 12 - start));
        return res.end(JSON.stringify([{ status: "OK", result: null }, { status: "OK", result: null },
          { status: "OK", result: Array.from({ length: n }, (_, i) => `imports:${start + i}`) }, { status: "OK", result: n }]));
      }
      if (body.startsWith("DELETE")) {
        deletes.push(body);
        const lim = body.match(/LIMIT (\d+)/), t = body.match(/FROM (\w+) WHERE/)?.[1];
        const n = Math.min(left.get(t) ?? 0, lim ? Number(lim[1]) : Infinity);
        left.set(t, (left.get(t) ?? 0) - n);
        return res.end(JSON.stringify([{ status: "OK", result: Array.from({ length: n }, (_, i) => `${t}:${i}`) }]));
      }
      res.end("[]");
    });
  });
  await new Promise((r) => srv.listen(0, "127.0.0.1", r));
  const dir = mkdtempSync(join(tmpdir(), "kgi-"));
  writeFileSync(join(dir, "d.json"), JSON.stringify(delta()));
  const env = { ...process.env, KG_STORE_URL: `http://127.0.0.1:${srv.address().port}`, KG_STORE_PASS: "x",
    KG_DELTA: join(dir, "d.json"), KG_INGEST_DELETE_BATCH: "5", KG_INGEST_NODE_PAGE: "5", KG_INGEST_BACKOFF_MS: "5" };
  const out = await new Promise((resolve) => {
    const p = spawn(process.execPath, [SCRIPT], { env });
    let err = ""; p.stderr.on("data", (c) => (err += c));
    p.on("close", (code) => resolve({ code, err }));
  });
  srv.close(); rmSync(dir, { recursive: true });
  assert.equal(out.code, 0, out.err);
  assert.ok(deletes.every((b) => /LIMIT 5\b/.test(b)), `unbounded delete: ${deletes.find((b) => !/LIMIT 5\b/.test(b))}`);
  assert.equal(left.get("file"), 0);
  assert.equal(deletes.length, 4, "3 node batches + 1 empty probe");
  assert.deepEqual(pages.map((b) => Number(b.match(/START (\d+)/)[1])), [0, 5, 10], "node pages 0,5,10; the short third page ends the walk");
  assert.ok(pages.every((b) => b.includes("->imports, <-imports") && /LIMIT 5\b/.test(b)), "edges are reached through the graph, one bounded page of nodes at a time");
  assert.ok(![...pages, ...deletes].some((b) => /\bin\.repo\b|\bout\.repo\b/.test(b)), "no edge-table scan by in.repo/out.repo");
});

// #1061: the repo-scoped DELETE scans a whole edge table even when it matches nothing, so it
// can legitimately outlast the 120s request timeout. At the shared timeout the client aborted
// mid-scan, the server dropped the transaction and the delete never finished. The fake store
// answers every DELETE only after a pause longer than the shared timeout: the ingest must
// still complete on the delete's own budget, and with the retries it is allowed (2) a
// delete that never answers must abort loudly rather than be re-queued 8 times.
test("the repo-scoped delete has its own, longer timeout and fewer retries", async () => {
  let deletes = 0;
  const srv = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      res.setHeader("Content-Type", "application/json");
      if (body.startsWith("DELETE") || body.startsWith("LET $n")) {
        deletes++;
        return setTimeout(() => res.end(JSON.stringify([{ status: "OK", result: [] }])), 400);
      }
      res.end("[]");
    });
  });
  await new Promise((r) => srv.listen(0, "127.0.0.1", r));
  const dir = mkdtempSync(join(tmpdir(), "kgi-"));
  writeFileSync(join(dir, "d.json"), JSON.stringify(delta()));
  const base = { ...process.env, KG_STORE_URL: `http://127.0.0.1:${srv.address().port}`, KG_STORE_PASS: "x",
    KG_DELTA: join(dir, "d.json"), KG_INGEST_BACKOFF_MS: "5", KG_INGEST_TIMEOUT_MS: "150" };
  const go = (extra) => new Promise((resolve) => {
    const p = spawn(process.execPath, [SCRIPT], { env: { ...base, ...extra } });
    let err = ""; p.stderr.on("data", (c) => (err += c));
    p.on("close", (code) => resolve({ code, err }));
  });
  const ok = await go({ KG_INGEST_DELETE_TIMEOUT_MS: "5000" });
  assert.equal(ok.code, 0, ok.err);
  assert.doesNotMatch(ok.err, /transport error/, "a slow delete inside its own budget must not be retried");
  deletes = 0;
  const bad = await go({ KG_INGEST_DELETE_TIMEOUT_MS: "100" });
  srv.close(); rmSync(dir, { recursive: true });
  assert.notEqual(bad.code, 0, "a delete that outlasts its budget must abort");
  assert.match(bad.err, /retry 2\/2/);
  assert.doesNotMatch(bad.err, /retry 3\/2|retry 3\/8/);
  assert.match(bad.err, /repo-scoped edge delete failed after 0 edges of \[r\]/);
});
