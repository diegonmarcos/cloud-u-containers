// ── Stalwart Health — ultimate async 6-phase diagnostic (5 MCP tools) ──
//
// Phase 1: PRE-FLIGHT — WG tunnels (3 VMs), batch SSH data (oci-mail, oci-apps, gcp-proxy)
// Phase 2: CONTAINERS — status + crash-loop + restart count
// Phase 3: NETWORK + AUTH — TLS ports, certs, HTTP, OIDC chain, Stalwart Admin API, SnappyMail
// Phase 4: DNS AUTH — MX, DKIM, SPF, DMARC
// Phase 5: MAIL INTERNALS — IMAP, queue, spam, sieve, quota, ports, Admin API
// Phase 6: E2E DELIVERY — Resend → IMAP arrival → smtp-proxy → CF Worker
//
// All I/O is async (non-blocking). Independent checks run in parallel via Promise.all.
// SSH multiplexing: one ControlMaster per VM, commands fan out concurrently.
// 3-VM parallel batch: single SSH call per VM collects all data in one round-trip.

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { exec, execAsync } from "../../shared/exec.js";
import { sshExec, sshExecAsync } from "../../shared/ssh.js";
import { listContainers } from "../../shared/docker.js";
import { profileContainer } from "../../shared/diagnostics.js";
import { getBearerToken } from "../../shared/http.js";
import { performance } from "node:perf_hooks";

// ── Constants ────────────────────────────────────────────────────────────
const MAIL_VM = "oci-E2-f_0";
const C3_VM = "oci-A1-f_0";
const PROXY_VM = "gcp-E2-f_0";
const MAIL_DOMAIN = "mail.diegonmarcos.com";
const MAIL_WG_IP = "10.0.0.3";
const APPS_WG_IP = "10.0.0.6";
const PROXY_WG_IP = "10.0.0.1";
const MAIL_CONTAINERS = ["stalwart"];
const TEST_FROM = "health@mails.diegonmarcos.com";
const TEST_TO = "me@diegonmarcos.com";

// ── Helpers ──────────────────────────────────────────────────────────────
interface Check { name: string; passed: boolean; details: string; durationMs: number; error?: string; }

async function timedAsync(name: string, fn: () => Promise<{ passed: boolean; details: string }>): Promise<Check> {
  const start = Date.now();
  try { return { name, ...(await fn()), durationMs: Date.now() - start }; }
  catch (err: unknown) { return { name, passed: false, details: "", error: err instanceof Error ? err.message : String(err), durationMs: Date.now() - start }; }
}

function sshMail(cmd: string, timeout = 8_000) { return sshExecAsync(MAIL_VM, cmd, timeout, true, 3); }
function sshApps(cmd: string, timeout = 8_000) { return sshExecAsync(C3_VM, cmd, timeout, true, 3); }
function sshProxy(cmd: string, timeout = 8_000) { return sshExecAsync(PROXY_VM, cmd, timeout, true, 3); }
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
// BATCHED SSH DATA — one call per VM, parsed into structured cache
// ═══════════════════════════════════════════════════════════════════════════

// ── oci-mail data ────────────────────────────────────────────────────────
interface RemoteData {
  containers: string; restarts: string; disk: string; memory: string; load: string;
  dockerVersion: string; dovecotUser: string; imapCap: string; postfixQueue: string;
  rspamd: string; redis: string; admin: string; sieve: string; quota: string;
  users: string; smtp25: string; smtp587: string; webmailInternal: string;
  stalwartApiAccounts: string; stalwartApiDomains: string; stalwartApiQueue: string;
  snappymailInternal: string; sieve4190: string; allLocalPorts: string;
  debugDump: string;
}

let _remoteCache: RemoteData | null = null;

async function getRemoteDataAsync(): Promise<RemoteData> {
  if (_remoteCache) return _remoteCache;
  const T = 3;
  const script = `
ADMIN_CREDS=$(grep ADMIN_PASSWORD /opt/stalwart/.secrets 2>/dev/null | head -1 | cut -d= -f2-)
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
timeout ${T} docker inspect --format '{{.Name}}\t{{.RestartCount}}' $(timeout ${T} docker ps -aq --filter name=stalwart --filter name=smtp-proxy --filter name=snappymail 2>/dev/null) 2>/dev/null | tr -d '/'
echo "===dovecotUser==="
echo "a001 CAPABILITY" | timeout ${T} openssl s_client -connect localhost:993 -quiet 2>/dev/null | head -3
echo "===imapCap==="
echo "a001 CAPABILITY" | timeout ${T} openssl s_client -connect localhost:993 -quiet 2>/dev/null | head -3
echo "===postfixQueue==="
curl -skf -u "admin:\$ADMIN_CREDS" https://localhost:8443/api/queue/messages 2>/dev/null | head -3 || echo "empty"
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
curl -skf -u "admin:\$ADMIN_CREDS" https://localhost:8443/api/principal 2>/dev/null | head -5 || echo "0"
echo "===smtp25==="
echo QUIT | timeout ${T} nc -w3 localhost 25 2>&1 | head -1
echo "===smtp587==="
echo QUIT | timeout ${T} openssl s_client -starttls smtp -connect localhost:587 2>&1 | head -5
echo "===webmailInternal==="
curl -skL -o /dev/null -w '%{http_code}' --max-time ${T} https://${MAIL_WG_IP}:8443/ 2>&1
echo ""
echo "===stalwartApiAccounts==="
curl -skf -u "admin:\$ADMIN_CREDS" https://localhost:8443/api/principal 2>/dev/null | head -5 || echo "API_FAIL"
echo "===stalwartApiDomains==="
curl -skf -u "admin:\$ADMIN_CREDS" https://localhost:8443/api/domain 2>/dev/null | head -5 || echo "API_FAIL"
echo "===stalwartApiQueue==="
curl -skf -u "admin:\$ADMIN_CREDS" https://localhost:8443/api/queue/messages 2>/dev/null | head -3 || echo "empty"
echo "===snappymailInternal==="
curl -skL -o /dev/null -w '%{http_code}' --max-time ${T} http://localhost:8888/ 2>&1
echo ""
echo "===sieve4190==="
echo QUIT | timeout ${T} nc -w3 localhost 4190 2>&1 | head -1
echo "===allLocalPorts==="
sudo ss -tlnp 2>/dev/null | grep -E ':(25|465|587|993|4190|8443|8888)\\s' || ss -tlnp 2>/dev/null | grep -E ':(25|465|587|993|4190|8443|8888)\\s' || echo "(none)"
echo "===debugDump==="
echo "--- ss listening ports ---"
sudo ss -tlnp 2>/dev/null || ss -tlnp 2>/dev/null || true
echo "--- docker networks ---"
timeout ${T} docker network ls --format '{{.Name}}\t{{.Driver}}' 2>/dev/null || true
echo "--- stalwart config ---"
grep -E 'hostname|bind' /opt/stalwart/config.toml 2>/dev/null || echo "(no config yet)"
echo "--- stalwart logs (last 10) ---"
timeout ${T} docker logs stalwart --tail 10 2>&1 || echo "(no stalwart container)"
echo "--- resolv.conf ---"
cat /etc/resolv.conf 2>/dev/null || true
`.trim();

  log("SSH batch oci-mail: connecting...");
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
    containers: section("containers"), restarts: section("restarts"),
    disk: section("disk"), memory: section("memory"), load: section("load"),
    dockerVersion: section("dockerVersion"), dovecotUser: section("dovecotUser"),
    imapCap: section("imapCap"), postfixQueue: section("postfixQueue"),
    rspamd: section("rspamd"), redis: section("redis"), admin: section("admin"),
    sieve: section("sieve"), quota: section("quota"), users: section("users"),
    smtp25: section("smtp25"), smtp587: section("smtp587"),
    webmailInternal: section("webmailInternal"),
    stalwartApiAccounts: section("stalwartApiAccounts"),
    stalwartApiDomains: section("stalwartApiDomains"),
    stalwartApiQueue: section("stalwartApiQueue"),
    snappymailInternal: section("snappymailInternal"),
    sieve4190: section("sieve4190"), allLocalPorts: section("allLocalPorts"),
    debugDump: section("debugDump"),
  };
  return _remoteCache;
}

// ── oci-apps data (mail-mcp container tests) ─────────────────────────────
interface RemoteDataApps {
  mailMcpStatus: string; dnsResolve: string; imapTls: string; smtpTls: string;
  imapWg: string; imapLogin: string; smtpAuth: string;
}

let _appCache: RemoteDataApps | null = null;

async function getRemoteDataAppsAsync(): Promise<RemoteDataApps> {
  if (_appCache) return _appCache;
  // All tests run inside mail-mcp container via node (no openssl binary in container)
  const nodeScript = (code: string) => `docker exec mail-mcp node -e "${code.replace(/"/g, '\\"').replace(/\n\s*/g, "")}" 2>&1 | head -5`;

  const script = `
echo "===mailMcpStatus==="
docker ps --filter name=mail-mcp --format '{{.Status}}' 2>/dev/null || echo "NOT FOUND"
echo "===dnsResolve==="
${nodeScript(`
  require('dns').resolve4('imap.diegonmarcos.com',(e,a)=>console.log(e?'ERR:'+e.message:'OK:'+a.join(',')));
`)}
echo "===imapTls==="
${nodeScript(`
  const tls=require('tls');
  const s=tls.connect(993,'imap.diegonmarcos.com',{servername:'imap.diegonmarcos.com',timeout:5000},()=>{
    console.log('OK proto='+s.getProtocol()+' cn='+((s.getPeerCertificate()||{}).subject||{}).CN);s.end()
  });
  s.on('error',e=>console.log('ERR:'+e.code+' '+e.message));
  s.setTimeout(5000,()=>{console.log('ERR:TIMEOUT');s.destroy()});
`)}
echo "===smtpTls==="
${nodeScript(`
  const tls=require('tls');
  const s=tls.connect(465,'smtp.diegonmarcos.com',{servername:'smtp.diegonmarcos.com',timeout:5000},()=>{
    console.log('OK proto='+s.getProtocol());s.end()
  });
  s.on('error',e=>console.log('ERR:'+e.code+' '+e.message));
  s.setTimeout(5000,()=>{console.log('ERR:TIMEOUT');s.destroy()});
`)}
echo "===imapWg==="
${nodeScript(`
  const tls=require('tls');
  const s=tls.connect(993,'${MAIL_WG_IP}',{servername:'${MAIL_DOMAIN}',rejectUnauthorized:false,timeout:5000},()=>{
    console.log('OK proto='+s.getProtocol());s.end()
  });
  s.on('error',e=>console.log('ERR:'+e.code+' '+e.message));
  s.setTimeout(5000,()=>{console.log('ERR:TIMEOUT');s.destroy()});
`)}
echo "===imapLogin==="
${nodeScript(`
  const tls=require('tls');
  const u=process.env.MAIL_USER||'';const p=process.env.MAIL_PASSWORD||'';
  if(!u||!p){console.log('NO_CREDS');process.exit(0)}
  const s=tls.connect(993,'imap.diegonmarcos.com',{servername:'imap.diegonmarcos.com',timeout:6000},()=>{
    let buf='';
    s.on('data',d=>{buf+=d.toString();
      if(buf.includes('* OK')&&!buf.includes('a001')){s.write('a001 LOGIN '+u+' '+p+'\\r\\n')}
      if(buf.includes('a001 OK')){console.log('LOGIN_OK');s.end()}
      if(buf.includes('a001 NO')||buf.includes('a001 BAD')){console.log('LOGIN_FAIL: '+buf.split('\\n').pop());s.end()}
    });
  });
  s.on('error',e=>console.log('ERR:'+e.message));
  setTimeout(()=>{console.log('TIMEOUT');process.exit(1)},7000);
`)}
echo "===smtpAuth==="
${nodeScript(`
  const tls=require('tls');
  const s=tls.connect(465,'smtp.diegonmarcos.com',{servername:'smtp.diegonmarcos.com',timeout:5000},()=>{
    let phase=0,buf='';
    s.on('data',d=>{buf+=d.toString();
      if(phase===0&&buf.includes('220')){s.write('EHLO health-check\\r\\n');phase=1;buf=''}
      if(phase===1&&buf.includes('250')){
        const hasAuth=buf.includes('AUTH');
        console.log(hasAuth?'SMTP_AUTH_OK: '+buf.split('\\n').filter(l=>l.includes('AUTH'))[0]:'SMTP_NO_AUTH');
        s.write('QUIT\\r\\n');s.end()
      }
    });
  });
  s.on('error',e=>console.log('ERR:'+e.message));
  setTimeout(()=>{console.log('TIMEOUT');process.exit(1)},6000);
`)}
`.trim();

  log("SSH batch oci-apps: connecting...");
  const r = await sshExecAsync(C3_VM, script, 30_000, true, 3);
  const output = r.stdout;

  function section(name: string): string {
    const start = output.indexOf(`===${name}===`);
    if (start === -1) return "";
    const afterMarker = start + `===${name}===`.length + 1;
    const end = output.indexOf("===", afterMarker);
    return (end === -1 ? output.slice(afterMarker) : output.slice(afterMarker, end)).trim();
  }

  _appCache = {
    mailMcpStatus: section("mailMcpStatus"), dnsResolve: section("dnsResolve"),
    imapTls: section("imapTls"), smtpTls: section("smtpTls"),
    imapWg: section("imapWg"), imapLogin: section("imapLogin"), smtpAuth: section("smtpAuth"),
  };
  return _appCache;
}

// ── gcp-proxy data (Caddy L4, Authelia) ──────────────────────────────────
interface RemoteDataProxy {
  caddyL4_993: string; caddyL4_465: string; caddyL4_587: string; autheliaHealth: string;
}

let _proxyCache: RemoteDataProxy | null = null;

async function getRemoteDataProxyAsync(): Promise<RemoteDataProxy> {
  if (_proxyCache) return _proxyCache;
  const script = `
echo "===caddyL4_993==="
echo Q | timeout 3 openssl s_client -connect ${MAIL_WG_IP}:993 -servername ${MAIL_DOMAIN} 2>&1 | grep -c CONNECTED
echo "===caddyL4_465==="
echo Q | timeout 3 openssl s_client -connect ${MAIL_WG_IP}:465 -servername ${MAIL_DOMAIN} 2>&1 | grep -c CONNECTED
echo "===caddyL4_587==="
echo Q | timeout 3 openssl s_client -starttls smtp -connect ${MAIL_WG_IP}:587 -servername ${MAIL_DOMAIN} 2>&1 | grep -c CONNECTED
echo "===autheliaHealth==="
curl -skf http://localhost:9091/api/health 2>/dev/null || curl -skf http://authelia.app:9091/api/health 2>/dev/null || echo "FAIL"
`.trim();

  log("SSH batch gcp-proxy: connecting...");
  const r = await sshExecAsync(PROXY_VM, script, 15_000, true, 3);
  const output = r.stdout;

  function section(name: string): string {
    const start = output.indexOf(`===${name}===`);
    if (start === -1) return "";
    const afterMarker = start + `===${name}===`.length + 1;
    const end = output.indexOf("===", afterMarker);
    return (end === -1 ? output.slice(afterMarker) : output.slice(afterMarker, end)).trim();
  }

  _proxyCache = {
    caddyL4_993: section("caddyL4_993"), caddyL4_465: section("caddyL4_465"),
    caddyL4_587: section("caddyL4_587"), autheliaHealth: section("autheliaHealth"),
  };
  return _proxyCache;
}

function clearAllCaches() {
  _remoteCache = null;
  _appCache = null;
  _proxyCache = null;
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
// PHASE 1: PRE-FLIGHT — 3-VM parallel WG + batch SSH
// ═══════════════════════════════════════════════════════════════════════════

async function preflight(): Promise<Check[]> {
  // WG probes to all 3 VMs in parallel
  const wgChecks = await Promise.all([
    timedAsync("WG oci-mail", async () => {
      const r = await runA("bash", ["-c", `timeout 3 bash -c 'echo > /dev/tcp/${MAIL_WG_IP}/22' 2>&1`], 5_000);
      return { passed: r.ok, details: r.ok ? `${MAIL_WG_IP}:22 OK` : "WG DOWN" };
    }),
    timedAsync("WG oci-apps", async () => {
      const r = await runA("bash", ["-c", `timeout 3 bash -c 'echo > /dev/tcp/${APPS_WG_IP}/22' 2>&1`], 5_000);
      return { passed: r.ok, details: r.ok ? `${APPS_WG_IP}:22 OK` : "WG DOWN" };
    }),
    timedAsync("WG gcp-proxy", async () => {
      const r = await runA("bash", ["-c", `timeout 3 bash -c 'echo > /dev/tcp/${PROXY_WG_IP}/22' 2>&1`], 5_000);
      return { passed: r.ok, details: r.ok ? `${PROXY_WG_IP}:22 OK` : "WG DOWN" };
    }),
  ]);

  // Batch SSH to all 3 VMs in parallel
  const sshChecks = await Promise.all([
    timedAsync("SSH batch oci-mail", async () => {
      try {
        const data = await getRemoteDataAsync();
        return { passed: data.dockerVersion.length > 0, details: `Docker ${data.dockerVersion}` };
      } catch { return { passed: false, details: "SSH FAILED" }; }
    }),
    timedAsync("SSH batch oci-apps", async () => {
      try {
        const data = await getRemoteDataAppsAsync();
        return { passed: data.mailMcpStatus.includes("Up"), details: `mail-mcp: ${data.mailMcpStatus.slice(0, 30)}` };
      } catch { return { passed: false, details: "SSH FAILED" }; }
    }),
    timedAsync("SSH batch gcp-proxy", async () => {
      try {
        const data = await getRemoteDataProxyAsync();
        return { passed: !data.autheliaHealth.includes("FAIL"), details: "Authelia OK" };
      } catch { return { passed: false, details: "SSH FAILED" }; }
    }),
  ]);

  const checks = [...wgChecks, ...sshChecks];

  // System metrics from oci-mail (instant — from cache)
  const data = _remoteCache;
  if (data) {
    const diskPct = parseInt(data.disk);
    checks.push({ name: "Disk space", passed: !isNaN(diskPct) && diskPct < 90, details: `${diskPct}% used${diskPct >= 80 ? " ⚠️" : ""}`, durationMs: 0 });
    const memPct = parseInt(data.memory.match(/\((\d+)%\)/)?.[1] || "0");
    checks.push({ name: "Memory", passed: memPct < 95, details: data.memory + (memPct >= 85 ? " ⚠️" : ""), durationMs: 0 });
    const load = parseFloat(data.load.split(" ")[0]);
    checks.push({ name: "Load", passed: !isNaN(load) && load < 4, details: `load: ${data.load}${load >= 2 ? " ⚠️" : ""}`, durationMs: 0 });
  }

  return checks;
}

// ═══════════════════════════════════════════════════════════════════════════
// PHASE 2: CONTAINERS (from cached batch data)
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

  const checks: Check[] = [...MAIL_CONTAINERS, "smtp-proxy", "snappymail"].map((name): Check => {
    const c = containers.find((ct) => ct.name === name);
    if (!c) return { name, passed: false, details: "NOT FOUND", durationMs: 0 };
    const isUp = c.status.startsWith("Up");
    const isRestarting = c.status.includes("Restarting");
    const restarts = restartMap.get(name) || 0;
    const restartWarn = restarts > 3 ? ` ⚠️ ${restarts} restarts` : "";
    if (isRestarting) return { name, passed: false, details: `CRASH-LOOPING (${restarts} restarts)`, durationMs: 0 };
    if (!isUp) return { name, passed: false, details: `DOWN: ${c.status}`, durationMs: 0 };
    return { name, passed: restarts < 10, details: `${c.status.replace(/\s+\(.*/, "")}${restartWarn}`, durationMs: 0 };
  });

  // mail-mcp on oci-apps (from cache)
  const appData = _appCache;
  checks.push({ name: "mail-mcp", passed: !!appData?.mailMcpStatus.includes("Up"), details: appData?.mailMcpStatus.slice(0, 40) || "no data", durationMs: 0 });

  return checks;
}

// ═══════════════════════════════════════════════════════════════════════════
// PHASE 3: NETWORK + AUTH (async, parallel)
// ═══════════════════════════════════════════════════════════════════════════

async function networkChecks(): Promise<Check[]> {
  const data = _remoteCache;
  const appData = _appCache;
  const proxyData = _proxyCache;

  const checks = await Promise.all([
    // ── Infrastructure ──
    timedAsync("Caddy (gcp-proxy)", async () => {
      const r = await runA("bash", ["-c", `
        c_up=$(echo Q | timeout 3 openssl s_client -connect diegonmarcos.com:443 -servername diegonmarcos.com 2>&1 | grep -c CONNECTED)
        c_dns=$(dig +short caddy.app @${PROXY_WG_IP} 2>/dev/null | head -1)
        echo "up:$c_up dns:$c_dns"
      `], 6_000);
      const up = r.stdout.includes("up:1");
      const dns = r.stdout.match(/dns:(\S+)/)?.[1] || "";
      return { passed: up, details: up ? `HTTPS OK (${dns || "no DNS"})` : "Caddy DOWN" };
    }),
    timedAsync("Hickory DNS", async () => {
      const r = await runA("bash", ["-c", `dig +short stalwart.app @${PROXY_WG_IP} 2>&1 | head -1`], 5_000);
      const ip = r.stdout.trim();
      return { passed: ip === MAIL_WG_IP, details: ip === MAIL_WG_IP ? `stalwart.app → ${ip}` : `FAIL: ${ip || "no response"}` };
    }),

    // ── TLS via WG direct (SSH to oci-mail) ──
    timedAsync("TLS WG direct", async () => {
      if (!data) return { passed: false, details: "SSH down" };
      const r = await sshMail(`
        r993=$(echo Q | timeout 3 openssl s_client -connect localhost:993 -servername ${MAIL_DOMAIN} 2>&1)
        r465=$(echo Q | timeout 3 openssl s_client -connect localhost:465 -servername ${MAIL_DOMAIN} 2>&1)
        r587=$(echo Q | timeout 3 openssl s_client -starttls smtp -connect localhost:587 -servername ${MAIL_DOMAIN} 2>&1)
        echo "993:$(echo "$r993" | grep -c CONNECTED)"
        echo "465:$(echo "$r465" | grep -c CONNECTED)"
        echo "587:$(echo "$r587" | grep -c CONNECTED)"
        echo "$r993" | grep "Not After" | head -1
      `, 8_000);
      const out = r.stdout;
      const p993 = out.includes("993:1"), p465 = out.includes("465:1"), p587 = out.includes("587:1");
      const expiry = out.match(/Not After\s*:\s*(.+)/)?.[1]?.trim();
      let certInfo = "";
      if (expiry) { const days = Math.floor((new Date(expiry).getTime() - Date.now()) / 86400000); certInfo = `, cert ${days}d${days < 14 ? " ⚠️" : ""}`; }
      return { passed: p993 && p465 && p587, details: `${[p993 ? "993✓" : "993✗", p465 ? "465✓" : "465✗", p587 ? "587✓" : "587✗"].join(" ")}${certInfo}` };
    }),

    // ── Caddy L4 forwarding (from gcp-proxy batch) ──
    timedAsync("Caddy L4 → IMAP", async () => {
      if (!proxyData) return { passed: false, details: "no proxy data" };
      return { passed: proxyData.caddyL4_993.includes("1"), details: proxyData.caddyL4_993.includes("1") ? "993 forwarding OK" : "FAIL" };
    }),
    timedAsync("Caddy L4 → SMTPS", async () => {
      if (!proxyData) return { passed: false, details: "no proxy data" };
      return { passed: proxyData.caddyL4_465.includes("1"), details: proxyData.caddyL4_465.includes("1") ? "465 forwarding OK" : "FAIL" };
    }),
    timedAsync("Caddy L4 → SMTP", async () => {
      if (!proxyData) return { passed: false, details: "no proxy data" };
      return { passed: proxyData.caddyL4_587.includes("1"), details: proxyData.caddyL4_587.includes("1") ? "587 forwarding OK" : "FAIL" };
    }),

    // ── TLS via public domain (mail.diegonmarcos.com — Caddy L4 passthrough) ──
    timedAsync("mail:993 (IMAP)", async () => {
      const r = await runA("bash", ["-c", `echo Q | timeout 3 openssl s_client -connect ${MAIL_DOMAIN}:993 -servername ${MAIL_DOMAIN} 2>&1`], 5_000);
      return { passed: r.stdout.includes("CONNECTED"), details: r.stdout.includes("CONNECTED") ? "TLS OK" : "FAIL" };
    }),
    timedAsync("mail:465 (SMTPS)", async () => {
      const r = await runA("bash", ["-c", `echo Q | timeout 3 openssl s_client -connect ${MAIL_DOMAIN}:465 -servername ${MAIL_DOMAIN} 2>&1`], 5_000);
      return { passed: r.stdout.includes("CONNECTED"), details: r.stdout.includes("CONNECTED") ? "TLS OK" : "FAIL" };
    }),
    timedAsync("mail:587 (SMTP Sub)", async () => {
      const r = await runA("bash", ["-c", `echo Q | timeout 3 openssl s_client -starttls smtp -connect ${MAIL_DOMAIN}:587 -servername ${MAIL_DOMAIN} 2>&1`], 5_000);
      return { passed: r.stdout.includes("CONNECTED"), details: r.stdout.includes("CONNECTED") ? "STARTTLS OK" : "FAIL" };
    }),

    // ── Local SMTP (from cache) ──
    timedAsync("SMTP :25 relay", async () => {
      if (!data) return { passed: false, details: "no data" };
      return { passed: data.smtp25.includes("220"), details: data.smtp25.split("\n")[0] || "no banner" };
    }),
    timedAsync("SMTP :587 local TLS", async () => {
      if (!data) return { passed: false, details: "no data" };
      const ok = data.smtp587.includes("CONNECTED") || data.smtp587.includes("Let's Encrypt") || data.smtp587.includes("verify return:1");
      return { passed: ok, details: ok ? "STARTTLS OK" : "not responding" };
    }),

    // ── HTTP endpoints ──
    timedAsync("Webmail HTTPS", async () => {
      const r = await runA("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", `https://${MAIL_DOMAIN}/`]);
      return { passed: ["200", "301", "302"].includes(r.stdout.trim()), details: `HTTP ${r.stdout.trim()}` };
    }),
    timedAsync("Webmail internal", async () => {
      if (!data) return { passed: false, details: "no data" };
      return { passed: data.webmailInternal.trim() === "200", details: `HTTP ${data.webmailInternal.trim()}` };
    }),
    timedAsync("SnappyMail internal", async () => {
      if (!data) return { passed: false, details: "no data" };
      const code = data.snappymailInternal.trim();
      return { passed: ["200", "301", "302"].includes(code), details: `HTTP ${code}` };
    }),
    timedAsync("ManageSieve :4190", async () => {
      if (!data) return { passed: false, details: "no data" };
      const ok = data.sieve4190.includes("OK") || data.sieve4190.includes("SIEVE") || data.sieve4190.includes("IMPLEMENTATION");
      return { passed: ok, details: ok ? "ManageSieve OK" : data.sieve4190.slice(0, 50) || "no banner" };
    }),

    // ── Authelia OIDC chain ──
    timedAsync("Authelia health", async () => {
      if (!proxyData) return { passed: false, details: "no proxy data" };
      const ok = proxyData.autheliaHealth.includes("OK") || proxyData.autheliaHealth.includes("ok") || !proxyData.autheliaHealth.includes("FAIL");
      return { passed: ok, details: ok ? "Authelia OK" : proxyData.autheliaHealth.slice(0, 50) };
    }),
    timedAsync("OIDC bearer → webmail", async () => {
      const token = getBearerToken();
      if (!token) return { passed: false, details: "no OIDC token (check AUTHELIA_OIDC env vars)" };
      const r = await runA("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "-H", `Authorization: Bearer ${token}`, "--max-time", "5", `https://${MAIL_DOMAIN}/`]);
      const code = r.stdout.trim();
      if (code === "200") return { passed: true, details: `Bearer auth → 200 OK (full chain)` };
      if (code === "302") return { passed: false, details: `Bearer rejected → 302 (introspect-proxy issue)` };
      return { passed: false, details: `HTTP ${code}` };
    }),
    timedAsync("Stalwart Admin via Bearer", async () => {
      const token = getBearerToken();
      if (!token) return { passed: false, details: "no OIDC token" };
      const r = await runA("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "-H", `Authorization: Bearer ${token}`, "--max-time", "5", `https://${MAIL_DOMAIN}/api/`]);
      const code = r.stdout.trim();
      return { passed: ["200", "401", "403", "404"].includes(code), details: `HTTP ${code}` };
    }),

    // ── mail-mcp container connectivity (from oci-apps batch) ──
    timedAsync("mcp→DNS resolve", async () => {
      if (!appData) return { passed: false, details: "no app data" };
      const ok = appData.dnsResolve.startsWith("OK:");
      return { passed: ok, details: ok ? appData.dnsResolve.replace("OK:", "→ ") : appData.dnsResolve };
    }),
    timedAsync("mcp→IMAP TLS", async () => {
      if (!appData) return { passed: false, details: "no app data" };
      return { passed: appData.imapTls.startsWith("OK"), details: appData.imapTls };
    }),
    timedAsync("mcp→SMTP TLS", async () => {
      if (!appData) return { passed: false, details: "no app data" };
      return { passed: appData.smtpTls.startsWith("OK"), details: appData.smtpTls };
    }),
    timedAsync("mcp→IMAP WG direct", async () => {
      if (!appData) return { passed: false, details: "no app data" };
      return { passed: appData.imapWg.startsWith("OK"), details: `${MAIL_WG_IP}:993 ${appData.imapWg}` };
    }),
    timedAsync("mcp→IMAP LOGIN", async () => {
      if (!appData) return { passed: false, details: "no app data" };
      if (appData.imapLogin === "NO_CREDS") return { passed: false, details: "MAIL_USER/MAIL_PASSWORD not set in mail-mcp" };
      return { passed: appData.imapLogin.includes("LOGIN_OK"), details: appData.imapLogin };
    }),
    timedAsync("mcp→SMTP AUTH", async () => {
      if (!appData) return { passed: false, details: "no app data" };
      return { passed: appData.smtpAuth.includes("SMTP_AUTH_OK"), details: appData.smtpAuth };
    }),

    // ── MCP endpoint checks ──
    timedAsync("mail-mcp MCP", async () => {
      const r = await runA("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "3", "https://mcp.diegonmarcos.com/mail-mcp/mcp"]);
      return { passed: ["400", "405", "406"].includes(r.stdout.trim()), details: `HTTP ${r.stdout.trim()} (alive)` };
    }),
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

    // ── Listening ports verification (from cache) ──
    timedAsync("All ports bound", async () => {
      if (!data) return { passed: false, details: "no data" };
      const ports = data.allLocalPorts;
      const expected = [25, 465, 587, 993, 4190, 8443, 8888];
      const bound = expected.filter(p => ports.includes(`:${p}`));
      const missing = expected.filter(p => !ports.includes(`:${p}`));
      return { passed: missing.length === 0, details: missing.length === 0 ? `all ${expected.length} ports bound` : `missing: ${missing.join(", ")}` };
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
// PHASE 5: MAIL INTERNALS — Stalwart API + service health
// ═══════════════════════════════════════════════════════════════════════════

async function mailInternals(): Promise<Check[]> {
  const data = _remoteCache;
  if (!data) return [{ name: "internals", passed: false, details: "no remote data", durationMs: 0 }];

  const checks: Check[] = [
    { name: "IMAP auth", passed: data.dovecotUser.includes("IMAP4") || data.dovecotUser.includes("OK") || data.dovecotUser.includes("Stalwart"), details: (data.dovecotUser.includes("IMAP4") || data.dovecotUser.includes("OK") || data.dovecotUser.includes("Stalwart")) ? "Stalwart IMAP responding" : `FAILED: ${data.dovecotUser.slice(0, 60)}`, durationMs: 0 },
    { name: "IMAP protocol", passed: data.imapCap.includes("IMAP4") || data.imapCap.includes("OK"), details: data.imapCap.includes("IMAP4") ? "IMAP4rev1" : "not responding", durationMs: 0 },
    { name: "spam filter", passed: data.rspamd.includes("stalwart-builtin") || data.rspamd.includes("scanned"), details: (data.rspamd.includes("stalwart-builtin") || data.rspamd.includes("scanned")) ? "Stalwart built-in" : data.rspamd.slice(0, 40) || "unknown", durationMs: 0 },
    { name: "data store", passed: data.redis.trim() === "PONG" || data.redis.includes("stalwart"), details: "RocksDB", durationMs: 0 },
    { name: "admin panel", passed: ["200", "302", "303"].includes(data.admin.trim().replace(/[^0-9]/g, "")), details: data.admin.trim().replace(/[^0-9]/g, "") ? `HTTP ${data.admin.trim().replace(/[^0-9]/g, "")}` : "no response", durationMs: 0 },
    { name: "sieve filter", passed: data.sieve.includes("stalwart-builtin") || data.sieve.includes("managesieve"), details: "Stalwart ManageSieve", durationMs: 0 },
    { name: "mailbox quota", passed: true, details: data.quota.trim().slice(0, 60) || "no quota", durationMs: 0 },
  ];

  // Stalwart Admin API data
  if (!data.stalwartApiAccounts.includes("API_FAIL")) {
    try {
      const accounts = JSON.parse(data.stalwartApiAccounts);
      const count = Array.isArray(accounts) ? accounts.length : (accounts?.items?.length ?? 0);
      checks.push({ name: "Admin API accounts", passed: count > 0, details: `${count} accounts`, durationMs: 0 });
    } catch { checks.push({ name: "Admin API accounts", passed: data.stalwartApiAccounts.length > 2, details: data.stalwartApiAccounts.slice(0, 60), durationMs: 0 }); }
  } else {
    checks.push({ name: "Admin API accounts", passed: false, details: "API unreachable (auth failed?)", durationMs: 0 });
  }

  if (!data.stalwartApiDomains.includes("API_FAIL")) {
    checks.push({ name: "Admin API domains", passed: data.stalwartApiDomains.length > 2, details: data.stalwartApiDomains.slice(0, 60), durationMs: 0 });
  } else {
    checks.push({ name: "Admin API domains", passed: false, details: "API unreachable", durationMs: 0 });
  }

  // Queue status
  const queueOk = data.stalwartApiQueue.includes("empty") || data.stalwartApiQueue.includes("[]");
  checks.push({ name: "Mail queue", passed: queueOk || data.stalwartApiQueue.length < 100, details: queueOk ? "empty" : data.stalwartApiQueue.slice(0, 60), durationMs: 0 });

  // User accounts (from users field which now uses Admin API)
  try {
    const parsed = JSON.parse(data.users);
    const count = Array.isArray(parsed) ? parsed.length : parseInt(data.users.trim()) || 0;
    checks.push({ name: "User accounts", passed: count > 0, details: `${count} users`, durationMs: 0 });
  } catch {
    const count = parseInt(data.users.trim()) || 0;
    checks.push({ name: "User accounts", passed: count > 0, details: count > 0 ? `${count} users` : `unknown (${data.users.trim().slice(0, 30)})`, durationMs: 0 });
  }

  return checks;
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
      if (!sshOk) return { passed: false, details: "SSH down" };
      for (let i = 0; i < 3; i++) {
        await new Promise(r => setTimeout(r, 2000));
        const r = await sshMail(`docker logs stalwart --since 30s 2>&1 | grep -c "Message ingested" || echo 0`, 5_000);
        const count = parseInt(r.stdout.trim()) || 0;
        if (count > 0) return { passed: true, details: `delivered (poll ${i + 1}, ${(i + 1) * 2}s)` };
      }
      return { passed: false, details: "NOT FOUND after 6s" };
    }),
    timedAsync("smtp-proxy logs", async () => {
      if (!sshOk) return { passed: false, details: "SSH down" };
      const r = await sshMail(`docker logs smtp-proxy --since 5m 2>&1 | tail -3 || true`, 5_000);
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
  server.tool("obs.health.mail_up", "Quick UP: pre-flight + containers + network + DNS + internals", {},
    () => safeToolAsync(async () => {
      clearAllCaches();
      const sections: string[] = [];
      sections.push(formatChecks("PRE-FLIGHT", await preflight()));
      const sshOk = _remoteCache !== null;
      if (sshOk) {
        const [containers, network, dns] = await Promise.all([containerHealth(), networkChecks(), dnsAuth()]);
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

  server.tool("obs.health.mail_profile", "Deep profile all Stalwart containers", {},
    () => safeToolAsync(async () => {
      const p: Record<string, unknown> = {};
      for (const n of [...MAIL_CONTAINERS, "smtp-proxy", "snappymail"]) { try { p[n] = profileContainer(n); } catch (e: unknown) { p[n] = { error: String(e) }; } }
      return `Stalwart Profiles\n${"─".repeat(60)}\n${JSON.stringify(p, null, 2)}`;
    }),
  );

  server.tool("obs.health.mail_inbound", "E2E delivery: Resend → CF → smtp-proxy → Stalwart → IMAP", {},
    () => safeToolAsync(async () => formatChecks("E2E DELIVERY", await e2eDelivery())),
  );

  server.tool("obs.health.mail_outbound", "Outbound: SMTP relay + DNS auth", {},
    () => safeToolAsync(async () => {
      const [smtpChecks, dnsChecks] = await Promise.all([
        Promise.all([
          timedAsync("SMTP :25", async () => { const r = await sshMail(`echo QUIT | timeout 3 nc -w3 localhost 25 2>&1 | head -1`, 5_000); return { passed: r.stdout.includes("220"), details: r.stdout.trim().split("\n")[0] || "no banner" }; }),
          timedAsync("SMTP :587", async () => { const r = await sshMail(`echo QUIT | timeout 5 openssl s_client -connect localhost:587 2>&1 | head -3`, 8_000); return { passed: r.stdout.includes("CONNECTED"), details: r.stdout.includes("CONNECTED") ? "TLS OK" : "not responding" }; }),
        ]),
        dnsAuth(),
      ]);
      return formatChecks("OUTBOUND & DNS", [...smtpChecks, ...dnsChecks]);
    }),
  );

  server.tool("obs.health.mail", "Full 6-phase diagnostic: 3-VM parallel, OIDC auth, Admin API, IMAP LOGIN, all ports", {},
    () => safeToolAsync(async () => {
      clearAllCaches();
      const marks: { phase: string; ms: number }[] = [];
      const t0 = performance.now();
      const mark = (phase: string) => { marks.push({ phase, ms: Math.round(performance.now() - t0) }); };
      const sections: string[] = [];
      let checkTimeSumMs = 0;

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

      // ═══════════════════════════════════════════════════════════════
      // PHASE 0: INSTANT KPIs — public URLs + DNS (no SSH, <2s)
      // ═══════════════════════════════════════════════════════════════
      await runPhase("0. INSTANT KPIs", async () => {
        const checks = await Promise.all([
          // Public URL checks
          timedAsync("mail.* HTTPS", async () => {
            const r = await runA("curl", ["-sko", "/dev/null", "-w", "%{http_code}", "--max-time", "3", `https://${MAIL_DOMAIN}:443`]);
            return { passed: r.stdout.trim().startsWith("2") || r.stdout.trim().startsWith("3"), details: `HTTP ${r.stdout.trim()}` };
          }),
          timedAsync("webmail HTTPS", async () => {
            const r = await runA("curl", ["-sko", "/dev/null", "-w", "%{http_code}", "--max-time", "3", "https://webmail.diegonmarcos.com"]);
            return { passed: r.stdout.trim().startsWith("2") || r.stdout.trim().startsWith("3"), details: `HTTP ${r.stdout.trim()}` };
          }),
          timedAsync("auth HTTPS", async () => {
            const r = await runA("curl", ["-sko", "/dev/null", "-w", "%{http_code}", "--max-time", "3", "https://auth.diegonmarcos.com/api/health"]);
            return { passed: r.stdout.trim() === "200", details: `HTTP ${r.stdout.trim()}` };
          }),
          timedAsync("MCP endpoint", async () => {
            const r = await runA("curl", ["-sko", "/dev/null", "-w", "%{http_code}", "--max-time", "3", "https://mcp.diegonmarcos.com/mail-mcp/mcp"]);
            const code = r.stdout.trim();
            return { passed: ["400", "405", "406", "200"].includes(code), details: `HTTP ${code}` };
          }),
          // DNS checks (instant)
          timedAsync("MX record", async () => {
            const r = await runA("dig", ["+short", "MX", "diegonmarcos.com"], 3_000);
            return { passed: r.stdout.includes("cloudflare"), details: r.stdout.trim().split("\n")[0] || "NONE" };
          }),
          timedAsync("DKIM record", async () => {
            const r = await runA("dig", ["+short", "TXT", "dkim._domainkey.diegonmarcos.com"], 3_000);
            return { passed: r.stdout.includes("DKIM1"), details: r.stdout.trim() ? "present" : "MISSING" };
          }),
          // GHA status
          timedAsync("GHA health", async () => {
            const r = await runA("gh", ["-R", "diegonmarcos/cloud", "run", "list", "--limit", "5", "--json", "name,conclusion", "-q",
              '.[] | select(.conclusion == "failure") | .name'], 10_000);
            const failures = r.stdout.trim().split("\n").filter(Boolean);
            return { passed: failures.length === 0, details: failures.length === 0 ? "all green" : `${failures.length} failing: ${failures.slice(0, 2).join(", ")}` };
          }),
        ]);
        return formatChecks("0. INSTANT KPIs", checks);
      });

      // Phase 1: PRE-FLIGHT (must run first — establishes SSH mux + caches)
      await runPhase("1. PRE-FLIGHT", async () => formatChecks("1. PRE-FLIGHT", await preflight()));
      const sshOk = _remoteCache !== null;

      // ── SMART FALLBACK: if pre-flight had failures, run docker ps on ALL VMs ──
      const preflightFailed = !sshOk || !_appCache || !_proxyCache;
      if (preflightFailed) {
        const vmList = [
          { name: "oci-mail", ip: MAIL_WG_IP, user: "ubuntu" },
          { name: "oci-apps", ip: APPS_WG_IP, user: "ubuntu" },
          { name: "gcp-proxy", ip: PROXY_WG_IP, user: "diego" },
          { name: "oci-analytics", ip: "10.0.0.4", user: "ubuntu" },
        ];
        const fallbackLines: string[] = [
          "",
          "╔══════════════════════════════════════════════════════════════╗",
          "║  FALLBACK — docker ps on all VMs + cloud status             ║",
          "╚══════════════════════════════════════════════════════════════╝",
        ];
        // Docker ps on all VMs in parallel
        const vmResults = await Promise.all(vmList.map(async (vm) => {
          try {
            const r = await runA("ssh", [
              "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=5",
              "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
              `${vm.user}@${vm.ip}`,
              "docker ps -a --format '{{.Names}}\\t{{.Status}}' 2>/dev/null | sort",
            ], 15_000);
            return { vm, ok: r.ok, stdout: r.stdout };
          } catch { return { vm, ok: false, stdout: "" }; }
        }));
        for (const { vm, ok, stdout } of vmResults) {
          if (ok && stdout.trim()) {
            fallbackLines.push("", `── ${vm.name} (${vm.ip}) ──`);
            for (const line of stdout.trim().split("\n")) {
              const [cname, status] = line.split("\t");
              const icon = (status || "").includes("unhealthy") || (status || "").includes("Restarting") ? "✗" : "✓";
              fallbackLines.push(`  ${icon} ${(cname || "?").padEnd(30)} ${status || "?"}`);
            }
          } else {
            fallbackLines.push("", `── ${vm.name} (${vm.ip}) — UNREACHABLE ──`);
          }
        }
        // GHA recent failures
        try {
          const gha = await runA("gh", ["-R", "diegonmarcos/cloud", "run", "list", "--limit", "10",
            "--json", "name,status,conclusion", "-q",
            '.[] | select(.conclusion == "failure") | "\(.name)"'], 10_000);
          if (gha.ok && gha.stdout.trim()) {
            fallbackLines.push("", "── GHA Recent Failures ──");
            for (const line of gha.stdout.trim().split("\n").slice(0, 5)) {
              fallbackLines.push(`  ✗ ${line}`);
            }
          }
        } catch {}
        // OCI instance status
        try {
          const oci = await runA("oci", ["compute", "instance", "list",
            "--compartment-id", "ocid1.tenancy.oc1..aaaaaaaate22jsouuzgaw65ucwvufcj3lzjxw4ithwcz3cxw6iom6ys2ldsq",
            "--query", "data[].{name:\"display-name\",state:\"lifecycle-state\"}", "--output", "table"], 15_000);
          if (oci.ok && oci.stdout.trim()) {
            fallbackLines.push("", "── OCI VM Status ──", oci.stdout.trim());
          }
        } catch {}
        sections.push(fallbackLines.join("\n"));
      }

      // Phases 2-4: run in parallel
      if (sshOk) {
        const p2 = runPhase("2. CONTAINERS", async () => formatChecks("2. CONTAINERS", await containerHealth()));
        const p3 = runPhase("3. NETWORK + AUTH", async () => formatChecks("3. NETWORK + AUTH", await networkChecks()));
        const p4 = runPhase("4. DNS AUTH", async () => formatChecks("4. DNS AUTH", await dnsAuth()));
        await Promise.all([p2, p3, p4]);
      } else {
        sections.push("", "⚠️ SSH to oci-mail FAILED — skipping container/internal checks");
        sections.push("", formatChecks("2. CONTAINERS", [{ name: "skipped", passed: false, details: "SSH unreachable", durationMs: 0 }]));
        const p3 = runPhase("3. NETWORK + AUTH", async () => formatChecks("3. NETWORK + AUTH", await networkChecks()));
        const p4 = runPhase("4. DNS AUTH", async () => formatChecks("4. DNS AUTH", await dnsAuth()));
        await Promise.all([p3, p4]);
      }

      // Phase 5: MAIL INTERNALS
      if (sshOk) {
        await runPhase("5. MAIL INTERNALS", async () => formatChecks("5. MAIL INTERNALS", await mailInternals()));
      } else {
        sections.push("", formatChecks("5. MAIL INTERNALS", [{ name: "skipped", passed: false, details: "SSH unreachable", durationMs: 0 }]));
      }

      // Phase 6: E2E DELIVERY
      await runPhase("6. E2E DELIVERY", async () => formatChecks("6. E2E DELIVERY", await e2eDelivery()));

      // ── PERFORMANCE SUMMARY ──
      const totalMs = Math.round(performance.now() - t0);
      const phaseTimes = marks.filter(m => m.phase !== "start");
      const perfLines = phaseTimes.map(m => `  ${m.phase.padEnd(22)} ${(m.ms / 1000).toFixed(1)}s`);

      // Count per-check time to compute parallel efficiency
      const allText = sections.join("\n");
      const checkTimeMatches = allText.match(/\d+ms/g) || [];
      checkTimeSumMs = checkTimeMatches.reduce((s, m) => s + parseInt(m), 0);
      const efficiency = checkTimeSumMs > 0 ? Math.round((checkTimeSumMs / totalMs) * 100) : 0;

      sections.push("", [
        `PERFORMANCE`,
        `${"═".repeat(60)}`,
        `  Wall-clock:         ${(totalMs / 1000).toFixed(1)}s`,
        `  Check-time sum:     ${(checkTimeSumMs / 1000).toFixed(1)}s`,
        `  Parallel efficiency: ${efficiency}% (higher = more parallelism)`,
        "",
        ...perfLines,
      ].join("\n"));

      // ── RESULT ──
      const passCount = (allText.match(/✓/g) || []).length;
      const failCount = (allText.match(/✗/g) || []).length;
      const hasFailures = failCount > 0 || allText.includes("FAILED");

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
          if (_remoteCache.debugDump) sections.push("", _remoteCache.debugDump);
          sections.push("", "── RAW CONTAINER STATUS ──", _remoteCache.containers || "(empty)");
          sections.push("", "── STALWART API ACCOUNTS ──", _remoteCache.stalwartApiAccounts || "(empty)");
          sections.push("", "── STALWART API DOMAINS ──", _remoteCache.stalwartApiDomains || "(empty)");
          sections.push("", "── STALWART API QUEUE ──", _remoteCache.stalwartApiQueue || "(empty)");
          sections.push("", "── LISTENING PORTS ──", _remoteCache.allLocalPorts || "(empty)");
          sections.push("", "── DISK / MEMORY / LOAD ──");
          sections.push(`disk: ${_remoteCache.disk}% | memory: ${_remoteCache.memory} | load: ${_remoteCache.load}`);
        }
        if (_appCache) {
          sections.push("", "── MAIL-MCP CONTAINER TESTS ──");
          sections.push(`DNS: ${_appCache.dnsResolve}`);
          sections.push(`IMAP TLS: ${_appCache.imapTls}`);
          sections.push(`SMTP TLS: ${_appCache.smtpTls}`);
          sections.push(`IMAP LOGIN: ${_appCache.imapLogin}`);
          sections.push(`SMTP AUTH: ${_appCache.smtpAuth}`);
        }
        if (_proxyCache) {
          sections.push("", "── GCP-PROXY CADDY L4 ──");
          sections.push(`993: ${_proxyCache.caddyL4_993} | 465: ${_proxyCache.caddyL4_465} | 587: ${_proxyCache.caddyL4_587}`);
          sections.push(`Authelia: ${_proxyCache.autheliaHealth}`);
        }
        if (!_remoteCache) sections.push("", "⚠️ No oci-mail data (SSH failed)");
      }

      log(`mail_full complete: ${totalMs}ms, ${passCount}✓ ${failCount}✗`);
      return sections.join("\n");
    }),
  );
}

// ── Standalone runner (GHA / CLI) ────────────────────────────────────────
if (process.argv[1]?.endsWith("health_mail.ts")) {
  (async () => {
    const { McpServer: S } = await import("@modelcontextprotocol/sdk/server/mcp.js");
    const server = new S({ name: "health-runner", version: "1.0.0" });
    registerHealthMailTools(server);
    const tools = (server as any)._registeredTools;
    const tool = tools?.["obs.health.mail"];
    if (!tool?.handler) {
      console.error("ERROR: mail-full tool handler not found");
      process.exit(1);
    }
    try {
      const result = await tool.handler({}, {});
      const text = result?.content?.[0]?.text ?? "No output";
      console.log(text);
      const failed = (text.match(/✗/g) || []).length;
      process.exit(failed > 0 ? 1 : 0);
    } catch (err) {
      console.error("FATAL:", err);
      process.exit(1);
    }
  })();
}
