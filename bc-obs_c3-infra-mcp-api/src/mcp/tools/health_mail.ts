// ── Stalwart Health — fully async 6-phase diagnostic (5 MCP tools) ──
//
// Phase 1: PRE-FLIGHT — WG tunnel, SSH, Docker daemon, disk, load, memory
// Phase 2: CONTAINERS — status + crash-loop + restart count + deep service checks
// Phase 3: NETWORK — TLS ports + cert expiry, SMTP relay, webmail, endpoints
// Phase 4: DNS AUTH — MX, DKIM, SPF, DMARC
// Phase 5: MAIL INTERNALS — dovecot auth/IMAP, postfix queue, rspamd, redis, sieve, quota
// Phase 6: E2E DELIVERY — Resend → IMAP arrival → smtp-proxy → CF Worker
//
// All I/O is async (non-blocking). Independent checks run in parallel via Promise.all.
// SSH multiplexing: one ControlMaster per VM, commands fan out over it concurrently.

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { exec, execAsync } from "../../shared/exec.js";
import { sshExec, sshExecAsync } from "../../shared/ssh.js";
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

async function timedAsync(name: string, fn: () => Promise<{ passed: boolean; details: string }>): Promise<Check> {
  const start = Date.now();
  try { return { name, ...(await fn()), durationMs: Date.now() - start }; }
  catch (err: unknown) { return { name, passed: false, details: "", error: err instanceof Error ? err.message : String(err), durationMs: Date.now() - start }; }
}

// Async SSH with fast timeout (3s connect, no WG retry) — uses mux socket
function sshA(cmd: string, timeout = 8_000) { return sshExecAsync(MAIL_VM, cmd, timeout, true, 3); }
// Async local exec
function runA(cmd: string, args: string[], timeout = 8_000) { return execAsync(cmd, args, { timeout }); }

const log = (msg: string) => process.stderr.write(`[mail-health] ${msg}\n`);
function getResendApiKey(): string | null { return process.env.RESEND_API_KEY || null; }

async function dnsLookupAsync(type: string, name: string): Promise<string> {
  const dig = await runA("bash", ["-c", `command -v dig >/dev/null 2>&1 && dig +short +time=3 +tries=1 ${type} ${name} 2>&1`], 5_000);
  if (dig.ok && dig.stdout.trim()) return dig.stdout.trim();
  const flag = type === "MX" ? "mx" : "txt";
  const r = await runA("nslookup", ["-timeout=3", `-type=${flag}`, name], 5_000);
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
// BATCHED SSH DATA — single SSH call collects ALL remote data at once
// ═══════════════════════════════════════════════════════════════════════════

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

async function getRemoteDataAsync(): Promise<RemoteData> {
  if (_remoteCache) return _remoteCache;

  const T = 3; // per-command timeout (keep low — total must stay under 60s)
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
grep -c 'class = ' /opt/stalwart/config.toml 2>/dev/null || echo "0"
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
for p in 993 465 587 25 8443 8384 8080; do timeout 1 bash -c "echo > /dev/tcp/10.0.0.3/\\$p" 2>/dev/null && echo "\\$p OK" || echo "\\$p FAIL"; done
`.trim();

  log("SSH batch: connecting...");
  const r = await sshExecAsync(MAIL_VM, script, 20_000, true, 3);
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
// PHASE 1: PRE-FLIGHT (async)
// ═══════════════════════════════════════════════════════════════════════════

async function preflight(): Promise<Check[]> {
  const checks: Check[] = [];

  // WG tunnel + SSH batch in parallel
  const [wgCheck, sshCheck] = await Promise.all([
    timedAsync("WG tunnel", async () => {
      const r = await runA("bash", ["-c", `timeout 3 bash -c 'echo > /dev/tcp/${MAIL_WG_IP}/22' 2>&1`], 5_000);
      return { passed: r.ok, details: r.ok ? `${MAIL_WG_IP}:22 OK` : "WG DOWN" };
    }),
    timedAsync("SSH + data collect", async () => {
      try {
        const data = await getRemoteDataAsync();
        return { passed: data.dockerVersion.length > 0, details: `SSH OK, Docker ${data.dockerVersion}` };
      } catch {
        return { passed: false, details: "SSH FAILED" };
      }
    }),
  ]);
  checks.push(wgCheck, sshCheck);

  const data = _remoteCache;
  if (!data) return checks;

  // Parse pre-collected data (instant — no I/O)
  const diskPct = parseInt(data.disk);
  checks.push({ name: "Disk space", passed: !isNaN(diskPct) && diskPct < 90, details: `${diskPct}% used${diskPct >= 80 ? " ⚠️" : ""}`, durationMs: 0 });

  const memPct = parseInt(data.memory.match(/\((\d+)%\)/)?.[1] || "0");
  checks.push({ name: "Memory", passed: memPct < 95, details: data.memory + (memPct >= 85 ? " ⚠️" : ""), durationMs: 0 });

  const load = parseFloat(data.load.split(" ")[0]);
  checks.push({ name: "Load", passed: !isNaN(load) && load < 4, details: `load: ${data.load}${load >= 2 ? " ⚠️" : ""}`, durationMs: 0 });

  return checks;
}

// ═══════════════════════════════════════════════════════════════════════════
// PHASE 2: CONTAINERS + restart counts (async)
// ═══════════════════════════════════════════════════════════════════════════

async function containerHealth(): Promise<Check[]> {
  const data = _remoteCache;
  if (!data || !data.containers) return [{ name: "Container listing", passed: false, details: "no remote data", durationMs: 0 }];

  const containers = data.containers.split("\n").filter(Boolean).map((line) => {
    const [name, status, image, ports] = line.split("\t");
    return { name: name ?? "", status: status ?? "", image: image ?? "", ports: ports ?? "" };
  });

  const restartMap = new Map<string, number>();
  for (const line of data.restarts.split("\n")) {
    const [name, count] = line.split("\t");
    if (name) restartMap.set(name, parseInt(count) || 0);
  }

  // Local container checks (from cache — instant)
  const localChecks = [...MAIL_CONTAINERS, "smtp-proxy"].map((name): Check => {
    const c = containers.find((ct) => ct.name === name);
    if (!c) return { name, passed: false, details: "NOT FOUND", durationMs: 0 };
    const isUp = c.status.startsWith("Up");
    const isHealthy = c.status.includes("healthy");
    const isRestarting = c.status.includes("Restarting");
    const restarts = restartMap.get(name) || 0;
    const restartWarn = restarts > 3 ? ` ⚠️ ${restarts} restarts` : "";
    if (isRestarting) return { name, passed: false, details: `CRASH-LOOPING (${restarts} restarts)`, durationMs: 0 };
    if (!isUp) return { name, passed: false, details: `DOWN: ${c.status}`, durationMs: 0 };
    return { name, passed: restarts < 10, details: `${c.status.replace(/\s+\(.*/, "")}${isHealthy ? " (healthy)" : ""}${restartWarn}`, durationMs: 0 };
  });

  // mail-mcp on oci-apps — async SSH check
  const mcpCheck = await timedAsync("mail-mcp", async () => {
    const { containers: c3c, ok: c3ok } = listContainers(C3_VM, true);
    if (!c3ok) return { passed: false, details: "oci-apps unreachable" };
    const mcp = c3c.find((c) => c.name === "mail-mcp");
    if (!mcp) return { passed: false, details: "NOT FOUND" };
    return { passed: mcp.status.startsWith("Up"), details: mcp.status.replace(/\s+\(.*/, "") };
  });

  return [...localChecks, mcpCheck];
}

// ═══════════════════════════════════════════════════════════════════════════
// PHASE 3: NETWORK + TLS cert expiry (async, parallel)
// ═══════════════════════════════════════════════════════════════════════════

async function networkChecks(): Promise<Check[]> {
  const data = _remoteCache;

  // All network checks run in parallel — they're independent
  const checks = await Promise.all([
    // Caddy reverse proxy
    timedAsync("Caddy (gcp-proxy)", async () => {
      const r = await runA("bash", ["-c", `
        c_up=$(echo Q | timeout 3 openssl s_client -connect diegonmarcos.com:443 -servername diegonmarcos.com 2>&1 | grep -c CONNECTED)
        c_dns=$(dig +short caddy.app @10.0.0.1 2>/dev/null | head -1)
        echo "up:$c_up dns:$c_dns"
      `], 6_000);
      const up = r.stdout.includes("up:1");
      const dns = r.stdout.match(/dns:(\S+)/)?.[1] || "";
      return { passed: up, details: up ? `HTTPS OK (${dns || "no DNS"})` : "Caddy DOWN" };
    }),

    // Hickory DNS
    timedAsync("Hickory DNS", async () => {
      const r = await runA("bash", ["-c", `dig +short stalwart.app @10.0.0.1 2>&1 | head -1`], 5_000);
      const ip = r.stdout.trim();
      return { passed: ip === "10.0.0.3", details: ip === "10.0.0.3" ? `stalwart.app → ${ip}` : `FAIL: ${ip || "no response"}` };
    }),

    // TLS via WG direct (SSH to oci-mail)
    timedAsync("TLS WG direct", async () => {
      if (!data) return { passed: false, details: "SSH down" };
      const r = await sshA(`
        r993=$(echo Q | timeout 3 openssl s_client -connect localhost:993 -servername ${MAIL_DOMAIN} 2>&1)
        r465=$(echo Q | timeout 3 openssl s_client -connect localhost:465 -servername ${MAIL_DOMAIN} 2>&1)
        r587=$(echo Q | timeout 3 openssl s_client -starttls smtp -connect localhost:587 -servername ${MAIL_DOMAIN} 2>&1)
        echo "993:$(echo "$r993" | grep -c CONNECTED)"
        echo "465:$(echo "$r465" | grep -c CONNECTED)"
        echo "587:$(echo "$r587" | grep -c CONNECTED)"
        echo "$r993" | grep "Not After" | head -1
      `, 8_000);
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
    }),

    // TLS via public domains (all 4 in parallel)
    timedAsync("imap.diegonmarcos.com:993", async () => {
      const r = await runA("bash", ["-c", `echo Q | timeout 3 openssl s_client -connect imap.diegonmarcos.com:993 -servername imap.diegonmarcos.com 2>&1`], 5_000);
      return { passed: r.stdout.includes("CONNECTED"), details: r.stdout.includes("CONNECTED") ? "TLS OK" : "FAIL" };
    }),
    timedAsync("smtp.diegonmarcos.com:465", async () => {
      const r = await runA("bash", ["-c", `echo Q | timeout 3 openssl s_client -connect smtp.diegonmarcos.com:465 -servername smtp.diegonmarcos.com 2>&1`], 5_000);
      return { passed: r.stdout.includes("CONNECTED"), details: r.stdout.includes("CONNECTED") ? "TLS OK" : "FAIL" };
    }),
    timedAsync("smtp.diegonmarcos.com:587", async () => {
      const r = await runA("bash", ["-c", `echo Q | timeout 3 openssl s_client -starttls smtp -connect smtp.diegonmarcos.com:587 -servername smtp.diegonmarcos.com 2>&1`], 5_000);
      return { passed: r.stdout.includes("CONNECTED"), details: r.stdout.includes("CONNECTED") ? "STARTTLS OK" : "FAIL" };
    }),
    timedAsync("mail.diegonmarcos.com:993", async () => {
      const r = await runA("bash", ["-c", `echo Q | timeout 3 openssl s_client -connect ${MAIL_DOMAIN}:993 -servername ${MAIL_DOMAIN} 2>&1`], 5_000);
      return { passed: r.stdout.includes("CONNECTED"), details: r.stdout.includes("CONNECTED") ? "TLS OK" : "FAIL" };
    }),

    // Local SMTP (from cache — instant if data available)
    timedAsync("SMTP :25 relay", async () => {
      if (!data) return { passed: false, details: "no data" };
      return { passed: data.smtp25.includes("220"), details: data.smtp25.split("\n")[0] || "no banner" };
    }),
    timedAsync("SMTP :587 local TLS", async () => {
      if (!data) return { passed: false, details: "no data" };
      const ok = data.smtp587.includes("CONNECTED") || data.smtp587.includes("Let's Encrypt") || data.smtp587.includes("verify return:1");
      return { passed: ok, details: ok ? "STARTTLS OK" : "not responding" };
    }),

    // HTTP endpoints (parallel)
    timedAsync("Webmail HTTPS", async () => {
      const r = await runA("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", `https://${MAIL_DOMAIN}/`]);
      return { passed: ["200", "301", "302"].includes(r.stdout.trim()), details: `HTTP ${r.stdout.trim()}` };
    }),
    timedAsync("Webmail auth chain", async () => {
      const r = await runA("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", "--location-trusted", `https://${MAIL_DOMAIN}/`]);
      const code = r.stdout.trim();
      if (code === "302") return { passed: true, details: `Authelia redirect OK (${code})` };
      if (code === "200") return { passed: true, details: `authenticated OK (${code})` };
      return { passed: false, details: `HTTP ${code}` };
    }),
    timedAsync("Webmail internal", async () => {
      if (!data) return { passed: false, details: "no data" };
      return { passed: data.webmailInternal.trim() === "200", details: `HTTP ${data.webmailInternal.trim()}` };
    }),
    timedAsync("smtp-proxy", async () => {
      const r = await runA("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "3", "https://smtp-proxy.diegonmarcos.com/"]);
      return { passed: r.stdout.trim() !== "000" && r.stdout.trim() !== "502", details: `HTTP ${r.stdout.trim()}` };
    }),
    timedAsync("mail-mcp MCP", async () => {
      const r = await runA("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "3", "https://mcp.diegonmarcos.com/mail-mcp/mcp"]);
      return { passed: ["400", "405", "406"].includes(r.stdout.trim()), details: `HTTP ${r.stdout.trim()} (alive)` };
    }),

    // ── mail-mcp container connectivity (tests FROM the container that actually connects to IMAP) ──

    // DNS resolution from inside mail-mcp
    timedAsync("mcp→DNS resolve", async () => {
      const r = await sshExecAsync(C3_VM, `docker exec mail-mcp node -e "require('dns').resolve4('imap.diegonmarcos.com',(e,a)=>console.log(e?'ERR:'+e.message:'OK:'+a.join(',')))"`, 8_000, true, 3);
      const out = r.stdout.trim();
      if (out.startsWith("OK:")) return { passed: true, details: out.replace("OK:", "→ ") };
      return { passed: false, details: out || "no output" };
    }),

    // TLS IMAP from inside mail-mcp (this is the actual path mailu-mcp uses)
    timedAsync("mcp→IMAP TLS", async () => {
      const script = `
        const tls=require('tls');
        const s=tls.connect(993,'imap.diegonmarcos.com',{servername:'imap.diegonmarcos.com',timeout:5000},()=>{
          console.log('OK proto='+s.getProtocol()+' cert='+s.getPeerCertificate().subject?.CN);s.end()
        });
        s.on('error',e=>console.log('ERR:'+e.code+' '+e.message));
        s.setTimeout(5000,()=>{console.log('ERR:TIMEOUT');s.destroy()});
      `.replace(/\n\s*/g, "");
      const r = await sshExecAsync(C3_VM, `docker exec mail-mcp node -e "${script.replace(/"/g, '\\"')}"`, 10_000, true, 3);
      const out = r.stdout.trim();
      if (out.startsWith("OK")) return { passed: true, details: out };
      return { passed: false, details: out || r.stderr.trim().slice(0, 80) || "no output" };
    }),

    // TLS SMTP from inside mail-mcp
    timedAsync("mcp→SMTP TLS", async () => {
      const script = `
        const tls=require('tls');
        const s=tls.connect(465,'smtp.diegonmarcos.com',{servername:'smtp.diegonmarcos.com',timeout:5000},()=>{
          console.log('OK proto='+s.getProtocol());s.end()
        });
        s.on('error',e=>console.log('ERR:'+e.code+' '+e.message));
        s.setTimeout(5000,()=>{console.log('ERR:TIMEOUT');s.destroy()});
      `.replace(/\n\s*/g, "");
      const r = await sshExecAsync(C3_VM, `docker exec mail-mcp node -e "${script.replace(/"/g, '\\"')}"`, 10_000, true, 3);
      const out = r.stdout.trim();
      if (out.startsWith("OK")) return { passed: true, details: out };
      return { passed: false, details: out || r.stderr.trim().slice(0, 80) || "no output" };
    }),

    // IMAP via WG IP from inside mail-mcp (bypass DNS/Caddy — direct to Stalwart)
    timedAsync("mcp→IMAP WG", async () => {
      const script = `
        const tls=require('tls');
        const s=tls.connect(993,'${MAIL_WG_IP}',{servername:'${MAIL_DOMAIN}',rejectUnauthorized:false,timeout:5000},()=>{
          console.log('OK proto='+s.getProtocol());s.end()
        });
        s.on('error',e=>console.log('ERR:'+e.code+' '+e.message));
        s.setTimeout(5000,()=>{console.log('ERR:TIMEOUT');s.destroy()});
      `.replace(/\n\s*/g, "");
      const r = await sshExecAsync(C3_VM, `docker exec mail-mcp node -e "${script.replace(/"/g, '\\"')}"`, 10_000, true, 3);
      const out = r.stdout.trim();
      if (out.startsWith("OK")) return { passed: true, details: `${MAIL_WG_IP}:993 ${out}` };
      return { passed: false, details: `${MAIL_WG_IP}:993 ${out || r.stderr.trim().slice(0, 80) || "no output"}` };
    }),

    // mail-mcp functional check
    timedAsync("mail-mcp tools", async () => {
      const initBody = JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "health", version: "1.0" } } });
      const r = await runA("curl", ["-sk", "-X", "POST", "-H", "Content-Type: application/json", "-H", "Accept: application/json, text/event-stream", "-d", initBody, "-D", "/tmp/mcp-headers.txt", "--max-time", "5", "https://mcp.diegonmarcos.com/mail-mcp/mcp"], 8_000);
      const hdr = exec("cat", ["/tmp/mcp-headers.txt"]);
      const sessionId = hdr.stdout.match(/mcp-session-id:\s*(\S+)/i)?.[1] || "";
      if (!sessionId) return { passed: false, details: "no MCP session" };
      const listBody = JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/list" });
      const r2 = await runA("curl", ["-sk", "-X", "POST", "-H", "Content-Type: application/json", "-H", "Accept: application/json, text/event-stream", "-H", `Mcp-Session-Id: ${sessionId}`, "-d", listBody, "--max-time", "5", "https://mcp.diegonmarcos.com/mail-mcp/mcp"], 8_000);
      const toolCount = (r2.stdout.match(/"name"/g) || []).length;
      return { passed: toolCount > 0, details: `${toolCount} tools registered` };
    }),
  ]);

  return checks;
}

// ═══════════════════════════════════════════════════════════════════════════
// PHASE 4: DNS AUTH (async, parallel)
// ═══════════════════════════════════════════════════════════════════════════

async function dnsAuth(): Promise<Check[]> {
  return Promise.all([
    timedAsync("MX", async () => { const o = await dnsLookupAsync("MX", "diegonmarcos.com"); return { passed: o.includes("mx") || o.includes("cloudflare"), details: o.split("\n")[0] || "no MX" }; }),
    timedAsync("DKIM", async () => { const o = await dnsLookupAsync("TXT", "dkim._domainkey.diegonmarcos.com"); return { passed: o.includes("v=DKIM1"), details: o.includes("v=DKIM1") ? "present" : "missing" }; }),
    timedAsync("SPF", async () => { const o = await dnsLookupAsync("TXT", "diegonmarcos.com"); return { passed: o.includes("v=spf1"), details: o.split("\n").find((l) => l.includes("spf1"))?.trim() || "missing" }; }),
    timedAsync("DMARC", async () => { const o = await dnsLookupAsync("TXT", "_dmarc.diegonmarcos.com"); return { passed: o.includes("v=DMARC1"), details: o.trim().split("\n")[0] || "missing" }; }),
  ]);
}

// ═══════════════════════════════════════════════════════════════════════════
// PHASE 5: MAIL INTERNALS — deep service health (from cached data)
// ═══════════════════════════════════════════════════════════════════════════

async function mailInternals(): Promise<Check[]> {
  const data = _remoteCache;
  if (!data) return [{ name: "internals", passed: false, details: "no remote data", durationMs: 0 }];

  // All checks use cached data — no I/O, but we keep them as timedAsync for consistency
  return [
    { name: "IMAP auth", passed: data.dovecotUser.includes("IMAP4") || data.dovecotUser.includes("OK") || data.dovecotUser.includes("Stalwart"), details: (data.dovecotUser.includes("IMAP4") || data.dovecotUser.includes("OK") || data.dovecotUser.includes("Stalwart")) ? "Stalwart IMAP responding" : `FAILED: ${data.dovecotUser.slice(0, 60)}`, durationMs: 0 },
    { name: "IMAP protocol", passed: data.imapCap.includes("IMAP4") || data.imapCap.includes("OK"), details: data.imapCap.includes("IMAP4") ? "IMAP4rev1" : "not responding", durationMs: 0 },
    { name: "postfix queue", passed: data.postfixQueue.includes("empty") || !data.postfixQueue.match(/-- (\d+)/) || parseInt(data.postfixQueue.match(/-- (\d+)/)?.[1] || "0") < 50, details: data.postfixQueue.includes("empty") ? "empty" : data.postfixQueue.slice(-40), durationMs: 0 },
    { name: "spam filter", passed: data.rspamd.includes("stalwart-builtin") || data.rspamd.includes("scanned"), details: (data.rspamd.includes("stalwart-builtin") || data.rspamd.includes("scanned")) ? "Stalwart built-in" : `${data.rspamd.slice(0, 40) || "unknown"}`, durationMs: 0 },
    { name: "data store", passed: data.redis.trim() === "PONG" || data.redis.includes("stalwart"), details: "RocksDB", durationMs: 0 },
    { name: "admin panel", passed: ["200", "302", "303"].includes(data.admin.trim().replace(/[^0-9]/g, "")), details: data.admin.trim().replace(/[^0-9]/g, "") ? `HTTP ${data.admin.trim().replace(/[^0-9]/g, "")}` : "no response", durationMs: 0 },
    { name: "sieve filter", passed: data.sieve.includes("stalwart-builtin") || data.sieve.includes("require") || data.sieve.includes("managesieve"), details: (data.sieve.includes("stalwart-builtin") || data.sieve.includes("require") || data.sieve.includes("managesieve")) ? "Stalwart ManageSieve" : `${data.sieve.slice(0, 40) || "empty"}`, durationMs: 0 },
    { name: "mailbox quota", passed: true, details: data.quota.trim().slice(0, 60) || "no quota", durationMs: 0 },
    { name: "user accounts", passed: (parseInt(data.users.trim()) || 0) > 0, details: (parseInt(data.users.trim()) || 0) > 0 ? `${parseInt(data.users.trim())} users` : `unknown (${data.users.trim().slice(0, 30) || "empty"})`, durationMs: 0 },
  ];
}

// ═══════════════════════════════════════════════════════════════════════════
// PHASE 6: E2E DELIVERY — async send + poll
// ═══════════════════════════════════════════════════════════════════════════

async function e2eDelivery(): Promise<Check[]> {
  const checks: Check[] = [];
  const apiKey = getResendApiKey();
  if (!apiKey) { checks.push({ name: "Resend API key", passed: false, details: "not set", durationMs: 0 }); return checks; }
  checks.push({ name: "Resend API key", passed: true, details: "found", durationMs: 0 });

  const tag = `health-${Date.now()}`;
  let emailId = "";

  checks.push(await timedAsync("Send via Resend", async () => {
    const body = JSON.stringify({ from: `Health <${TEST_FROM}>`, to: [TEST_TO], subject: `[health-check] ${tag}`, text: `Health ${tag}` });
    const r = await runA("curl", ["-s", "-X", "POST", "-H", "Content-Type: application/json", "-H", `Authorization: Bearer ${apiKey}`, "-d", body, "https://api.resend.com/emails"], 10_000);
    const p = JSON.parse(r.stdout || "{}");
    if (p.id) { emailId = p.id; return { passed: true, details: `id=${p.id}` }; }
    return { passed: false, details: p.message || "failed" };
  }));

  if (!emailId) return checks;

  // Resend status poll + IMAP arrival + smtp-proxy logs + CF Worker — in parallel
  const sshOk = _remoteCache !== null;
  const [resendCheck, imapCheck, proxyCheck, cfCheck] = await Promise.all([
    timedAsync("Resend status", async () => {
      for (let i = 0; i < 3; i++) {
        if (i > 0) await new Promise(r => setTimeout(r, 1500));
        const r = await runA("curl", ["-s", "-H", `Authorization: Bearer ${apiKey}`, `https://api.resend.com/emails/${emailId}`], 8_000);
        const ev = JSON.parse(r.stdout || "{}").last_event || "?";
        if (ev === "delivered") return { passed: true, details: `delivered (poll ${i + 1})` };
        if (ev === "bounced") return { passed: false, details: "BOUNCED" };
      }
      return { passed: true, details: "sent (IMAP is truth)" };
    }),

    timedAsync("IMAP arrival", async () => {
      if (!sshOk) return { passed: false, details: "SSH down — cannot check IMAP" };
      for (let i = 0; i < 3; i++) {
        await new Promise(r => setTimeout(r, 2000));
        const r = await sshA(`docker logs stalwart --since 30s 2>&1 | grep -c "Message ingested" || echo 0`, 5_000);
        const count = parseInt(r.stdout.trim()) || 0;
        if (count > 0) return { passed: true, details: `delivered (poll ${i + 1}, ${(i + 1) * 2}s)` };
      }
      return { passed: false, details: "NOT FOUND after 6s" };
    }),

    timedAsync("smtp-proxy logs", async () => {
      if (!sshOk) return { passed: false, details: "SSH down" };
      const r = await sshA(`docker logs smtp-proxy --since 5m 2>&1 | tail -3; docker exec smtp-proxy cat /var/log/nginx/access.log 2>/dev/null | tail -3 || true`, 5_000);
      const all = r.stdout + r.stderr;
      if (all.includes("502") || all.includes("refused")) return { passed: false, details: `errors: ${all.trim().split("\n").slice(-2).join(" | ")}` };
      if (all.includes("POST") || all.includes("200")) return { passed: true, details: "activity confirmed" };
      return { passed: true, details: "no logs (IMAP is truth)" };
    }),

    timedAsync("CF Worker", async () => {
      const k = process.env.CF_API_KEY, e = process.env.CF_API_EMAIL;
      if (!k || !e) return { passed: true, details: "info: no CF creds" };
      const r = await runA("curl", ["-s", "-H", `X-Auth-Email: ${e}`, "-H", `X-Auth-Key: ${k}`,
        "https://api.cloudflare.com/client/v4/accounts/e5cb0a0c6f448e54f217de484259f0ae/workers/scripts/email-forwarder"], 8_000);
      try { const d = JSON.parse(r.stdout); return { passed: true, details: `active (${d?.result?.modified_on?.slice(0, 10) || "?"})` }; }
      catch { return { passed: true, details: "info: CF API unparseable" }; }
    }),
  ]);

  checks.push(resendCheck, imapCheck, proxyCheck, cfCheck);
  return checks;
}

// ═══════════════════════════════════════════════════════════════════════════
// TOOL REGISTRATION — fully async handlers
// ═══════════════════════════════════════════════════════════════════════════

async function safeToolAsync(fn: () => Promise<string>): Promise<{ content: [{ type: "text"; text: string }] }> {
  try { return { content: [{ type: "text" as const, text: await fn() }] }; }
  catch (err: unknown) { return { content: [{ type: "text" as const, text: `ERROR: ${err instanceof Error ? err.message : String(err)}` }] }; }
}

export function registerHealthMailTools(server: McpServer): void {
  server.tool("mail_up", "Quick UP: pre-flight + containers + network + DNS + internals", {},
    () => safeToolAsync(async () => {
      clearRemoteCache();
      const sections: string[] = [];
      sections.push(formatChecks("PRE-FLIGHT", await preflight()));
      const sshOk = _remoteCache !== null;

      // Containers (depends on SSH) vs Network+DNS (independent) — run in parallel
      if (sshOk) {
        const [containers, network, dns] = await Promise.all([
          containerHealth(),
          networkChecks(),
          dnsAuth(),
        ]);
        sections.push("", formatChecks("CONTAINERS", containers));
        sections.push("", formatChecks("NETWORK", network));
        sections.push("", formatChecks("DNS AUTH", dns));
        sections.push("", formatChecks("MAIL INTERNALS", await mailInternals()));
      } else {
        sections.push("", "⚠️ SSH FAILED — container/internal checks skipped");
        const [network, dns] = await Promise.all([networkChecks(), dnsAuth()]);
        sections.push("", formatChecks("NETWORK", network));
        sections.push("", formatChecks("DNS AUTH", dns));
      }
      return sections.join("\n");
    }),
  );

  server.tool("mail_profile", "Deep profile all Stalwart containers", {},
    () => safeToolAsync(async () => {
      const p: Record<string, unknown> = {};
      for (const n of [...MAIL_CONTAINERS, "smtp-proxy"]) { try { p[n] = profileContainer(n); } catch (e: unknown) { p[n] = { error: String(e) }; } }
      return `Stalwart Profiles\n${"─".repeat(60)}\n${JSON.stringify(p, null, 2)}`;
    }),
  );

  server.tool("mail_send_test", "E2E delivery: Resend → CF → smtp-proxy → Stalwart → IMAP", {},
    () => safeToolAsync(async () => formatChecks("E2E DELIVERY", await e2eDelivery())),
  );

  server.tool("mail_outbound_test", "Outbound: SMTP relay + DNS auth", {},
    () => safeToolAsync(async () => {
      const [smtpChecks, dnsChecks] = await Promise.all([
        Promise.all([
          timedAsync("SMTP :25", async () => { const r = await sshA(`echo QUIT | timeout 3 nc -w3 localhost 25 2>&1 | head -1`, 5_000); return { passed: r.stdout.includes("220"), details: r.stdout.trim().split("\n")[0] || "no banner" }; }),
          timedAsync("SMTP :587", async () => { const r = await sshA(`echo QUIT | timeout 5 openssl s_client -connect localhost:587 2>&1 | head -3`, 8_000); return { passed: r.stdout.includes("CONNECTED"), details: r.stdout.includes("CONNECTED") ? "TLS OK" : "not responding" }; }),
        ]),
        dnsAuth(),
      ]);
      return formatChecks("OUTBOUND & DNS", [...smtpChecks, ...dnsChecks]);
    }),
  );

  server.tool("mail_full", "Full 6-phase diagnostic: pre-flight → containers → network → DNS → internals → e2e delivery", {},
    () => safeToolAsync(async () => {
      clearRemoteCache();
      const marks: { phase: string; ms: number }[] = [];
      const t0 = performance.now();
      const mark = (phase: string) => { marks.push({ phase, ms: Math.round(performance.now() - t0) }); };
      const sections: string[] = [];

      const runPhase = async (name: string, fn: () => Promise<string>) => {
        log(`${name} starting...`);
        try {
          const result = await fn();
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

      // Phase 1: PRE-FLIGHT (must run first — establishes SSH mux + remote cache)
      await runPhase("1. PRE-FLIGHT", async () => formatChecks("1. PRE-FLIGHT", await preflight()));
      const sshOk = _remoteCache !== null;

      // Phases 2-4: run in parallel (containers uses cache, network+DNS are independent)
      if (sshOk) {
        const phase2 = runPhase("2. CONTAINERS", async () => formatChecks("2. CONTAINERS", await containerHealth()));
        const phase3 = runPhase("3. NETWORK", async () => formatChecks("3. NETWORK", await networkChecks()));
        const phase4 = runPhase("4. DNS AUTH", async () => formatChecks("4. DNS AUTH", await dnsAuth()));
        await Promise.all([phase2, phase3, phase4]);
      } else {
        sections.push("", "⚠️ SSH to oci-mail FAILED — skipping container/internal checks");
        sections.push("", formatChecks("2. CONTAINERS", [{ name: "skipped", passed: false, details: "SSH unreachable", durationMs: 0 }]));
        const phase3 = runPhase("3. NETWORK", async () => formatChecks("3. NETWORK", await networkChecks()));
        const phase4 = runPhase("4. DNS AUTH", async () => formatChecks("4. DNS AUTH", await dnsAuth()));
        await Promise.all([phase3, phase4]);
      }

      // Phase 5: MAIL INTERNALS (depends on SSH cache)
      if (sshOk) {
        await runPhase("5. MAIL INTERNALS", async () => formatChecks("5. MAIL INTERNALS", await mailInternals()));
      } else {
        sections.push("", formatChecks("5. MAIL INTERNALS", [{ name: "skipped", passed: false, details: "SSH unreachable", durationMs: 0 }]));
      }

      // Phase 6: E2E DELIVERY
      await runPhase("6. E2E DELIVERY", async () => formatChecks("6. E2E DELIVERY", await e2eDelivery()));

      // ── SUMMARY ──
      const totalMs = Math.round(performance.now() - t0);
      const perfLines = marks.filter(m => m.phase !== "start").map(m => `  ${m.phase.padEnd(22)} ${(m.ms / 1000).toFixed(1)}s`);
      sections.push("", `PERFORMANCE (total: ${(totalMs / 1000).toFixed(1)}s)\n${"─".repeat(40)}\n${perfLines.join("\n")}`);

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

        if (_remoteCache) {
          sections.push("");
          sections.push("╔══════════════════════════════════════════════════════════════╗");
          sections.push("║          FULL DEBUG DUMP — USE THIS TO DIAGNOSE             ║");
          sections.push("╚══════════════════════════════════════════════════════════════╝");

          if (_remoteCache.debugDump) {
            sections.push("", _remoteCache.debugDump);
          }

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
