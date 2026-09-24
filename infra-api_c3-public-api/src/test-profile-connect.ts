// Tester: Profile ▸ Connect (#566) — POST /profile/connect/{start,fetch}.
//
// Usage (registered in ../build.json#tests, run by per-service-tests.yml):
//   nix shell nixpkgs#sops nixpkgs#age --command node test-profile-connect.ts
//
// What it proves, reading DERIVED values rather than literals written here:
//   A  identity: no Caddy-stamped X-Auth-User/Remote-User → no identity.
//   B  codes: TTL, cooldown and attempt budget are the ones build.json declares;
//      a code is single-use, bound to the identity that asked, and burns.
//   C  the mail: goes to build.json's mail_to, carries the code, masks on reply.
//   D  missingParts names exactly the absent piece, never "ok" by default.
//   E  REAL sops/age round trip with a throwaway key minted here: the declared
//      key decrypts; a wrong key fails; an ambient SOPS_AGE_KEY_FILE that WOULD
//      decrypt is ignored (only the declared identity may be used).
//   F  compose.nix RENDERED by nix-instantiate carries build.json#profile_connect
//      (env + read-only bundle mount + sops mount), and re-rendering with a
//      mutated build.json moves the rendered value — it tracks, not coincides.
//
// Missing sops/age/nix-instantiate FAILS — this tester never skips.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  CodeStore,
  DecryptError,
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

// ── D/E. bundle — real sops + age ──────────────────────────────────────────
const need = (bin: string, args: string[]) => {
  try { execFileSync(bin, args, { stdio: "pipe" }); return true; } catch { return false; }
};
const haveSops = need("sops", ["--version"]);
const haveAge = need("age-keygen", ["--help"]) || need("age", ["--version"]);
t("E0 sops and age are on PATH (a missing tool fails, it never skips)", () => {
  assert.ok(haveSops, "sops not on PATH");
  assert.ok(haveAge, "age not on PATH");
});

const work = mkdtempSync(join(tmpdir(), "profile-connect-"));
try {
  if (haveSops && haveAge) {
    const sopsBin = execFileSync("sh", ["-c", "command -v sops"], { encoding: "utf8" }).trim();
    const mint = () => {
      const out = execFileSync("age-keygen", [], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
      const secret = out.split("\n").find((l) => l.startsWith("AGE-SECRET-KEY-1"))!;
      const pub = /public key: (age1[0-9a-z]+)/.exec(out)![1];
      return { secret, pub };
    };
    const server = mint();
    const other = mint();

    // A bundle shaped like cloud-vault configs/profile-secrets.json: nested,
    // with the keyless-readable root keys the emitter leaves in clear.
    const plain = {
      schema_version: 1,
      _generated: { by: "configs/emit.py", tree_sha256: "x" },
      mesh: { profiles: { "wg-v4-full": "[Interface]\nPrivateKey = k\n" } },
      about: { name: "N", phone: { pending: true, source: "s", reason: "r" } },
      autocomplete: { lists: ["Personal Data", "Cloud Keys"] },
    };
    const schema = { schema_version: 1, sections: [{ id: "mesh", label: "Mesh" }] };
    writeFileSync(join(work, "plain.json"), JSON.stringify(plain));
    const enc = execFileSync(sopsBin, [
      "-e", "--age", server.pub, "--unencrypted-regex", "^(schema_version|_generated)$",
      "--input-type", "json", "--output-type", "json", join(work, "plain.json"),
    ], { encoding: "utf8", env: { PATH: process.env.PATH ?? "" } });
    rmSync(join(work, "plain.json"));
    writeFileSync(join(work, pc.bundle_file), enc);
    writeFileSync(join(work, pc.schema_file), JSON.stringify(schema));

    const cfg: ProfileConnectCfg = {
      mailTo: pc.mail_to, mailFrom: pc.mail_from, codeTtlS: pc.code_ttl_s,
      resendCooldownS: pc.resend_cooldown_s, maxAttempts: pc.max_attempts,
      bundleDir: work, bundleFile: pc.bundle_file, schemaFile: pc.schema_file,
      ageKey: server.secret, sopsBin,
    };

    t("E1 the fixture really is ciphertext at rest", () => {
      assert.ok(enc.includes("ENC[AES256_GCM"), "sops did not encrypt");
      assert.ok(!enc.includes("PrivateKey = k"), "plaintext leaked into the ciphertext file");
    });
    t("D1 fully configured → nothing missing", () => assert.deepEqual(missingParts(cfg), []));
    t("D2 each absent part is named, alone", () => {
      assert.deepEqual(missingParts({ ...cfg, ageKey: "" }), ["age_key"]);
      assert.deepEqual(missingParts({ ...cfg, ageKey: "not-a-key" }), ["age_key"]);
      assert.deepEqual(missingParts({ ...cfg, bundleFile: "absent.json" }), ["bundle"]);
      assert.deepEqual(missingParts({ ...cfg, schemaFile: "absent.json" }), ["schema"]);
      assert.deepEqual(missingParts({ ...cfg, sopsBin: join(work, "no-sops") }), ["sops"]);
      assert.deepEqual(missingParts({ ...cfg, mailTo: "" }), ["mail_to"]);
      assert.deepEqual(missingParts({ ...cfg, bundleDir: "" }), ["bundle", "schema"]);
    });
    t("E2 the declared server key decrypts to exactly the bundle, with the schema beside it", () => {
      const out = loadBundle(cfg);
      assert.deepEqual(out.bundle, plain);
      assert.deepEqual(out.schema, schema);
    });
    t("E3 a different key cannot decrypt (DecryptError, no plaintext)", () => {
      assert.throws(() => loadBundle({ ...cfg, ageKey: other.secret }), (e) => {
        assert.ok(e instanceof DecryptError, `expected DecryptError, got ${(e as Error).constructor.name}`);
        assert.ok(!(e as Error).message.includes("PrivateKey = k"), "plaintext in the error");
        return true;
      });
    });
    t("E4 an ambient SOPS_AGE_KEY_FILE that WOULD decrypt is ignored", () => {
      const kf = join(work, "ambient-keys.txt");
      writeFileSync(kf, server.secret + "\n", { mode: 0o600 });
      const prev = process.env.SOPS_AGE_KEY_FILE;
      process.env.SOPS_AGE_KEY_FILE = kf;
      try {
        assert.throws(() => loadBundle({ ...cfg, ageKey: other.secret }), DecryptError);
      } finally {
        if (prev === undefined) delete process.env.SOPS_AGE_KEY_FILE; else process.env.SOPS_AGE_KEY_FILE = prev;
      }
    });
  }
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
    assert.equal(env.PROFILE_CONNECT_AGE_KEY_ENV, pc.age_key_secret);
    assert.equal(env.PROFILE_CONNECT_SOPS_BIN, `${pc.nix_bin_mount}/sops`);
  });
  t("F2 the key is passed by NAME only — no key material in the rendered compose", () =>
    assert.ok(!JSON.stringify(svc).includes("AGE-SECRET-KEY"), "age key material in compose"));
  t("F3 the bundle dir is mounted READ-ONLY at the declared mount, sops beside it", () => {
    assert.ok(vols.includes(`${pc.bundle_host_dir}:${pc.bundle_mount}:ro`), vols.join(" | "));
    assert.ok(vols.includes(`${pc.host_nix_profile_bin}:${pc.nix_bin_mount}:ro`), vols.join(" | "));
    assert.ok(vols.includes("/nix/store:/nix/store:ro"), vols.join(" | "));
  });
  t("F4 mutating build.json moves the rendered values (tracks, not coincides)", () => {
    const m = render(`{ mail_to = "mutant@example.invalid"; bundle_mount = "/mutant"; max_attempts = 97; }`)["c3-public-api"];
    assert.equal(m.environment.PROFILE_CONNECT_MAIL_TO, "mutant@example.invalid");
    assert.equal(m.environment.PROFILE_CONNECT_BUNDLE_DIR, "/mutant");
    assert.equal(m.environment.PROFILE_CONNECT_MAX_ATTEMPTS, "97");
    assert.ok((m.volumes as string[]).includes(`${pc.bundle_host_dir}:/mutant:ro`));
  });
}

if (failed) {
  console.error(`\nNOT GREEN: ${failed} check(s) failed`);
  process.exit(1);
}
console.log("\nGREEN: profile-connect");
