import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { join, dirname, resolve } from "node:path";

// ─────────────────────────────────────────────────────────────────────────────
// CodeGraph — unified, queryable knowledge graph served by the cgc MCP.
//
// Auto-discovers and merges THREE graph layers from the cloud repo (which the
// container has at $GIT_ROOT/cloud — the same octocode repos volume):
//
//   1. INFRA (deterministic)    2_configs/dist/build-kg-graph_delta.json
//      vm / service / container / domain / repo / module / package nodes + edges.
//   2. CODE STRUCTURE (deterministic, ALL repos)  2_configs/dist/code-signatures-*.json
//      one file per repo (cloud, unix, front, tools, cloud-data, front-data).
//      → file nodes + `imports` edges (local file→file, external file→package).
//   3. SEMANTIC (Opus-authored, per repo)  ca-dat_kg-graph/src/graph-semantic-*.json
//      subsystem / artifact nodes + intent edges (orchestrates/feeds/deploys/…).
//
// Everything is data-driven: drop a new code-signatures-<repo>.json or
// graph-semantic-<repo>.json into those dirs and it is picked up on next load.
// No hardcoded repo list, no per-repo wiring.
// ─────────────────────────────────────────────────────────────────────────────

// Resolution order for the graph data dir:
//   1. CODEGRAPH_GRAPHS_DIR env (explicit override)
//   2. ./graphs bundled inside the image (/app/code/graphs) — ships with the cgc
//      build, so the graph is live WITHOUT depending on the octocode repos volume.
//   3. repo layout fallback ($GIT_ROOT/cloud/{2_configs/dist, …/kg-graph/src}).
const GIT_ROOT = process.env.GIT_ROOT ?? `${process.env.HOME ?? "/home/diego"}/git`;
const CLOUD = join(GIT_ROOT, "cloud");
const BUNDLED = join(import.meta.dirname!, "..", "..", "graphs");
const useBundle = (): string | null => {
  if (process.env.CODEGRAPH_GRAPHS_DIR && existsSync(process.env.CODEGRAPH_GRAPHS_DIR)) return process.env.CODEGRAPH_GRAPHS_DIR;
  if (existsSync(join(BUNDLED, "build-kg-graph_delta.json"))) return BUNDLED;
  return null;
};
const BUNDLE = useBundle();
const DIST = BUNDLE ?? join(CLOUD, "2_configs", "dist");          // ① infra + ② code-signatures
const SEMANTIC_DIR = BUNDLE ?? join(CLOUD, "a_solutions", "ca-dat_kg-graph", "src"); // ③ semantic
const TTL_MS = 5 * 60 * 1000;

interface GNode { table: string; id: string; key: string; properties: Record<string, unknown>; layer: string }
interface GEdge { table: string; from: string; to: string; key: string; properties: Record<string, unknown>; layer: string }
interface Graph { nodes: Map<string, GNode>; edges: GEdge[]; adj: Map<string, GEdge[]>; radj: Map<string, GEdge[]>; sources: string[] }

let _cache: Graph | null = null;
let _ts = 0;

function listJson(dir: string, prefix: string): string[] {
  if (!existsSync(dir)) return [];
  return readdirSync(dir).filter((f) => f.startsWith(prefix) && f.endsWith(".json")).map((f) => join(dir, f));
}

function addNode(g: Graph, n: Omit<GNode, "layer">, layer: string): void {
  if (!g.nodes.has(n.key)) g.nodes.set(n.key, { ...n, layer });
}
function addEdge(g: Graph, e: Omit<GEdge, "layer">, layer: string): void {
  const edge: GEdge = { ...e, layer };
  g.edges.push(edge);
  (g.adj.get(e.from) ?? g.adj.set(e.from, []).get(e.from)!).push(edge);
  (g.radj.get(e.to) ?? g.radj.set(e.to, []).get(e.to)!).push(edge);
}

// ── Layer loaders ────────────────────────────────────────────────────────────
function loadExplicit(g: Graph, path: string, layer: string): void {
  // build-kg-graph_delta.json + graph-semantic-*.json share {nodes[],edges[]}.
  let d: { nodes?: GNode[]; edges?: GEdge[] };
  try { d = JSON.parse(readFileSync(path, "utf8")); } catch { return; }
  for (const n of d.nodes ?? []) if (n?.key) addNode(g, n, layer);
  for (const e of d.edges ?? []) if (e?.from && e?.to) addEdge(g, { ...e, key: e.key ?? `${e.from}->${e.table}->${e.to}` }, layer);
  g.sources.push(`${layer}:${path.split("/").pop()}`);
}

function loadSignatures(g: Graph, path: string): void {
  let d: { repo?: string; files?: Array<{ path: string; lang: string; role: string; exports: string[]; imports: string[]; symbols: string[] }> };
  try { d = JSON.parse(readFileSync(path, "utf8")); } catch { return; }
  const repo = d.repo ?? "unknown";
  const byPath = new Map<string, string>(); // repo-rel path → node key
  for (const f of d.files ?? []) {
    const key = `file:${repo}/${f.path}`;
    byPath.set(f.path, key);
    addNode(g, { table: "file", id: `${repo}:${f.path}`, key, properties: { repo, path: f.path, lang: f.lang, role: f.role, exports: f.exports.slice(0, 12), symbols: f.symbols.slice(0, 12) } }, "code");
  }
  // imports → edges. Local (./ ../) resolve to a sibling file node; external → package node.
  for (const f of d.files ?? []) {
    const fromKey = `file:${repo}/${f.path}`;
    for (const imp of f.imports ?? []) {
      if (imp.startsWith(".")) {
        const baseDir = dirname(f.path);
        const cand = resolve("/" + baseDir, imp).slice(1); // normalise ../
        const hit = [cand, `${cand}.ts`, `${cand}.js`, `${cand}.nix`, `${cand}.sh`, `${cand}/index.ts`, `${cand}/mod.rs`, `${cand}/default.nix`]
          .map((c) => byPath.get(c)).find(Boolean);
        if (hit) addEdge(g, { table: "imports", from: fromKey, to: hit, key: `${fromKey}->imports->${hit}` }, "code");
      } else if (imp && !imp.startsWith("$") && !imp.startsWith("/")) {
        const pkg = imp.replace(/^(@[^/]+\/[^/]+).*/, "$1").split("/")[0].replace(/^(@[^/]+\/[^/]+)/, "$1");
        const pkgName = imp.startsWith("@") ? imp.split("/").slice(0, 2).join("/") : pkg;
        const pkgKey = `package:${pkgName}`;
        addNode(g, { table: "package", id: pkgName, key: pkgKey, properties: { name: pkgName, external: true } }, "code");
        addEdge(g, { table: "code_depends_on", from: fromKey, to: pkgKey, key: `${fromKey}->code_depends_on->${pkgKey}` }, "code");
      }
    }
  }
  g.sources.push(`code:${repo}(${(d.files ?? []).length}f)`);
}

function loadGraph(): Graph {
  const now = Date.now();
  if (_cache && now - _ts < TTL_MS) return _cache;
  const g: Graph = { nodes: new Map(), edges: [], adj: new Map(), radj: new Map(), sources: [] };
  const delta = join(DIST, "build-kg-graph_delta.json");
  if (existsSync(delta)) loadExplicit(g, delta, "infra");
  for (const p of listJson(DIST, "code-signatures-")) loadSignatures(g, p);
  for (const p of listJson(SEMANTIC_DIR, "graph-semantic-")) loadExplicit(g, p, "semantic");
  _cache = g; _ts = now;
  return g;
}

// ── Query helpers ────────────────────────────────────────────────────────────
function resolveTarget(g: Graph, t: string): GNode[] {
  if (g.nodes.has(t)) return [g.nodes.get(t)!];
  const low = t.toLowerCase();
  const exact = [...g.nodes.values()].filter((n) => n.id.toLowerCase() === low || String(n.properties.name ?? "").toLowerCase() === low || String(n.properties.path ?? "").toLowerCase().endsWith(low));
  if (exact.length) return exact;
  return [...g.nodes.values()].filter((n) => n.key.toLowerCase().includes(low) || String(n.properties.name ?? "").toLowerCase().includes(low) || String(n.properties.path ?? "").toLowerCase().includes(low)).slice(0, 15);
}
const nlabel = (n: GNode): string => `${n.key}${n.properties.name ? ` (${n.properties.name})` : ""}`;
const txt = (s: string) => ({ content: [{ type: "text" as const, text: s }] });

export function registerCodegraphTools(server: McpServer): void {
  server.tool(
    "cgc.codegraph.overview",
    "Overview of the unified code knowledge graph (infra + code-structure of ALL repos + Opus semantic layer): node/edge counts by table and layer, loaded sources.",
    {},
    async () => {
      const g = loadGraph();
      const byTable: Record<string, number> = {}; const byLayer: Record<string, number> = {};
      for (const n of g.nodes.values()) { byTable[n.table] = (byTable[n.table] ?? 0) + 1; byLayer[n.layer] = (byLayer[n.layer] ?? 0) + 1; }
      const edgeByTable: Record<string, number> = {};
      for (const e of g.edges) edgeByTable[e.table] = (edgeByTable[e.table] ?? 0) + 1;
      return txt(JSON.stringify({ nodes: g.nodes.size, edges: g.edges.length, node_tables: byTable, nodes_by_layer: byLayer, edge_tables: edgeByTable, sources: g.sources }, null, 2));
    }
  );

  server.tool(
    "cgc.codegraph.search",
    "Search the code knowledge graph for nodes (files, modules, services, subsystems, packages) by name/path/key substring.",
    { query: z.string().describe("Substring to match against node key/name/path"), limit: z.number().optional().default(25) },
    async ({ query, limit }) => {
      const g = loadGraph();
      const hits = resolveTarget(g, query).slice(0, limit);
      return txt(hits.length ? hits.map((n) => `• [${n.layer}/${n.table}] ${n.key}${n.properties.description ? ` — ${String(n.properties.description).slice(0, 140)}` : n.properties.role ? ` «${n.properties.role}»` : ""}`).join("\n") : `No nodes match "${query}".`);
    }
  );

  server.tool(
    "cgc.codegraph.get_node",
    "Full details of one graph node plus its incident edges (in + out).",
    { node_id: z.string().describe("Node key (e.g. 'subsystem:ship_engine', 'file:cloud/2_configs/...'), id, or name") },
    async ({ node_id }) => {
      const g = loadGraph();
      const ns = resolveTarget(g, node_id);
      if (!ns.length) return txt(`No node matches "${node_id}".`);
      const n = ns[0];
      const out = (g.adj.get(n.key) ?? []).map((e) => `  →[${e.table}] ${e.to}${e.properties.rationale ? ` — ${e.properties.rationale}` : ""}`);
      const inc = (g.radj.get(n.key) ?? []).map((e) => `  ←[${e.table}] ${e.from}`);
      return txt(`${nlabel(n)}  [${n.layer}/${n.table}]\nproperties: ${JSON.stringify(n.properties)}\nout (${out.length}):\n${out.slice(0, 40).join("\n")}\nin (${inc.length}):\n${inc.slice(0, 40).join("\n")}` + (ns.length > 1 ? `\n\n(+${ns.length - 1} other matches — refine node_id)` : ""));
    }
  );

  server.tool(
    "cgc.codegraph.dependencies",
    "Query the dependency edges of a module/file/service/subsystem. upstream = who points AT it, downstream = what it points to.",
    { target: z.string().describe("Node key/id/name"), direction: z.enum(["upstream", "downstream", "both"]).optional().default("both") },
    async ({ target, direction }) => {
      const g = loadGraph();
      const ns = resolveTarget(g, target);
      if (!ns.length) return txt(`No node matches "${target}".`);
      const n = ns[0];
      const down = (g.adj.get(n.key) ?? []).map((e) => `  →[${e.table}] ${e.to}`);
      const up = (g.radj.get(n.key) ?? []).map((e) => `  ←[${e.table}] ${e.from}`);
      const parts: string[] = [`${nlabel(n)} [${n.layer}/${n.table}]`];
      if (direction !== "upstream") parts.push(`downstream (${down.length}):\n${down.slice(0, 60).join("\n") || "  (none)"}`);
      if (direction !== "downstream") parts.push(`upstream (${up.length}):\n${up.slice(0, 60).join("\n") || "  (none)"}`);
      return txt(parts.join("\n"));
    }
  );

  server.tool(
    "cgc.codegraph.impact_analysis",
    "Blast radius: BFS the downstream dependents of a node up to `depth` hops — what is (transitively) affected if it changes.",
    { target: z.string().describe("Node key/id/name"), depth: z.number().optional().default(3) },
    async ({ target, depth }) => {
      const g = loadGraph();
      const ns = resolveTarget(g, target);
      if (!ns.length) return txt(`No node matches "${target}".`);
      const start = ns[0].key;
      const seen = new Map<string, number>([[start, 0]]);
      let frontier = [start];
      for (let d = 1; d <= depth && frontier.length; d++) {
        const next: string[] = [];
        for (const k of frontier) for (const e of g.radj.get(k) ?? []) if (!seen.has(e.from)) { seen.set(e.from, d); next.push(e.from); }
        frontier = next;
      }
      seen.delete(start);
      const byDepth: Record<number, string[]> = {};
      for (const [k, d] of seen) (byDepth[d] ??= []).push(k);
      const lines = Object.entries(byDepth).map(([d, ks]) => `  depth ${d} (${ks.length}): ${ks.slice(0, 25).join(", ")}${ks.length > 25 ? " …" : ""}`);
      return txt(`Impact of changing ${nlabel(ns[0])}: ${seen.size} dependents within ${depth} hops\n${lines.join("\n") || "  (no dependents)"}`);
    }
  );

  server.tool(
    "cgc.codegraph.trace_call_path",
    "Shortest dependency/relationship path between two nodes (BFS over all edge types). Works across files, modules, services, and semantic subsystems.",
    { from: z.string().describe("Source node key/id/name"), to: z.string().describe("Target node key/id/name"), max_depth: z.number().optional().default(8) },
    async ({ from, to, max_depth }) => {
      const g = loadGraph();
      const a = resolveTarget(g, from)[0], b = resolveTarget(g, to)[0];
      if (!a) return txt(`No node matches source "${from}".`);
      if (!b) return txt(`No node matches target "${to}".`);
      if (a.key === b.key) return txt("Source and target are the same node.");
      const prev = new Map<string, { via: GEdge; from: string }>();
      const seen = new Set([a.key]); let frontier = [a.key]; let found = false;
      for (let d = 0; d < max_depth && frontier.length && !found; d++) {
        const next: string[] = [];
        for (const k of frontier) for (const e of g.adj.get(k) ?? []) if (!seen.has(e.to)) { seen.add(e.to); prev.set(e.to, { via: e, from: k }); if (e.to === b.key) { found = true; break; } next.push(e.to); }
        frontier = next;
      }
      if (!prev.has(b.key)) return txt(`No path found from ${a.key} → ${b.key} within ${max_depth} hops (the graph is directed; try swapping, or use dependencies).`);
      const chain: string[] = []; let cur = b.key;
      while (cur !== a.key) { const p = prev.get(cur)!; chain.unshift(`  ─[${p.via.table}]→ ${cur}`); cur = p.from; }
      return txt(`Path ${a.key} → ${b.key}:\n${a.key}\n${chain.join("\n")}`);
    }
  );
}
