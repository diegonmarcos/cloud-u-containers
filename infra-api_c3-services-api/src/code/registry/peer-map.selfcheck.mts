/**
 * Self-check for peer-map.ts — run it, do not read it and hope.
 *
 *   node --experimental-strip-types peer-map.selfcheck.mts
 *
 * Exits non-zero on the first failed assertion. No framework, no fixtures
 * directory: it builds a throwaway container layout under the OS temp dir.
 *
 * What it pins down is the exact defect that made this module necessary: the
 * peer map filename must follow the container's declared `name`, so renaming a
 * container cannot silently leave the registry empty. The "cannot read" case is
 * asserted too — a loader that cannot find its map has to say which paths it
 * tried, not return a clean empty answer.
 */
import { mkdtempSync, mkdirSync, writeFileSync, cpSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import assert from "node:assert/strict";

const root = mkdtempSync(join(tmpdir(), "peer-map-selfcheck-"));
const registryDir = join(root, "src", "code", "registry");
mkdirSync(registryDir, { recursive: true });
cpSync(join(import.meta.dirname, "peer-map.ts"), join(registryDir, "peer-map.ts"));

const declaration = join(root, "src", "build.json");
const moduleUnderTest = join(registryDir, "peer-map.ts");

async function candidatesFor(buildJsonContents: string | null): Promise<string[]> {
  if (buildJsonContents === null) rmSync(declaration, { force: true });
  else writeFileSync(declaration, buildJsonContents);
  // Fresh import each time: peerMapCandidates() reads the declaration on call,
  // but the cache-buster keeps this honest if that ever changes.
  const mod = await import(`${moduleUnderTest}?v=${Math.random()}`);
  return mod.peerMapCandidates() as string[];
}

const expected = join(root, "src", "build-cloud-services-mcp.json");

// 1. The name in build.json decides the peer map filename.
assert.deepEqual(
  await candidatesFor(JSON.stringify({ name: "cloud-services-mcp" })),
  [expected],
  "peer map must be named from the declared container name"
);

// 2. Renaming the container renames the peer map — the regression that emptied
//    the registry when c3-services-api became cloud-services-mcp.
assert.deepEqual(
  await candidatesFor(JSON.stringify({ name: "c3-services-api" })),
  [join(root, "src", "build-c3-services-api.json")],
  "a renamed container must look for its own peer map, not the old name"
);

// 3. No declaration to read: no guessed filename, and the description says so.
const { describeCandidates } = await import(`${moduleUnderTest}?v=describe`);
const none = await candidatesFor(null);
assert.deepEqual(none, [], "with no build.json there is nothing to guess from");
assert.match(
  describeCandidates(none),
  /no build\.json found/,
  "an unreadable peer map must report where it looked"
);

// 4. An unparsable declaration is not silently treated as a missing one.
assert.deepEqual(await candidatesFor("{ not json"), [], "a corrupt build.json yields no candidate");

rmSync(root, { recursive: true, force: true });
console.log("peer-map selfcheck: 4 assertions passed");
