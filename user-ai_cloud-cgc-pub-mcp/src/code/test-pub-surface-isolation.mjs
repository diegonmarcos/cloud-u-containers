// Tester: no private repo is reachable through cloud-cgc-pub-mcp.
//
// THE DEFECT (audit 2026-10-13). cloud-cgc-pub-mcp mounted the whole shared
// octocode_repos volume at /repos, and that volume carries checkouts of the
// PRIVATE repos (cloud-data, cloud-me-pvt-my-ai). The public endpoint's
// knowledge.inventory list_directory repo=cloud-data listed the private tree,
// secrets/ included, and every repo-scoped tool schema advertised the private
// names in its enum. The bundled codegraph also served cloud-data's file and
// symbol structure.
//
// WHAT THIS PROVES, by EXECUTION rather than grep:
//   A. compose.nix (EVALUATED with nix-instantiate) gives the pub container
//      only per-repo subpath mounts of PUBLIC repos — no whole-volume /repos
//      mount, no private name anywhere in its volumes; pvt keeps the full one.
//   B. surface.ts: private names refused on pub for every spelling of the
//      surface env that is not exactly "pvt" (fail-closed), public allowed.
//   C. The REAL tool modules are registered against a capturing fake server
//      (zod / MCP SDK / better-sqlite3 stubbed so CI needs no npm install),
//      over a scratch GIT_ROOT that DOES contain private checkouts — the
//      "even if mounted" case. Every enum is checked for private names and
//      every repo-taking handler is invoked with every private name.
//   D. The codegraph tools never return a private repo's nodes.
//
// Usage: node --experimental-strip-types test-pub-surface-isolation.mjs  (cwd src/code)
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { register } from "node:module";

const CODE = dirname(fileURLToPath(import.meta.url));
const SVC = join(CODE, "..", "..");
const BJ = JSON.parse(readFileSync(join(SVC, "build.json"), "utf8"));
const OCT = BJ.runtime.octocode;
const PRIVATE = [...new Set([...OCT.private_repos, ...Object.keys(OCT.sync_exclude ?? {}), "cloud-data", "cloud-me-pvt-data", "cloud-me-pvt-my-ai", "cloud-vault"])];
const PUBLIC = OCT.index_repos.filter((r) => !PRIVATE.includes(r));

let pass = 0, fail = 0;
const check = (n, c, d = "") => c
  ? (pass++, console.log(`PASS ${n}`))
  : (fail++, console.error(`FAIL ${n}${d ? ` — ${d}` : ""}`));
const mentionsPrivate = (s) => PRIVATE.some((p) => new RegExp(`(^|[^a-z0-9-])${p.replace(/-/g, "[-_]")}($|[^a-z0-9-])`, "i").test(s));

check("P0 build.json declares the private repos (cloud-data, cloud-me-pvt-my-ai)",
  OCT.private_repos.includes("cloud-me-pvt-data") && OCT.private_repos.includes("cloud-me-pvt-my-ai"),
  JSON.stringify(OCT.private_repos));
check("P1 exactly the 6 public repos remain", JSON.stringify([...PUBLIC].sort()) ===
  JSON.stringify(["cloud-infra", "cloud-infra-desktop", "cloud-u-android", "cloud-u-containers", "front-data", "front-diegonmarcos"]),
  PUBLIC.join(","));

// ── A. compose.nix, evaluated ───────────────────────────────────────────────
let nixOk = true;
try { execFileSync("nix-instantiate", ["--version"], { stdio: "pipe" }); } catch { nixOk = false; }
check("A0 nix-instantiate is available (this tester EVALUATES compose.nix)", nixOk);
if (nixOk) {
  const expr = `let b = builtins.fromJSON (builtins.readFile ./build.json);
    # The real container arg (src/build-cloud-cgc-pub-mcp.json) is a symlink into
    # cloud-infra's 1_cloud-configs/dist, dangling in a standalone checkout. compose.nix
    # only reads .services.<name>.ip and .services.ntfy from it, so a minimal
    # stand-in is enough: nothing asserted here depends on those values.
    c = { services = { "cloud-cgc-pub-mcp" = { ip = "10.0.0.6"; }; ntfy = { ip = "10.0.0.6"; ports = { app = 8090; }; }; }; };
    in (import ./src/compose.nix { buildJson = b; container = c; }).services`;
  const svcs = JSON.parse(execFileSync("nix-instantiate", ["--eval", "--strict", "--json", "--expr", expr],
    { cwd: SVC, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }));
  const pub = svcs[BJ.containers.app.container_name];
  const pvt = svcs[BJ.containers.pvt.container_name];
  const vols = pub.volumes ?? [];
  const repoVols = vols.filter((v) => typeof v === "object" ? v.source === OCT.repos_volume : String(v).split(":")[0] === OCT.repos_volume);
  check("A1 pub has NO whole-volume repos mount",
    !repoVols.some((v) => typeof v === "string" || !v.volume?.subpath), JSON.stringify(repoVols.filter((v) => typeof v === "string")));
  const targets = repoVols.map((v) => v.target).sort();
  check("A2 pub repos mounts are exactly the public repos",
    JSON.stringify(targets) === JSON.stringify(PUBLIC.map((r) => `${OCT.repos_path}/${r}`).sort()), targets.join(","));
  check("A3 every pub repos mount is read-only and subpath == target leaf",
    repoVols.every((v) => v.read_only === true && v.target === `${OCT.repos_path}/${v.volume.subpath}`));
  check("A4 no private name appears anywhere in pub's volumes",
    !mentionsPrivate(JSON.stringify(vols)), JSON.stringify(vols));
  check("A5 pub env CGC_SURFACE=pub and pvt env CGC_SURFACE=pvt",
    pub.environment?.CGC_SURFACE === "pub" && pvt.environment?.CGC_SURFACE === "pvt");
  check("A6 pub env CGC_PRIVATE_REPOS lists every private repo",
    OCT.private_repos.every((r) => String(pub.environment?.CGC_PRIVATE_REPOS ?? "").split(/\s+/).includes(r)));
  check("A7 pvt keeps the full repos volume (private surface still answers about everything)",
    (pvt.volumes ?? []).includes(`${OCT.repos_volume}:${OCT.repos_path}:ro`));
}

// ── B. surface.ts policy ────────────────────────────────────────────────────
const surface = await import(pathToFileURL(join(CODE, "surface.ts")).href);
for (const env of [{}, { CGC_SURFACE: "" }, { CGC_SURFACE: "pub" }, { CGC_SURFACE: "PVT " + "x" }, { CGC_SURFACE: "private" }]) {
  const label = JSON.stringify(env);
  check(`B1 surface ${label} resolves to pub`, surface.currentSurface(env) === "pub");
  for (const p of [...PRIVATE, "cloud_data", "Cloud-Data", "cloud-me-pvt-my-ai"]) {
    check(`B2 ${label} refuses ${p}`, surface.isRepoAllowed(p, env) === false);
  }
  for (const p of PUBLIC) check(`B3 ${label} allows ${p}`, surface.isRepoAllowed(p, env) === true);
  check(`B4 ${label} refuses an undeclared repo`, surface.isRepoAllowed("some-other-repo", env) === false);
}
check("B5 pvt surface allows private repos", surface.isRepoAllowed("cloud-me-pvt-data", { CGC_SURFACE: "pvt" }) === true);
check("B6 hard floor holds even with an empty env deny list",
  surface.HARD_DENY.includes("cloud-me-pvt-data") && surface.HARD_DENY.includes("cloud-data") && surface.HARD_DENY.includes("cloud-me-pvt-my-ai") && surface.HARD_DENY.includes("cloud-vault"));

// ── C/D. the real tools, over a scratch GIT_ROOT that DOES hold private repos ──
const root = mkdtempSync(join(tmpdir(), "cgc-pub-iso-"));
try {
  for (const r of [...OCT.index_repos, "cloud-vault"]) {
    mkdirSync(join(root, r, "secrets"), { recursive: true });
    writeFileSync(join(root, r, "secrets", "CANARY.txt"), `canary-${r}\n`);
    writeFileSync(join(root, r, "README.md"), `readme ${r} needle-${r}\n`);
  }
  // A public repo with a symlink that points INTO a private checkout.
  symlinkSync(join(root, "cloud-me-pvt-data"), join(root, "front-diegonmarcos", "escape"));
  process.env.GIT_ROOT = root;
  process.env.CONFIG_PATH = join(root, "config.json");
  process.env.REPO_SYNC = "off";
  delete process.env.CGC_SURFACE;

  const stubs = {
    "zod": `const chain = () => new Proxy(function(){}, { get: (t, k) => k === "__opts" ? t.__opts : (k === "then" ? undefined : (...a) => chain()), apply: () => chain() });
      export const z = new Proxy({}, { get: (_, k) => (...a) => { const c = chain(); if (k === "enum") { const p = new Proxy(function(){}, { get: (t, kk) => kk === "__enum" ? a[0] : (kk === "then" ? undefined : () => p) }); return p; } return c; } });
      export default { z };`,
    "@modelcontextprotocol/sdk/server/mcp.js": `export class McpServer { constructor() { this.tools = new Map(); }
      tool(name, ...rest) { const handler = rest[rest.length - 1]; const shape = rest.find((x) => x && typeof x === "object" && !Array.isArray(x)) ?? {}; this.tools.set(name, { shape, handler }); }
      resource() {} }`,
    "better-sqlite3": `export default class Database { constructor() { throw new Error("sqlite stubbed in tester"); } }`,
  };
  const hook = `
    const STUBS = ${JSON.stringify(Object.fromEntries(Object.entries(stubs).map(([k, v]) => [k, "data:text/javascript," + encodeURIComponent(v)])))};
    import { existsSync } from "node:fs";
    import { fileURLToPath } from "node:url";
    export async function resolve(spec, ctx, next) {
      if (STUBS[spec]) return { url: STUBS[spec], shortCircuit: true };
      if ((spec.startsWith("./") || spec.startsWith("../")) && spec.endsWith(".js") && ctx.parentURL?.startsWith("file:")) {
        const ts = new URL(spec.replace(/\\.js$/, ".ts"), ctx.parentURL);
        if (existsSync(fileURLToPath(ts))) return { url: ts.href, shortCircuit: true };
      }
      return next(spec, ctx);
    }`;
  register("data:text/javascript," + encodeURIComponent(hook));

  const { McpServer } = await import("@modelcontextprotocol/sdk/server/mcp.js");
  const server = new McpServer();
  const mods = [
    ["tools/a-knowledge/inventory.ts", "registerInventoryTools"],
    ["tools/b-code-graph-context/octocode.ts", "registerOctocodeTools"],
    ["tools/b-code-graph-context/codegraph.ts", "registerCodegraphTools"],
  ];
  for (const [f, fn] of mods) {
    const m = await import(pathToFileURL(join(CODE, f)).href);
    m[fn](server);
  }
  check("C0 tools registered", server.tools.has("knowledge.inventory") && server.tools.has("cgc.octocode.search"), [...server.tools.keys()].join(","));

  // Every enum in every captured schema: no private name.
  for (const [name, { shape }] of server.tools) {
    for (const [field, schema] of Object.entries(shape)) {
      const opts = schema?.__enum;
      if (!Array.isArray(opts)) continue;
      check(`C1 ${name}.${field} enum lists no private repo`, !opts.some((o) => PRIVATE.includes(o)), opts.join(","));
      if (field === "repo") check(`C2 ${name}.repo enum is exactly the public repos`,
        JSON.stringify([...opts].sort()) === JSON.stringify([...PUBLIC].sort()), opts.join(","));
    }
  }

  const text = (r) => (r?.content ?? []).map((c) => c.text).join("\n");
  const inv = server.tools.get("knowledge.inventory").handler;
  for (const p of PRIVATE) {
    for (const call of [
      { method: "list_directory", repo: p },
      { method: "list_directory", repo: p, path: "secrets" },
      { method: "read_file", repo: p, path: "secrets/CANARY.txt" },
      { method: "read_file", repo: p, path: "README.md" },
      { method: "search_repos", repo: p, pattern: "canary" },
    ]) {
      const r = await inv(call);
      const t = text(r);
      check(`C3 inventory ${call.method} repo=${p}${call.path ? " path=" + call.path : ""} is refused`,
        r?.isError === true && !t.includes("canary-") && !t.includes("CANARY") && !t.includes(`needle-${p}`), t.slice(0, 200));
    }
  }
  // Traversal from a public repo into a private sibling.
  for (const path of ["../cloud-data/secrets/CANARY.txt", "../cloud-data", "escape/secrets/CANARY.txt", "escape"]) {
    const m = path.endsWith("CANARY.txt") ? "read_file" : "list_directory";
    const r = await inv({ method: m, repo: "front-diegonmarcos", path });
    check(`C4 ${m} repo=front path=${path} cannot reach a private checkout`,
      r?.isError === true && !text(r).includes("canary-") && !text(r).includes("CANARY"), text(r).slice(0, 200));
  }
  // Unscoped search must not enter private checkouts.
  {
    const r = await inv({ method: "search_repos", pattern: "canary-" });
    check("C5 unscoped search_repos never returns private content",
      !PRIVATE.some((p) => text(r).includes(`canary-${p}`)), text(r).slice(0, 300));
    check("C6 unscoped search_repos still searches the public repos",
      PUBLIC.every((p) => text(r).includes(`canary-${p}`) || text(r).includes(`[${p}]`)), text(r).slice(0, 300));
  }
  // Public repos still work.
  for (const p of PUBLIC) {
    const r = await inv({ method: "list_directory", repo: p });
    check(`C7 list_directory repo=${p} works`, r?.isError !== true && text(r).includes("README.md"), text(r).slice(0, 200));
  }
  const oc = server.tools.get("cgc.octocode.search").handler;
  const og = server.tools.get("cgc.octocode.graphrag").handler;
  const oi = server.tools.get("cgc.octocode.index").handler;
  for (const p of PRIVATE) {
    check(`C8 octocode.search repo=${p} refused`, (await oc({ query: "x", repo: p }))?.isError === true);
    check(`C9 octocode.graphrag repo=${p} refused`, (await og({ operation: "overview", repo: p }))?.isError === true);
    check(`C10 octocode.index path=${root}/${p} refused`, (await oi({ path: join(root, p) }))?.isError === true);
  }

  // D. codegraph: overview + search must not surface a private repo's nodes.
  const ov = server.tools.get("cgc.codegraph.overview");
  const se = server.tools.get("cgc.codegraph.search");
  if (ov && se) {
    const o = text(await ov.handler({}));
    check("D1 codegraph overview loads no private code-signatures", !/code:cloud-data\(/.test(o), o.slice(0, 400));
    for (const p of OCT.private_repos) {
      const s = text(await se.handler({ query: p, limit: 200 }));
      // A node BELONGS to a repo by its key: repo:<r>, file:<r>/..., symbol:<r>/...
      // (a public file that merely names a CLOUD_DATA constant is not a leak).
      const own = [...s.matchAll(/\b(repo|file|symbol):([A-Za-z0-9_.-]+)/g)].map((m) => m[2]);
      const leaked = own.filter((r) => PRIVATE.some((q) => r.replace(/_/g, "-").toLowerCase() === q));
      check(`D2 codegraph search "${p}" returns no ${p} repo/file/symbol node`, leaked.length === 0, leaked.slice(0, 3).join(" | "));
    }
  } else {
    check("D0 codegraph tools registered", false, [...server.tools.keys()].join(","));
  }
} finally {
  rmSync(root, { recursive: true, force: true });
}

console.log(`\n${pass} passed, ${fail} failed`);
if (fail) { console.error("NOT GREEN"); process.exit(1); }
