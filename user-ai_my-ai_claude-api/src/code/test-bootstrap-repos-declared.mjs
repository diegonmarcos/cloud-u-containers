// Tester: ticket #557 — what lands in the shared agent tree must be DECLARED.
//
// The bootstrap used to be a hardcoded shell loop naming four repos:
//   for repo in cloud-infra cloud-u-containers cloud-u-android cloud-u-linux
// while the live tree held seven. Three (cloud-data, cloud-data-my-ai-memory,
// cloud-vault) had been cloned by hand and would have vanished on the next
// volume recreate, and the whole `front` family was missing entirely — so every
// agent asked to touch a front project was working blind, which is the failure
// shape where a missing tree produces confident answers about a DIFFERENT repo
// rather than an honest "not here".
//
// A second list is the defect, not the four names. These assertions hold the
// ONE declaration (build.json runtime.repos) as the only source, and fail if a
// literal repo loop comes back into the shell.
//
// Usage: node test-bootstrap-repos-declared.mjs   (cwd = <repo>/user-ai_my-ai_claude-api/src/code)
import { readFileSync } from "node:fs";
import { join } from "node:path";

let pass = 0;
let fail = 0;
const check = (name, cond, detail = "") => {
  if (cond) { pass++; console.log(`PASS ${name}`); }
  else { fail++; console.error(`FAIL ${name}${detail ? ` — ${detail}` : ""}`); }
};

const here = process.cwd();                                  // .../src/code
const build = JSON.parse(readFileSync(join(here, "../../build.json"), "utf8"));
const compose = readFileSync(join(here, "../compose.nix"), "utf8");
const start = readFileSync(join(here, "start.sh"), "utf8");

const repos = build?.runtime?.repos;

// ── D: the declaration ───────────────────────────────────────────────────────
check("D1 build.json declares runtime.repos as a non-empty array",
  Array.isArray(repos) && repos.length > 0, JSON.stringify(repos));
check("D2 every entry names a repo",
  repos.every((r) => typeof r.repo === "string" && r.repo.length > 0),
  JSON.stringify(repos));

const names = new Set(repos.map((r) => r.repo));
const dirs = repos.map((r) => r.dir || r.repo);
check("D3 no duplicate checkout directories", new Set(dirs).size === dirs.length,
  JSON.stringify(dirs));

// ── F: the front family, which is the whole point of the ticket ──────────────
// Sourced from ffront/repos.json, the front registry index — these are its five
// members plus the index itself. Pinned by name so a reshuffle cannot silently
// drop one and leave agents blind to that project again.
const FRONT = [
  "ffront",
  "diegonmarcos.github.io",
  "front-assets-cdn",
  "front-data",
  "front-galaxy-gaia",
  "front-unity",
];
for (const f of FRONT) {
  check(`F:${f} is declared`, names.has(f), `runtime.repos has no "${f}"`);
}

// front members are checked out as front-<thing>; the site repo is the one whose
// GitHub name does not follow that, so it carries an explicit dir.
const site = repos.find((r) => r.repo === "diegonmarcos.github.io");
check("F7 diegonmarcos.github.io checks out as front-diegonmarcos (ffront/repos.json)",
  site?.dir === "front-diegonmarcos", JSON.stringify(site));

// ── C: the pre-#557 repos are still declared ─────────────────────────────────
// Including the three that were only ever cloned by hand. Dropping one here
// would delete it from the tree on the next volume recreate, silently.
for (const r of ["cloud-infra", "cloud-u-containers", "cloud-u-android", "cloud-u-linux",
                 "cloud-data", "cloud-data-my-ai-memory", "cloud-me_vault"]) {
  check(`C:${r} is declared`, names.has(r), `runtime.repos has no "${r}"`);
}
// The vault repo was renamed diegonmarcos/cloud-vault -> cloud-me_vault (#592),
// but everything on the box reads ~/git/cloud-vault, so it keeps that dir.
const vault = repos.find((r) => r.repo === "cloud-me_vault");
check("C-vault cloud-me_vault checks out as cloud-vault (dir override)",
  vault?.dir === "cloud-vault", JSON.stringify(vault));
check("C8 cloud-infra clones with submodules (a_solutions is empty without it)",
  repos.find((r) => r.repo === "cloud-infra")?.submodules === true);

// ── W: the wiring, so the declaration is not decorative ──────────────────────
check("W1 compose.nix emits the declaration as BRIDGE_BOOTSTRAP_REPOS",
  /BRIDGE_BOOTSTRAP_REPOS\s*=\s*builtins\.toJSON rt\.repos/.test(compose),
  "compose.nix does not pass runtime.repos through");
check("W2 compose.nix takes no `or` fallback (absence must fail eval, not mean nothing)",
  !/BRIDGE_BOOTSTRAP_REPOS[^;]*\bor\b/.test(compose),
  "a fallback would be a second declaration of what to clone");
check("W3 start.sh reads BRIDGE_BOOTSTRAP_REPOS",
  /BRIDGE_BOOTSTRAP_REPOS/.test(start), "start.sh ignores the declaration");

// The regression guard: no literal repo list may return to the shell.
const literalLoop = /for\s+repo\s+in\s+[a-z][\w.-]*\s+[a-z][\w.-]*/.test(start);
check("W4 start.sh has NO hardcoded repo loop", !literalLoop,
  "a literal `for repo in <names>` is back in start.sh — that is the second declaration #557 removed");

// An unreadable or empty declaration must be LOUD, not a silent empty ~/git.
check("W5 an empty/unreadable declaration is reported as an ERROR",
  /NO repos bootstrapped/.test(start),
  "start.sh can end up with zero repos without saying so");

console.log(`\n${pass} PASS, ${fail} FAIL`);
if (fail > 0) { console.error("NOT GREEN"); process.exit(1); }
console.log("ALL GREEN");
