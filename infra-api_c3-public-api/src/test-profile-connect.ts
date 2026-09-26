// Tester: Profile ▸ Connect (#566) — POST /profile/connect/{start,fetch}.
//
// Usage (registered in ../build.json#tests, run by per-service-tests.yml):
//   node test-profile-connect.ts
//
// What it proves, reading DERIVED values rather than literals written here:
//   A  identity: no Caddy-stamped X-Auth-User/Remote-User → no identity.
//   B  codes: TTL, cooldown and attempt budget are the ones build.json declares;
//      a code is single-use, bound to the identity that asked, and burns.
//   C  the mail: goes to build.json's mail_to, carries the code, masks on reply.
//   D  missingParts names exactly the absent piece, never "ok" by default.
//   E  the bundle is served AS IS (#589: plaintext in the private vault) — and a
//      file that is still sops-encrypted is REFUSED, because it is exactly the
//      file the phone cannot read (#585); no key, no sops anywhere here.
//   F  compose.nix RENDERED by nix-instantiate carries build.json#profile_connect
//      (env + read-only bundle mount, no key, no sops mount), and re-rendering
//      with a mutated build.json moves the rendered value — it tracks, not coincides.
//
// Missing nix-instantiate FAILS — this tester never skips.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  BundleError,
  CodeStore,
  codeMail,
  identity,
  loadBundle,
  maskAddress,
  missingParts,
  type ProfileConnectCfg,
} from "./code/shared/profile-connect.ts";

let failed = 0;
const t = (name: string, fn: () => void) => {
  try { fn(); console.log(`PASS ${name}`); }
  catch (e) { failed++; console.error(`FAIL ${name}\n     ${(e as Error).message.split("\n").join("\n     ")}`); }
};

const bj = JSON.parse(readFileSync("../build.json", "utf8"));
const pc = bj.profile_connect;
const hs = bj.deploy?.host_sync?.profile_bundle;
assert.ok(hs && typeof hs === "object", "build.json has no deploy.host_sync.profile_bundle — nothing would put the bundle on the VM (#586)");
assert.ok(pc && typeof pc === "object", "build.json has no profile_connect block");

// ── A. identity ────────────────────────────────────────────────────────────
t("A1 X-Auth-User is the identity", () =>
  assert.equal(identity({ "x-auth-user": " c3-infra-mcp-api " }), "c3-infra-mcp-api"));
t("A2 Remote-User (Authelia cookie path) is the identity", () =>
  assert.equal(identity({ "remote-user": "diego" }), "diego"));
t("A3 no stamped header → no identity (mesh IP is not an identity)", () => {
  assert.equal(identity({}), null);
  assert.equal(identity({ "x-auth-user": "   " }), null);
  assert.equal(identity({ authorization: "Bearer x" }), null);
});

// ── B. codes, against the DECLARED budget ──────────────────────────────────
const policy = { codeTtlS: pc.code_ttl_s, resendCooldownS: pc.resend_cooldown_s, maxAttempts: pc.max_attempts };
t("B0 declared budget is sane (ttl > cooldown > 0, attempts ≥ 1)", () => {
  assert.ok(policy.codeTtlS > policy.resendCooldownS && policy.resendCooldownS > 0, JSON.stringify(policy));
  assert.ok(Number.isInteger(policy.maxAttempts) && policy.maxAttempts >= 1);
});
t("B1 a code is 6 digits and single-use", () => {
  const s = new CodeStore(policy);
  const r = s.issue("u", 0);
  assert.ok(r.ok);
  if (!r.ok) return;
  assert.match(r.code, /^[0-9]{6}$/);
  assert.equal(r.expiresIn, pc.code_ttl_s);
  assert.deepEqual(s.verify("u", r.code, 1), { ok: true });
  assert.deepEqual(s.verify("u", r.code, 2), { ok: false, error: "no_code" });
});
t("B2 a code is bound to the identity that asked for it", () => {
  const s = new CodeStore(policy);
  const r = s.issue("alice", 0);
  assert.ok(r.ok);
  if (!r.ok) return;
  assert.deepEqual(s.verify("mallory", r.code, 1), { ok: false, error: "no_code" });
  assert.deepEqual(s.verify("alice", r.code, 2), { ok: true });
});
t("B3 a code expires at exactly the declared TTL", () => {
  const s = new CodeStore(policy);
  const r = s.issue("u", 0);
  assert.ok(r.ok);
  if (!r.ok) return;
  assert.deepEqual(s.verify("u", r.code, pc.code_ttl_s * 1000), { ok: false, error: "expired" });
  const s2 = new CodeStore(policy);
  const r2 = s2.issue("u", 0);
  if (!r2.ok) return assert.fail("issue");
  assert.deepEqual(s2.verify("u", r2.code, pc.code_ttl_s * 1000 - 1), { ok: true });
});
t("B4 wrong guesses count down and the last one burns the code", () => {
  const s = new CodeStore(policy);
  const r = s.issue("u", 0);
  if (!r.ok) return assert.fail("issue");
  const wrong = r.code === "000000" ? "000001" : "000000";
  for (let left = pc.max_attempts - 1; left >= 1; left--) {
    assert.deepEqual(s.verify("u", wrong, 1), { ok: false, error: "bad_code", attemptsLeft: left });
  }
  assert.deepEqual(s.verify("u", wrong, 1), { ok: false, error: "too_many_attempts" });
  assert.deepEqual(s.verify("u", r.code, 2), { ok: false, error: "no_code" }, "the right code must not work after the budget is spent");
});
t("B5 resend inside the declared cooldown is refused; after it, a NEW code replaces the old", () => {
  const s = new CodeStore(policy);
  const a = s.issue("u", 0);
  if (!a.ok) return assert.fail("issue");
  const early = s.issue("u", pc.resend_cooldown_s * 1000 - 1);
  assert.deepEqual(early, { ok: false, error: "cooldown", retryAfter: 1 });
  let b = s.issue("u", pc.resend_cooldown_s * 1000);
  assert.ok(b.ok, "resend at the cooldown boundary must be allowed");
  if (!b.ok) return;
  // Force a distinct code so "old one is dead" is observable.
  for (let i = 0; b.ok && b.code === a.code && i < 5; i++) { s.revoke("u"); b = s.issue("u", pc.resend_cooldown_s * 1000); }
  if (!b.ok) return assert.fail("reissue");
  assert.notEqual(b.code, a.code);
  assert.deepEqual(s.verify("u", a.code, pc.resend_cooldown_s * 1000 + 1), { ok: false, error: "bad_code", attemptsLeft: pc.max_attempts - 1 });
  assert.deepEqual(s.verify("u", b.code, pc.resend_cooldown_s * 1000 + 2), { ok: true });
});
t("B6 revoke kills a live code", () => {
  const s = new CodeStore(policy);
  const r = s.issue("u", 0);
  if (!r.ok) return assert.fail("issue");
  s.revoke("u");
  assert.deepEqual(s.verify("u", r.code, 1), { ok: false, error: "no_code" });
});

// ── C. the mail ────────────────────────────────────────────────────────────
t("C1 the code mail goes to the declared owner mailbox and carries the code", () => {
  const cfg = { mailFrom: pc.mail_from, mailTo: pc.mail_to, codeTtlS: pc.code_ttl_s };
  const raw = codeMail(cfg, "424242", "c3-infra-mcp-api", new Date(0));
  const cut = raw.indexOf("\r\n\r\n");
  const head = raw.slice(0, cut), body = raw.slice(cut + 4);
  assert.match(head, new RegExp(`^To: <${pc.mail_to.replace(/[.]/g, "\\.")}>$`, "m"));
  assert.match(head, new RegExp(`^From: .*<${pc.mail_from.replace(/[.]/g, "\\.")}>$`, "m"));
  assert.ok(body.includes("424242"), "code missing from body");
  assert.ok(body.includes(`${Math.round(pc.code_ttl_s / 60)} minutes`), "TTL in the mail must be the declared one");
  assert.ok(!/\n(?!\r)/.test(raw.replace(/\r\n/g, "")), "bare LF in an RFC 5322 message");
});
t("C2 the reply masks the declared mailbox: first char + domain only", () => {
  const m = maskAddress(pc.mail_to);
  const [local, domain] = pc.mail_to.split("@");
  assert.equal(m, `${local[0]}•@${domain}`);
  if (local.length > 1) assert.ok(!m.includes(local), "local part leaked");
});

// ── D/E. bundle — served as is, ciphertext refused ─────────────────────────
const need = (bin: string, args: string[]) => {
  try { execFileSync(bin, args, { stdio: "pipe" }); return true; } catch { return false; }
};

const work = mkdtempSync(join(tmpdir(), "profile-connect-"));
try {
  // A bundle shaped like cloud-vault E0_configs/profile-secrets.json (#589: plaintext).
  const plain = {
    schema_version: 1,
    mesh: { profiles: { "wg-v4-full": "[Interface]\nPrivateKey = k\n" } },
    about: { name: "N", phone: { pending: true, source: "s", reason: "r" } },
    autocomplete: { lists: ["Personal Data", "Cloud Keys"] },
    _generated: { emitter: "E0_configs/emit.py", tree_sha256: "x" },
  };
  const schema = { schema_version: 1, sections: [{ id: "mesh", label: "Mesh" }] };
  writeFileSync(join(work, pc.bundle_file), JSON.stringify(plain));
  writeFileSync(join(work, pc.schema_file), JSON.stringify(schema));

  const cfg: ProfileConnectCfg = {
    mailTo: pc.mail_to, mailFrom: pc.mail_from, codeTtlS: pc.code_ttl_s,
    resendCooldownS: pc.resend_cooldown_s, maxAttempts: pc.max_attempts,
    bundleDir: work, bundleFile: pc.bundle_file, schemaFile: pc.schema_file,
  };

  t("D1 fully configured → nothing missing", () => assert.deepEqual(missingParts(cfg), []));
  t("D2 each absent part is named, alone", () => {
    assert.deepEqual(missingParts({ ...cfg, bundleFile: "absent.json" }), ["bundle"]);
    assert.deepEqual(missingParts({ ...cfg, schemaFile: "absent.json" }), ["schema"]);
    assert.deepEqual(missingParts({ ...cfg, mailTo: "" }), ["mail_to"]);
    assert.deepEqual(missingParts({ ...cfg, bundleDir: "" }), ["bundle", "schema"]);
  });
  t("E1 the plaintext bundle is served exactly as written, with the schema beside it", () => {
    const out = loadBundle(cfg);
    assert.deepEqual(out.bundle, plain);
    assert.deepEqual(out.schema, schema);
  });
  t("E2 a still-encrypted bundle (sops root) is refused — that file is the #585 silent import", () => {
    const enc = { ...plain, mesh: { profiles: { "wg-v4-full": "ENC[AES256_GCM,data:AAAA,iv:AAAA,tag:AAAA,type:str]" } },
      sops: { age: [{ recipient: "age1x", enc: "" }], mac: "ENC[AES256_GCM,data:AAAA,type:str]" } };
    writeFileSync(join(work, "enc.json"), JSON.stringify(enc));
    assert.throws(() => loadBundle({ ...cfg, bundleFile: "enc.json" }), (e) => {
      assert.ok(e instanceof BundleError, `expected BundleError, got ${(e as Error).constructor.name}`);
      assert.match((e as Error).message, /sops-encrypted/);
      return true;
    });
  });
  t("E3 a bundle without schema_version, or not JSON, is refused with BundleError", () => {
    writeFileSync(join(work, "nover.json"), JSON.stringify({ mesh: {} }));
    assert.throws(() => loadBundle({ ...cfg, bundleFile: "nover.json" }), BundleError);
    writeFileSync(join(work, "junk.json"), "not json");
    assert.throws(() => loadBundle({ ...cfg, bundleFile: "junk.json" }), BundleError);
  });
  t("E4 nothing about a key or sops is declared any more (#589)", () => {
    for (const k of ["age_key_secret", "nix_bin_mount", "host_nix_profile_bin"]) assert.ok(!(k in pc), `${k} still declared`);
    assert.ok(!(readFileSync("./code/shared/profile-connect.ts", "utf8").includes("SOPS_AGE_KEY")), "the app still reaches for an age key");
  });
} finally {
  rmSync(work, { recursive: true, force: true });
}

// ── F. compose.nix renders build.json#profile_connect ──────────────────────
const haveNix = need("nix-instantiate", ["--version"]);
t("F0 nix-instantiate is available (this tester EVALUATES compose.nix)", () =>
  assert.ok(haveNix, "nix-instantiate not on PATH"));
if (haveNix) {
  // Stub the cloud-data services table compose.nix reads (IPs/ports only);
  // everything under test comes from the real build.json.
  const render = (override: string) => JSON.parse(execFileSync("nix-instantiate", [
    "--eval", "--strict", "--json", "--expr", `
      let
        b0 = builtins.fromJSON (builtins.readFile ../build.json);
        b = b0 // { profile_connect = b0.profile_connect // (${override}); };
        stub = { ip = "10.0.0.99"; ports.app = 1; };
        backendSvcs = builtins.listToAttrs (map (k: { name = b.backends.\${k}.service; value = stub; })
          (builtins.attrNames b.backends));
        services = backendSvcs // {
          "c3-public-api" = stub;
          \${b.mail.primary.service} = stub // { extra_ports."25".service = b.mail.primary.via; };
        };
      in (import ./compose.nix { buildJson = b; container = { inherit services; }; }).services`,
  ], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }));

  const svc = render("{}")["c3-public-api"];
  const env = svc.environment ?? {};
  const vols: string[] = svc.volumes ?? [];
  t("F1 rendered env carries every profile_connect value from build.json", () => {
    assert.equal(env.PROFILE_CONNECT_MAIL_TO, pc.mail_to);
    assert.equal(env.PROFILE_CONNECT_MAIL_FROM, pc.mail_from);
    assert.equal(env.PROFILE_CONNECT_CODE_TTL_S, String(pc.code_ttl_s));
    assert.equal(env.PROFILE_CONNECT_RESEND_COOLDOWN_S, String(pc.resend_cooldown_s));
    assert.equal(env.PROFILE_CONNECT_MAX_ATTEMPTS, String(pc.max_attempts));
    assert.equal(env.PROFILE_CONNECT_BUNDLE_DIR, pc.bundle_mount);
    assert.equal(env.PROFILE_CONNECT_BUNDLE_FILE, pc.bundle_file);
    assert.equal(env.PROFILE_CONNECT_SCHEMA_FILE, pc.schema_file);
  });
  t("F2 no key, no sops in the rendered compose (#589)", () => {
    const r = JSON.stringify(svc);
    assert.ok(!r.includes("AGE-SECRET-KEY") && !r.includes("AGE_KEY") && !/sops/i.test(r), "key or sops wiring still rendered");
  });
  t("F3 the bundle dir is mounted READ-ONLY at the declared mount, and nothing else is", () => {
    assert.ok(vols.includes(`${hs.host_dir}:${pc.bundle_mount}:ro`), vols.join(" | "));
    assert.ok(!vols.some((v) => v.includes("/nix/")), `nix mounts still rendered: ${vols.join(" | ")}`);
  });
  t("F4 mutating build.json moves the rendered values (tracks, not coincides)", () => {
    const m = render(`{ mail_to = "mutant@example.invalid"; bundle_mount = "/mutant"; max_attempts = 97; }`)["c3-public-api"];
    assert.equal(m.environment.PROFILE_CONNECT_MAIL_TO, "mutant@example.invalid");
    assert.equal(m.environment.PROFILE_CONNECT_BUNDLE_DIR, "/mutant");
    assert.equal(m.environment.PROFILE_CONNECT_MAX_ATTEMPTS, "97");
    assert.ok((m.volumes as string[]).includes(`${hs.host_dir}:/mutant:ro`));
  });
  t("F5 host_sync ships exactly the files the app reads from the mount (#586)", () => {
    assert.deepEqual([...hs.files].sort(), [pc.bundle_file, pc.schema_file].sort(), JSON.stringify(hs.files));
    assert.ok(hs.host_dir.endsWith(`/${hs.vault_dir}`), `${hs.host_dir} does not end in /${hs.vault_dir}`);
  });
}

if (failed) {
  console.error(`\nNOT GREEN: ${failed} check(s) failed`);
  process.exit(1);
}
console.log("\nGREEN: profile-connect");
