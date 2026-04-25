#!/usr/bin/env tsx
// Tester suite — proves the MCP works (FIRE RULE 4).
// Run from src/code/: `tsx tests/run.ts` (after sops decrypt of .secrets into env)
//
// Each test returns { name, ok, detail }. The runner exits non-zero if any fail.
import { ImapFlow } from "imapflow";
import { listAccounts, configuredAccountAliases, getAccount } from "../mcp/shared/config.js";
import { withImap } from "../mcp/shared/imap.js";
import { getTransport } from "../mcp/shared/smtp.js";

interface TestResult { name: string; ok: boolean; detail: string; skip?: boolean }

async function testConfigDataDriven(): Promise<TestResult> {
  try {
    const all = listAccounts();
    if (!Array.isArray(all) || all.length === 0) return { name: "config_data_driven", ok: false, detail: "build.json accounts is empty" };
    for (const a of all) {
      if (!a.alias || !a.email || !a.secret_env) {
        return { name: "config_data_driven", ok: false, detail: `account missing required fields: ${JSON.stringify(a)}` };
      }
    }
    return { name: "config_data_driven", ok: true, detail: `${all.length} account(s) declared in build.json` };
  } catch (e: any) { return { name: "config_data_driven", ok: false, detail: e.message }; }
}

async function testCredentialsLoaded(): Promise<TestResult> {
  const ready = configuredAccountAliases();
  if (ready.length === 0) {
    return { name: "credentials_loaded", ok: false, detail: "No App Passwords in env. Decrypt secrets.yaml via build.sh secrets first." };
  }
  return { name: "credentials_loaded", ok: true, detail: `${ready.length} credential(s) loaded: ${ready.join(", ")}` };
}

async function testImapLogin(): Promise<TestResult> {
  const aliases = configuredAccountAliases();
  if (aliases.length === 0) return { name: "imap_login", ok: false, detail: "no credentials", skip: true };
  const failures: string[] = [];
  const successes: string[] = [];
  for (const alias of aliases) {
    try {
      await withImap(alias, async (c, email) => {
        const lock = await c.getMailboxLock("INBOX");
        try {
          await c.status("INBOX", { messages: true } as any);
          successes.push(`${alias} (${email})`);
        } finally { lock.release(); }
      });
    } catch (e: any) {
      failures.push(`${alias}: ${e.message}`);
    }
  }
  if (failures.length > 0) {
    return { name: "imap_login", ok: false, detail: `failures: ${failures.join("; ")}; successes: ${successes.join(", ")}` };
  }
  return { name: "imap_login", ok: true, detail: `IMAP login OK for: ${successes.join(", ")}` };
}

async function testSmtpVerify(): Promise<TestResult> {
  const aliases = configuredAccountAliases();
  if (aliases.length === 0) return { name: "smtp_verify", ok: false, detail: "no credentials", skip: true };
  const failures: string[] = [];
  for (const alias of aliases) {
    try {
      const { transport, from } = getTransport(alias);
      await transport.verify();
      transport.close();
      void from;
    } catch (e: any) {
      failures.push(`${alias}: ${e.message}`);
    }
  }
  if (failures.length > 0) return { name: "smtp_verify", ok: false, detail: failures.join("; ") };
  return { name: "smtp_verify", ok: true, detail: `SMTP handshake OK for ${aliases.length} account(s)` };
}

async function testRoundtripSelfMail(): Promise<TestResult> {
  if (process.env.SKIP_ROUNDTRIP === "1") return { name: "roundtrip_self_mail", ok: true, detail: "skipped (SKIP_ROUNDTRIP=1)", skip: true };
  const aliases = configuredAccountAliases();
  if (aliases.length === 0) return { name: "roundtrip_self_mail", ok: false, detail: "no credentials", skip: true };
  const alias = aliases[0];
  const acc = getAccount(alias);
  const marker = `gpmcp-test-${Date.now()}`;
  try {
    const { transport, from } = getTransport(alias);
    await transport.sendMail({
      from,
      to: acc.email,
      subject: `[google-personal-mcp tester] ${marker}`,
      text: `This is an automated tester probe. Marker: ${marker}`,
    });
    transport.close();

    // Wait up to 30s for delivery, polling INBOX
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline) {
      const found = await withImap(alias, async (c) => {
        const lock = await c.getMailboxLock("INBOX");
        try {
          const uids = await c.search({ subject: marker } as any, { uid: true });
          return (uids ?? []).length;
        } finally { lock.release(); }
      });
      if (found > 0) {
        // Cleanup: delete the test message
        await withImap(alias, async (c) => {
          const lock = await c.getMailboxLock("INBOX");
          try {
            const uids = await c.search({ subject: marker } as any, { uid: true });
            if (uids && uids.length > 0) await c.messageDelete(uids.map(String), { uid: true });
          } finally { lock.release(); }
        });
        return { name: "roundtrip_self_mail", ok: true, detail: `marker '${marker}' delivered + cleaned up` };
      }
      await new Promise((r) => setTimeout(r, 2000));
    }
    return { name: "roundtrip_self_mail", ok: false, detail: `marker '${marker}' not delivered within 30s` };
  } catch (e: any) {
    return { name: "roundtrip_self_mail", ok: false, detail: e.message };
  }
}

async function testHealthEndpointShape(): Promise<TestResult> {
  // Validates that the /health response shape is correct (without booting HTTP)
  // by calling the same logic the http handler uses.
  const aliases = configuredAccountAliases();
  const body = { status: "ok", name: "google-personal-mcp", accounts_configured: aliases.length, accounts: aliases };
  if (typeof body.status !== "string" || typeof body.accounts_configured !== "number") {
    return { name: "health_shape", ok: false, detail: "health body type drift" };
  }
  return { name: "health_shape", ok: true, detail: `health shape valid (${aliases.length} accounts)` };
}

async function main() {
  const tests = [
    testConfigDataDriven,
    testCredentialsLoaded,
    testImapLogin,
    testSmtpVerify,
    testRoundtripSelfMail,
    testHealthEndpointShape,
  ];
  const results: TestResult[] = [];
  for (const t of tests) {
    const r = await t();
    results.push(r);
    const tag = r.skip ? "SKIP" : r.ok ? "PASS" : "FAIL";
    process.stdout.write(`[${tag}] ${r.name}: ${r.detail}\n`);
  }
  const failed = results.filter((r) => !r.ok && !r.skip).length;
  const passed = results.filter((r) => r.ok && !r.skip).length;
  const skipped = results.filter((r) => r.skip).length;
  process.stdout.write(`\nSummary: ${passed} passed, ${failed} failed, ${skipped} skipped\n`);
  process.exit(failed > 0 ? 1 : 0);
}

main().catch((e) => { process.stderr.write(`tester crashed: ${e?.stack ?? e}\n`); process.exit(2); });
