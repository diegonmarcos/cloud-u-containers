/**
 * Where this container's derived peer map lives.
 *
 * The ship engine writes `1_cloud-configs/dist/build-<name>.json`, where
 * `<name>` is the `name` field of the container's OWN `build.json`, and the
 * image carries that file at `/app/build-<name>.json`.
 *
 * Both consumers of this module used to restate that filename as the literal
 * "build-c3-services-api.json". When the container was renamed to
 * cloud-services-mcp its image began carrying `build-cloud-services-mcp.json`,
 * the literal stopped matching, and the loaders fell straight through to their
 * "no file found" branch. The result was not a loud failure: the registry held
 * ZERO services, `getBaseUrl()` returned null for everything, and every tool
 * silently used its hardcoded fallback address instead of the declared one —
 * which is how `infra.matomo.*` kept dialling 10.0.0.4 while the declaration
 * said 10.0.0.6.
 *
 * So: read the name from the declaration, never restate it here. A future
 * rename then costs nothing.
 */
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

/**
 * Roots that may hold a container's `build.json` next to its peer map.
 *   /app   — the deployed image
 *   ../..  — the development tree (`src/`, the parent of `src/code/registry/`)
 */
const ROOTS = ["/app", join(import.meta.dirname ?? "", "../..")];

/** Candidate paths for the peer map, most specific first. May be empty. */
export function peerMapCandidates(): string[] {
  const candidates: string[] = [];
  for (const root of ROOTS) {
    const ownDeclaration = join(root, "build.json");
    if (!existsSync(ownDeclaration)) continue;
    try {
      const { name } = JSON.parse(readFileSync(ownDeclaration, "utf-8")) as { name?: string };
      if (name) candidates.push(join(root, `build-${name}.json`));
    } catch {
      // A build.json we cannot parse tells us nothing about the peer map's
      // name. Try the next root rather than guessing a filename.
    }
  }
  return candidates;
}

/**
 * Human-readable account of where we looked, for error messages. A loader that
 * cannot find its peer map must say which paths it tried — "empty registry"
 * on its own is exactly the confident-but-wrong report this fix exists to stop.
 */
export function describeCandidates(candidates: string[]): string {
  if (candidates.length === 0) {
    return `no build.json found in any of: ${ROOTS.join(", ")}`;
  }
  return `tried: ${candidates.join(", ")}`;
}
