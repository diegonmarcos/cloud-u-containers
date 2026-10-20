// #883 S12 guard: "Jev has no opinion" == today's GHA error report. jevFlake returns an empty line for every
// failure/doubt, so workflowsGhaErrors adds nothing; an opinion adds exactly one advisory line.
// Run: node --experimental-strip-types test-jev-flake.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { jevFlake } from "./shared/libs/jev-flake.ts";

const env = { JEV_TIMEOUT_MS: "200" };
const tail = ["npm ERR! network timeout", "Process completed with exit code 1."];
const json = (b, ok = true) => async () => ({ ok, json: async () => b });
const flake = (value, confident = true) => json({ ok: true, call: "c1", results: { flake: { type: "noul", value, p: 0.93, confident } } });

const none = {
  "sidecar down": async () => { throw new Error("ECONNREFUSED"); },
  no_key: json({ ok: false, reason: "no_key" }),
  gate_closed: json({ ok: false, reason: "gate_closed", call: "c0" }),
  "HTTP 502": json({}, false),
  malformed: json("<html>"),
  "not confident": flake(true, false),
  hangs: (_u, init) => new Promise((_r, rej) => init.signal.addEventListener("abort", () => rej(new Error("abort")))),
};
for (const [label, f] of Object.entries(none)) assert.equal((await jevFlake("ship", tail, f, env)).line, "", label + " -> report unchanged");
assert.equal((await jevFlake("ship", [], flake(true), env)).line, "", "an empty log is not asked");
assert.equal((await jevFlake("ship", tail, flake(true), { ...env, JEV_GHA: "0" })).line, "", "JEV_GHA=0");
const yes = await jevFlake("ship", tail, flake(true), env);
assert.match(yes.line, /^ {2}Jev suggests: likely a FLAKE/);
assert.equal(yes.call, "c1");
assert.match((await jevFlake("ship", tail, flake(false), env)).line, /REAL failure/);

const src = readFileSync(new URL("./mcp/tools/workflows.ts", import.meta.url), "utf8");
assert.match(
  src,
  /const advice = await jevFlake\(r\.workflowName, relevant\);\n\s+if \(advice\.line\) sections\.push\(advice\.line\);/,
  "the report only gains a line when there is one",
);
console.log("PASS");
