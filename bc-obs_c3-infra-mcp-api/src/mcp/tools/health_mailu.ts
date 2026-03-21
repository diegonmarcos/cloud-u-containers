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
import { performance } from "node:perf_hooks";

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

// SSH with fast timeout (3s connect, no WG retry) for health checks
function ssh(cmd: string, timeout = 8_000) { return sshExec(MAILU_VM, cmd, timeout, true, 3); }
const log = (msg: string) => process.stderr.write(`[mailu-health] ${msg}\n`);
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
    const r = exec("bash", ["-c", `timeout 3 bash -c 'echo > /dev/tcp/${MAILU_WG_IP}/22' 2>&1`]);
    return { passed: r.ok, details: r.ok ? `${MAILU_WG_IP}:22 OK` : "WG DOWN" };
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
}

let _remoteCache: RemoteData | null = null;

function getRemoteData(): RemoteData {
  if (_remoteCache) return _remoteCache;

  // Each command wrapped in timeout to prevent one hanging command from blocking all
  const T = 5; // per-command timeout (docker exec needs 3-5s on 1GB VMs)
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
timeout ${T} docker inspect --format '{{.Name}}\t{{.RestartCount}}' $(timeout ${T} docker ps -aq --filter name=mailu --filter name=smtp-proxy 2>/dev/null) 2>/dev/null | tr -d '/'
echo "===dovecotUser==="
timeout ${T} docker exec mailu-imap-1 doveadm user ${TEST_TO} 2>&1 | head -3
echo "===imapCap==="
echo "a001 CAPABILITY" | timeout ${T} openssl s_client -connect localhost:993 -quiet 2>/dev/null | head -3
echo "===postfixQueue==="
timeout ${T} docker exec mailu-smtp-1 postqueue -p 2>&1 | tail -1
echo "===rspamd==="
timeout ${T} docker exec mailu-antispam-1 curl -sf http://localhost:11334/stat 2>&1 | head -5
echo "===redis==="
timeout ${T} docker exec mailu-redis-1 redis-cli ping 2>&1
echo "===admin==="
curl -skL -o /dev/null -w '%{http_code}' --max-time ${T} https://localhost:8444/admin/ 2>&1
echo ""
echo "===sieve==="
timeout ${T} docker exec mailu-imap-1 cat /overrides/before.sieve 2>&1 | head -1
echo "===quota==="
timeout ${T} docker exec mailu-imap-1 doveadm quota get -u ${TEST_TO} 2>&1 | head -3
echo "===users==="
timeout ${T} docker exec mailu-admin-1 flask mailu config-export --users 2>/dev/null | grep -c '@' || echo 0
echo "===smtp25==="
echo QUIT | timeout ${T} nc -w3 localhost 25 2>&1 | head -1
echo "===smtp587==="
echo QUIT | timeout ${T} openssl s_client -connect localhost:587 2>&1 | head -3
echo "===webmailInternal==="
curl -skL -o /dev/null -w '%{http_code}' --max-time ${T} https://${MAILU_WG_IP}:8444/webmail 2>&1
echo ""
`.trim();

  log("SSH batch: connecting...");
  const r = sshExec(MAILU_VM, script, 25_000, true, 3);
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

  // TLS ports — run ALL 3 in parallel via single bash call
  checks.push(timed("TLS :993/:465/:587", () => {
    const r = exec("bash", ["-c", `
      r993=$(echo Q | timeout 3 openssl s_client -connect ${MAILU_DOMAIN}:993 2>&1) &
      r465=$(echo Q | timeout 3 openssl s_client -connect ${MAILU_DOMAIN}:465 2>&1) &
      r587=$(echo Q | timeout 3 openssl s_client -starttls smtp -connect ${MAILU_DOMAIN}:587 2>&1) &
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
    const status = [p993 ? "993✓" : "993✗", p465 ? "465✓" : "465✗", p587 ? "587✓" : "587✗"].join(" ");
    return { passed: all, details: `${status}${certInfo}` };
  }));

  // Local SMTP (from cached data)
  const data = _remoteCache;
  checks.push(timed("SMTP :25 relay", () => {
    if (!data) return { passed: false, details: "no data" };
    return { passed: data.smtp25.includes("220"), details: data.smtp25.split("\n")[0] || "no banner" };
  }));
  checks.push(timed("SMTP :587 local TLS", () => {
    if (!data) return { passed: false, details: "no data" };
    return { passed: data.smtp587.includes("CONNECTED"), details: data.smtp587.includes("CONNECTED") ? "TLS OK" : "not responding" };
  }));

  // HTTP endpoints
  checks.push(timed("Webmail HTTPS", () => {
    const r = exec("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "3", `https://${MAILU_DOMAIN}/webmail`]);
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
  checks.push(timed("mailu-mcp MCP", () => {
    const r = exec("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "3", "https://mcp.diegonmarcos.com/mailu-mcp/mcp"]);
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
    timed("dovecot auth", () => {
      const ok = data.dovecotUser.includes(TEST_TO) || data.dovecotUser.includes("uid") || data.dovecotUser.includes("mail");
      return { passed: ok, details: ok ? "user lookup OK" : `FAILED: ${data.dovecotUser.slice(0, 60)}` };
    }),
    timed("IMAP protocol", () => {
      return { passed: data.imapCap.includes("IMAP4") || data.imapCap.includes("OK"), details: data.imapCap.includes("IMAP4") ? "IMAP4rev1" : "not responding" };
    }),
    timed("postfix queue", () => {
      if (data.postfixQueue.includes("empty")) return { passed: true, details: "empty" };
      const n = data.postfixQueue.match(/-- (\d+)/)?.[1];
      return { passed: !n || parseInt(n) < 50, details: n ? `${n} queued${parseInt(n) >= 20 ? " ⚠️" : ""}` : data.postfixQueue.slice(-40) };
    }),
    timed("rspamd", () => {
      const ok = data.rspamd.includes("scanned") || data.rspamd.includes("ham") || data.rspamd.includes("spam") || data.rspamd.length > 10;
      return { passed: ok, details: ok ? "responding" : `DOWN: ${data.rspamd.slice(0, 40) || "empty"}` };
    }),
    timed("redis", () => {
      return { passed: data.redis.trim() === "PONG", details: data.redis.trim() };
    }),
    timed("admin panel", () => {
      const code = data.admin.trim().replace(/[^0-9]/g, "");
      return { passed: ["200", "302", "303"].includes(code), details: code ? `HTTP ${code}` : "no response" };
    }),
    timed("sieve filter", () => {
      const active = data.sieve.includes("require") || data.sieve.includes("fileinto") || data.sieve.includes("mailbox");
      return { passed: active, details: active ? "before.sieve loaded" : `NOT FOUND: ${data.sieve.slice(0, 40) || "empty"}` };
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
    for (let i = 0; i < 3; i++) {
      exec("bash", ["-c", "sleep 2"]);
      const r = ssh(`docker exec mailu-imap-1 doveadm search -u ${TEST_TO} subject "${tag}" 2>&1 | head -3`, 5_000);
      if (r.ok && r.stdout.trim().length > 0 && !r.stdout.includes("error")) return { passed: true, details: `found (poll ${i + 1}, ${(i + 1) * 2}s)` };
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

export function registerHealthMailuTools(server: McpServer): void {
  server.tool("mailu_up", "Quick UP: pre-flight + containers + network + DNS + internals", {},
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
    async () => safeTool(() => {
      clearRemoteCache();
      const marks: { phase: string; ms: number }[] = [];
      const t0 = performance.now();
      const mark = (phase: string) => { marks.push({ phase, ms: Math.round(performance.now() - t0) }); };
      const sections: string[] = [];

      log("Phase 1: PRE-FLIGHT starting...");
      mark("start");
      const pf = preflight();
      mark("1. PRE-FLIGHT");
      log(`Phase 1: done (${marks[marks.length - 1].ms}ms)`);
      sections.push(formatChecks("1. PRE-FLIGHT", pf));

      const sshOk = _remoteCache !== null;

      if (!sshOk) {
        log("SSH FAILED — skipping phases 2, 5");
        sections.push("", "⚠️ SSH to oci-mail FAILED — skipping container/internal checks");
        sections.push("", formatChecks("2. CONTAINERS", [{ name: "skipped", passed: false, details: "SSH unreachable", durationMs: 0 }]));
      } else {
        log("Phase 2: CONTAINERS starting...");
        sections.push("", formatChecks("2. CONTAINERS", containerHealth()));
        mark("2. CONTAINERS");
        log(`Phase 2: done (${marks[marks.length - 1].ms}ms)`);
      }

      log("Phase 3: NETWORK starting...");
      sections.push("", formatChecks("3. NETWORK", networkChecks()));
      mark("3. NETWORK");
      log(`Phase 3: done (${marks[marks.length - 1].ms}ms)`);

      log("Phase 4: DNS starting...");
      sections.push("", formatChecks("4. DNS AUTH", dnsAuth()));
      mark("4. DNS AUTH");
      log(`Phase 4: done (${marks[marks.length - 1].ms}ms)`);

      if (sshOk) {
        log("Phase 5: MAIL INTERNALS starting...");
        sections.push("", formatChecks("5. MAIL INTERNALS", mailInternals()));
        mark("5. MAIL INTERNALS");
        log(`Phase 5: done (${marks[marks.length - 1].ms}ms)`);
      } else {
        sections.push("", formatChecks("5. MAIL INTERNALS", [{ name: "skipped", passed: false, details: "SSH unreachable", durationMs: 0 }]));
      }

      log("Phase 6: E2E DELIVERY starting...");
      sections.push("", formatChecks("6. E2E DELIVERY", e2eDelivery()));
      mark("6. E2E DELIVERY");
      log(`Phase 6: done (${marks[marks.length - 1].ms}ms)`);

      // Performance summary
      const totalMs = Math.round(performance.now() - t0);
      const perfLines = marks.filter(m => m.phase !== "start").map(m => `  ${m.phase.padEnd(22)} ${(m.ms / 1000).toFixed(1)}s`);
      sections.push("", `PERFORMANCE (total: ${(totalMs / 1000).toFixed(1)}s)\n${"─".repeat(40)}\n${perfLines.join("\n")}`);

      log(`mailu_full complete: ${totalMs}ms`);
      return sections.join("\n");
    }),
  );
}
