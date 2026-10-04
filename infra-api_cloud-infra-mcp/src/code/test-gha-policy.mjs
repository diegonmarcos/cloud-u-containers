// Tests the policy behind devops.workflows.gha_artifacts / gha_artifact_download / gha_rerun_job.
// Run: node --experimental-strip-types test-gha-policy.mjs
import assert from "node:assert/strict";
import { validRepo, validId, validArtifactName, safeRelPath, planInline, rerunnable } from "./shared/libs/gha-policy.ts";

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
console.log(`${n} passed`);
