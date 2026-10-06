// Tests the policy behind devops.workflows.gha_artifacts / gha_artifact_download / gha_rerun_job.
// Run: node --experimental-strip-types test-gha-policy.mjs
import assert from "node:assert/strict";
import { validRepo, validId, validArtifactName, safeRelPath, planInline, rerunnable, validSha, cancellable, grepLines, validPsPattern } from "./shared/libs/gha-policy.ts";

let n = 0;
const t = (name, fn) => { fn(); n++; console.log(`ok - ${name}`); };

t("repo", () => {
  assert.ok(validRepo("diegonmarcos/cloud-u-containers"));
  for (const r of ["x", "a/b/c", "a/..", "-a b/c", "a/b;rm", ""]) assert.equal(validRepo(r), false, r);
});
t("ids", () => {
  assert.ok(validId("37146173596"));
  for (const i of ["0", "-1", "12a", "", "1 2", "--debug"]) assert.equal(validId(i), false, i);
});
t("artifact name", () => {
  assert.ok(validArtifactName("dist-arm64"));
  for (const a of ["", "../x", "a/b", "-n", "..", "a\nb"]) assert.equal(validArtifactName(a), false, a);
});
t("extracted paths", () => {
  assert.equal(safeRelPath("./a/b.txt"), "a/b.txt");
  for (const p of ["/etc/passwd", "../x", "a/../../x", ""]) assert.equal(safeRelPath(p), null, p);
});
t("inline plan caps", () => {
  const p = planInline([{ path: "a", size: 10 }, { path: "big", size: 300 }, { path: "b", size: 80 }, { path: "c", size: 20 }], 100, 200);
  assert.deepEqual(p.inline, ["a", "b"]);
  assert.deepEqual(p.skipped, ["big", "c"]);
});
t("rerun only finished runs", () => {
  assert.ok(rerunnable("completed"));
  for (const s of ["in_progress", "queued", undefined]) assert.equal(rerunnable(s), false);
});
t("sha", () => {
  assert.ok(validSha("eb0111daa")); assert.ok(validSha("f3ca976c7844b56b2c2628bbdda9a98ad6a9d10b"));
  for (const x of ["", "abc", "zzzzzzz", "eb0111daa;rm", "--all"]) assert.equal(validSha(x), false, x);
});
t("cancel only unfinished runs", () => {
  for (const s of ["in_progress", "queued", "waiting", "pending"]) assert.ok(cancellable(s), s);
  for (const s of ["completed", undefined, ""]) assert.equal(cancellable(s), false, String(s));
});
t("grep lines with context", () => {
  const L = ["a", "b", "ERROR one", "c", "d", "e", "error two", "f"];
  assert.deepEqual(grepLines(L, "error"), ["ERROR one", "error two"]);
  assert.deepEqual(grepLines(L, "error", 1), ["b", "ERROR one", "c", "--", "e", "error two", "f"]);
  assert.deepEqual(grepLines(L, "(unclosed"), []);           // literal fallback, no match, no throw
  assert.deepEqual(grepLines(["x (unclosed y"], "(unclosed"), ["x (unclosed y"]);
  assert.equal(grepLines(L, ""), null);
  assert.equal(grepLines(L, "x".repeat(201)), null);
});
t("ps pattern", () => {
  for (const p of ["octocode", "Runner.Worker", "gradle daemon", "/usr/bin/node"]) assert.ok(validPsPattern(p), p);
  for (const p of ["", "a'b", "a;b", "$(id)", "a|b", "`x`", "-ef", "x".repeat(81)]) assert.equal(validPsPattern(p), false, p);
});
console.log(`${n} passed`);
