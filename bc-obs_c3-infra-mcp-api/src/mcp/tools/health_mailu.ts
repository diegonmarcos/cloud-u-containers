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
  const dig = exec("bash", ["-c", `command -v dig >/dev/null 2>&1 && dig +short +time=3 +tries=1 ${type} ${name} 2>&1`]);
  if (dig.ok && dig.stdout.trim()) return dig.stdout.trim();
  // Fallback: nslookup
  if (type === "MX") {
    const r = exec("nslookup", ["-timeout=3", "-type=mx", name], { timeout: 5_000 });
    const lines = (r.stdout + r.stderr).split("\n").filter((l) => l.includes("mail exchanger"));
    return lines.map((l) => l.replace(/.*mail exchanger = /, "").trim()).join("\n") || "";
  }
  if (type === "TXT") {
    const r = exec("nslookup", ["-timeout=3", "-type=txt", name], { timeout: 5_000 });
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
    const r = exec("bash", ["-c", `echo Q | timeout 5 openssl s_client -connect ${MAILU_DOMAIN}:993 2>&1`]);
    const connected = r.stdout.includes("CONNECTED");
    const verified = r.stdout.includes("Verify return code: 0");
    return { passed: connected && verified, details: connected ? (verified ? "TLS OK" : "TLS invalid") : "unreachable" };
  }));

  // SMTPS (465) via Caddy L4
  checks.push(timed("SMTPS :465 (Caddy L4)", () => {
    const r = exec("bash", ["-c", `echo Q | timeout 5 openssl s_client -connect ${MAILU_DOMAIN}:465 2>&1`]);
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
    const r = exec("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5",
      `https://${MAILU_DOMAIN}/webmail`]);
    const code = r.stdout.trim();
    return { passed: ["200", "301", "302"].includes(code), details: `HTTP ${code}` };
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
    const hasMx = out.includes("mx") || out.includes("cloudflare") || out.includes("diegonmarcos");
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
  let emailId = "";

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
    if (parsed.id) {
      emailId = parsed.id;
      return { passed: true, details: `id=${parsed.id}` };
    }
    return { passed: false, details: parsed.message || r.stdout || r.stderr };
  }));

  // Poll Resend delivery status
  if (emailId) {
    checks.push(timed("Resend delivery status", () => {
      const maxAttempts = 3;
      for (let attempt = 0; attempt < maxAttempts; attempt++) {
        if (attempt > 0) exec("bash", ["-c", "sleep 1.5"]);
        const r = exec("curl", ["-s", "-H", `Authorization: Bearer ${apiKey}`,
          `https://api.resend.com/emails/${emailId}`], { timeout: 8_000 });
        const parsed = JSON.parse(r.stdout || "{}");
        const event = parsed.last_event || "unknown";
        if (event === "delivered") return { passed: true, details: `delivered (poll ${attempt + 1})` };
        if (event === "bounced" || event === "complained") return { passed: false, details: `${event}` };
      }
      return { passed: false, details: "not delivered after polling" };
    }));

    // IMAP inbox verification — check if email actually arrived in Mailu
    checks.push(timed("IMAP inbox check", () => {
      exec("bash", ["-c", "sleep 2"]); // wait for delivery pipeline
      const r = sshExec(MAILU_VM,
        `docker exec mailu-imap-1 doveadm search -u ${TEST_TO} subject "health-check" subject "${tag}" 2>&1 | head -5`,
        10_000);
      const found = r.ok && r.stdout.trim().length > 0 && !r.stdout.includes("no results");
      return { passed: found, details: found ? `found in inbox` : `NOT in inbox: ${r.stdout.trim() || r.stderr.trim() || "empty"}` };
    }));

    // smtp-proxy logs — did it receive and forward the email?
    checks.push(timed("smtp-proxy delivery log", () => {
      const r = sshExec(MAILU_VM,
        `docker logs smtp-proxy --since 2m 2>&1 | tail -10`,
        8_000);
      const logs = r.stdout + r.stderr;
      const hasDelivery = logs.includes("250") || logs.includes("accepted") || logs.includes("delivered");
      const hasError = logs.includes("error") || logs.includes("refused") || logs.includes("timeout");
      return {
        passed: hasDelivery && !hasError,
        details: hasError ? `ERROR in logs:\n    ${logs.trim().split("\n").slice(-3).join("\n    ")}`
          : hasDelivery ? "delivery confirmed in logs"
          : `no delivery activity:\n    ${logs.trim().split("\n").slice(-3).join("\n    ")}`,
      };
    }));
  }

  return checks;
}

/** Analyze CF Worker logs — detect backup email triggers and delivery failures */
function analyzeWorkerLogs(): Check[] {
  const checks: Check[] = [];
  const workerLogs = fetchWorkerLogs();

  checks.push(timed("CF Worker API access", () => {
    if (workerLogs && typeof workerLogs === "object" && "error" in workerLogs) {
      return { passed: false, details: String((workerLogs as { error: string }).error) };
    }
    return { passed: true, details: "API accessible" };
  }));

  checks.push(timed("CF Worker delivery path", () => {
    const logs = JSON.stringify(workerLogs);
    const deliveredToMailu = logs.includes("delivered to Mailu") || logs.includes("Email delivered");
    const backupTriggered = logs.includes("forwarding to backup") || logs.includes("Insurance copy");
    const deliveryFailed = logs.includes("delivery failed") || logs.includes("SMTP proxy failed");

    if (deliveryFailed) return { passed: false, details: "DELIVERY FAILED — Worker could not reach smtp-proxy" };
    if (backupTriggered) return { passed: false, details: "BACKUP TRIGGERED — emails going to diegonmarcos@live.com instead of Mailu" };
    if (deliveredToMailu) return { passed: true, details: "Primary path OK (smtp-proxy)" };
    return { passed: true, details: "No recent failures detected" };
  }));

  return checks;
}

function mailuOutboundTest(): Check[] {
  const checks: Check[] = [];

  // Outbound: SMTP submission port accepts connections
  checks.push(timed("SMTP submission :587", () => {
    const r = sshExec(MAILU_VM,
      `echo "EHLO healthcheck" | nc -w3 localhost 587 2>&1 | head -3`,
      8_000);
    const hasEhlo = r.stdout.includes("250") || r.stdout.includes("220");
    return { passed: hasEhlo, details: hasEhlo ? "EHLO accepted" : r.stdout.trim().split("\n")[0] || "no response" };
  }));

  // Outbound: Send a real email from Mailu via SMTP (swaks or sendmail)
  checks.push(timed("Outbound: Mailu → external", () => {
    const tag = `outbound-${Date.now()}`;
    // Use Mailu admin CLI to send a test email via the local SMTP relay
    const r = sshExec(MAILU_VM,
      `docker exec mailu-admin-1 flask mailu send-test me@diegonmarcos.com "${tag}" 2>&1 || ` +
      `echo "EHLO test\nMAIL FROM:<health@diegonmarcos.com>\nRCPT TO:<me@diegonmarcos.com>\nDATA\nSubject: [health-outbound] ${tag}\n\nOutbound test\n.\nQUIT" | nc -w5 localhost 25 2>&1 | tail -3`,
      15_000);
    const sent = r.stdout.includes("250") || r.stdout.includes("queued") || r.stdout.includes("OK");
    return { passed: sent, details: sent ? `queued (${tag})` : r.stdout.trim().split("\n").slice(-2).join(" | ") || "send failed" };
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

function safeTool(fn: () => string): { content: [{ type: "text"; text: string }] } {
  try {
    return { content: [{ type: "text" as const, text: fn() }] };
  } catch (err: unknown) {
    const msg = err instanceof Error ? `${err.message}\n${err.stack}` : String(err);
    return { content: [{ type: "text" as const, text: `ERROR: ${msg}` }] };
  }
}

export function registerHealthMailuTools(server: McpServer): void {
  server.tool(
    "mailu_up",
    "Quick UP check: containers, TLS ports (993/465/587), webmail, MX record",
    {},
    async () => safeTool(() => formatChecks("Mailu UP Check", mailuUp())),
  );

  server.tool(
    "mailu_profile",
    "Deep profile all 8 Mailu containers (CPU, memory, network, disk, ports, health)",
    {},
    async () => safeTool(() =>
      `Mailu Container Profiles\n${"─".repeat(60)}\n\n${JSON.stringify(mailuProfile(), null, 2)}`
    ),
  );

  server.tool(
    "mailu_send_test",
    "Inbound delivery test: send email via Resend API → Mailu mailbox",
    {},
    async () => safeTool(() => formatChecks("Mailu Inbound Send Test", mailuSendTestResend())),
  );

  server.tool(
    "mailu_outbound_test",
    "Outbound + DNS auth: SMTP relay, DKIM, SPF, DMARC records",
    {},
    async () => safeTool(() => formatChecks("Mailu Outbound & DNS Auth", mailuOutboundTest())),
  );

  server.tool(
    "mailu_full",
    "Full mail health pipeline: UP + profile + inbound send test + outbound + DNS auth + CF Worker logs",
    {},
    async () => safeTool(() => {
      const sections = [
        formatChecks("1. UP CHECK", mailuUp()),
        "",
        formatChecks("2. OUTBOUND & DNS AUTH", mailuOutboundTest()),
        "",
        formatChecks("3. INBOUND (Resend → CF Worker → smtp-proxy → Mailu → IMAP)", mailuSendTestResend()),
        "",
        formatChecks("4. CF WORKER ANALYSIS", analyzeWorkerLogs()),
      ];
      return sections.join("\n");
    }),
  );
}
