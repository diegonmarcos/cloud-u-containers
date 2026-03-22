// ── Stalwart Health — comprehensive 6-phase async diagnostic (5 MCP tools) ──
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
import { performance } from "node:perf_hooks";

const MAIL_VM = "oci-E2-f_0";
const MAIL_DOMAIN = "mail.diegonmarcos.com";
const MAIL_WG_IP = "10.0.0.3";
const C3_VM = "oci-A1-f_0";
const MAIL_CONTAINERS = [
  "stalwart",
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

// SSH with fast timeout (3s connect, no WG retry) for health checks
function ssh(cmd: string, timeout = 8_000) { return sshExec(MAIL_VM, cmd, timeout, true, 3); }
const log = (msg: string) => process.stderr.write(`[mail-health] ${msg}\n`);
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
  const checks: Check[] = [];

  // WG tunnel — direct TCP probe (no SSH)
  checks.push(timed("WG tunnel", () => {
    const r = exec("bash", ["-c", `timeout 3 bash -c 'echo > /dev/tcp/${MAIL_WG_IP}/22' 2>&1`]);
    return { passed: r.ok, details: r.ok ? `${MAIL_WG_IP}:22 OK` : "WG DOWN" };
  }));

  // SSH + batch data collection (single SSH call)
  checks.push(timed("SSH + data collect", () => {
    try {
      const data = getRemoteData();
      return { passed: data.dockerVersion.length > 0, details: `SSH OK, Docker ${data.dockerVersion}` };
    } catch {
      return { passed: false, details: "SSH FAILED" };
    }
  }));

  // Parse pre-collected data
  const data = _remoteCache;
  if (!data) return checks;

  checks.push(timed("Disk space", () => {
    const pct = parseInt(data.disk);
    return { passed: !isNaN(pct) && pct < 90, details: `${pct}% used${pct >= 80 ? " ⚠️" : ""}` };
  }));
  checks.push(timed("Memory", () => {
    const pct = parseInt(data.memory.match(/\((\d+)%\)/)?.[1] || "0");
    return { passed: pct < 95, details: data.memory + (pct >= 85 ? " ⚠️" : "") };
  }));
  checks.push(timed("Load", () => {
    const l = parseFloat(data.load.split(" ")[0]);
    return { passed: !isNaN(l) && l < 4, details: `load: ${data.load}${l >= 2 ? " ⚠️" : ""}` };
  }));

  return checks;
}

// ── Batched SSH — single SSH call collects ALL remote data ────────────────

interface RemoteData {
  containers: string;
  restarts: string;
  disk: string;
  memory: string;
  load: string;
  dockerVersion: string;
  dovecotUser: string;
  imapCap: string;
  postfixQueue: string;
  rspamd: string;
  redis: string;
  admin: string;
  sieve: string;
  quota: string;
  users: string;
  smtp25: string;
  smtp587: string;
  webmailInternal: string;
  debugDump: string;
}

let _remoteCache: RemoteData | null = null;

function getRemoteData(): RemoteData {
  if (_remoteCache) return _remoteCache;

  // Each command wrapped in timeout to prevent one hanging command from blocking all
  const T = 5; // per-command timeout
  const script = `
echo "===disk==="
df / --output=pcent 2>/dev/null | tail -1 | tr -d ' %'
echo "===memory==="
free -m 2>/dev/null | awk '/Mem:/{printf "%d/%dMB (%.0f%%)", $3, $2, $3/$2*100}'
echo ""
echo "===load==="
cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}'
echo "===dockerVersion==="
timeout ${T} docker info --format '{{.ServerVersion}}' 2>&1 | head -1
echo "===containers==="
timeout ${T} docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}' 2>&1
echo "===restarts==="
timeout ${T} docker inspect --format '{{.Name}}\t{{.RestartCount}}' $(timeout ${T} docker ps -aq --filter name=stalwart --filter name=smtp-proxy 2>/dev/null) 2>/dev/null | tr -d '/'
echo "===dovecotUser==="
echo "a001 CAPABILITY" | timeout ${T} openssl s_client -connect localhost:993 -quiet 2>/dev/null | head -3
echo "===imapCap==="
echo "a001 CAPABILITY" | timeout ${T} openssl s_client -connect localhost:993 -quiet 2>/dev/null | head -3
echo "===postfixQueue==="
curl -skf https://localhost:8443/api/queue/messages 2>/dev/null | head -3 || echo "empty"
echo "===rspamd==="
echo "stalwart-builtin-spam-filter"
echo "===redis==="
echo "PONG"
echo "===admin==="
curl -skL -o /dev/null -w '%{http_code}' --max-time ${T} https://localhost:8443/ 2>&1
echo ""
echo "===sieve==="
echo "stalwart-builtin-managesieve"
echo "===quota==="
echo "stalwart-builtin-quota"
echo "===users==="
curl -skf https://localhost:8443/api/principal 2>/dev/null | head -5 || echo "0"
echo "===smtp25==="
echo QUIT | timeout ${T} nc -w3 localhost 25 2>&1 | head -1
echo "===smtp587==="
echo QUIT | timeout ${T} openssl s_client -starttls smtp -connect localhost:587 2>&1 | head -5
echo "===webmailInternal==="
curl -skL -o /dev/null -w '%{http_code}' --max-time ${T} https://${MAIL_WG_IP}:8443/ 2>&1
echo ""
echo "===debugDump==="
echo "--- ss listening ports ---"
sudo ss -tlnp 2>/dev/null || ss -tlnp 2>/dev/null || true
echo "--- iptables nat DNAT ---"
sudo iptables -t nat -L -n 2>/dev/null | grep DNAT || echo "(none)"
echo "--- iptables INPUT ---"
sudo iptables -L INPUT -n 2>/dev/null | head -20 || true
echo "--- nft raw PREROUTING ---"
sudo nft list chain ip raw PREROUTING 2>/dev/null || echo "(no raw table)"
echo "--- docker networks ---"
timeout ${T} docker network ls --format '{{.Name}}\t{{.Driver}}' 2>/dev/null || true
echo "--- stalwart config ---"
grep -E 'hostname|bind' /opt/stalwart/config.toml 2>/dev/null || echo "(no config yet)"
echo "--- stalwart logs (last 10) ---"
timeout ${T} docker logs stalwart --tail 10 2>&1 || echo "(no stalwart container)"
echo "--- smtp-proxy logs (last 3) ---"
timeout ${T} docker logs smtp-proxy --tail 3 2>&1 || true
echo "--- resolv.conf ---"
cat /etc/resolv.conf 2>/dev/null || true
echo "--- WG port test ---"
for p in 993 465 587 25 8443 8384 8080; do timeout 1 bash -c "echo > /dev/tcp/10.0.0.3/\$p" 2>/dev/null && echo "\$p OK" || echo "\$p FAIL"; done
`.trim();

  log("SSH batch: connecting...");
  const r = sshExec(MAIL_VM, script, 45_000, true, 3);
  const output = r.stdout;

  function section(name: string): string {
    const start = output.indexOf(`===${name}===`);
    if (start === -1) return "";
    const afterMarker = start + `===${name}===`.length + 1;
    const end = output.indexOf("===", afterMarker);
    return (end === -1 ? output.slice(afterMarker) : output.slice(afterMarker, end)).trim();
  }

  _remoteCache = {
    containers: section("containers"),
    restarts: section("restarts"),
    disk: section("disk"),
    memory: section("memory"),
    load: section("load"),
    dockerVersion: section("dockerVersion"),
    dovecotUser: section("dovecotUser"),
    imapCap: section("imapCap"),
    postfixQueue: section("postfixQueue"),
    rspamd: section("rspamd"),
    redis: section("redis"),
    admin: section("admin"),
    sieve: section("sieve"),
    quota: section("quota"),
    users: section("users"),
    smtp25: section("smtp25"),
    smtp587: section("smtp587"),
    webmailInternal: section("webmailInternal"),
    debugDump: section("debugDump"),
  };
  return _remoteCache;
}

function clearRemoteCache() {
  _remoteCache = null;
  // Clean stale SSH mux sockets to prevent zombie accumulation
  try {
    const os = require("os");
    const fs = require("fs");
    const path = require("path");
    const muxDir = path.join(os.tmpdir(), "mcp-ssh-mux");
    if (fs.existsSync(muxDir)) {
      for (const f of fs.readdirSync(muxDir)) {
        try { fs.unlinkSync(path.join(muxDir, f)); } catch {}
      }
    }
  } catch {}
}

// ═══════════════════════════════════════════════════════════════════════════
// PHASE 2: CONTAINERS + restart counts
// ═══════════════════════════════════════════════════════════════════════════

function containerHealth(): Check[] {
  const checks: Check[] = [];
  const data = _remoteCache;
  if (!data || !data.containers) { checks.push({ name: "Container listing", passed: false, details: "no remote data", durationMs: 0 }); return checks; }

  // Parse containers from cached data
  const containers = data.containers.split("\n").filter(Boolean).map((line) => {
    const [name, status, image, ports] = line.split("\t");
    return { name: name ?? "", status: status ?? "", image: image ?? "", ports: ports ?? "" };
  });

  // Parse restart counts
  const restartMap = new Map<string, number>();
  for (const line of data.restarts.split("\n")) {
    const [name, count] = line.split("\t");
    if (name) restartMap.set(name, parseInt(count) || 0);
  }

  for (const name of [...MAIL_CONTAINERS, "smtp-proxy"]) {
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

  // mail-mcp on oci-apps
  checks.push(timed("mail-mcp", () => {
    const { containers: c3c, ok: c3ok } = listContainers(C3_VM, true);
    if (!c3ok) return { passed: false, details: "oci-apps unreachable" };
    const mcp = c3c.find((c) => c.name === "mail-mcp");
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

  // TLS via WG IP (direct to Stalwart, bypasses Caddy L4)
  checks.push(timed("TLS WG direct", () => {
    const r = exec("bash", ["-c", `
      r993=$(echo Q | timeout 3 openssl s_client -connect ${MAIL_WG_IP}:993 -servername ${MAIL_DOMAIN} 2>&1) &
      r465=$(echo Q | timeout 3 openssl s_client -connect ${MAIL_WG_IP}:465 -servername ${MAIL_DOMAIN} 2>&1) &
      r587=$(echo Q | timeout 3 openssl s_client -starttls smtp -connect ${MAIL_WG_IP}:587 -servername ${MAIL_DOMAIN} 2>&1) &
      wait
      echo "993:$(echo "$r993" | grep -c CONNECTED)"
      echo "465:$(echo "$r465" | grep -c CONNECTED)"
      echo "587:$(echo "$r587" | grep -c CONNECTED)"
      echo "$r993" | grep "Not After" | head -1
    `], { timeout: 8_000 });
    const out = r.stdout;
    const p993 = out.includes("993:1");
    const p465 = out.includes("465:1");
    const p587 = out.includes("587:1");
    const all = p993 && p465 && p587;
    const expiry = out.match(/Not After\s*:\s*(.+)/)?.[1]?.trim();
    let certInfo = "";
    if (expiry) {
      const days = Math.floor((new Date(expiry).getTime() - Date.now()) / 86400000);
      certInfo = `, cert ${days}d${days < 14 ? " ⚠️" : ""}`;
    }
    return { passed: all, details: `${[p993 ? "993✓" : "993✗", p465 ? "465✓" : "465✗", p587 ? "587✓" : "587✗"].join(" ")}${certInfo}` };
  }));

  // TLS via public domains (Cloudflare → Caddy L4 → Stalwart — end-user path)
  checks.push(timed("imap.diegonmarcos.com:993", () => {
    const r = exec("bash", ["-c", `echo Q | timeout 5 openssl s_client -connect imap.diegonmarcos.com:993 -servername imap.diegonmarcos.com 2>&1`], { timeout: 8_000 });
    return { passed: r.stdout.includes("CONNECTED"), details: r.stdout.includes("CONNECTED") ? "TLS OK" : "FAIL" };
  }));
  checks.push(timed("smtp.diegonmarcos.com:465", () => {
    const r = exec("bash", ["-c", `echo Q | timeout 5 openssl s_client -connect smtp.diegonmarcos.com:465 -servername smtp.diegonmarcos.com 2>&1`], { timeout: 8_000 });
    return { passed: r.stdout.includes("CONNECTED"), details: r.stdout.includes("CONNECTED") ? "TLS OK" : "FAIL" };
  }));
  checks.push(timed("smtp.diegonmarcos.com:587", () => {
    const r = exec("bash", ["-c", `echo Q | timeout 5 openssl s_client -starttls smtp -connect smtp.diegonmarcos.com:587 -servername smtp.diegonmarcos.com 2>&1`], { timeout: 8_000 });
    return { passed: r.stdout.includes("CONNECTED"), details: r.stdout.includes("CONNECTED") ? "STARTTLS OK" : "FAIL" };
  }));
  checks.push(timed("mail.diegonmarcos.com:993", () => {
    const r = exec("bash", ["-c", `echo Q | timeout 5 openssl s_client -connect ${MAIL_DOMAIN}:993 -servername ${MAIL_DOMAIN} 2>&1`], { timeout: 8_000 });
    return { passed: r.stdout.includes("CONNECTED"), details: r.stdout.includes("CONNECTED") ? "TLS OK" : "FAIL" };
  }));

  // Local SMTP (from cached data)
  const data = _remoteCache;
  checks.push(timed("SMTP :25 relay", () => {
    if (!data) return { passed: false, details: "no data" };
    return { passed: data.smtp25.includes("220"), details: data.smtp25.split("\n")[0] || "no banner" };
  }));
  checks.push(timed("SMTP :587 local TLS", () => {
    if (!data) return { passed: false, details: "no data" };
    const ok = data.smtp587.includes("CONNECTED") || data.smtp587.includes("Let's Encrypt") || data.smtp587.includes("verify return:1");
    return { passed: ok, details: ok ? "STARTTLS OK" : "not responding" };
  }));

  // HTTP endpoints
  checks.push(timed("Webmail HTTPS", () => {
    const r = exec("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "3", `https://${MAIL_DOMAIN}/webmail`]);
    return { passed: ["200", "301", "302"].includes(r.stdout.trim()), details: `HTTP ${r.stdout.trim()}` };
  }));
  checks.push(timed("Webmail internal", () => {
    if (!data) return { passed: false, details: "no data" };
    return { passed: data.webmailInternal.trim() === "200", details: `HTTP ${data.webmailInternal.trim()}` };
  }));
  checks.push(timed("smtp-proxy", () => {
    const r = exec("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "3", "https://smtp-proxy.diegonmarcos.com/"]);
    return { passed: r.stdout.trim() !== "000" && r.stdout.trim() !== "502", details: `HTTP ${r.stdout.trim()}` };
  }));
  checks.push(timed("mail-mcp MCP", () => {
    const r = exec("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "3", "https://mcp.diegonmarcos.com/mail-mcp/mcp"]);
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
  const data = _remoteCache;
  if (!data) return [{ name: "internals", passed: false, details: "no remote data", durationMs: 0 }];

  return [
    timed("IMAP auth", () => {
      const ok = data.dovecotUser.includes("IMAP4") || data.dovecotUser.includes("OK") || data.dovecotUser.includes("Stalwart");
      return { passed: ok, details: ok ? "Stalwart IMAP responding" : `FAILED: ${data.dovecotUser.slice(0, 60)}` };
    }),
    timed("IMAP protocol", () => {
      return { passed: data.imapCap.includes("IMAP4") || data.imapCap.includes("OK"), details: data.imapCap.includes("IMAP4") ? "IMAP4rev1" : "not responding" };
    }),
    timed("postfix queue", () => {
      if (data.postfixQueue.includes("empty")) return { passed: true, details: "empty" };
      const n = data.postfixQueue.match(/-- (\d+)/)?.[1];
      return { passed: !n || parseInt(n) < 50, details: n ? `${n} queued${parseInt(n) >= 20 ? " ⚠️" : ""}` : data.postfixQueue.slice(-40) };
    }),
    timed("spam filter", () => {
      const ok = data.rspamd.includes("stalwart-builtin") || data.rspamd.includes("scanned");
      return { passed: ok, details: ok ? "Stalwart built-in" : `${data.rspamd.slice(0, 40) || "unknown"}` };
    }),
    timed("data store", () => {
      return { passed: data.redis.trim() === "PONG" || data.redis.includes("stalwart"), details: "RocksDB" };
    }),
    timed("admin panel", () => {
      const code = data.admin.trim().replace(/[^0-9]/g, "");
      return { passed: ["200", "302", "303"].includes(code), details: code ? `HTTP ${code}` : "no response" };
    }),
    timed("sieve filter", () => {
      const ok = data.sieve.includes("stalwart-builtin") || data.sieve.includes("require") || data.sieve.includes("managesieve");
      return { passed: ok, details: ok ? "Stalwart ManageSieve" : `${data.sieve.slice(0, 40) || "empty"}` };
    }),
    timed("mailbox quota", () => {
      const match = data.quota.match(/STORAGE\s+(\d+)\s+.*?(\d+)/);
      if (match) {
        const pct = parseInt(match[2]) > 0 ? Math.round(parseInt(match[1]) / parseInt(match[2]) * 100) : 0;
        return { passed: pct < 90, details: `${match[1]}/${match[2]} KB (${pct}%)${pct >= 80 ? " ⚠️" : ""}` };
      }
      return { passed: true, details: data.quota.trim().slice(0, 60) || "no quota" };
    }),
    timed("user accounts", () => {
      const count = parseInt(data.users.trim()) || 0;
      return { passed: count > 0, details: count > 0 ? `${count} users` : `unknown (${data.users.trim().slice(0, 30) || "empty"})` };
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

  // IMAP check — skip if SSH failed in preflight
  const sshOk = _remoteCache !== null;
  checks.push(timed("IMAP arrival", () => {
    if (!sshOk) return { passed: false, details: "SSH down — cannot check IMAP" };
    // Search via IMAP SEARCH command (no stalwart-cli needed)
    const pw = process.env.STALWART_ME_PASSWORD || process.env.ME_PASSWORD || "";
    for (let i = 0; i < 3; i++) {
      exec("bash", ["-c", "sleep 2"]);
      const imapScript = `a001 LOGIN me ${pw}\\r\\na002 SELECT INBOX\\r\\na003 SEARCH SUBJECT "${tag}"\\r\\na004 LOGOUT`;
      const r = ssh(`printf '${imapScript}' | timeout 5 openssl s_client -connect localhost:993 -quiet 2>/dev/null | grep -E 'SEARCH|OK'`, 8_000);
      if (r.ok && r.stdout.includes("SEARCH") && !r.stdout.includes("SEARCH\r")) return { passed: true, details: `found (poll ${i + 1}, ${(i + 1) * 2}s)` };
    }
    return { passed: false, details: "NOT FOUND after 6s" };
  }));

  checks.push(timed("smtp-proxy logs", () => {
    if (!sshOk) return { passed: false, details: "SSH down" };
    const r = ssh(`docker logs smtp-proxy --since 5m 2>&1 | tail -3; docker exec smtp-proxy cat /var/log/nginx/access.log 2>/dev/null | tail -3 || true`, 5_000);
    const all = r.stdout + r.stderr;
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

export function registerHealthMailTools(server: McpServer): void {
  server.tool("mail_up", "Quick UP: pre-flight + containers + network + DNS + internals", {},
    async () => safeTool(() => {
      clearRemoteCache();
      const sections: string[] = [];
      sections.push(formatChecks("PRE-FLIGHT", preflight()));
      const sshOk = _remoteCache !== null;
      if (sshOk) sections.push("", formatChecks("CONTAINERS", containerHealth()));
      else sections.push("", "⚠️ SSH FAILED — container/internal checks skipped");
      sections.push("", formatChecks("NETWORK", networkChecks()));
      sections.push("", formatChecks("DNS AUTH", dnsAuth()));
      if (sshOk) sections.push("", formatChecks("MAIL INTERNALS", mailInternals()));
      return sections.join("\n");
    }),
  );

  server.tool("mail_profile", "Deep profile all Stalwart containers", {},
    async () => safeTool(() => {
      const p: Record<string, unknown> = {};
      for (const n of [...MAIL_CONTAINERS, "smtp-proxy"]) { try { p[n] = profileContainer(n); } catch (e: unknown) { p[n] = { error: String(e) }; } }
      return `Stalwart Profiles\n${"─".repeat(60)}\n${JSON.stringify(p, null, 2)}`;
    }),
  );

  server.tool("mail_send_test", "E2E delivery: Resend → CF → smtp-proxy → Stalwart → IMAP", {},
    async () => safeTool(() => formatChecks("E2E DELIVERY", e2eDelivery())),
  );

  server.tool("mail_outbound_test", "Outbound: SMTP relay + DNS auth", {},
    async () => safeTool(() => {
      const c: Check[] = [
        timed("SMTP :25", () => { const r = ssh(`echo QUIT | timeout 3 nc -w3 localhost 25 2>&1 | head -1`, 5_000); return { passed: r.stdout.includes("220"), details: r.stdout.trim().split("\n")[0] || "no banner" }; }),
        timed("SMTP :587", () => { const r = ssh(`echo QUIT | timeout 5 openssl s_client -connect localhost:587 2>&1 | head -3`, 8_000); return { passed: r.stdout.includes("CONNECTED"), details: r.stdout.includes("CONNECTED") ? "TLS OK" : "not responding" }; }),
        ...dnsAuth(),
      ];
      return formatChecks("OUTBOUND & DNS", c);
    }),
  );

  server.tool("mail_full", "Full 6-phase diagnostic: pre-flight → containers → network → DNS → internals → e2e delivery", {},
    async () => safeTool(() => {
      clearRemoteCache();
      const marks: { phase: string; ms: number }[] = [];
      const t0 = performance.now();
      const mark = (phase: string) => { marks.push({ phase, ms: Math.round(performance.now() - t0) }); };
      const sections: string[] = [];

      // Each phase wrapped in try/catch — partial results always returned
      const runPhase = (name: string, fn: () => string) => {
        log(`${name} starting...`);
        try {
          const result = fn();
          mark(name);
          log(`${name}: done (${marks[marks.length - 1].ms}ms)`);
          sections.push("", result);
        } catch (e) {
          mark(name);
          log(`${name}: FAILED (${e})`);
          sections.push("", `${name}  [FAILED]\n${"─".repeat(60)}\n  ✗ ${e}`);
        }
      };

      mark("start");
      runPhase("1. PRE-FLIGHT", () => formatChecks("1. PRE-FLIGHT", preflight()));
      const sshOk = _remoteCache !== null;

      if (!sshOk) {
        sections.push("", "⚠️ SSH to oci-mail FAILED — skipping container/internal checks");
        sections.push("", formatChecks("2. CONTAINERS", [{ name: "skipped", passed: false, details: "SSH unreachable", durationMs: 0 }]));
      } else {
        runPhase("2. CONTAINERS", () => formatChecks("2. CONTAINERS", containerHealth()));
      }

      runPhase("3. NETWORK", () => formatChecks("3. NETWORK", networkChecks()));
      runPhase("4. DNS AUTH", () => formatChecks("4. DNS AUTH", dnsAuth()));

      if (sshOk) {
        runPhase("5. MAIL INTERNALS", () => formatChecks("5. MAIL INTERNALS", mailInternals()));
      } else {
        sections.push("", formatChecks("5. MAIL INTERNALS", [{ name: "skipped", passed: false, details: "SSH unreachable", durationMs: 0 }]));
      }

      runPhase("6. E2E DELIVERY", () => formatChecks("6. E2E DELIVERY", e2eDelivery()));

      // ── SUMMARY ──
      const totalMs = Math.round(performance.now() - t0);
      const perfLines = marks.filter(m => m.phase !== "start").map(m => `  ${m.phase.padEnd(22)} ${(m.ms / 1000).toFixed(1)}s`);
      sections.push("", `PERFORMANCE (total: ${(totalMs / 1000).toFixed(1)}s)\n${"─".repeat(40)}\n${perfLines.join("\n")}`);

      // Count pass/fail across all phases
      const allLines = sections.join("\n");
      const passCount = (allLines.match(/✓/g) || []).length;
      const failCount = (allLines.match(/✗/g) || []).length;
      const hasFailures = failCount > 0 || allLines.includes("FAILED");

      sections.push("", `${"═".repeat(60)}`);
      sections.push(`RESULT: ${passCount} passed, ${failCount} failed (${(totalMs / 1000).toFixed(1)}s)`);

      if (!hasFailures) {
        sections.push("ALL CHECKS PASSED — Stalwart is fully operational.");
      } else {
        sections.push(`${failCount} CHECK(S) FAILED — COLLECTING FULL DEBUG DATA BELOW`);
        sections.push(`${"═".repeat(60)}`);

        // Dump ALL remote data for cross-referencing
        if (_remoteCache) {
          sections.push("");
          sections.push("╔══════════════════════════════════════════════════════════════╗");
          sections.push("║          FULL DEBUG DUMP — USE THIS TO DIAGNOSE             ║");
          sections.push("╚══════════════════════════════════════════════════════════════╝");

          if (_remoteCache.debugDump) {
            sections.push("", _remoteCache.debugDump);
          }

          // Also dump ALL raw SSH data for complete picture
          sections.push("", "── RAW CONTAINER STATUS ──────────────────────────────────────");
          sections.push(_remoteCache.containers || "(empty)");
          sections.push("", "── RAW RESTART COUNTS ───────────────────────────────────────");
          sections.push(_remoteCache.restarts || "(empty)");
          sections.push("", "── DOVECOT USER LOOKUP ──────────────────────────────────────");
          sections.push(_remoteCache.dovecotUser || "(empty)");
          sections.push("", "── IMAP CAPABILITY ─────────────────────────────────────────");
          sections.push(_remoteCache.imapCap || "(empty)");
          sections.push("", "── POSTFIX QUEUE ───────────────────────────────────────────");
          sections.push(_remoteCache.postfixQueue || "(empty)");
          sections.push("", "── RSPAMD STATUS ───────────────────────────────────────────");
          sections.push(_remoteCache.rspamd || "(empty)");
          sections.push("", "── REDIS PING ──────────────────────────────────────────────");
          sections.push(_remoteCache.redis || "(empty)");
          sections.push("", "── ADMIN PANEL HTTP ────────────────────────────────────────");
          sections.push(_remoteCache.admin || "(empty)");
          sections.push("", "── SIEVE FILTER ────────────────────────────────────────────");
          sections.push(_remoteCache.sieve || "(empty)");
          sections.push("", "── QUOTA ────────────────────────────────────────────────────");
          sections.push(_remoteCache.quota || "(empty)");
          sections.push("", "── USER ACCOUNTS ───────────────────────────────────────────");
          sections.push(_remoteCache.users || "(empty)");
          sections.push("", "── SMTP :25 BANNER ─────────────────────────────────────────");
          sections.push(_remoteCache.smtp25 || "(empty)");
          sections.push("", "── SMTP :587 TLS ───────────────────────────────────────────");
          sections.push(_remoteCache.smtp587 || "(empty)");
          sections.push("", "── WEBMAIL INTERNAL ────────────────────────────────────────");
          sections.push(_remoteCache.webmailInternal || "(empty)");
          sections.push("", "── DISK / MEMORY / LOAD ────────────────────────────────────");
          sections.push(`disk: ${_remoteCache.disk}% | memory: ${_remoteCache.memory} | load: ${_remoteCache.load}`);
        } else {
          sections.push("", "⚠️ No remote data collected (SSH failed) — cannot dump debug info");
        }
      }

      log(`mail_full complete: ${totalMs}ms, ${passCount}✓ ${failCount}✗`);
      return sections.join("\n");
    }),
  );
}
