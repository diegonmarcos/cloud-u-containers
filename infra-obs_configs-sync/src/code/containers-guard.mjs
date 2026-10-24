#!/usr/bin/env node
// containers-guard.mjs - guards for the C3 Containers data. Exit 1 on any failure.
//   node containers-guard.mjs <cloud-u-containers-root> [served-containers-declared.json]
// 1 every container has a group+category declared in build.json, both in the vocabulary
// 2 each container name is in exactly ONE group+category (no overlap, no duplicate name)
// 3 Infra Apps categories are in the declared order
// 4 the served JSON (if given) lists exactly the container names of the build.json files: no stale, none missing
import fs from "node:fs";
import path from "node:path";
import { derive, loadServices, entriesOf } from "./containers-declared.mjs";

export function check(root, served) {
  const errs = [];
  const vocab = JSON.parse(fs.readFileSync(path.join(root, "_shared", "containers-taxonomy.json"), "utf8"));
  const groups = new Map(vocab.groups.map((g) => [g.label, g.categories]));
  const names = new Map();
  for (const e of loadServices(root).flatMap(entriesOf)) {
    if (e.kind !== "container") continue;
    if (!e.tax) { errs.push(`no taxonomy: ${e.name} (${e.dir})`); continue; }
    if (!groups.has(e.tax.group)) errs.push(`unknown group "${e.tax.group}": ${e.name}`);
    else if (!groups.get(e.tax.group).includes(e.tax.category)) errs.push(`unknown category "${e.tax.category}" in ${e.tax.group}: ${e.name}`);
    if (names.has(e.name)) errs.push(`container name declared twice: ${e.name} (${names.get(e.name)} and ${e.dir})`);
    names.set(e.name, e.dir);
  }
  const d = derive(root);
  const seen = new Map();
  for (const g of d.groups) for (const c of g.categories) for (const n of c.containers) {
    if (seen.has(n)) errs.push(`overlap: ${n} in ${seen.get(n)} and ${g.label}/${c.label}`);
    seen.set(n, `${g.label}/${c.label}`);
  }
  const infra = vocab.groups.find((g) => g.id === "infra").categories;
  const got = d.groups.find((g) => g.id === "infra").categories.map((c) => c.label);
  if (JSON.stringify(infra) !== JSON.stringify(got)) errs.push(`infra category order differs: ${got.join(",")}`);
  if (infra[0] !== "Net-Routing & Security" || infra[infra.length - 1] !== "Ops-dBs-projects") errs.push("infra vocabulary order changed");
  if (served) {
    const s = JSON.parse(fs.readFileSync(served, "utf8"));
    const have = new Set((s.containers || []).map((c) => c.name));
    for (const n of have) if (!names.has(n)) errs.push(`stale in served JSON (no build.json declares it): ${n}`);
    for (const n of names.keys()) if (!have.has(n)) errs.push(`missing from served JSON: ${n}`);
  }
  return errs;
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(new URL(import.meta.url).pathname)) {
  const errs = check(process.argv[2], process.argv[3]);
  if (errs.length) { console.error(errs.join("\n")); process.exit(1); }
  console.log("containers-guard: OK");
}
