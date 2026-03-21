// ── Mailu Health — comprehensive 6-phase async diagnostic (5 MCP tools) ──
//
// Phase 1: PRE-FLIGHT — WG tunnel, SSH, Docker daemon, disk, load, memory
// Phase 2: CONTAINERS — status + crash-loop + restart count + deep service checks
// Phase 3: NETWORK — TLS ports + cert expiry, SMTP relay, webmail, endpoints
// Phase 4: DNS AUTH — MX, DKIM, SPF, DMARC
// Phase 5: MAIL INTERNALS — dovecot auth/IMAP, postfix queue, rspamd, redis, sieve, quota
// Phase 6: E2E DELIVERY — Resend → IMAP arrival → smtp-proxy → CF Worker

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { exec } from "../../shared/exec.js";
import { sshExec } from "../../shared/ssh.js";
import { listContainers } from "../../shared/docker.js";
import { profileContainer } from "../../shared/diagnostics.js";
import { execSync } from "child_process";

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

interface Check { name: string; passed: boolean; details: string; durationMs: number; error?: string; }

function timed(name: string, fn: () => { passed: boolean; details: string }): Check {
  const start = Date.now();
  try { return { name, ...fn(), durationMs: Date.now() - start }; }
  catch (err: unknown) { return { name, passed: false, details: "", error: err instanceof Error ? err.message : String(err), durationMs: Date.now() - start }; }
}

async function timedAsync(name: string, fn: () => Promise<{ passed: boolean; details: string }>): Promise<Check> {
  const start = Date.now();
  try { return { name, ...(await fn()), durationMs: Date.now() - start }; }
  catch (err: unknown) { return { name, passed: false, details: "", error: err instanceof Error ? err.message : String(err), durationMs: Date.now() - start }; }
}

function ssh(cmd: string, timeout = 8_000) { return sshExec(MAILU_VM, cmd, timeout); }
function getResendApiKey(): string | null { return process.env.RESEND_API_KEY || null; }

function dnsLookup(type: string, name: string): string {
  const dig = exec("bash", ["-c", `command -v dig >/dev/null 2>&1 && dig +short +time=3 +tries=1 ${type} ${name} 2>&1`]);
  if (dig.ok && dig.stdout.trim()) return dig.stdout.trim();
  const flag = type === "MX" ? "mx" : "txt";
  const r = exec("nslookup", ["-timeout=3", `-type=${flag}`, name], { timeout: 5_000 });
  const lines = (r.stdout + r.stderr).split("\n");
  if (type === "MX") return lines.filter((l) => l.includes("mail exchanger")).map((l) => l.replace(/.*mail exchanger = /, "").trim()).join("\n") || "";
  return lines.filter((l) => l.includes("text =") || l.includes("v=")).map((l) => l.replace(/.*text = /, "").trim()).join("\n") || "";
}

function formatChecks(title: string, checks: Check[]): string {
  const passed = checks.filter((c) => c.passed).length;
  const total = checks.length;
  const status = passed === total ? "ALL PASSED" : `${passed}/${total} PASSED`;
  return [`${title}  [${status}]`, "─".repeat(60),
    ...checks.map((c) => `  ${c.passed ? "✓" : "✗"} ${c.name.padEnd(30)} ${`${c.durationMs}ms`.padStart(8)}  ${c.details}${c.error ? ` — ${c.error}` : ""}`)
  ].join("\n");
}

// ═══════════════════════════════════════════════════════════════════════════
// PHASE 1: PRE-FLIGHT
// ═══════════════════════════════════════════════════════════════════════════

function preflight(): Check[] {
  return [
    timed("WG tunnel", () => {
      const r = exec("bash", ["-c", `timeout 3 bash -c 'echo > /dev/tcp/${MAILU_WG_IP}/22' 2>&1`]);
      return { passed: r.ok, details: r.ok ? `${MAILU_WG_IP}:22 OK` : "WG DOWN" };
    }),
    timed("SSH", () => {
      const r = ssh("echo OK", 8_000);
      return { passed: r.ok && r.stdout.includes("OK"), details: r.ok ? "OK" : `FAILED: ${r.stderr.trim().split("\n")[0]}` };
    }),
    timed("Docker daemon", () => {
      const r = ssh("docker info --format '{{.ServerVersion}}' 2>&1 | head -1", 5_000);
      return { passed: r.ok && !r.stdout.includes("error"), details: `Docker ${r.stdout.trim()}` };
    }),
    timed("Disk space", () => {
      const r = ssh("df / --output=pcent | tail -1 | tr -d ' %'", 3_000);
      const pct = parseInt(r.stdout.trim());
      return { passed: !isNaN(pct) && pct < 90, details: `${pct}% used${pct >= 80 ? " ⚠️" : ""}` };
    }),
    timed("Memory", () => {
      const r = ssh("free -m | awk '/Mem:/{printf \"%d/%dMB (%.0f%%)\", $3, $2, $3/$2*100}'", 3_000);
      const pct = parseInt(r.stdout.match(/\((\d+)%\)/)?.[1] || "0");
      return { passed: pct < 95, details: r.stdout.trim() + (pct >= 85 ? " ⚠️" : "") };
    }),
    timed("Load", () => {
      const r = ssh("cat /proc/loadavg | awk '{print $1, $2, $3}'", 3_000);
      const l = parseFloat(r.stdout.split(" ")[0]);
      return { passed: !isNaN(l) && l < 4, details: `load: ${r.stdout.trim()}${l >= 2 ? " ⚠️" : ""}` };
    }),
  ];
}

// ═══════════════════════════════════════════════════════════════════════════
// PHASE 2: CONTAINERS + restart counts
// ═══════════════════════════════════════════════════════════════════════════

function containerHealth(): Check[] {
  const checks: Check[] = [];
  const { containers, ok } = listContainers(MAILU_VM, true);
  if (!ok) { checks.push({ name: "Container listing", passed: false, details: "SSH/Docker unreachable", durationMs: 0 }); return checks; }

  // Container status + restart count (via docker inspect)
  const restartData = ssh(
    `docker inspect --format '{{.Name}}\t{{.RestartCount}}' $(docker ps -aq --filter name=mailu --filter name=smtp-proxy) 2>/dev/null | tr -d '/'`, 5_000
  );
  const restartMap = new Map<string, number>();
  for (const line of restartData.stdout.trim().split("\n")) {
    const [name, count] = line.split("\t");
    if (name) restartMap.set(name, parseInt(count) || 0);
  }

  for (const name of [...MAILU_CONTAINERS, "smtp-proxy"]) {
    checks.push(timed(name, () => {
      const c = containers.find((ct) => ct.name === name);
      if (!c) return { passed: false, details: "NOT FOUND" };
      const isUp = c.status.startsWith("Up");
      const isHealthy = c.status.includes("healthy");
      const isRestarting = c.status.includes("Restarting");
      const restarts = restartMap.get(name) || 0;
      const restartWarn = restarts > 3 ? ` ⚠️ ${restarts} restarts` : "";
      if (isRestarting) return { passed: false, details: `CRASH-LOOPING (${restarts} restarts)` };
      if (!isUp) return { passed: false, details: `DOWN: ${c.status}` };
      return { passed: restarts < 10, details: `${c.status.replace(/\s+\(.*/, "")}${isHealthy ? " (healthy)" : ""}${restartWarn}` };
    }));
  }

  // mailu-mcp on oci-apps
  checks.push(timed("mailu-mcp", () => {
    const { containers: c3c, ok: c3ok } = listContainers(C3_VM, true);
    if (!c3ok) return { passed: false, details: "oci-apps unreachable" };
    const mcp = c3c.find((c) => c.name === "mailu-mcp");
    if (!mcp) return { passed: false, details: "NOT FOUND" };
    return { passed: mcp.status.startsWith("Up"), details: mcp.status.replace(/\s+\(.*/, "") };
  }));

  return checks;
}

// ═══════════════════════════════════════════════════════════════════════════
// PHASE 3: NETWORK + TLS cert expiry
// ═══════════════════════════════════════════════════════════════════════════

function networkChecks(): Check[] {
  const checks: Check[] = [];

  // TLS ports with cert expiry check
  for (const [port, proto] of [["993", ""], ["465", ""], ["587", "-starttls smtp"]] as const) {
    checks.push(timed(`TLS :${port}`, () => {
      const r = exec("bash", ["-c", `echo Q | timeout 5 openssl s_client ${proto} -connect ${MAILU_DOMAIN}:${port} 2>&1`]);
      if (!r.stdout.includes("CONNECTED")) return { passed: false, details: "unreachable" };
      // Extract cert expiry
      const expiry = r.stdout.match(/Not After\s*:\s*(.+)/)?.[1]?.trim();
      if (expiry) {
        const days = Math.floor((new Date(expiry).getTime() - Date.now()) / 86400000);
        return { passed: days > 7, details: `TLS OK, expires in ${days}d${days < 14 ? " ⚠️" : ""}` };
      }
      return { passed: true, details: "TLS OK" };
    }));
  }

  // Local SMTP
  checks.push(timed("SMTP :25 relay", () => {
    const r = ssh(`echo QUIT | timeout 3 nc -w3 localhost 25 2>&1 | head -1`, 5_000);
    return { passed: r.stdout.includes("220"), details: r.stdout.trim().split("\n")[0] || "no banner" };
  }));
  checks.push(timed("SMTP :587 local TLS", () => {
    const r = ssh(`echo QUIT | timeout 5 openssl s_client -connect localhost:587 2>&1 | head -3`, 8_000);
    return { passed: r.stdout.includes("CONNECTED"), details: r.stdout.includes("CONNECTED") ? "TLS OK" : "not responding" };
  }));

  // HTTP endpoints
  checks.push(timed("Webmail HTTPS", () => {
    const r = exec("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", `https://${MAILU_DOMAIN}/webmail`]);
    return { passed: ["200", "301", "302"].includes(r.stdout.trim()), details: `HTTP ${r.stdout.trim()}` };
  }));
  checks.push(timed("Webmail internal", () => {
    const r = ssh(`curl -skL -o /dev/null -w '%{http_code}' --max-time 5 https://${MAILU_WG_IP}:8444/webmail`);
    return { passed: r.stdout.trim() === "200", details: `HTTP ${r.stdout.trim()}` };
  }));
  checks.push(timed("smtp-proxy", () => {
    const r = exec("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", "https://smtp-proxy.diegonmarcos.com/"]);
    return { passed: r.stdout.trim() !== "000" && r.stdout.trim() !== "502", details: `HTTP ${r.stdout.trim()}` };
  }));
  checks.push(timed("mailu-mcp MCP", () => {
    const r = exec("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", "https://mcp.diegonmarcos.com/mailu-mcp/mcp"]);
    return { passed: ["400", "405", "406"].includes(r.stdout.trim()), details: `HTTP ${r.stdout.trim()} (alive)` };
  }));

  return checks;
}

// ═══════════════════════════════════════════════════════════════════════════
// PHASE 4: DNS AUTH
// ═══════════════════════════════════════════════════════════════════════════

function dnsAuth(): Check[] {
  return [
    timed("MX", () => { const o = dnsLookup("MX", "diegonmarcos.com"); return { passed: o.includes("mx") || o.includes("cloudflare"), details: o.split("\n")[0] || "no MX" }; }),
    timed("DKIM", () => { const o = dnsLookup("TXT", "dkim._domainkey.diegonmarcos.com"); return { passed: o.includes("v=DKIM1"), details: o.includes("v=DKIM1") ? "present" : "missing" }; }),
    timed("SPF", () => { const o = dnsLookup("TXT", "diegonmarcos.com"); return { passed: o.includes("v=spf1"), details: o.split("\n").find((l) => l.includes("spf1"))?.trim() || "missing" }; }),
    timed("DMARC", () => { const o = dnsLookup("TXT", "_dmarc.diegonmarcos.com"); return { passed: o.includes("v=DMARC1"), details: o.trim().split("\n")[0] || "missing" }; }),
  ];
}

// ═══════════════════════════════════════════════════════════════════════════
// PHASE 5: MAIL INTERNALS — deep service health
// ═══════════════════════════════════════════════════════════════════════════

function mailInternals(): Check[] {
  return [
    // Dovecot auth
    timed("dovecot auth", () => {
      const r = ssh(`docker exec mailu-imap-1 doveadm user ${TEST_TO} 2>&1 | head -3`, 5_000);
      return { passed: r.ok && r.stdout.includes(TEST_TO), details: r.stdout.includes(TEST_TO) ? "user OK" : `FAILED: ${r.stdout.trim().slice(0, 60)}` };
    }),
    // IMAP protocol
    timed("IMAP protocol", () => {
      const r = ssh(`echo "a001 CAPABILITY" | timeout 3 openssl s_client -connect localhost:993 -quiet 2>/dev/null | head -3`, 5_000);
      return { passed: r.stdout.includes("IMAP4rev1") || r.stdout.includes("OK"), details: r.stdout.includes("IMAP4") ? "IMAP4rev1" : "not responding" };
    }),
    // Postfix queue
    timed("postfix queue", () => {
      const r = ssh(`docker exec mailu-smtp-1 postqueue -p 2>&1 | tail -1`, 5_000);
      if (r.stdout.includes("empty")) return { passed: true, details: "empty" };
      const n = r.stdout.match(/-- (\d+)/)?.[1];
      return { passed: !n || parseInt(n) < 50, details: n ? `${n} queued${parseInt(n) >= 20 ? " ⚠️" : ""}` : r.stdout.trim().slice(-40) };
    }),
    // Rspamd
    timed("rspamd", () => {
      const r = ssh(`docker exec mailu-antispam-1 curl -sf http://localhost:11334/stat 2>&1 | head -5`, 5_000);
      return { passed: r.ok && (r.stdout.includes("scanned") || r.stdout.includes("ham")), details: r.ok ? "responding" : "DOWN" };
    }),
    // Redis
    timed("redis", () => {
      const r = ssh(`docker exec mailu-redis-1 redis-cli ping 2>&1`, 3_000);
      return { passed: r.stdout.trim() === "PONG", details: r.stdout.trim() };
    }),
    // Admin panel
    timed("admin panel", () => {
      const r = ssh(`curl -skL -o /dev/null -w '%{http_code}' --max-time 3 https://localhost:8444/admin/`, 5_000);
      return { passed: ["200", "302", "303"].includes(r.stdout.trim()), details: `HTTP ${r.stdout.trim()}` };
    }),
    // Sieve filter active
    timed("sieve filter", () => {
      const r = ssh(`docker exec mailu-imap-1 cat /overrides/before.sieve 2>&1 | head -1`, 3_000);
      const active = r.stdout.includes("require") || r.stdout.includes("fileinto");
      return { passed: active, details: active ? "before.sieve loaded" : "NOT FOUND" };
    }),
    // Mail quota
    timed("mailbox quota", () => {
      const r = ssh(`docker exec mailu-imap-1 doveadm quota get -u ${TEST_TO} 2>&1 | head -3`, 5_000);
      if (r.stdout.includes("STORAGE")) {
        const match = r.stdout.match(/STORAGE\s+(\d+)\s+.*?(\d+)/);
        if (match) {
          const used = parseInt(match[1]);
          const limit = parseInt(match[2]);
          const pct = limit > 0 ? Math.round(used / limit * 100) : 0;
          return { passed: pct < 90, details: `${used}/${limit} KB (${pct}%)${pct >= 80 ? " ⚠️" : ""}` };
        }
      }
      return { passed: true, details: r.stdout.trim().slice(0, 60) || "no quota set" };
    }),
    // Mailu user count
    timed("user accounts", () => {
      const r = ssh(`docker exec mailu-admin-1 flask mailu config-export --users 2>/dev/null | grep -c '@' || echo 0`, 5_000);
      const count = parseInt(r.stdout.trim());
      return { passed: count > 0, details: `${count} users` };
    }),
  ];
}

// ═══════════════════════════════════════════════════════════════════════════
// PHASE 6: E2E DELIVERY — async send + poll
// ═══════════════════════════════════════════════════════════════════════════

function e2eDelivery(): Check[] {
  const checks: Check[] = [];
  const apiKey = getResendApiKey();
  if (!apiKey) { checks.push({ name: "Resend API key", passed: false, details: "not set", durationMs: 0 }); return checks; }
  checks.push({ name: "Resend API key", passed: true, details: "found", durationMs: 0 });

  const tag = `health-${Date.now()}`;
  let emailId = "";

  checks.push(timed("Send via Resend", () => {
    const body = JSON.stringify({ from: `Health <${TEST_FROM}>`, to: [TEST_TO], subject: `[health-check] ${tag}`, text: `Health ${tag}` });
    const r = exec("curl", ["-s", "-X", "POST", "-H", "Content-Type: application/json", "-H", `Authorization: Bearer ${apiKey}`, "-d", body, "https://api.resend.com/emails"], { timeout: 10_000 });
    const p = JSON.parse(r.stdout || "{}");
    if (p.id) { emailId = p.id; return { passed: true, details: `id=${p.id}` }; }
    return { passed: false, details: p.message || "failed" };
  }));

  if (!emailId) return checks;

  checks.push(timed("Resend status", () => {
    for (let i = 0; i < 3; i++) {
      if (i > 0) exec("bash", ["-c", "sleep 1.5"]);
      const r = exec("curl", ["-s", "-H", `Authorization: Bearer ${apiKey}`, `https://api.resend.com/emails/${emailId}`], { timeout: 8_000 });
      const ev = JSON.parse(r.stdout || "{}").last_event || "?";
      if (ev === "delivered") return { passed: true, details: `delivered (poll ${i + 1})` };
      if (ev === "bounced") return { passed: false, details: "BOUNCED" };
    }
    return { passed: true, details: "sent (IMAP is truth)" };
  }));

  checks.push(timed("IMAP arrival", () => {
    for (let i = 0; i < 4; i++) {
      exec("bash", ["-c", "sleep 3"]);
      const r = ssh(`docker exec mailu-imap-1 doveadm search -u ${TEST_TO} subject "${tag}" 2>&1 | head -5`, 8_000);
      if (r.ok && r.stdout.trim().length > 0 && !r.stdout.includes("error")) return { passed: true, details: `found (poll ${i + 1}, ${(i + 1) * 3}s)` };
    }
    return { passed: false, details: "NOT FOUND after 12s" };
  }));

  checks.push(timed("smtp-proxy logs", () => {
    const l = ssh(`docker logs smtp-proxy --since 5m 2>&1 | tail -3`, 5_000);
    const a = ssh(`docker exec smtp-proxy cat /var/log/nginx/access.log 2>/dev/null | tail -3 || true`, 5_000);
    const all = l.stdout + l.stderr + a.stdout;
    if (all.includes("502") || all.includes("refused")) return { passed: false, details: `errors: ${all.trim().split("\n").slice(-2).join(" | ")}` };
    if (all.includes("POST") || all.includes("200")) return { passed: true, details: "activity confirmed" };
    return { passed: true, details: "no logs (IMAP is truth)" };
  }));

  checks.push(timed("CF Worker", () => {
    const k = process.env.CF_API_KEY, e = process.env.CF_API_EMAIL;
    if (!k || !e) return { passed: true, details: "info: no CF creds" };
    const r = exec("curl", ["-s", "-H", `X-Auth-Email: ${e}`, "-H", `X-Auth-Key: ${k}`,
      "https://api.cloudflare.com/client/v4/accounts/e5cb0a0c6f448e54f217de484259f0ae/workers/scripts/email-forwarder"], { timeout: 8_000 });
    try { const d = JSON.parse(r.stdout); return { passed: true, details: `active (${d?.result?.modified_on?.slice(0, 10) || "?"})` }; }
    catch { return { passed: true, details: "info: CF API unparseable" }; }
  }));

  return checks;
}

// ═══════════════════════════════════════════════════════════════════════════
// TOOL REGISTRATION — async handlers
// ═══════════════════════════════════════════════════════════════════════════

function safeTool(fn: () => string): { content: [{ type: "text"; text: string }] } {
  try { return { content: [{ type: "text" as const, text: fn() }] }; }
  catch (err: unknown) { return { content: [{ type: "text" as const, text: `ERROR: ${err instanceof Error ? err.message : String(err)}` }] }; }
}

export function registerHealthMailuTools(server: McpServer): void {
  server.tool("mailu_up", "Quick UP: pre-flight + containers + network + DNS + internals", {},
    async () => safeTool(() => [
      formatChecks("PRE-FLIGHT", preflight()), "",
      formatChecks("CONTAINERS", containerHealth()), "",
      formatChecks("NETWORK", networkChecks()), "",
      formatChecks("DNS AUTH", dnsAuth()), "",
      formatChecks("MAIL INTERNALS", mailInternals()),
    ].join("\n")),
  );

  server.tool("mailu_profile", "Deep profile all Mailu containers", {},
    async () => safeTool(() => {
      const p: Record<string, unknown> = {};
      for (const n of [...MAILU_CONTAINERS, "smtp-proxy"]) { try { p[n] = profileContainer(n); } catch (e: unknown) { p[n] = { error: String(e) }; } }
      return `Mailu Profiles\n${"─".repeat(60)}\n${JSON.stringify(p, null, 2)}`;
    }),
  );

  server.tool("mailu_send_test", "E2E delivery: Resend → CF → smtp-proxy → Mailu → IMAP", {},
    async () => safeTool(() => formatChecks("E2E DELIVERY", e2eDelivery())),
  );

  server.tool("mailu_outbound_test", "Outbound: SMTP relay + DNS auth", {},
    async () => safeTool(() => {
      const c: Check[] = [
        timed("SMTP :25", () => { const r = ssh(`echo QUIT | timeout 3 nc -w3 localhost 25 2>&1 | head -1`, 5_000); return { passed: r.stdout.includes("220"), details: r.stdout.trim().split("\n")[0] || "no banner" }; }),
        timed("SMTP :587", () => { const r = ssh(`echo QUIT | timeout 5 openssl s_client -connect localhost:587 2>&1 | head -3`, 8_000); return { passed: r.stdout.includes("CONNECTED"), details: r.stdout.includes("CONNECTED") ? "TLS OK" : "not responding" }; }),
        ...dnsAuth(),
      ];
      return formatChecks("OUTBOUND & DNS", c);
    }),
  );

  server.tool("mailu_full", "Full 6-phase diagnostic: pre-flight → containers → network → DNS → internals → e2e delivery", {},
    async () => safeTool(() => [
      formatChecks("1. PRE-FLIGHT", preflight()), "",
      formatChecks("2. CONTAINERS", containerHealth()), "",
      formatChecks("3. NETWORK", networkChecks()), "",
      formatChecks("4. DNS AUTH", dnsAuth()), "",
      formatChecks("5. MAIL INTERNALS", mailInternals()), "",
      formatChecks("6. E2E DELIVERY", e2eDelivery()),
    ].join("\n")),
  );
}
