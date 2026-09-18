#!/usr/bin/env node
// Tester — every AI agent container still wires into the ONE agent-toolbelt
// declaration (ticket #509, extends #366/#450's gh/yq/ripgrep guard).
//
// #450's original guard grepped each Dockerfile/build.json for literal
// substrings ("/usr/local/bin/gh", "ripgrep") — it could pass forever even
// after three services drifted into three different tool lists, because
// "the list contains a name" says nothing about what the built image ships.
// This guard instead asserts every declared container is wired to
// _shared/agent-toolbelt.json — the single source _shared/engine.nix reads —
// so drift is structurally impossible: edit the JSON once, every container's
// next build picks it up. The JSON's own apt_packages/binaries floor is
// enforced here too, so the declaration cannot be silently emptied.
//
// Registered via user-ai_hermes-agent/build.json#tests (ticket #486's
// per-service runner); run it directly with `node _shared/test-agent-toolbelt.mjs`.
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const SHARED_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.dirname(SHARED_DIR);

const failures = [];
const pass = (msg) => console.log(`  ✓ ${msg}`);
const fail = (msg) => { console.error(`  ✗ ${msg}`); failures.push(msg); };

const declPath = path.join(SHARED_DIR, "agent-toolbelt.json");
if (!existsSync(declPath)) {
  console.error(`FAIL — ${declPath} does not exist. The single agent-toolbelt declaration is gone.`);
  process.exit(1);
}
const decl = JSON.parse(readFileSync(declPath, "utf8"));

console.log("── 0: the declaration itself is non-trivial ──");
if (!Array.isArray(decl.apt_packages) || decl.apt_packages.length === 0) {
  fail("agent-toolbelt.json#apt_packages is empty or missing");
} else {
  pass(`apt_packages declares ${decl.apt_packages.length} packages`);
}
if (!Array.isArray(decl.binaries) || decl.binaries.length === 0) {
  fail("agent-toolbelt.json#binaries is empty or missing");
} else {
  pass(`binaries declares ${decl.binaries.length} tools to verify`);
}
if (!decl.tarballs?.gh?.version || !decl.tarballs?.yq?.version) {
  fail("agent-toolbelt.json#tarballs.gh/yq is missing a version — gh/yq install would break (#366)");
} else {
  pass(`gh ${decl.tarballs.gh.version} / yq ${decl.tarballs.yq.version} declared`);
}
// sudo is a deliberate judgement call (dispatch #509): these containers run
// unprivileged (uid 10001/10000), so sudo has no privilege to escalate to.
// A future edit re-adding it would be silent scope creep, not a fix.
if (decl.apt_packages.includes("sudo") || decl.binaries.includes("sudo")) {
  fail("agent-toolbelt.json declares sudo — these containers are unprivileged by design; do not add it");
} else {
  pass("sudo correctly excluded (unprivileged containers)");
}

console.log("\n── 1: every declared container resolves to a real file ──");
if (!Array.isArray(decl.containers) || decl.containers.length === 0) {
  fail("agent-toolbelt.json#containers is empty — nothing to guard, adding a 4th container would silently skip this test");
}

for (const c of decl.containers ?? []) {
  if (c.kind === "type-a") {
    const dfPath = path.join(REPO_ROOT, c.dir, c.dockerfile);
    if (!existsSync(dfPath)) {
      fail(`${c.name}: Dockerfile not found at ${c.dir}/${c.dockerfile}`);
      continue;
    }
    const text = readFileSync(dfPath, "utf8");
    for (const token of ["@AGENT_TOOLBELT_APT@", "@AGENT_TOOLBELT_EXTRA_RUN@"]) {
      if (text.includes(token)) {
        pass(`${c.name}: Dockerfile splices ${token}`);
      } else {
        fail(`${c.name}: Dockerfile does not splice ${token} — it has drifted back to a hand-written tool list, disconnected from agent-toolbelt.json`);
      }
    }
  } else if (c.kind === "type-b") {
    const bjPath = path.join(REPO_ROOT, c.dir, c.build_json);
    if (!existsSync(bjPath)) {
      fail(`${c.name}: build.json not found at ${c.dir}/${c.build_json}`);
      continue;
    }
    const bj = JSON.parse(readFileSync(bjPath, "utf8"));
    if (bj.docker?.agent_toolbelt === true) {
      pass(`${c.name}: build.json sets docker.agent_toolbelt=true`);
    } else {
      fail(`${c.name}: build.json does not set docker.agent_toolbelt=true — hermes-agent's toolbelt would fall back to (or lose) its own runtime_packages/runtime_extra_run instead of the shared declaration`);
    }
  } else {
    fail(`${c.name}: unknown kind "${c.kind}" in agent-toolbelt.json#containers`);
  }
}

console.log("");
if (failures.length > 0) {
  console.error(`FAIL — ${failures.length} agent-toolbelt declaration gap(s) found (#509, extends #366/#450)`);
  process.exit(1);
}
console.log(`PASS — all ${decl.containers.length} declared AI containers wire into the single agent-toolbelt.json declaration (${decl.apt_packages.length} apt packages, ${decl.binaries.length} verified binaries).`);
