// infra_plugin: path confinement runs before any network call; write payload; no child_process.
// Run: node --experimental-strip-types test-plugin-gh.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { confine, PREFIX, scanContent, buildPutPayload, pluginList, pluginRead, pluginWrite, pluginDeploy } from "./mcp/plugin-gh.ts";

const P = PREFIX;
let calls = [];
const mk = (routes = {}) => async (url, init = {}) => {
  calls.push({ url, method: init.method, body: init.body });
  const key = `${init.method} ${url.split("?")[0].replace("https://api.github.com/repos/diegonmarcos/cloud-u-linux/", "")}`;
  const r = routes[key];
  if (!r) return { ok: false, status: 404, json: async () => ({ message: "Not Found" }) };
  return { ok: true, status: 200, json: async () => r };
};

// 1. confinement happens first: bad paths never reach fetch
for (const bad of ["/etc/passwd", "../x", `${P}../../.github/workflows/x.yml`, `${P}a/../b`, "da_my-ai/data/other/x", "da_my-ai/data/claudeX/x", `${P}a\\b`, `${P}a//b`, "C:/x", "", `${P}.`, `${P}sp ace`]) {
  calls = [];
  await assert.rejects(() => pluginRead(mk(), bad, "t"), undefined, `read ${bad}`);
  await assert.rejects(() => pluginList(mk(), bad, "t"), undefined, `list ${bad}`);
  await assert.rejects(() => pluginWrite(mk(), { path: bad, content: "x", sha: "new", message: "m" }, "t"), undefined, `write ${bad}`);
  assert.equal(calls.length, 0, `network called for ${bad}`);
}
assert.equal(confine(P.slice(0, -1)), P);
assert.equal(confine(`${P}settings.base.json`), `${P}settings.base.json`);

// 2. write refuses before network: no token, oversize, secret, private ip, missing sha
calls = [];
const w = (o, t = "t") => pluginWrite(mk(), { path: `${P}a.json`, content: "{}", sha: "abc", message: "m", ...o }, t ?? undefined);
await assert.rejects(() => w({}, null), /token/);
await assert.rejects(() => w({ content: "x".repeat(64 * 1024 + 1) }), /exceeds/);
await assert.rejects(() => w({ content: "-----BEGIN OPENSSH PRIVATE KEY-----" }), /PUBLIC/);
await assert.rejects(() => w({ content: 'api_key = "abcdefghijklmnopqrstuvwxyz0123"' }), /PUBLIC/);
await assert.rejects(() => w({ content: "host 10.0.0.4" }), /PUBLIC/);
await assert.rejects(() => w({ content: "host 192.168.1.5" }), /PUBLIC/);
await assert.rejects(() => w({ sha: "" }), /sha required/);
assert.equal(calls.length, 0, "refusals must not touch the network");
assert.deepEqual(scanContent('{"a":"hello","ip":"8.8.8.8","t":"$TOKEN"}'), []);

// 3. payload + sequence: verify sha, then PUT with sha, main, base64; returns commit + ci url
assert.deepEqual(buildPutPayload("msg", "héllo", "s1"), { message: "msg", content: Buffer.from("héllo").toString("base64"), branch: "main", sha: "s1" });
assert.equal("sha" in buildPutPayload("m", "x", "new"), false);
calls = [];
const path = `${P}a.json`;
const f = mk({
  [`GET ${"contents/" + path}`]: { type: "file", sha: "abc" },
  [`PUT ${"contents/" + path}`]: { commit: { sha: "c0ffee" }, content: { sha: "def" } },
  "GET actions/runs": { workflow_runs: [{ html_url: "https://github.com/diegonmarcos/cloud-u-linux/actions/runs/9" }] },
});
const res = await pluginWrite(f, { path, content: "{}", sha: "abc", message: "m" }, "t");
assert.equal(res.commit, "c0ffee");
assert.match(res.ci, /actions\/runs\/9/);
assert.deepEqual(calls.map((c) => c.method), ["GET", "PUT", "GET"]);
assert.deepEqual(JSON.parse(calls[1].body), { message: "m", content: Buffer.from("{}").toString("base64"), branch: "main", sha: "abc" });
await assert.rejects(() => pluginWrite(f, { path, content: "{}", sha: "stale", message: "m" }, "t"), /mismatch/);
await assert.rejects(() => pluginWrite(mk({ [`GET contents/${path}`]: { type: "symlink", sha: "abc" } }), { path, content: "{}", sha: "abc", message: "m" }, "t"), /symlink/);
await assert.rejects(() => pluginRead(mk({ [`GET contents/${path}`]: { type: "symlink", sha: "abc" } }), path), /symlink/);

// 4. list filters symlinks/submodules; deploy reports not available without a dotfiles workflow
const l = await pluginList(mk({ [`GET contents/${P.slice(0, -1)}`]: [{ type: "file", path: "a", size: 1, sha: "1" }, { type: "symlink", path: "b" }, { type: "dir", path: "c" }] }));
assert.deepEqual(l.map((e) => e.path), ["a", "c"]);
const d = await pluginDeploy(mk({ "GET actions/workflows": { workflows: [{ path: ".github/workflows/ship-my-ai-app.yml", state: "active", id: 1 }] } }), "t");
assert.equal(d.available, false);

// 5. no child_process / exec / eval in the plugin sources
for (const file of ["./mcp/plugin-gh.ts", "./mcp/tools/plugin.ts"]) {
  const src = readFileSync(new URL(file, import.meta.url), "utf8");
  assert.ok(!/child_process|execAsync|execSync|spawn|\beval\(|new Function|exec\.js/.test(src), `${file} must not use process execution`);
}
console.log("ok");
