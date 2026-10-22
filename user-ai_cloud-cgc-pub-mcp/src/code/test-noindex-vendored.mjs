// The vendored AFFiNE upstream trees inside ac_cloud-notes must stay out of the public
// graphrag pass (octocode's relationship analysis livelocks on them: 100% of a core, no LLM
// call, no output, 87 minutes per window, run 39688954936, #1061), while the owner's own
// ac_cloud-notes code stays indexed. One source of truth: build.json noindex_extra.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const bj = JSON.parse(readFileSync(join(here, "../../build.json"), "utf8"));
const extra = bj.runtime.octocode.noindex_extra["cloud-u-android"] ?? [];
let fail = 0;
const check = (ok, msg) => { console.log(`${ok ? "  ok  " : "  FAIL"} ${msg}`); if (!ok) fail = 1; };

for (const p of ["ac_cloud-notes/packages/", "ac_cloud-notes/blocksuite/"]) {
  check(extra.includes(p), `cloud-u-android noindex_extra excludes the vendored upstream tree ${p}`);
}
for (const keep of ["deploy", "docs", "scripts", "sync-server", "tools", "web"]) {
  const hit = extra.find((p) => p === "ac_cloud-notes/" || p === `ac_cloud-notes/${keep}/`);
  check(!hit, `the owner's own ac_cloud-notes/${keep}/ stays indexed`);
}
check(!(bj.runtime.octocode.noindex_patterns ?? []).some((p) => p.includes("ac_cloud-notes")),
  "the vendored trees are declared per repo (noindex_extra), not in the global patterns");
process.exit(fail);
