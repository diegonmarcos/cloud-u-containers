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

const stmts = [];
for (const n of nodes) {
  if (!n?.table || n?.id == null) continue;
  stmts.push(`UPSERT ${thing(n.table, n.id)} CONTENT ${JSON.stringify(n.properties ?? {})} RETURN NONE;`);
}
let edgeOk = 0;
for (const e of edges) {
  const a = byKey.get(e.from), b = byKey.get(e.to);
  if (!a || !b || !e.table) continue;
  stmts.push(`RELATE (${thing(a.table, a.id)})->${e.table}->(${thing(b.table, b.id)}) RETURN NONE;`);
  edgeOk++;
}
console.error(`[kg-ingest] ${nodes.length} nodes + ${edgeOk}/${edges.length} edges → ${URL_} (ns=${NS} db=${DB})`);

const auth = "Basic " + Buffer.from(`${USER}:${PASS}`).toString("base64");
const sql = async (body) => {
  const r = await fetch(`${URL_.replace(/\/$/, "")}/sql`, {
    method: "POST",
    headers: { Authorization: auth, "surreal-ns": NS, "surreal-db": DB, Accept: "application/json", "Content-Type": "text/plain" },
    body,
  });
  if (!r.ok) throw new Error(`HTTP ${r.status}: ${(await r.text()).slice(0, 300)}`);
};

let done = 0;
for (let i = 0; i < stmts.length; i += BATCH) {
  await sql(stmts.slice(i, i + BATCH).join("\n"));
  done += Math.min(BATCH, stmts.length - i);
  process.stderr.write(`\r[kg-ingest] ${done}/${stmts.length} statements`);
}
console.error(`\n[kg-ingest] DONE — ${nodes.length} nodes, ${edgeOk} edges ingested into kg-store`);
