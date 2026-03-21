// ── Mailu Health — comprehensive 5-phase diagnostic (5 MCP tools) ──
//
// Phase 1: PRE-FLIGHT — WG tunnel, SSH, Docker daemon, disk space
// Phase 2: CONTAINERS — each container status + crash-loop detection
// Phase 3: NETWORK — TLS ports, SMTP relay, webmail, smtp-proxy, mailu-mcp
// Phase 4: DNS AUTH — MX, DKIM, SPF, DMARC
// Phase 5: E2E DELIVERY — Resend send → IMAP inbox check → CF Worker analysis

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

const MAILU_VM = "oci-E2-f_0";
const MAILU_DOMAIN = "mail.diegonmarcos.com";
const MAILU_WG_IP = "10.0.0.3";
const C3_VM = "oci-A1-f_0";
const MAILU_CONTAINERS = [
  "mailu-front-1", "mailu-admin-1", "mailu-imap-1", "mailu-smtp-1",
  "mailu-antispam-1", "mailu-webmail-1", "mailu-resolver-1", "mailu-redis-1",
];
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
    return { name, passed: false, details: "",
      error: err instanceof Error ? err.message : String(err),
      durationMs: Date.now() - start };
  }
}

function getResendApiKey(): string | null {
  return process.env.RESEND_API_KEY || null;
}

function dnsLookup(type: string, name: string): string {
  const dig = exec("bash", ["-c", `command -v dig >/dev/null 2>&1 && dig +short +time=3 +tries=1 ${type} ${name} 2>&1`]);
  if (dig.ok && dig.stdout.trim()) return dig.stdout.trim();
  if (type === "MX") {
    const r = exec("nslookup", ["-timeout=3", "-type=mx", name], { timeout: 5_000 });
    return (r.stdout + r.stderr).split("\n").filter((l) => l.includes("mail exchanger"))
      .map((l) => l.replace(/.*mail exchanger = /, "").trim()).join("\n") || "";
  }
  if (type === "TXT") {
    const r = exec("nslookup", ["-timeout=3", "-type=txt", name], { timeout: 5_000 });
    return (r.stdout + r.stderr).split("\n").filter((l) => l.includes("text =") || l.includes("v="))
      .map((l) => l.replace(/.*text = /, "").trim()).join("\n") || "";
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

// ═══════════════════════════════════════════════════════════════════════════
// PHASE 1: PRE-FLIGHT — infrastructure reachability
// ═══════════════════════════════════════════════════════════════════════════

function preflight(): Check[] {
  const checks: Check[] = [];

  // WireGuard tunnel to oci-mail
  checks.push(timed("WG tunnel to oci-mail", () => {
    const r = exec("bash", ["-c", `timeout 3 bash -c 'echo > /dev/tcp/${MAILU_WG_IP}/22' 2>&1`]);
    return { passed: r.ok, details: r.ok ? "10.0.0.3:22 reachable" : "WG DOWN — tunnel unreachable" };
  }));

  // SSH to oci-mail
  checks.push(timed("SSH to oci-mail", () => {
    const r = sshExec(MAILU_VM, "echo OK", 8_000);
    return { passed: r.ok && r.stdout.includes("OK"), details: r.ok ? "SSH OK" : `SSH FAILED: ${r.stderr.trim().split("\n")[0]}` };
  }));

  // Docker daemon on oci-mail
  checks.push(timed("Docker daemon", () => {
    const r = sshExec(MAILU_VM, "docker info --format '{{.ServerVersion}}' 2>&1 | head -1", 5_000);
    const version = r.stdout.trim();
    return { passed: r.ok && version.length > 0 && !version.includes("error"), details: r.ok ? `Docker ${version}` : "Docker UNREACHABLE" };
  }));

  // Disk space on oci-mail
  checks.push(timed("Disk space", () => {
    const r = sshExec(MAILU_VM, "df / --output=pcent | tail -1 | tr -d ' %'", 5_000);
    const pct = parseInt(r.stdout.trim(), 10);
    if (isNaN(pct)) return { passed: false, details: "cannot read disk usage" };
    return { passed: pct < 90, details: `${pct}% used${pct >= 80 ? " ⚠️ HIGH" : ""}` };
  }));

  // VM load average
  checks.push(timed("VM load", () => {
    const r = sshExec(MAILU_VM, "cat /proc/loadavg | awk '{print $1, $2, $3}'", 3_000);
    const load = r.stdout.trim();
    const load1 = parseFloat(load.split(" ")[0]);
    return { passed: !isNaN(load1) && load1 < 4, details: `load: ${load}${load1 >= 2 ? " ⚠️ HIGH" : ""}` };
  }));

  return checks;
}

// ═══════════════════════════════════════════════════════════════════════════
// PHASE 2: CONTAINERS — per-container status + crash-loop detection
// ═══════════════════════════════════════════════════════════════════════════

function containerHealth(): Check[] {
  const checks: Check[] = [];

  const { containers, ok } = listContainers(MAILU_VM, true);
  if (!ok) {
    checks.push({ name: "Container listing", passed: false, details: "SSH/Docker unreachable", durationMs: 0 });
    return checks;
  }

  // Check each Mailu container + smtp-proxy
  const targets = [...MAILU_CONTAINERS, "smtp-proxy"];
  for (const name of targets) {
    checks.push(timed(name, () => {
      const c = containers.find((ct) => ct.name === name);
      if (!c) return { passed: false, details: "NOT FOUND" };

      const isUp = c.status.startsWith("Up");
      const isHealthy = c.status.includes("healthy");
      const isRestarting = c.status.includes("Restarting");

      // Crash-loop detection: check restart count
      const restartMatch = c.status.match(/Restarting \((\d+)\)/);
      const restartCount = restartMatch ? parseInt(restartMatch[1], 10) : 0;

      if (isRestarting) return { passed: false, details: `CRASH-LOOPING (restart ${restartCount})` };
      if (!isUp) return { passed: false, details: `DOWN: ${c.status}` };
      return { passed: true, details: c.status.replace(/\s+\(.*/, "") + (isHealthy ? " (healthy)" : "") };
    }));
  }

  // mailu-mcp on oci-apps
  checks.push(timed("mailu-mcp", () => {
    const { containers: c3Containers, ok: c3Ok } = listContainers(C3_VM, true);
    if (!c3Ok) return { passed: false, details: "oci-apps unreachable" };
    const mcp = c3Containers.find((c) => c.name === "mailu-mcp");
    if (!mcp) return { passed: false, details: "NOT FOUND on oci-apps" };
    return { passed: mcp.status.startsWith("Up"), details: mcp.status.replace(/\s+\(.*/, "") };
  }));

  // ── Deep service checks (internal health, not just container status) ──

  // Dovecot auth — tests IMAP user lookup (catches auth-userdb socket errors)
  checks.push(timed("dovecot auth", () => {
    const r = sshExec(MAILU_VM,
      `docker exec mailu-imap-1 doveadm user me@diegonmarcos.com 2>&1 | head -3`, 5_000);
    const ok = r.ok && r.stdout.includes("me@diegonmarcos.com");
    return { passed: ok, details: ok ? "user lookup OK" : `FAILED: ${r.stdout.trim() || r.stderr.trim()}` };
  }));

  // Dovecot IMAP — test actual IMAP login via openssl
  checks.push(timed("dovecot IMAP login", () => {
    const r = sshExec(MAILU_VM,
      `echo "a001 CAPABILITY" | timeout 3 openssl s_client -connect localhost:993 -quiet 2>/dev/null | head -3`, 5_000);
    const ok = r.stdout.includes("IMAP4rev1") || r.stdout.includes("OK");
    return { passed: ok, details: ok ? "IMAP4rev1 OK" : "IMAP not responding" };
  }));

  // Postfix queue — check for stuck emails
  checks.push(timed("postfix queue", () => {
    const r = sshExec(MAILU_VM,
      `docker exec mailu-smtp-1 postqueue -p 2>&1 | tail -1`, 5_000);
    const empty = r.stdout.includes("Mail queue is empty") || r.stdout.includes("is empty");
    const count = r.stdout.match(/-- (\d+) .* Request/)?.[1];
    if (empty) return { passed: true, details: "queue empty" };
    if (count) return { passed: parseInt(count) < 50, details: `${count} messages queued${parseInt(count) >= 20 ? " ⚠️" : ""}` };
    return { passed: true, details: r.stdout.trim().split("\n").slice(-1)[0] || "unknown" };
  }));

  // Rspamd (antispam) — check if learning/scanning works
  checks.push(timed("rspamd antispam", () => {
    const r = sshExec(MAILU_VM,
      `docker exec mailu-antispam-1 curl -sf http://localhost:11334/stat 2>&1 | head -5`, 5_000);
    const ok = r.ok && (r.stdout.includes("scanned") || r.stdout.includes("learned") || r.stdout.includes("ham"));
    return { passed: ok, details: ok ? "rspamd responding" : `rspamd DOWN: ${r.stdout.trim().slice(0, 60) || r.stderr.trim().slice(0, 60)}` };
  }));

  // Redis — check if Mailu's redis is responding
  checks.push(timed("redis", () => {
    const r = sshExec(MAILU_VM,
      `docker exec mailu-redis-1 redis-cli ping 2>&1`, 3_000);
    return { passed: r.stdout.trim() === "PONG", details: r.stdout.trim() === "PONG" ? "PONG" : `FAILED: ${r.stdout.trim()}` };
  }));

  // Mailu admin API — check if admin panel responds
  checks.push(timed("admin API", () => {
    const r = sshExec(MAILU_VM,
      `curl -skL -o /dev/null -w '%{http_code}' --max-time 3 https://localhost:8444/admin/ 2>&1`, 5_000);
    const code = r.stdout.trim();
    return { passed: ["200", "302", "303"].includes(code), details: `HTTP ${code}` };
  }));

  return checks;
}

// ═══════════════════════════════════════════════════════════════════════════
// PHASE 3: NETWORK — ports, endpoints, connectivity
// ═══════════════════════════════════════════════════════════════════════════

function networkChecks(): Check[] {
  const checks: Check[] = [];

  // External TLS ports via Caddy L4
  checks.push(timed("IMAPS :993", () => {
    const r = exec("bash", ["-c", `echo Q | timeout 5 openssl s_client -connect ${MAILU_DOMAIN}:993 2>&1`]);
    return { passed: r.stdout.includes("CONNECTED"), details: r.stdout.includes("CONNECTED") ? "TLS OK" : "unreachable" };
  }));

  checks.push(timed("SMTPS :465", () => {
    const r = exec("bash", ["-c", `echo Q | timeout 5 openssl s_client -connect ${MAILU_DOMAIN}:465 2>&1`]);
    return { passed: r.stdout.includes("CONNECTED"), details: r.stdout.includes("CONNECTED") ? "TLS OK" : "unreachable" };
  }));

  checks.push(timed("SMTP :587 STARTTLS", () => {
    const r = exec("bash", ["-c", `echo Q | timeout 5 openssl s_client -starttls smtp -connect ${MAILU_DOMAIN}:587 2>&1`]);
    return { passed: r.stdout.includes("CONNECTED"), details: r.stdout.includes("CONNECTED") ? "STARTTLS OK" : "unreachable" };
  }));

  // Local SMTP ports on oci-mail
  checks.push(timed("SMTP :25 local relay", () => {
    const r = sshExec(MAILU_VM, `echo QUIT | timeout 3 nc -w3 localhost 25 2>&1 | head -1`, 5_000);
    return { passed: r.stdout.includes("220"), details: r.stdout.trim().split("\n")[0] || "no 220 banner" };
  }));

  checks.push(timed("SMTP :587 local", () => {
    const r = sshExec(MAILU_VM, `echo QUIT | timeout 5 openssl s_client -connect localhost:587 2>&1 | head -3`, 8_000);
    return { passed: r.stdout.includes("CONNECTED"), details: r.stdout.includes("CONNECTED") ? "TLS OK" : "not responding" };
  }));

  // Webmail
  checks.push(timed("Webmail HTTPS", () => {
    const r = exec("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", `https://${MAILU_DOMAIN}/webmail`]);
    const code = r.stdout.trim();
    return { passed: ["200", "301", "302"].includes(code), details: `HTTP ${code}` };
  }));

  checks.push(timed("Webmail internal (WG)", () => {
    const r = sshExec(MAILU_VM, `curl -skL -o /dev/null -w '%{http_code}' --max-time 5 https://${MAILU_WG_IP}:8444/webmail`);
    return { passed: r.stdout.trim() === "200", details: `HTTP ${r.stdout.trim()}` };
  }));

  // smtp-proxy endpoint
  checks.push(timed("smtp-proxy endpoint", () => {
    const r = exec("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", "https://smtp-proxy.diegonmarcos.com/"]);
    const code = r.stdout.trim();
    return { passed: code !== "000" && code !== "502", details: `HTTP ${code}` };
  }));

  // mailu-mcp MCP endpoint
  checks.push(timed("mailu-mcp endpoint", () => {
    const r = exec("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", "https://mcp.diegonmarcos.com/mailu-mcp/mcp"]);
    const code = r.stdout.trim();
    return { passed: ["400", "405", "406"].includes(code), details: `HTTP ${code} (MCP alive)` };
  }));

  return checks;
}

// ═══════════════════════════════════════════════════════════════════════════
// PHASE 4: DNS AUTH — MX, DKIM, SPF, DMARC
// ═══════════════════════════════════════════════════════════════════════════

function dnsAuth(): Check[] {
  const checks: Check[] = [];

  checks.push(timed("MX record", () => {
    const out = dnsLookup("MX", "diegonmarcos.com");
    const ok = out.includes("mx") || out.includes("cloudflare") || out.includes("diegonmarcos");
    return { passed: ok, details: out.split("\n")[0] || "no MX" };
  }));

  checks.push(timed("DKIM record", () => {
    const out = dnsLookup("TXT", "dkim._domainkey.diegonmarcos.com");
    return { passed: out.includes("v=DKIM1"), details: out.includes("v=DKIM1") ? "DKIM1 present" : "missing" };
  }));

  checks.push(timed("SPF record", () => {
    const out = dnsLookup("TXT", "diegonmarcos.com");
    return { passed: out.includes("v=spf1"), details: out.split("\n").find((l) => l.includes("spf1"))?.trim() || "missing" };
  }));

  checks.push(timed("DMARC record", () => {
    const out = dnsLookup("TXT", "_dmarc.diegonmarcos.com");
    return { passed: out.includes("v=DMARC1"), details: out.trim().split("\n")[0] || "missing" };
  }));

  return checks;
}

// ═══════════════════════════════════════════════════════════════════════════
// PHASE 5: E2E DELIVERY — send → verify arrival → analyze pipeline
// ═══════════════════════════════════════════════════════════════════════════

function e2eDelivery(): Check[] {
  const checks: Check[] = [];
  const apiKey = getResendApiKey();

  if (!apiKey) {
    checks.push({ name: "Resend API key", passed: false, details: "RESEND_API_KEY not set", durationMs: 0 });
    return checks;
  }
  checks.push({ name: "Resend API key", passed: true, details: "Found", durationMs: 0 });

  // Send via Resend
  const tag = `health-${Date.now()}`;
  let emailId = "";

  checks.push(timed("Send via Resend", () => {
    const body = JSON.stringify({
      from: `Health Check <${TEST_FROM}>`, to: [TEST_TO],
      subject: `[health-check] inbound ${tag}`,
      text: `Health check ${new Date().toISOString()}. Tag: ${tag}`,
    });
    const r = exec("curl", ["-s", "-X", "POST", "-H", "Content-Type: application/json",
      "-H", `Authorization: Bearer ${apiKey}`, "-d", body, "https://api.resend.com/emails"], { timeout: 10_000 });
    const parsed = JSON.parse(r.stdout || "{}");
    if (parsed.id) { emailId = parsed.id; return { passed: true, details: `id=${parsed.id}` }; }
    return { passed: false, details: parsed.message || r.stderr || "send failed" };
  }));

  if (!emailId) return checks;

  // Poll Resend delivery status
  checks.push(timed("Resend delivery", () => {
    for (let i = 0; i < 3; i++) {
      if (i > 0) exec("bash", ["-c", "sleep 1.5"]);
      const r = exec("curl", ["-s", "-H", `Authorization: Bearer ${apiKey}`,
        `https://api.resend.com/emails/${emailId}`], { timeout: 8_000 });
      const event = JSON.parse(r.stdout || "{}").last_event || "unknown";
      if (event === "delivered") return { passed: true, details: `delivered (poll ${i + 1})` };
      if (event === "bounced") return { passed: false, details: "BOUNCED" };
    }
    return { passed: true, details: "sent (IMAP is ground truth)" };
  }));

  // IMAP inbox check — poll for arrival in Health folder
  checks.push(timed("IMAP arrival (Health folder)", () => {
    for (let i = 0; i < 4; i++) {
      exec("bash", ["-c", "sleep 3"]);
      const r = sshExec(MAILU_VM,
        `docker exec mailu-imap-1 doveadm search -u ${TEST_TO} subject "${tag}" 2>&1 | head -5`, 8_000);
      const found = r.ok && r.stdout.trim().length > 0 && !r.stdout.includes("no results") && !r.stdout.includes("error");
      if (found) return { passed: true, details: `found (poll ${i + 1}, ${(i + 1) * 3}s)` };
    }
    return { passed: false, details: "NOT FOUND after 12s — email lost in pipeline" };
  }));

  // smtp-proxy activity
  checks.push(timed("smtp-proxy logs", () => {
    const logs = sshExec(MAILU_VM, `docker logs smtp-proxy --since 5m 2>&1 | tail -5`, 5_000);
    const access = sshExec(MAILU_VM,
      `docker exec smtp-proxy cat /var/log/nginx/access.log 2>/dev/null | tail -3 || echo none`, 5_000);
    const all = logs.stdout + logs.stderr + access.stdout;
    const hasActivity = all.includes("POST") || all.includes("200") || all.includes("250");
    const hasError = all.includes("502") || all.includes("503") || all.includes("refused");
    if (hasError) return { passed: false, details: `errors: ${all.trim().split("\n").slice(-2).join(" | ")}` };
    if (hasActivity) return { passed: true, details: "delivery activity confirmed" };
    return { passed: true, details: "no logs (IMAP is ground truth)" };
  }));

  // CF Worker analysis
  checks.push(timed("CF Worker path", () => {
    const cfKey = process.env.CF_API_KEY;
    const cfEmail = process.env.CF_API_EMAIL;
    if (!cfKey || !cfEmail) return { passed: true, details: "info: no CF credentials" };
    const r = exec("curl", ["-s", "-H", `X-Auth-Email: ${cfEmail}`, "-H", `X-Auth-Key: ${cfKey}`,
      "https://api.cloudflare.com/client/v4/accounts/e5cb0a0c6f448e54f217de484259f0ae/workers/scripts/email-forwarder"],
      { timeout: 8_000 });
    try {
      const data = JSON.parse(r.stdout);
      const modified = data?.result?.modified_on || "unknown";
      return { passed: true, details: `worker active (modified: ${modified})` };
    } catch {
      return { passed: true, details: "info: CF API response unparseable" };
    }
  }));

  return checks;
}

// ═══════════════════════════════════════════════════════════════════════════
// TOOL REGISTRATION
// ═══════════════════════════════════════════════════════════════════════════

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
    "Quick UP check: pre-flight + containers + network + DNS",
    {},
    async () => safeTool(() => {
      const sections = [
        formatChecks("PRE-FLIGHT", preflight()),
        "",
        formatChecks("CONTAINERS", containerHealth()),
        "",
        formatChecks("NETWORK", networkChecks()),
        "",
        formatChecks("DNS AUTH", dnsAuth()),
      ];
      return sections.join("\n");
    }),
  );

  server.tool(
    "mailu_profile",
    "Deep profile all Mailu containers (CPU, memory, network, disk, ports, health)",
    {},
    async () => safeTool(() => {
      const profiles: Record<string, unknown> = {};
      for (const name of [...MAILU_CONTAINERS, "smtp-proxy"]) {
        try { profiles[name] = profileContainer(name); }
        catch (err: unknown) { profiles[name] = { error: err instanceof Error ? err.message : String(err) }; }
      }
      return `Mailu Container Profiles\n${"─".repeat(60)}\n\n${JSON.stringify(profiles, null, 2)}`;
    }),
  );

  server.tool(
    "mailu_send_test",
    "Inbound delivery test: Resend → CF Worker → smtp-proxy → Mailu → IMAP",
    {},
    async () => safeTool(() => formatChecks("E2E DELIVERY TEST", e2eDelivery())),
  );

  server.tool(
    "mailu_outbound_test",
    "Outbound: SMTP relay + DNS auth (DKIM, SPF, DMARC)",
    {},
    async () => safeTool(() => {
      const checks: Check[] = [];
      // SMTP ports
      checks.push(timed("SMTP :25 relay", () => {
        const r = sshExec(MAILU_VM, `echo QUIT | timeout 3 nc -w3 localhost 25 2>&1 | head -1`, 5_000);
        return { passed: r.stdout.includes("220"), details: r.stdout.trim().split("\n")[0] || "no banner" };
      }));
      checks.push(timed("SMTP :587 submission", () => {
        const r = sshExec(MAILU_VM, `echo QUIT | timeout 5 openssl s_client -connect localhost:587 2>&1 | head -3`, 8_000);
        return { passed: r.stdout.includes("CONNECTED"), details: r.stdout.includes("CONNECTED") ? "TLS OK" : "not responding" };
      }));
      // DNS auth
      checks.push(...dnsAuth());
      return formatChecks("OUTBOUND & DNS AUTH", checks);
    }),
  );

  server.tool(
    "mailu_full",
    "Full 5-phase mail health: pre-flight → containers → network → DNS → e2e delivery",
    {},
    async () => safeTool(() => {
      const sections = [
        formatChecks("1. PRE-FLIGHT", preflight()),
        "",
        formatChecks("2. CONTAINERS", containerHealth()),
        "",
        formatChecks("3. NETWORK", networkChecks()),
        "",
        formatChecks("4. DNS AUTH", dnsAuth()),
        "",
        formatChecks("5. E2E DELIVERY (Resend → CF → smtp-proxy → Mailu → IMAP)", e2eDelivery()),
      ];
      return sections.join("\n");
    }),
  );
}
