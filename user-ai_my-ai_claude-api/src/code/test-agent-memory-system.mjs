// Tester: ticket #556 — the agents actually have the memory system.
//
// THE DEFECT: a-context-inject-memory.sh has been called "inject-memory" since
// it was written and injected NO memory — only the principles checklist. A real
// store was mounted the whole time in the shared tree (a 72-line MEMORY.md index
// over ~169 entries under memory-entries/{feedback,project,reference}). Every
// agent that ever ran on oci-apps started with zero recall, and nothing said so,
// because the hook's own NAME made it look handled. That is the worst version of
// this failure: not a broken feature, an absent one wearing the label of a
// present one.
//
// Two properties this pins, and they pull against each other:
//   INDEX ONLY — entries are read on demand. A layout where the entry directory
//   auto-loads has already turned a 4.5k-token preload into 87k once; injecting
//   the entries here would repeat it on every agent session.
//   ABSENCE IS LOUD — a hook that silently emits nothing is indistinguishable
//   from one whose memory is merely empty. The agent must be TOLD it has no
//   recall, or it will answer from the conversation as though it did.
//
// Usage: node test-agent-memory-system.mjs   (cwd = <repo>/user-ai_my-ai_claude-api/src/code)
import { readFileSync } from "node:fs";
import { join } from "node:path";

let pass = 0;
let fail = 0;
const check = (name, cond, detail = "") => {
  if (cond) { pass++; console.log(`PASS ${name}`); }
  else { fail++; console.error(`FAIL ${name}${detail ? ` — ${detail}` : ""}`); }
};

const here = process.cwd();
const build = JSON.parse(readFileSync(join(here, "../../build.json"), "utf8"));
const compose = readFileSync(join(here, "../compose.nix"), "utf8");
const hook = readFileSync(join(here, "claude-config/hooks/a-context-inject-memory.sh"), "utf8");
const mem = build?.runtime?.memory;

// ── D: the declaration ──────────────────────────────────────────────────────
check("D1 build.json declares runtime.memory", !!mem && typeof mem === "object", JSON.stringify(mem));
for (const k of ["dir", "index", "entries"]) {
  check(`D2:${k} is declared`, typeof mem?.[k] === "string" && mem[k].length > 0, JSON.stringify(mem?.[k]));
}
check("D3 the entry types are an enumerated list",
  Array.isArray(mem?.types) && mem.types.length > 0, JSON.stringify(mem?.types));
check("D4 the store lives in the SHARED tree, not a private path",
  /^git\//.test(mem?.dir || ""), `dir=${mem?.dir} — must be under the mounted git tree`);

// ── W: the wiring ───────────────────────────────────────────────────────────
check("W1 compose.nix emits AGENT_MEMORY_DIR", /AGENT_MEMORY_DIR\s*=/.test(compose));
check("W2 the path is DERIVED from the declaration, not retyped",
  /AGENT_MEMORY_DIR\s*=\s*"\$\{home\}\/\$\{rt\.memory\.dir\}"/.test(compose),
  "a hardcoded path here would be a second declaration of where memory lives");
for (const v of ["AGENT_MEMORY_INDEX", "AGENT_MEMORY_ENTRIES", "AGENT_MEMORY_TYPES"]) {
  check(`W3:${v} is emitted`, new RegExp(`${v}\\s*=`).test(compose));
}
check("W4 the hook reads the declaration", /AGENT_MEMORY_DIR/.test(hook));

// ── I: index only ───────────────────────────────────────────────────────────
check("I1 the hook cats the INDEX", /cat "\$\{_mem_dir\}\/\$\{_mem_index\}"/.test(hook));
// The load-bearing negative: never bulk-read the entry tree at session start.
const bulk = /cat\s+[^\n]*\$\{?_mem_entries/.test(hook)
          || /find\s+[^\n]*_mem_entries[^\n]*-exec\s+cat/.test(hook);
check("I2 the hook NEVER bulk-reads the entries", !bulk,
  "injecting memory-entries/ at session start is the 4.5k→87k preload blowup");

// ── L: absence is loud ──────────────────────────────────────────────────────
check("L1 an unset AGENT_MEMORY_DIR is announced", /MEMORY: UNAVAILABLE/.test(hook));
check("L2 an unreadable index is announced", /MEMORY: UNREACHABLE/.test(hook));
check("L3 both say the agent has NO recall, not merely 'no memory found'",
  (hook.match(/WITHOUT recall/g) || []).length >= 2,
  "the agent must know it is answering without memory, not assume empty == none exists");

// ── R: the write rule travels with the read ─────────────────────────────────
// An agent that can read but not write the store accumulates nothing.
check("R1 the hook states where a NEW entry goes", /memory-entries|_mem_entries/.test(hook) && /<type>/.test(hook));
check("R2 the hook states the index gets ONE pointer line", /ONE line/.test(hook));
check("R3 the hook forbids putting entry content in the index",
  /NEVER put entry content in the index/.test(hook));
check("R4 recalled entries are flagged as possibly stale",
  /VERIFY it still exists/.test(hook),
  "a memory naming a deleted file must not be acted on blind");

console.log(`\n${pass} PASS, ${fail} FAIL`);
if (fail > 0) { console.error("NOT GREEN"); process.exit(1); }
console.log("ALL GREEN");
