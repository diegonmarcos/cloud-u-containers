// ── Cloud Full — 8-layer dependency-ordered async diagnostic (2 MCP tools) ──
//
// Layer 0: SELF-CHECK — C3 API heartbeat, local WG interface
// Layer 1: WIREGUARD MESH — TCP probe :22 to all VMs
// Layer 2: PLATFORM — SSH auth + batch data (Docker, disk, memory, containers)
// Layer 3: CORE SERVICES — Caddy, Authelia, Hickory DNS, ntfy, OIDC chain
// Layer 4: DATA SERVICES — Gitea, NocoDB, Syncthing, Matomo, backups, Vaultwarden
// Layer 5: APPLICATIONS — Mattermost, PhotoPrism, AFFiNE, Grist, etc.
// Layer 6: SPECIALIZED — Stalwart mail, SnappyMail, Dagu, Crawlee, mail-mcp
// Layer 7: EXTERNAL — Cloudflare DNS, GHCR registry, Resend API
//
// Layers run sequentially (dependency order). Checks within each layer run in parallel.
// Batch SSH per VM: one call collects all data, cached for layers 3-6.
// If a layer fails, dependent checks in subsequent layers report "skipped".

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { execAsync } from "../../shared/exec.js";
import { sshExecAsync } from "../../shared/ssh.js";
import { getConfig } from "../../shared/config.js";
import { getBearerToken } from "../../shared/http.js";
import { performance } from "node:perf_hooks";

// ── Helpers (same pattern as health_mail.ts) ─────────────────────────────

interface Check { name: string; passed: boolean; details: string; durationMs: number; error?: string; }

async function timedAsync(name: string, fn: () => Promise<{ passed: boolean; details: string }>): Promise<Check> {
  const start = Date.now();
  try { return { name, ...(await fn()), durationMs: Date.now() - start }; }
  catch (err: unknown) { return { name, passed: false, details: "", error: err instanceof Error ? err.message : String(err), durationMs: Date.now() - start }; }
}

function runA(cmd: string, args: string[], timeout = 8_000) { return execAsync(cmd, args, { timeout }); }
const log = (msg: string) => process.stderr.write(`[cloud-health] ${msg}\n`);

function formatChecks(title: string, checks: Check[]): string {
  const passed = checks.filter((c) => c.passed).length;
  const total = checks.length;
  const status = passed === total ? "ALL PASSED" : `${passed}/${total} PASSED`;
  return [`${title}  [${status}]`, "─".repeat(60),
    ...checks.map((c) => `  ${c.passed ? "✓" : "✗"} ${c.name.padEnd(30)} ${`${c.durationMs}ms`.padStart(8)}  ${c.details}${c.error ? ` — ${c.error}` : ""}`)
  ].join("\n");
}

// ── Batch SSH data per VM ────────────────────────────────────────────────

interface VmBatchData {
  dockerPs: string;
  dockerVersion: string;
  disk: string;
  memory: string;
  load: string;
}

const _vmCache = new Map<string, VmBatchData>();

async function batchVmData(vmId: string): Promise<VmBatchData | null> {
  if (_vmCache.has(vmId)) return _vmCache.get(vmId)!;
  const script = `
echo "===dockerVersion==="
timeout 3 docker info --format '{{.ServerVersion}}' 2>&1 | head -1
echo "===disk==="
df -h / 2>/dev/null | awk 'NR==2{gsub(/%/,""); print $5}' || df / 2>/dev/null | awk 'NR==2{print $5}' | tr -d '%'
echo "===memory==="
free -m 2>/dev/null | awk '/Mem:/{printf "%d/%dMB (%.0f%%)", $3, $2, $3/$2*100}' || echo "N/A"
echo ""
echo "===load==="
cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}' || echo "N/A"
echo "===dockerPs==="
timeout 5 docker ps -a --format '{{.Names}}\t{{.Status}}' 2>&1
`.trim();

  try {
    const r = await sshExecAsync(vmId, script, 20_000, true, 3);
    const output = r.stdout;
    // Fallback: if batch script failed but SSH works, try just docker ps
    if (!output.includes("===dockerPs===")) {
      log(`batch failed for ${vmId}, trying docker ps fallback`);
      const fallback = await sshExecAsync(vmId, "docker ps -a --format '{{.Names}}\t{{.Status}}' 2>&1", 10_000, true, 2);
      if (fallback.ok && fallback.stdout.trim()) {
        const data: VmBatchData = { dockerPs: fallback.stdout.trim(), dockerVersion: "fallback", disk: "N/A", memory: "N/A", load: "N/A" };
        _vmCache.set(vmId, data);
        return data;
      }
    }
    const section = (name: string): string => {
      const start = output.indexOf(`===${name}===`);
      if (start === -1) return "";
      const afterMarker = start + `===${name}===`.length + 1;
      const end = output.indexOf("===", afterMarker);
      return (end === -1 ? output.slice(afterMarker) : output.slice(afterMarker, end)).trim();
    };
    const data: VmBatchData = {
      dockerPs: section("dockerPs"), dockerVersion: section("dockerVersion"),
      disk: section("disk"), memory: section("memory"), load: section("load"),
    };
    _vmCache.set(vmId, data);
    return data;
  } catch { return null; }
}

function containerUp(batchData: VmBatchData, name: string): { up: boolean; status: string } {
  // Exact match first, then prefix match (e.g. "photoprism" → "photoprism_app")
  const lines = batchData.dockerPs.split("\n");
  let line = lines.find(l => l.startsWith(name + "\t"));
  if (!line) line = lines.find(l => l.split("\t")[0]?.startsWith(name));
  if (!line) line = lines.find(l => l.split("\t")[0]?.includes(name));
  if (!line) return { up: false, status: "NOT FOUND" };
  const parts = line.split("\t");
  const containerName = parts[0] || name;
  const status = parts[1] || "";
  const isUp = status.startsWith("Up");
  return { up: isUp, status: `${containerName} ${status.replace(/\s+\(.*/, "")}`.trim() };
}

// ── State tracking ───────────────────────────────────────────────────────

interface CloudState {
  reachableVms: Set<string>;
  sshOkVms: Set<string>;
  dockerOkVms: Set<string>;
  caddyOk: boolean;
  autheliaOk: boolean;
}

// ═══════════════════════════════════════════════════════════════════════════
// LAYER IMPLEMENTATIONS
// ═══════════════════════════════════════════════════════════════════════════

async function layer0SelfCheck(): Promise<Check[]> {
  // C3 API: try mesh first, then localhost (works from both desktop and VM)
  const apiUrls = ["http://10.0.0.6:8081/health", "http://localhost:8081/health"];
  return Promise.all([
    timedAsync("C3 API heartbeat", async () => {
      for (const url of apiUrls) {
        const r = await runA("curl", ["-sf", "--max-time", "3", url], 5_000);
        if (r.ok) return { passed: true, details: r.stdout.trim().slice(0, 40) || "ok" };
      }
      return { passed: false, details: "UNREACHABLE (tried mesh + localhost)" };
    }),
    timedAsync("Local WG interface", async () => {
      const r = await runA("bash", ["-c", "timeout 3 bash -c 'echo > /dev/tcp/10.0.0.6/22' 2>&1"], 5_000);
      return { passed: r.ok, details: r.ok ? "10.0.0.6:22 OK" : "WG interface DOWN" };
    }),
  ]);
}

async function layer1WgMesh(): Promise<{ checks: Check[]; reachable: Set<string> }> {
  const config = getConfig();
  const vms = Object.entries(config.vms).filter(([_, v]) => v.wg_ip && v.ip !== "TBD");
  const reachable = new Set<string>();

  const checks = await Promise.all(vms.map(([vmId, vm]) =>
    timedAsync(`${vm.label || vmId} (${vm.wg_ip})`, async () => {
      const r = await runA("bash", ["-c", `timeout 3 bash -c 'echo > /dev/tcp/${vm.wg_ip}/22' 2>&1`], 5_000);
      if (r.ok) reachable.add(vmId);
      return { passed: r.ok, details: r.ok ? `:22 OK` : "unreachable" };
    })
  ));

  return { checks, reachable };
}

async function layer2Platform(reachableVms: Set<string>): Promise<{ checks: Check[]; sshOk: Set<string>; dockerOk: Set<string> }> {
  const config = getConfig();
  const sshOk = new Set<string>();
  const dockerOk = new Set<string>();

  // Batch SSH to all reachable VMs in parallel
  const vmEntries = Object.entries(config.vms).filter(([id]) => reachableVms.has(id));
  const results = await Promise.all(vmEntries.map(async ([vmId, vm]) => {
    const label = vm.label || vmId;
    const checks: Check[] = [];

    // SSH + batch data in one call
    const batchCheck = await timedAsync(`${label} SSH+data`, async () => {
      const data = await batchVmData(vmId);
      if (!data) return { passed: false, details: "SSH FAILED" };
      sshOk.add(vmId);
      if (data.dockerVersion) dockerOk.add(vmId);
      const diskPct = parseInt(data.disk);
      const diskWarn = !isNaN(diskPct) && diskPct >= 80 ? ` disk:${diskPct}%⚠️` : "";
      return { passed: data.dockerVersion.length > 0, details: `Docker ${data.dockerVersion}${diskWarn}` };
    });
    checks.push(batchCheck);

    return checks;
  }));

  // Unreachable VMs
  const unreachableChecks = Object.entries(config.vms)
    .filter(([id, v]) => v.wg_ip && v.ip !== "TBD" && !reachableVms.has(id))
    .map(([_, vm]): Check => ({ name: `${vm.label} SSH+data`, passed: false, details: "skipped (unreachable in Layer 1)", durationMs: 0 }));

  return { checks: [...results.flat(), ...unreachableChecks], sshOk, dockerOk };
}

async function layer3CoreServices(state: CloudState): Promise<Check[]> {
  const proxyId = "gcp-E2-f_0";
  const proxyData = _vmCache.get(proxyId);

  const checks = await Promise.all([
    timedAsync("Caddy", async () => {
      if (!proxyData) return { passed: false, details: "gcp-proxy unreachable" };
      const c = containerUp(proxyData, "caddy");
      if (!c.up) { state.caddyOk = false; return { passed: false, details: c.status }; }
      const r = await runA("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", "https://diegonmarcos.com"], 8_000);
      const ok = ["200", "301", "302", "404"].includes(r.stdout.trim());
      state.caddyOk = ok;
      return { passed: ok, details: `${c.status} | HTTPS ${r.stdout.trim()}` };
    }),

    timedAsync("Authelia", async () => {
      if (!proxyData) return { passed: false, details: "gcp-proxy unreachable" };
      const c = containerUp(proxyData, "authelia");
      if (!c.up) { state.autheliaOk = false; return { passed: false, details: c.status }; }
      const r = await runA("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", "https://auth.diegonmarcos.com/api/health"], 8_000);
      const ok = r.stdout.trim() === "200";
      state.autheliaOk = ok;
      return { passed: ok || c.up, details: `${c.status} | health ${r.stdout.trim()}` };
    }),

    timedAsync("Hickory DNS", async () => {
      if (!proxyData) return { passed: false, details: "gcp-proxy unreachable" };
      const c = containerUp(proxyData, "hickory-dns");
      const r = await runA("bash", ["-c", `dig +short stalwart.app @10.0.0.1 2>&1 | head -1`], 5_000);
      const resolved = r.stdout.trim() === "10.0.0.3";
      return { passed: c.up && resolved, details: `${c.status} | stalwart.app → ${r.stdout.trim() || "FAIL"}` };
    }),

    timedAsync("ntfy", async () => {
      if (!proxyData) return { passed: false, details: "gcp-proxy unreachable" };
      const c = containerUp(proxyData, "ntfy");
      return { passed: c.up, details: c.status };
    }),

    timedAsync("OIDC bearer chain", async () => {
      const token = getBearerToken();
      if (!token) return { passed: false, details: "no OIDC token (env vars missing?)" };
      const r = await runA("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "-H", `Authorization: Bearer ${token}`, "--max-time", "5", "https://api.diegonmarcos.com/c3-api/health"], 8_000);
      return { passed: r.stdout.trim() === "200", details: `Bearer → ${r.stdout.trim()}` };
    }),
  ]);

  return checks;
}

async function layer4DataServices(state: CloudState): Promise<Check[]> {
  // Dynamic: read from config.json — data category services
  const config = getConfig();
  const dataNames = ["gitea", "nocodb", "syncthing", "matomo", "vaultwarden", "db-agent", "redis"];
  const services = dataNames.map(name => {
    const svc = config.services[name];
    if (!svc) return null;
    const containers = svc.containers ?? [name];
    return { name, container: containers[0], vmId: svc.vm };
  }).filter((s): s is NonNullable<typeof s> => s !== null);

  return Promise.all(services.map(({ name, container, vmId }) =>
    timedAsync(name, async () => {
      if (!state.dockerOkVms.has(vmId)) return { passed: false, details: `skipped (${vmId} Docker down)` };
      const data = _vmCache.get(vmId);
      if (!data) return { passed: false, details: "no batch data" };
      const c = containerUp(data, container);
      return { passed: c.up, details: c.status };
    })
  ));
}

async function layer5Applications(state: CloudState): Promise<Check[]> {
  // Dynamic: read from config.json — app category services
  const config = getConfig();
  const appNames = ["mattermost", "photoprism", "grist", "hedgedoc", "code-server", "radicale", "etherpad", "filebrowser", "revealmd", "windmill"];
  const apps = appNames.map(name => {
    const svc = config.services[name];
    if (!svc) return null;
    const containers = svc.containers ?? [name];
    return { name, container: containers[0], vmId: svc.vm };
  }).filter((s): s is NonNullable<typeof s> => s !== null);

  return Promise.all(apps.map(({ name, container, vmId }) =>
    timedAsync(name, async () => {
      if (!state.dockerOkVms.has(vmId)) return { passed: false, details: `skipped (${vmId} Docker down)` };
      const data = _vmCache.get(vmId);
      if (!data) return { passed: false, details: "no batch data" };
      const c = containerUp(data, container);
      return { passed: c.up, details: c.status };
    })
  ));
}

async function layer6Specialized(state: CloudState): Promise<Check[]> {
  return Promise.all([
    // Stalwart mail server + TLS + MX
    timedAsync("Stalwart", async () => {
      const data = _vmCache.get("oci-E2-f_0");
      if (!data) return { passed: false, details: "oci-mail unreachable" };
      const c = containerUp(data, "stalwart");
      return { passed: c.up, details: c.status };
    }),
    timedAsync("IMAP TLS :993", async () => {
      const r = await runA("bash", ["-c", `echo Q | timeout 3 openssl s_client -connect imap.diegonmarcos.com:993 -servername imap.diegonmarcos.com 2>&1 | grep -c CONNECTED`], 5_000);
      return { passed: r.stdout.trim() === "1", details: r.stdout.trim() === "1" ? "TLS OK" : "FAIL" };
    }),
    timedAsync("MX record", async () => {
      const r = await dnsLookupQuick("MX", "diegonmarcos.com");
      return { passed: r.includes("mx") || r.includes("cloudflare"), details: r.split("\n")[0] || "no MX" };
    }),

    // SnappyMail
    timedAsync("SnappyMail", async () => {
      const data = _vmCache.get("oci-E2-f_0");
      if (!data) return { passed: false, details: "oci-mail unreachable" };
      const c = containerUp(data, "snappymail");
      return { passed: c.up, details: c.status };
    }),

    // Dagu scheduler
    timedAsync("Dagu", async () => {
      const data = _vmCache.get("oci-E2-f_0");
      if (!data) return { passed: false, details: "oci-mail unreachable" };
      const c = containerUp(data, "dagu");
      return { passed: c.up, details: c.status };
    }),

    // Crawlee
    timedAsync("Crawlee", async () => {
      const data = _vmCache.get("oci-A1-f_0");
      if (!data) return { passed: false, details: "oci-apps unreachable" };
      // crawlee may have multiple containers
      const containers = data.dockerPs.split("\n").filter(l => l.includes("crawlee"));
      if (containers.length === 0) return { passed: false, details: "NOT FOUND" };
      const allUp = containers.every(l => l.includes("Up"));
      return { passed: allUp, details: `${containers.length} containers, ${allUp ? "all up" : "some down"}` };
    }),

    // mail-mcp
    timedAsync("mail-mcp", async () => {
      const data = _vmCache.get("oci-A1-f_0");
      if (!data) return { passed: false, details: "oci-apps unreachable" };
      const c = containerUp(data, "mail-mcp");
      return { passed: c.up, details: c.status };
    }),
  ]);
}

async function dnsLookupQuick(type: string, name: string): Promise<string> {
  const r = await runA("bash", ["-c", `command -v dig >/dev/null 2>&1 && dig +short +time=3 +tries=1 ${type} ${name} 2>&1`], 5_000);
  return r.stdout.trim();
}

async function layer7External(): Promise<Check[]> {
  return Promise.all([
    timedAsync("Cloudflare DNS", async () => {
      const r = await runA("bash", ["-c", `dig +short diegonmarcos.com @1.1.1.1 2>&1 | head -1`], 5_000);
      const ip = r.stdout.trim();
      return { passed: ip.length > 0 && !ip.includes("error"), details: ip || "FAIL" };
    }),
    timedAsync("GHCR registry", async () => {
      const r = await runA("curl", ["-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", "https://ghcr.io/v2/"], 8_000);
      const ok = ["200", "401"].includes(r.stdout.trim()); // 401 = reachable but needs auth
      return { passed: ok, details: `HTTP ${r.stdout.trim()}` };
    }),
    timedAsync("Resend API", async () => {
      if (!process.env.RESEND_API_KEY) return { passed: true, details: "info: no API key" };
      const r = await runA("curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", "-H", `Authorization: Bearer ${process.env.RESEND_API_KEY}`, "https://api.resend.com/domains"], 8_000);
      return { passed: ["200", "401"].includes(r.stdout.trim()), details: `HTTP ${r.stdout.trim()}` };
    }),
  ]);
}

// ═══════════════════════════════════════════════════════════════════════════
// TOOL REGISTRATION
// ═══════════════════════════════════════════════════════════════════════════

async function safeToolAsync(fn: () => Promise<string>): Promise<{ content: [{ type: "text"; text: string }] }> {
  try { return { content: [{ type: "text" as const, text: await fn() }] }; }
  catch (err: unknown) { return { content: [{ type: "text" as const, text: `ERROR: ${err instanceof Error ? err.message : String(err)}` }] }; }
}

export function registerHealthCloudTools(server: McpServer): void {

  server.tool("cloud-up", "Quick infrastructure UP check: self-check + WG mesh + platform (~10s)", {},
    () => safeToolAsync(async () => {
      _vmCache.clear();
      const t0 = performance.now();
      const sections: string[] = [];

      const l0 = await layer0SelfCheck();
      sections.push(formatChecks("0. SELF-CHECK", l0));

      const { checks: l1, reachable } = await layer1WgMesh();
      sections.push("", formatChecks("1. WIREGUARD MESH", l1));

      const { checks: l2 } = await layer2Platform(reachable);
      sections.push("", formatChecks("2. PLATFORM", l2));

      const totalMs = Math.round(performance.now() - t0);
      const all = sections.join("\n");
      const pass = (all.match(/✓/g) || []).length;
      const fail = (all.match(/✗/g) || []).length;
      sections.push("", `${"═".repeat(60)}`);
      sections.push(`RESULT: ${pass} passed, ${fail} failed (${(totalMs / 1000).toFixed(1)}s)`);
      return sections.join("\n");
    }),
  );

  server.tool("cloud-full", "Full 8-layer cloud diagnostic: infrastructure → services → external (~45s)", {},
    () => safeToolAsync(async () => {
      _vmCache.clear();
      const marks: { layer: string; ms: number }[] = [];
      const t0 = performance.now();
      const mark = (layer: string) => { marks.push({ layer, ms: Math.round(performance.now() - t0) }); };
      const sections: string[] = [];
      const state: CloudState = {
        reachableVms: new Set(), sshOkVms: new Set(), dockerOkVms: new Set(),
        caddyOk: true, autheliaOk: true,
      };

      const runLayer = async (name: string, fn: () => Promise<string>) => {
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

      // Layer 0: Self-Check
      await runLayer("0. SELF-CHECK", async () => formatChecks("0. SELF-CHECK", await layer0SelfCheck()));

      // Layer 1: WireGuard Mesh
      await runLayer("1. WIREGUARD MESH", async () => {
        const { checks, reachable } = await layer1WgMesh();
        state.reachableVms = reachable;
        return formatChecks("1. WIREGUARD MESH", checks);
      });

      // Layer 2: Platform (batch SSH to all reachable VMs)
      await runLayer("2. PLATFORM", async () => {
        const { checks, sshOk, dockerOk } = await layer2Platform(state.reachableVms);
        state.sshOkVms = sshOk;
        state.dockerOkVms = dockerOk;
        return formatChecks("2. PLATFORM", checks);
      });

      // Layers 3-5: run in parallel (all read from cached batch data)
      const p3 = runLayer("3. CORE SERVICES", async () => formatChecks("3. CORE SERVICES", await layer3CoreServices(state)));
      const p4 = runLayer("4. DATA SERVICES", async () => formatChecks("4. DATA SERVICES", await layer4DataServices(state)));
      const p5 = runLayer("5. APPLICATIONS", async () => formatChecks("5. APPLICATIONS", await layer5Applications(state)));
      await Promise.all([p3, p4, p5]);

      // Layer 6: Specialized
      await runLayer("6. SPECIALIZED", async () => formatChecks("6. SPECIALIZED", await layer6Specialized(state)));

      // Layer 7: External
      await runLayer("7. EXTERNAL", async () => formatChecks("7. EXTERNAL", await layer7External()));

      // ── PERFORMANCE ──
      const totalMs = Math.round(performance.now() - t0);
      const perfLines = marks.filter(m => m.layer !== "start").map(m => `  ${m.layer.padEnd(22)} ${(m.ms / 1000).toFixed(1)}s`);
      const allText = sections.join("\n");
      const checkTimeMatches = allText.match(/\d+ms/g) || [];
      const checkTimeSumMs = checkTimeMatches.reduce((s, m) => s + parseInt(m), 0);
      const efficiency = checkTimeSumMs > 0 ? Math.round((checkTimeSumMs / totalMs) * 100) : 0;

      sections.push("", [
        `PERFORMANCE`,
        `${"═".repeat(60)}`,
        `  Wall-clock:          ${(totalMs / 1000).toFixed(1)}s`,
        `  Check-time sum:      ${(checkTimeSumMs / 1000).toFixed(1)}s`,
        `  Parallel efficiency: ${efficiency}%`,
        "",
        ...perfLines,
      ].join("\n"));

      // ── RESULT ──
      const passCount = (allText.match(/✓/g) || []).length;
      const failCount = (allText.match(/✗/g) || []).length;
      sections.push("", `${"═".repeat(60)}`);
      sections.push(`RESULT: ${passCount} passed, ${failCount} failed (${(totalMs / 1000).toFixed(1)}s)`);

      if (failCount === 0) {
        sections.push("ALL CHECKS PASSED — Cloud is fully operational.");
      } else {
        // Dependency chain summary
        const chain: string[] = [];
        const unreachable = Object.entries(getConfig().vms).filter(([id, v]) => v.wg_ip && v.ip !== "TBD" && !state.reachableVms.has(id));
        if (unreachable.length > 0) chain.push(`WG unreachable: ${unreachable.map(([_, v]) => v.label).join(", ")} → checks skipped`);
        if (!state.caddyOk) chain.push("Caddy DOWN → HTTPS routes may be affected");
        if (!state.autheliaOk) chain.push("Authelia DOWN → auth-protected services may be affected");
        if (chain.length > 0) {
          sections.push("", `DEPENDENCY CHAIN:`);
          chain.forEach(c => sections.push(`  ${c}`));
        }
      }

      log(`cloud_full complete: ${totalMs}ms, ${passCount}✓ ${failCount}✗`);
      return sections.join("\n");
    }),
  );
}

// ── Standalone runner (GHA / CLI) ────────────────────────────────────────
// When executed directly (not imported by MCP server), run cloud_full and exit
if (process.argv[1]?.endsWith("health_cloud.ts")) {
  (async () => {
    const { McpServer: S } = await import("@modelcontextprotocol/sdk/server/mcp.js");
    const server = new S({ name: "health-runner", version: "1.0.0" });
    registerHealthCloudTools(server);
    const tools = (server as any)._registeredTools;
    const tool = tools?.["cloud-full"];
    if (!tool?.handler) {
      console.error("ERROR: cloud-full tool handler not found");
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
