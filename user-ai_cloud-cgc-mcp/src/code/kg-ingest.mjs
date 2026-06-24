#!/usr/bin/env node
// kg-ingest — load the infra knowledge-graph delta ({nodes[],edges[]}) into the
// kg-store SurrealDB as idempotent SurrealQL (UPSERT nodes + RELATE edges, batched).
// Called by reindex.sh after octocode builds the code graph, so the one-shot job
// (re)builds BOTH graphs. Fully env-gated/data-driven — no-ops if kg-store is not
// configured. Uses only Node built-ins.
import { readFileSync, existsSync } from "node:fs";

const URL_  = process.env.KG_STORE_URL;                       // http://127.0.0.1:8001
const NS    = process.env.KG_STORE_NS  || "infra";
const DB    = process.env.KG_STORE_DB  || "production";
const USER  = process.env.KG_STORE_USER || "root";
const PASS  = process.env.KG_STORE_PASS;
const DELTA = process.env.KG_DELTA || "/app/graphs/build-kg-graph_delta.json";
const BATCH = parseInt(process.env.KG_INGEST_BATCH || "500", 10);

const skip = (m) => { console.error(`[kg-ingest] skip — ${m}`); process.exit(0); };
if (!URL_)  skip("KG_STORE_URL unset");
if (!PASS)  skip("KG_STORE_PASS unset");
if (!existsSync(DELTA)) skip(`delta not found: ${DELTA}`);

const d = JSON.parse(readFileSync(DELTA, "utf8"));
const nodes = d.nodes ?? [], edges = d.edges ?? [];
const byKey = new Map(nodes.map((n) => [n.key, n]));
const q = (s) => JSON.stringify(String(s));            // safe SurrealQL string literal
const thing = (t, id) => `type::thing(${q(t)}, ${q(id)})`;

// Nodes → UPSERT (batched, distinct record ids never conflict).
const nodeStmts = [];
for (const n of nodes) {
  if (!n?.table || n?.id == null) continue;
  nodeStmts.push(`UPSERT ${thing(n.table, n.id)} CONTENT ${JSON.stringify(n.properties ?? {})} RETURN NONE;`);
}
// Edges → RELATE, sent ONE PER REQUEST (see flush note below): multiple RELATEs in
// a single /sql request silently consolidate edges that share a vertex inside one
// transaction (proven: unbatched 8000→8000; batched 90134→35978, 0 errors).
let edgeOk = 0;
const edgeStmts = [];
for (const e of edges) {
  const a = byKey.get(e.from), b = byKey.get(e.to);
  if (!a || !b || !e.table) continue;
  edgeStmts.push(`RELATE (${thing(a.table, a.id)})->${e.table}->(${thing(b.table, b.id)}) RETURN NONE;`);
  edgeOk++;
}
console.error(`[kg-ingest] ${nodes.length} nodes + ${edgeOk}/${edges.length} edges → ${URL_} (ns=${NS} db=${DB})`);

const auth = "Basic " + Buffer.from(`${USER}:${PASS}`).toString("base64");
// Returns {errs, firstErr}. SurrealDB's /sql returns HTTP 200 even when individual
// statements fail — the body is an array of {status:"OK"|"ERR", result|detail}.
// Checking only r.ok silently drops failed UPSERT/RELATE (the cause of missing
// edges). Parse per-statement status and surface the first error.
const sql = async (body) => {
  const r = await fetch(`${URL_.replace(/\/$/, "")}/sql`, {
    method: "POST",
    headers: { Authorization: auth, "surreal-ns": NS, "surreal-db": DB, Accept: "application/json", "Content-Type": "text/plain" },
    body,
  });
  if (!r.ok) throw new Error(`HTTP ${r.status}: ${(await r.text()).slice(0, 300)}`);
  const out = await r.json();
  let errs = 0, firstErr = null;
  if (Array.isArray(out)) for (const x of out) {
    if (x && x.status && x.status !== "OK") {
      errs++;
      if (!firstErr) firstErr = String(x.result ?? x.detail ?? JSON.stringify(x)).slice(0, 240);
    }
  }
  return { errs, firstErr };
};

// ── Nodes: UPSERT batched by statement count AND request byte size. SurrealDB's
// /sql rejects oversized bodies (HTTP 413); node CONTENT (imports/exports/symbols
// arrays) can be large, so cap bytes too. Distinct record ids never conflict, so
// batching nodes is safe + fast.
const MAX_BYTES = parseInt(process.env.KG_INGEST_MAX_BYTES || "200000", 10);
let nDone = 0, buf = [], bytes = 0, nodeErrs = 0, firstErr = null;
const flush = async () => {
  if (!buf.length) return;
  const { errs, firstErr: fe } = await sql(buf.join("\n"));
  nodeErrs += errs; if (fe && !firstErr) firstErr = fe;
  nDone += buf.length; buf = []; bytes = 0;
  process.stderr.write(`\r[kg-ingest] nodes ${nDone}/${nodeStmts.length}`);
};
for (const s of nodeStmts) {
  if (buf.length && bytes + s.length + 1 > MAX_BYTES) await flush();
  buf.push(s); bytes += s.length + 1;
  if (buf.length >= BATCH) await flush();
}
await flush();

// ── Edges: ONE RELATE per request, concurrency-limited. Multiple RELATEs in one
// /sql request silently consolidate edges sharing a vertex within the transaction
// (proven: unbatched 8000→8000; a single batched request 90134→35978, 0 errors).
// Each RELATE in its own request = its own transaction = no consolidation. Conflicts
// Concurrency MUST default to 1: SurrealDB consolidates RELATEs that touch a shared
// vertex when they run in the same transaction OR concurrently (proven: seq climbs
// 1:1 / preserves all; batched-single AND concurrent-10 both deterministically
// collapse 90134→~36k with 0 errors). Override via KG_INGEST_CONCURRENCY only if a
// lower edge fidelity is acceptable for speed. Slower but correct (full mirror).
const CONC = parseInt(process.env.KG_INGEST_CONCURRENCY || "1", 10);
let ei = 0, eDone = 0, edgeErrs = 0;
const worker = async () => {
  while (ei < edgeStmts.length) {
    const s = edgeStmts[ei++];
    let r = await sql(s).catch(() => ({ errs: 1, firstErr: "request failed" }));
    if (r.errs) r = await sql(s).catch(() => ({ errs: 1 }));   // one retry on conflict
    if (r.errs) { edgeErrs++; if (r.firstErr && !firstErr) firstErr = r.firstErr; }
    if (++eDone % 2000 === 0) process.stderr.write(`\r[kg-ingest] edges ${eDone}/${edgeStmts.length} (${edgeErrs} failed)`);
  }
};
await Promise.all(Array.from({ length: CONC }, () => worker()));

const totalErrs = nodeErrs + edgeErrs;
if (totalErrs) console.error(`\n[kg-ingest] ⚠ ${totalErrs} statements FAILED (${nodeErrs} node, ${edgeErrs} edge) — first: ${firstErr}`);
console.error(`\n[kg-ingest] DONE — ${nodeStmts.length} nodes + ${edgeOk} edges → kg-store (${totalErrs} failed)`);
