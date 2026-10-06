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
async function run(plan, extraEnv = {}) {
  const edgeIds = new Map(), stmts = [];
  let edgeReq = 0;
  const srv = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      stmts.push(body.split("\n")[0].slice(0, 40));
      const ins = body.startsWith("INSERT RELATION");
      const mode = ins ? plan(++edgeReq, body) : "ok";
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
  assert.ok(!r.stmts.some((s) => s.startsWith("DELETE FROM")));
  const d = await run(() => "ok");
  assert.ok(d.stmts.some((s) => s.startsWith("DELETE FROM")));
});
