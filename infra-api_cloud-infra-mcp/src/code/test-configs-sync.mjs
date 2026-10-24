// infra_obs method debug.configs_sync: declared in the enum, reads the configs-sync data repo, allowlists the file name.
// Usage: node --experimental-strip-types test-configs-sync.mjs  (exit 0 = PASS)
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
const src = readFileSync(new URL("./mcp/tools/meta.ts", import.meta.url), "utf8");
assert.match(src, /"debug\.configs_sync"/, "method declared");
assert.equal((src.match(/case "debug\.configs_sync"/g) || []).length, 1, "exactly one handler");
assert.match(src, /cloud_db_infra-ops-obsv_configs-sync/, "served from the data repo");
assert.ok(!/debug\.configs_sync[\s\S]{0,1200}readFileSync/.test(src), "no local copy is read");
console.log("test-configs-sync (mcp): PASS");
