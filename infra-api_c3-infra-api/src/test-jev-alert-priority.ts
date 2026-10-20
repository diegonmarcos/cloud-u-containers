// #882 S3 guard: "Jev has no opinion" == today's alert priority ("high"). jevAlertPriority returns null for
// every failure mode, so poller.ts's `?? "high"` keeps the hard-coded priority; a confident in-set pick
// re-ranks, never below "default". Also checks the poller still carries the fallback.
// Usage: node test-jev-alert-priority.ts   (exit 0 = PASS)
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { jevAlertPriority } from "./code/shared/libs/jev.ts";

const st = { rule: "cpu", target: "oci-apps", metric: "cpu", op: "gt", threshold: 90, value: 97 };
const json = (b: unknown, ok = true) => (async () => ({ ok, json: async () => b })) as unknown as typeof fetch;
const pick = (p: string, confident = true) => json({ ok: true, results: { priority: { type: "choice", pick: p, p: 0.9, confident } } });
const env = { JEV_TIMEOUT_MS: "200" };

const none: Array<[string, typeof fetch]> = [
  ["sidecar down", (async () => { throw new Error("ECONNREFUSED"); }) as unknown as typeof fetch],
  ["no_key", json({ ok: false, reason: "no_key" })],
  ["gate_closed", json({ ok: false, reason: "gate_closed" })],
  ["HTTP 502", json({}, false)],
  ["malformed", json("<html>")],
  ["not confident", pick("urgent", false)],
  ["priority not offered (min)", pick("min")],
  ["priority not offered (low)", pick("low")],
  ["hangs past the timeout", ((_u: string, init: any) => new Promise((_r, rej) => init.signal.addEventListener("abort", () => rej(new Error("abort"))))) as unknown as typeof fetch],
];
for (const [label, f] of none) assert.equal(await jevAlertPriority(st, f, env), null, label + " -> no opinion");
assert.equal(await jevAlertPriority(st, pick("urgent"), { ...env, JEV_ALERTS: "0" }), null, "JEV_ALERTS=0 -> no opinion");
assert.equal(await jevAlertPriority(st, pick("urgent"), env), "urgent", "a confident urgent re-ranks");
assert.equal(await jevAlertPriority(st, pick("default"), env), "default", "a confident default re-ranks");

const poller = readFileSync(new URL("./code/shared/libs/poller.ts", import.meta.url), "utf8");
assert.match(poller, /jevAlertPriority\([^\n]*\)\) \?\? "high"/, 'poller keeps "high" as the fallback');
console.log("PASS");
