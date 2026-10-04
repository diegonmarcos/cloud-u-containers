// Tests the REAL path policy behind devops.vm.read_file / read_tree / write_file.
// Run: node --experimental-strip-types test-vm-files-policy.mjs
import assert from "node:assert/strict";
import {
  normalizeAbs, readDenied, treeDenied, writeTarget, resolvedInside, looksText, envLine, shq,
  TREE_EXCLUDES,
} from "./shared/libs/vm-files-policy.ts";

let n = 0;
const t = (name, fn) => { fn(); n++; console.log(`ok - ${name}`); };

t("normalize", () => {
  assert.equal(normalizeAbs("/a/./b/../c//d"), "/a/c/d");
  assert.equal(normalizeAbs("relative/x"), null);
  assert.equal(normalizeAbs("/a\nb"), null);
  assert.equal(normalizeAbs("/../../etc"), "/etc");
});

t("reads: secrets refused", () => {
  for (const p of [
    "/run/secrets/db", "/run/secrets", "/opt/containers/x/secrets/token", "/opt/x/app.secrets",
    "/root/.ssh/id_rsa", "/home/u/.ssh/config", "/home/u/.config/sops/age/keys.txt", "/x/age/keys.txt",
    "/srv/id_ed25519", "/etc/ssl/private/site.key", "/a/cert.pem", "/app/.env", "/app/.env.production",
    "/etc/shadow", "/proc/1/environ", "/opt/../run/secrets/x", "/home/u/.gnupg/pubring.kbx",
  ]) assert.ok(readDenied(p), `should refuse ${p}`);
});

t("reads: ordinary paths allowed", () => {
  for (const p of [
    "/etc/hostname", "/opt/containers/caddy/Caddyfile", "/var/log/syslog",
    "/opt/containers/x/secrets.yaml", "/opt/containers/x/.secrets-hash", "/home/appuser/git/_dispatch/RULES.txt",
  ]) assert.equal(readDenied(p), null, `should allow ${p}`);
});

t("tree: broad roots refused", () => {
  for (const p of ["/", "/etc", "/home", "/root", "/run", "/proc"]) assert.ok(treeDenied(p), p);
  assert.equal(treeDenied("/opt/containers/caddy"), null);
  assert.ok(TREE_EXCLUDES.includes("secrets") && TREE_EXCLUDES.includes(".ssh"));
});

t("writes: only under declared root", () => {
  const ok = writeTarget("oci-apps", "cloud-agi-claude", "/home/appuser/git/_dispatch/x/brief.md");
  assert.equal(ok.ok, true);
  assert.equal(ok.path, "/home/appuser/git/_dispatch/x/brief.md");
  for (const [vm, c, p] of [
    ["oci-apps", "cloud-agi-claude", "/home/appuser/git/cloud-infra/x"],
    ["oci-apps", "cloud-agi-claude", "/home/appuser/git/_dispatch/../cloud-infra/x"],
    ["oci-apps", "cloud-agi-claude", "/home/appuser/git/_dispatchX/x"],
    ["oci-apps", "cloud-agi-claude", "/home/appuser/git/_dispatch"],
    ["oci-apps", "cloud-agi-claude", "/home/appuser/git/_dispatch/.env"],
    ["oci-apps", "other", "/home/appuser/git/_dispatch/x"],
    ["gcp-proxy", "cloud-agi-claude", "/home/appuser/git/_dispatch/x"],
    ["oci-apps", "cloud-agi-claude", "rel/x"],
  ]) assert.equal(writeTarget(vm, c, p).ok, false, `${c}@${vm}:${p}`);
  assert.equal(resolvedInside("/home/appuser/git/_dispatch/a", "/home/appuser/git/_dispatch"), true);
  assert.equal(resolvedInside("/home/appuser/git/x", "/home/appuser/git/_dispatch"), false);
});

t("text detection", () => {
  assert.equal(looksText(Buffer.from("héllo\n")), true);
  assert.equal(looksText(Buffer.from([0x41, 0, 0x42])), false);
  assert.equal(looksText(Buffer.from([0xff, 0xfe, 0x80])), false);
});

t("env masking", () => {
  assert.equal(envLine("TZ=Europe/Madrid"), "TZ=Europe/Madrid");
  assert.equal(envLine("PATH=/usr/bin"), "PATH=/usr/bin");
  assert.equal(envLine("DB_PASSWORD=x"), "DB_PASSWORD=***");
  assert.equal(envLine("API_TOKEN=x"), "API_TOKEN=***");
  assert.equal(envLine("WHATEVER=x"), "WHATEVER=***");
});

t("shell quoting", () => {
  assert.equal(shq("a'b"), `'a'\\''b'`);
});

console.log(`${n} passed`);
