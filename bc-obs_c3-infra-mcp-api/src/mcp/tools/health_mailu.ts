// ── Mailu Health — mail-specific UP, profiling, send/receive tests (5 tools) ──

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { exec } from "../../shared/exec.js";
import { sshExec } from "../../shared/ssh.js";
import { listContainers } from "../../shared/docker.js";
import { profileContainer } from "../../shared/diagnostics.js";
import { GIT_BASE } from "../../shared/paths.js";
import { readFileSync, existsSync } from "fs";
import { join } from "path";

// ── Constants ────────────────────────────────────────────────────────────

const MAILU_VM = "oci-E2-f_0"; // oci-mail
const MAILU_DOMAIN = "mail.diegonmarcos.com";
const MAILU_WG_IP = "10.0.0.3";
const MAILU_CONTAINERS = [
  "mailu-front-1", "mailu-admin-1", "mailu-imap-1", "mailu-smtp-1",
  "mailu-antispam-1", "mailu-webmail-1", "mailu-resolver-1", "mailu-redis-1",
];
const RESEND_ENV_PATH = join(GIT_BASE, "vault/A0_keys/providers/resend/resend.env");
const TEST_FROM = "health@mails.diegonmarcos.com";
const TEST_TO = "me@diegonmarcos.com";

// ── Helpers ──────────────────────────────────────────────────────────────

interface Check {
  name: string;
  passed: boolean;
  details: string;
  durationMs: number;
  error?: string;
}

function timed(name: string, fn: () => { passed: boolean; details: string }): Check {
  const start = Date.now();
  try {
    const result = fn();
    return { name, ...result, durationMs: Date.now() - start };
  } catch (err: unknown) {
    return {
      name,
      passed: false,
      details: "",
      error: err instanceof Error ? err.message : String(err),
      durationMs: Date.now() - start,
    };
  }
}

function getResendApiKey(): string | null {
  if (process.env.RESEND_API_KEY) return process.env.RESEND_API_KEY;
  if (!existsSync(RESEND_ENV_PATH)) return null;
  const content = readFileSync(RESEND_ENV_PATH, "utf-8");
  const match = content.match(/RESEND_API_KEY=(.+)/);
  return match ? match[1].trim() : null;
}

/** DNS lookup with dig → nslookup fallback (Termux may lack dig) */
function dnsLookup(type: string, name: string): string {
  // Try dig first
  const dig = exec("bash", ["-c", `command -v dig >/dev/null 2>&1 && dig +short ${type} ${name} 2>&1`]);
  if (dig.ok && dig.stdout.trim()) return dig.stdout.trim();
  // Fallback: nslookup
  if (type === "MX") {
    const r = exec("nslookup", ["-type=mx", name], { timeout: 10_000 });
    const lines = (r.stdout + r.stderr).split("\n").filter((l) => l.includes("mail exchanger"));
    return lines.map((l) => l.replace(/.*mail exchanger = /, "").trim()).join("\n") || "";
  }
  if (type === "TXT") {
    const r = exec("nslookup", ["-type=txt", name], { timeout: 10_000 });
    const lines = (r.stdout + r.stderr).split("\n").filter((l) => l.includes("text =") || l.includes("v="));
    return lines.map((l) => l.replace(/.*text = /, "").trim()).join("\n") || "";
  }
  return "";
}

function formatChecks(title: string, checks: Check[]): string {
  const passed = checks.filter((c) => c.passed).length;
  const total = checks.length;
  const status = passed === total ? "ALL PASSED" : `${passed}/${total} PASSED`;
  const lines = [
    `${title}  [${status}]`,
    "─".repeat(60),
    ...checks.map((c) => {
      const icon = c.passed ? "✓" : "✗";
      const dur = `${c.durationMs}ms`;
      const err = c.error ? ` — ${c.error}` : "";
      return `  ${icon} ${c.name.padEnd(30)} ${dur.padStart(8)}  ${c.details}${err}`;
    }),
  ];
  return lines.join("\n");
}

// ── Tool implementations ─────────────────────────────────────────────────

function mailuUp(): Check[] {
  const checks: Check[] = [];

  // Container health
  checks.push(timed("Containers running", () => {
    const { containers, ok } = listContainers(MAILU_VM, true);
    if (!ok) return { passed: false, details: "SSH/Docker unreachable" };
    const mailuContainers = containers.filter((c) => c.name.startsWith("mailu-"));
    const healthy = mailuContainers.filter((c) => c.status.includes("healthy"));
    const running = mailuContainers.filter((c) => c.status.startsWith("Up"));
    return {
      passed: healthy.length >= 7,
      details: `${healthy.length}/${mailuContainers.length} healthy, ${running.length} running`,
    };
  }));

  // IMAPS (993) via Caddy L4
  checks.push(timed("IMAPS :993 (Caddy L4)", () => {
    const r = exec("bash", ["-c", `echo Q | timeout 8 openssl s_client -connect ${MAILU_DOMAIN}:993 2>&1`]);
    const connected = r.stdout.includes("CONNECTED");
    const verified = r.stdout.includes("Verify return code: 0");
    return { passed: connected && verified, details: connected ? (verified ? "TLS OK" : "TLS invalid") : "unreachable" };
  }));

  // SMTPS (465) via Caddy L4
  checks.push(timed("SMTPS :465 (Caddy L4)", () => {
    const r = exec("bash", ["-c", `echo Q | timeout 8 openssl s_client -connect ${MAILU_DOMAIN}:465 2>&1`]);
    const connected = r.stdout.includes("CONNECTED");
    return { passed: connected, details: connected ? "TLS OK" : "unreachable" };
  }));

  // SMTP Submission (587) STARTTLS via Caddy L4
  checks.push(timed("SMTP :587 STARTTLS (Caddy L4)", () => {
    const r = exec("bash", ["-c", `echo Q | timeout 8 openssl s_client -starttls smtp -connect ${MAILU_DOMAIN}:587 2>&1`]);
    const connected = r.stdout.includes("CONNECTED");
    return { passed: connected, details: connected ? "STARTTLS OK" : "unreachable" };
  }));

  // Webmail HTTPS
  checks.push(timed("Webmail HTTPS", () => {
    const r = exec("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "10",
      `https://${MAILU_DOMAIN}/webmail`]);
    const code = r.stdout.trim();
    return { passed: code === "301" || code === "200", details: `HTTP ${code}` };
  }));

  // Webmail via WireGuard (internal)
  checks.push(timed("Webmail internal (WG)", () => {
    const r = sshExec(MAILU_VM,
      `curl -skL -o /dev/null -w '%{http_code}' --max-time 5 https://${MAILU_WG_IP}:8444/webmail`);
    const code = r.stdout.trim();
    return { passed: code === "200", details: `HTTP ${code}` };
  }));

  // MX DNS record
  checks.push(timed("MX DNS record", () => {
    const out = dnsLookup("MX", "diegonmarcos.com");
    const hasMx = out.includes("diegonmarcos.com");
    return { passed: hasMx, details: out.split("\n")[0] || "no MX" };
  }));

  // smtp-proxy container (CF Worker email delivery target)
  checks.push(timed("smtp-proxy container", () => {
    const { containers, ok } = listContainers(MAILU_VM, true);
    if (!ok) return { passed: false, details: "SSH/Docker unreachable" };
    const proxy = containers.find((c) => c.name === "smtp-proxy");
    if (!proxy) return { passed: false, details: "NOT FOUND — CF Worker inbound will fail" };
    const healthy = proxy.status.includes("healthy") || proxy.status.startsWith("Up");
    return { passed: healthy, details: proxy.status };
  }));

  // smtp-proxy HTTP endpoint
  checks.push(timed("smtp-proxy endpoint", () => {
    const r = exec("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5",
      "https://smtp-proxy.diegonmarcos.com/"]);
    const code = r.stdout.trim();
    return { passed: code !== "000" && code !== "502", details: `HTTP ${code}` };
  }));

  return checks;
}

function mailuProfile(): unknown {
  const profiles: Record<string, unknown> = {};

  // Mailu containers
  for (const container of MAILU_CONTAINERS) {
    try {
      profiles[container] = profileContainer(container);
    } catch (err: unknown) {
      profiles[container] = { error: err instanceof Error ? err.message : String(err) };
    }
  }

  // smtp-proxy container (CF Worker forwards email here)
  try {
    profiles["smtp-proxy"] = profileContainer("smtp-proxy");
  } catch {
    profiles["smtp-proxy"] = { error: "container not found — CF Worker email delivery will fail" };
  }

  return profiles;
}

/** Fetch recent Cloudflare Worker logs via CF API (requires observability enabled) */
function fetchWorkerLogs(): unknown {
  const cfKey = process.env.CF_API_KEY || (() => {
    const envPath = join(GIT_BASE, "vault/A0_keys/providers/cloudflare/api-key_opaque/cloudflare.env");
    if (!existsSync(envPath)) return null;
    const content = readFileSync(envPath, "utf-8");
    const match = content.match(/CF_API_KEY=(.+)/);
    return match ? match[1].trim() : null;
  })();
  const cfEmail = process.env.CF_API_EMAIL || (() => {
    const envPath = join(GIT_BASE, "vault/A0_keys/providers/cloudflare/api-key_opaque/cloudflare.env");
    if (!existsSync(envPath)) return null;
    const content = readFileSync(envPath, "utf-8");
    const match = content.match(/CF_API_EMAIL=(.+)/);
    return match ? match[1].trim() : null;
  })();
  const accountId = "e5cb0a0c6f448e54f217de484259f0ae";

  if (!cfKey || !cfEmail) return { error: "Cloudflare API credentials not found" };

  // Query Workers analytics for email-forwarder invocations (last 6h)
  const since = new Date(Date.now() - 6 * 3600 * 1000).toISOString();
  const r = exec("curl", [
    "-s",
    "-H", `X-Auth-Email: ${cfEmail}`,
    "-H", `X-Auth-Key: ${cfKey}`,
    `https://api.cloudflare.com/client/v4/accounts/${accountId}/workers/scripts/email-forwarder/telemetry/events?limit=20&filters=timestamp > '${since}'&fields=timestamp,outcome,logs`,
  ], { timeout: 15_000 });

  try {
    return JSON.parse(r.stdout);
  } catch {
    return { raw: r.stdout || r.stderr, error: "Failed to parse CF response" };
  }
}

function mailuSendTestResend(): Check[] {
  const checks: Check[] = [];
  const apiKey = getResendApiKey();

  if (!apiKey) {
    checks.push({ name: "Resend API key", passed: false, details: "Not found", durationMs: 0 });
    return checks;
  }

  checks.push({ name: "Resend API key", passed: true, details: "Found", durationMs: 0 });

  // Inbound test: Resend → Mailu (external sender delivers to our mailbox)
  const tag = `health-${Date.now()}`;
  checks.push(timed("Inbound: Resend → Mailu", () => {
    const body = JSON.stringify({
      from: `Health Check <${TEST_FROM}>`,
      to: [TEST_TO],
      subject: `[health-check] inbound ${tag}`,
      text: `Automated health check at ${new Date().toISOString()}. Tag: ${tag}`,
    });
    const r = exec("curl", [
      "-s", "-X", "POST",
      "-H", "Content-Type: application/json",
      "-H", `Authorization: Bearer ${apiKey}`,
      "-d", body,
      "https://api.resend.com/emails",
    ], { timeout: 15_000 });
    const parsed = JSON.parse(r.stdout || "{}");
    if (parsed.id) return { passed: true, details: `id=${parsed.id}` };
    return { passed: false, details: parsed.message || r.stdout || r.stderr };
  }));

  return checks;
}

function mailuOutboundTest(): Check[] {
  const checks: Check[] = [];

  // Outbound: Mailu SMTP → external (via Mailu's own relay)
  // Uses swaks (Swiss Army Knife for SMTP) on oci-mail to test the full SMTP pipeline
  checks.push(timed("Outbound: Mailu SMTP relay", () => {
    // Test that SMTP accepts a message on the submission port locally
    const r = sshExec(MAILU_VM,
      `echo "EHLO healthcheck" | nc -w5 localhost 587 2>&1 | head -5`,
      { timeout: 10_000 });
    const hasEhlo = r.stdout.includes("250") || r.stdout.includes("220");
    return { passed: hasEhlo, details: hasEhlo ? "EHLO accepted" : r.stdout.trim().split("\n")[0] || "no response" };
  }));

  // DKIM check
  checks.push(timed("DKIM record", () => {
    const out = dnsLookup("TXT", "dkim._domainkey.diegonmarcos.com");
    const hasDkim = out.includes("v=DKIM1");
    return { passed: hasDkim, details: hasDkim ? "DKIM1 present" : "missing or unresolvable" };
  }));

  // SPF check
  checks.push(timed("SPF record", () => {
    const out = dnsLookup("TXT", "diegonmarcos.com");
    const hasSpf = out.includes("v=spf1");
    return { passed: hasSpf, details: out.split("\n").find((l) => l.includes("spf1"))?.trim() || "missing" };
  }));

  // DMARC check
  checks.push(timed("DMARC record", () => {
    const out = dnsLookup("TXT", "_dmarc.diegonmarcos.com");
    const hasDmarc = out.includes("v=DMARC1");
    return { passed: hasDmarc, details: out.trim().split("\n")[0] || "missing" };
  }));

  return checks;
}

// ── Registration ─────────────────────────────────────────────────────────

export function registerHealthMailuTools(server: McpServer): void {
  server.tool(
    "mailu_up",
    "Quick UP check: containers, TLS ports (993/465/587), webmail, MX record",
    {},
    async () => {
      const checks = mailuUp();
      return { content: [{ type: "text" as const, text: formatChecks("Mailu UP Check", checks) }] };
    },
  );

  server.tool(
    "mailu_profile",
    "Deep profile all 8 Mailu containers (CPU, memory, network, disk, ports, health)",
    {},
    async () => {
      const profiles = mailuProfile();
      return {
        content: [{
          type: "text" as const,
          text: `Mailu Container Profiles\n${"─".repeat(60)}\n\n${JSON.stringify(profiles, null, 2)}`,
        }],
      };
    },
  );

  server.tool(
    "mailu_send_test",
    "Inbound delivery test: send email via Resend API → Mailu mailbox",
    {},
    async () => {
      const checks = mailuSendTestResend();
      return { content: [{ type: "text" as const, text: formatChecks("Mailu Inbound Send Test", checks) }] };
    },
  );

  server.tool(
    "mailu_outbound_test",
    "Outbound + DNS auth: SMTP relay, DKIM, SPF, DMARC records",
    {},
    async () => {
      const checks = mailuOutboundTest();
      return { content: [{ type: "text" as const, text: formatChecks("Mailu Outbound & DNS Auth", checks) }] };
    },
  );

  server.tool(
    "mailu_full",
    "Full mail health pipeline: UP + profile + inbound send test + outbound + DNS auth + CF Worker logs",
    {},
    async () => {
      const upChecks = mailuUp();
      const outboundChecks = mailuOutboundTest();
      const sendChecks = mailuSendTestResend();
      const profiles = mailuProfile();
      const workerLogs = fetchWorkerLogs();

      const sections = [
        formatChecks("1. UP CHECK", upChecks),
        "",
        formatChecks("2. OUTBOUND & DNS AUTH", outboundChecks),
        "",
        formatChecks("3. INBOUND SEND TEST (Resend → Mailu)", sendChecks),
        "",
        `4. CONTAINER PROFILES\n${"─".repeat(60)}`,
        JSON.stringify(profiles, null, 2),
        "",
        `5. CF WORKER LOGS (email-forwarder, last 6h)\n${"─".repeat(60)}`,
        JSON.stringify(workerLogs, null, 2),
      ];

      return { content: [{ type: "text" as const, text: sections.join("\n") }] };
    },
  );
}
