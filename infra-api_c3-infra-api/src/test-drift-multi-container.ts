// Test: drift detection now treats multi-container compose services (photoprism,
// crawlee-cloud, etherpad, hedgedoc, grist) as "deployed" when ANY of their declared
// container_name entries are running. Also validates glob-pattern matching
// (e.g. "photoprism_*") works.
//
// Usage: npx tsx test-drift-multi-container.ts
// Expected: exits 0 with PASS, non-zero on failure.

import assert from "node:assert/strict";

// Inline port of the glob matcher from code/shared/libs/health.ts so the test
// doesn't require the full runtime (config.json, SSH access, etc.) to load.
function hasGlob(pat: string): boolean { return pat.includes("*") || pat.includes("?"); }
function globToRegex(pat: string): RegExp {
    return new RegExp("^" + pat.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$");
}
function isDeployed(declared: string[], deployed: string[]): boolean {
    return deployed.some((name) =>
        declared.some((pat) =>
            hasGlob(pat) ? globToRegex(pat).test(name) : pat === name
        )
    );
}

// ── Fixtures: declared container_names from build.json, deployed from docker ps
const cases: Array<{
    label: string;
    declared: string[];
    deployed: string[];
    expect: boolean;
}> = [
    // Previously reported as MISSING — these must now be OK.
    { label: "etherpad (multi-container)", declared: ["etherpad_app", "etherpad_postgres"], deployed: ["etherpad_app", "etherpad_postgres", "unrelated"], expect: true },
    { label: "grist (single but role-named)", declared: ["grist_app"], deployed: ["grist_app"], expect: true },
    { label: "hedgedoc", declared: ["hedgedoc_app", "hedgedoc_postgres"], deployed: ["hedgedoc_app", "hedgedoc_postgres"], expect: true },
    { label: "photoprism (3 roles)", declared: ["photoprism_app", "photoprism_mariadb", "photoprism_rclone"], deployed: ["photoprism_app", "photoprism_mariadb", "photoprism_rclone"], expect: true },
    // Partial deployment still counts as deployed (1 of N up).
    { label: "photoprism partial (only app up)", declared: ["photoprism_app", "photoprism_mariadb", "photoprism_rclone"], deployed: ["photoprism_app"], expect: true },
    // Service truly missing — zero matches.
    { label: "missing service", declared: ["etherpad_app", "etherpad_postgres"], deployed: ["something_else", "other"], expect: false },
    // Glob pattern — accepts ANY photoprism_* container.
    { label: "glob photoprism_*", declared: ["photoprism_*"], deployed: ["photoprism_app", "photoprism_mariadb"], expect: true },
    { label: "glob no match", declared: ["photoprism_*"], deployed: ["umami", "authelia"], expect: false },
    { label: "glob question mark", declared: ["redis?"], deployed: ["redis1"], expect: true },
    { label: "glob question mark no match", declared: ["redis?"], deployed: ["redis10"], expect: false },
    // Legacy single-container service where name matches exactly.
    { label: "legacy exact", declared: ["authelia"], deployed: ["authelia", "caddy"], expect: true },
    // Empty deployed — VM unreachable simulation.
    { label: "no deployed", declared: ["etherpad_app"], deployed: [], expect: false },
];

let failed = 0;
for (const c of cases) {
    const got = isDeployed(c.declared, c.deployed);
    if (got !== c.expect) {
        console.log(`FAIL: ${c.label} — expected ${c.expect}, got ${got}`);
        failed++;
    } else {
        console.log(`  OK: ${c.label}`);
    }
}

// Also confirm the data flow from build.json → declared_names using a real
// fixture from disk. discoverServicesFromDisk should surface "containers" now.
import { readFileSync } from "node:fs";
const photoprism = JSON.parse(readFileSync("/home/diego/git/cloud/a_solutions/aa-sui_photoprism/build.json", "utf-8"));
const ppContainers = Object.values((photoprism.containers ?? {}) as Record<string, { container_name?: string }>)
    .map((c) => c.container_name)
    .filter((n): n is string => typeof n === "string" && n.length > 0);

assert.deepEqual(ppContainers.sort(), ["photoprism_app", "photoprism_mariadb", "photoprism_rclone"].sort(),
    "photoprism build.json should yield 3 container_name entries");
console.log("  OK: photoprism build.json yields [" + ppContainers.join(", ") + "]");

if (failed > 0) {
    console.log(`\nFAIL: ${failed}/${cases.length} cases failed`);
    process.exit(1);
}
console.log(`\nPASS: ${cases.length}/${cases.length} drift matching cases pass`);
