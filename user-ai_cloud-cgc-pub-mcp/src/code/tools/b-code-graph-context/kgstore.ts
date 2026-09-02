import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

// kg-store = the SurrealDB UNIFIED knowledge graph: octocode's code graph
// (file nodes + sibling_module/relationship edges, mirrored per repo) AND the
// infra topology (vm/service/container/domain/module/repo/package + edges).
// Exposes both DBs of the CGC stack — the octocode Lance DB is reached via the
// cgc.octocode.* tools; this reaches the SurrealDB side.
const URL_  = process.env.KG_STORE_URL  ?? "http://127.0.0.1:8001";
const NS    = process.env.KG_STORE_NS   ?? "infra";
const DB    = process.env.KG_STORE_DB   ?? "production";
const USER  = process.env.KG_STORE_USER ?? "root";
const PASS  = process.env.KG_STORE_PASS ?? "";

async function surql(q: string): Promise<string> {
  if (!PASS) return "kg-store unavailable: KG_STORE_PASS not set in this container.";
  const auth = "Basic " + Buffer.from(`${USER}:${PASS}`).toString("base64");
  try {
    const r = await fetch(`${URL_.replace(/\/$/, "")}/sql`, {
      method: "POST",
      headers: { Authorization: auth, "surreal-ns": NS, "surreal-db": DB, Accept: "application/json", "Content-Type": "text/plain" },
      body: q,
    });
    const txt = await r.text();
    return r.ok ? txt : `HTTP ${r.status}: ${txt.slice(0, 500)}`;
  } catch (e) {
    return `kg-store error: ${(e as Error).message}`;
  }
}

// Read-only guard: the MCP must never mutate the graph (writes come only from the
// reindex/ingest pipeline). Allowlist the leading verb of every statement instead of
// denylisting substrings — a denylist false-positives on any SELECT whose field/table/
// string literal contains a mutating word (e.g. WHERE status='update') and is trivially
// bypassable. ponytail: the proper long-term fix is a read-only SurrealDB user; today
// only a single root credential (KG_STORE_PASS) is wired, so this guard is load-bearing.
const READ_ONLY_VERBS = new Set(["SELECT", "INFO", "RETURN"]);

function isReadOnly(q: string): boolean {
  const stripped = q
    .replace(/\/\*[\s\S]*?\*\//g, " ")
    .replace(/--.*$/gm, " ");
  const statements = stripped.split(";").map((s) => s.trim()).filter((s) => s.length > 0);
  if (statements.length === 0) return false;
  return statements.every((s) => {
    const verb = s.match(/^[A-Za-z]+/)?.[0]?.toUpperCase();
    return !!verb && READ_ONLY_VERBS.has(verb);
  });
}

const NODE_TABLES = ["file", "vm", "service", "container", "domain", "module", "repo", "package", "documentation", "log"];
const EDGE_TABLES = ["sibling_module", "hosted_on", "runs_container", "depends_on", "proxied_by", "routes_to", "belongs_to_repo", "implements", "declares_tool", "consumes", "connected_to"];

export function registerKgStoreTools(server: McpServer): void {
  server.tool(
    "cgc.kgstore.query",
    "Query the kg-store SurrealDB UNIFIED knowledge graph (read-only SurrealQL: SELECT / INFO only). " +
    "Code-graph tables: file {path,node_type,repo,name,language,size_lines,imports,exports,symbols,functions} + sibling_module edges (file->file). " +
    "Infra tables: vm, service, container, domain, module, repo, package + edges hosted_on, runs_container, depends_on, proxied_by, routes_to, belongs_to_repo, implements, declares_tool, consumes. " +
    "Examples: \"SELECT path,language FROM file WHERE repo='cloud-infra' AND node_type='source_file' LIMIT 20\"; " +
    "\"SELECT count() FROM file GROUP BY repo\"; \"INFO FOR DB\"; graph traversal \"SELECT ->sibling_module->file AS siblings FROM file WHERE repo='cloud-infra-desktop' LIMIT 5\".",
    { surql: z.string().describe("Read-only SurrealQL (SELECT or INFO). Mutations are refused.") },
    async ({ surql: q }) => {
      if (!isReadOnly(q)) {
        return { content: [{ type: "text" as const, text: "Refused: cgc.kgstore.query is read-only (SELECT / INFO only)." }] };
      }
      const out = await surql(q);
      return { content: [{ type: "text" as const, text: out.slice(0, 24000) }] };
    }
  );

  server.tool(
    "cgc.kgstore.overview",
    "Overview of the kg-store SurrealDB unified graph: row counts for every node + edge table (octocode code graph mirrored across all repos + infra topology).",
    {},
    async () => {
      // Enumerate tables from INFO FOR DB, not a hardcoded list: octocode's
      // GraphRAG relation tables (imports/calls/extends/references/…) are created
      // dynamically from relation_type at ingest time, so a static list silently
      // hid them — the overview showed "edges: 0" while the store held 500k+.
      let tables: string[] = [];
      try {
        const info = JSON.parse(await surql("INFO FOR DB")) as Array<{ result?: { tables?: Record<string, string> } }>;
        tables = Object.keys(info?.[0]?.result?.tables ?? {}).sort();
      } catch { /* fall through to static list */ }
      if (!tables.length) tables = [...NODE_TABLES, ...EDGE_TABLES];
      const q = tables.map((t) => `SELECT count() AS n FROM ${t} GROUP ALL;`).join("\n");
      const out = await surql(q);
      try {
        const arr = JSON.parse(out) as Array<{ result?: Array<{ n?: number }> }>;
        const counts = new Map(tables.map((t, i) => [t, arr[i]?.result?.[0]?.n ?? 0]));
        const nodeSet = new Set(NODE_TABLES);
        const nodes = tables.filter((t) => nodeSet.has(t));
        const edges = tables.filter((t) => !nodeSet.has(t));
        const fmt = (names: string[]) => names.map((t) => `  ${t}: ${counts.get(t) ?? 0}`).join("\n");
        const text =
          "kg-store unified graph (SurrealDB " + NS + "/" + DB + ")\n" +
          "── nodes ──\n" + fmt(nodes) +
          "\n── edges / relations ──\n" + fmt(edges);
        return { content: [{ type: "text" as const, text }] };
      } catch {
        return { content: [{ type: "text" as const, text: out.slice(0, 6000) }] };
      }
    }
  );
}
