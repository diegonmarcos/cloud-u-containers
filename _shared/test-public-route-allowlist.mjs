// Guard: a build.json route may be public (wg_only:false anywhere in its
// proxy blocks) only if its service is on _shared/public-route-allowlist.json.
// Fleet rule: WG-only fail-closed by default; Caddy is the single SoT.
// Usage: node test-public-route-allowlist.mjs   (cwd = <repo>/_shared); STRICT=1 also fails on pending_owner_review.
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { join, resolve } from "node:path";

const root = resolve(process.cwd(), process.cwd().endsWith("_shared") ? ".." : ".");
const al = JSON.parse(readFileSync(join(root, "_shared/public-route-allowlist.json"), "utf8"));
const allowed = new Set(Object.keys(al.allowed)), pending = new Set(Object.keys(al.pending_owner_review));
const publicIn = (o, acc = []) => {
  if (o && typeof o === "object") for (const [k, v] of Object.entries(o)) {
    if (k === "wg_only" && v === false) acc.push(true); else publicIn(v, acc);
  }
  return acc;
};
let fail = 0;
const bad = (m) => { fail++; console.error(`FAIL ${m}`); };
const publicSvcs = [];
for (const d of readdirSync(root, { withFileTypes: true })) {
  if (!d.isDirectory() || d.name === "z_archive" || d.name.startsWith(".")) continue;
  const f = join(root, d.name, "build.json");
  if (!existsSync(f)) continue;
  if (publicIn(JSON.parse(readFileSync(f, "utf8"))).length) publicSvcs.push(d.name);
}
for (const s of publicSvcs) {
  if (allowed.has(s)) console.log(`PASS ${s} public, allowlisted`);
  else if (pending.has(s)) console.warn(`WARN ${s} public, pending owner review`) , process.env.STRICT && bad(`${s} pending owner review (STRICT)`);
  else bad(`${s} has a public route (wg_only:false) but is not on the allowlist; default is WG-only, remove wg_only:false or add it to _shared/public-route-allowlist.json with a reason`);
}
for (const s of pending) if (!publicSvcs.includes(s)) bad(`${s} is in pending_owner_review but is no longer public; remove it from the list`);
for (const s of allowed) if (!existsSync(join(root, s, "build.json"))) console.warn(`WARN allowlisted ${s} has no build.json here`);
console.log(fail ? `${fail} failed` : "ok");
process.exit(fail ? 1 : 0);
