/**
 * surface.ts — which MCP surface this process is, and which repos it may touch.
 *
 * cloud-cgc-pub-mcp and cloud-cgc-pvt-mcp are the SAME image running the SAME
 * code. Until 2026-10-13 the only thing separating them was which volumes
 * compose mounted. That held for the octocode DB (octocode_db vs
 * octocode_db_pvt), but both containers mounted the one shared octocode_repos
 * volume, and that volume carries checkouts of the PRIVATE repos too. So
 * knowledge.inventory list_directory / read_file / search_repos with
 * repo=cloud-data walked the private tree (secrets/ included) on the PUBLIC
 * endpoint, and every repo-scoped tool schema advertised the private names.
 *
 * This module is the second, code-level wall behind the compose fix (the pub
 * container now mounts only the public repos — see compose.nix pubReposMounts):
 *
 *   - FAIL-CLOSED: the surface is "pvt" only when CGC_SURFACE=pvt is set
 *     explicitly. Unset, empty, a typo, anything else: "pub".
 *   - DENY = a hard-coded floor (HARD_DENY below) UNION build.json
 *     .runtime.octocode.private_repos UNION .sync_exclude keys UNION the
 *     CGC_PRIVATE_REPOS env compose passes. The floor exists so a build.json
 *     that fails to load, or a private_repos list someone trims, cannot reopen
 *     the leak on its own.
 *   - ALLOW (pub) = .runtime.octocode.index_repos minus DENY. A repo that is
 *     in neither list (e.g. cloud-vault, which shared/libs/paths.ts adds to
 *     REPOS as a browse target for the infra MCPs) is refused too: on pub,
 *     anything not positively declared public is private.
 *
 * Asserted by test-pub-surface-isolation.mjs (build.json .tests).
 */
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { join, resolve, sep } from "node:path";

/** Names that are private no matter what any config file says. */
export const HARD_DENY: readonly string[] = ["cloud-me-pvt-data", "cloud-data", "cloud-me-pvt-my-ai", "cloud-me-my-ai", "cloud-vault"];

export type Surface = "pub" | "pvt";

export function currentSurface(env: NodeJS.ProcessEnv = process.env): Surface {
  return (env.CGC_SURFACE ?? "").trim().toLowerCase() === "pvt" ? "pvt" : "pub";
}

interface OctocodeDecl { index_repos: string[]; private_repos: string[]; sync_exclude: string[] }

function readDecl(): OctocodeDecl {
  const candidates = [
    "/app/build.json",
    join(import.meta.dirname ?? ".", "..", "build.json"), // src/code -> src/build.json (dev tree)
    join(import.meta.dirname ?? ".", "..", "..", "build.json"),
  ];
  for (const p of candidates) {
    if (!existsSync(p)) continue;
    try {
      const oct = JSON.parse(readFileSync(p, "utf-8"))?.runtime?.octocode ?? {};
      return {
        index_repos: Array.isArray(oct.index_repos) ? oct.index_repos : [],
        private_repos: Array.isArray(oct.private_repos) ? oct.private_repos : [],
        sync_exclude: oct.sync_exclude && typeof oct.sync_exclude === "object" ? Object.keys(oct.sync_exclude) : [],
      };
    } catch { /* try next */ }
  }
  // No declaration: allow nothing on pub (index_repos empty), deny the floor.
  return { index_repos: [], private_repos: [], sync_exclude: [] };
}

let _decl: OctocodeDecl | null = null;
const decl = (): OctocodeDecl => (_decl ??= readDecl());

/** Normalise a repo name for comparison: the infra graph spells repos with
 *  underscores (repo:cloud_data), build.json with hyphens. */
const norm = (s: string): string => s.trim().toLowerCase().replace(/[-_.]/g, "");

export function deniedRepos(env: NodeJS.ProcessEnv = process.env): Set<string> {
  const fromEnv = (env.CGC_PRIVATE_REPOS ?? "").split(/[\s,]+/).filter(Boolean);
  return new Set([...HARD_DENY, ...decl().private_repos, ...decl().sync_exclude, ...fromEnv]);
}

export function isRepoAllowed(name: string, env: NodeJS.ProcessEnv = process.env): boolean {
  if (currentSurface(env) === "pvt") return true;
  if (!name) return false;
  const n = norm(name);
  for (const d of deniedRepos(env)) if (norm(d) === n) return false;
  return decl().index_repos.some((r) => norm(r) === n);
}

/** Deny-only check, for data keyed by repo names that are NOT index_repos
 *  entries (the bundled code-signatures use legacy names: cloud, unix, tools).
 *  On pub, true for anything in the deny set; on pvt, always false. */
export function isRepoDenied(name: string, env: NodeJS.ProcessEnv = process.env): boolean {
  if (currentSurface(env) === "pvt") return false;
  const n = norm(String(name ?? ""));
  for (const d of deniedRepos(env)) if (norm(d) === n) return true;
  return false;
}

/** Filter a { repoName: value } map down to what this surface may expose. */
export function filterRepoMap<T>(map: Record<string, T>, env: NodeJS.ProcessEnv = process.env): Record<string, T> {
  return Object.fromEntries(Object.entries(map).filter(([k]) => isRepoAllowed(k, env)));
}

export function refusal(name: string): string {
  return `Repo '${name}' is not available on this surface (cloud-cgc-pub-mcp serves public repos only).`;
}

/** True when `child` is `base` or strictly inside it (no '/repos/front' vs '/repos/front-data' prefix slip). */
export function isInside(base: string, child: string): boolean {
  const b = resolve(base);
  const c = resolve(child);
  return c === b || c.startsWith(b.endsWith(sep) ? b : b + sep);
}

/**
 * Resolve `path` inside `repoBase`, refusing traversal both lexically and after
 * symlink resolution (a public repo's symlink must not reach a sibling).
 * Missing targets resolve lexically only — the caller's read will then ENOENT.
 */
export function resolveInsideRepo(repoBase: string, path: string): string {
  const resolved = resolve(repoBase, path);
  if (!isInside(repoBase, resolved)) throw new Error("Path traversal detected — access denied");
  if (existsSync(resolved)) {
    let realBase = repoBase;
    try { realBase = realpathSync(repoBase); } catch { /* keep lexical */ }
    if (!isInside(realBase, realpathSync(resolved))) throw new Error("Path escapes the repo via a symlink — access denied");
  }
  return resolved;
}
