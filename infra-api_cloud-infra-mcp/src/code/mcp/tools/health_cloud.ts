// ══════════════════════════════════════════════════════════════════════════════
// Cloud Health — thin shim over the Rust `cloud-health-full-daily` master.
//
// History (2026-04-23): the previous TypeScript implementation (~1700 LoC that
// duplicated the 10-layer diagnostic logic) was retired. The monster consolidated
// Rust report in cloud-data/reports/src/cloud-health-full-daily is now the
// single source of truth. These MCP tools trigger that report via SSH+Docker
// on oci-analytics (where Dagu owns the dagu_data volume the report writes to)
// and return its rendered markdown / JSON directly.
//
// Tool surface (unchanged for callers):
//   obs.health.cloud       — full 11-layer + stack markdown (cloud_health_daily.md)
//   obs.health.cloud_up    — quick executive summary (top of daily.md)
//   obs.health.resources_all / _vm / _db — sections extracted from the JSON
// ══════════════════════════════════════════════════════════════════════════════

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { sshExecAsync } from "../../shared/libs/ssh.js";

// ── Constants (data-driven: same VM/volume the Dagu DAGs already use) ────────
const REPORT_VM = "oci-analytics"; // Dagu host — owns dagu_data volume
const REPORT_IMAGE = "ghcr.io/diegonmarcos/cloud-data-reports:latest";
const REPORTS_WORKDIR = "/var/lib/dagu/data/cloud-data/reports";
const SSH_KEYS_MOUNT = "/opt/ssh-keys/dagu:/root/.ssh:ro";
const DAGU_VOLUME = "dagu_data:/var/lib/dagu/data";

const FRESH_REPORT_TIMEOUT_MS = 300_000; // 5 min — full master takes ~90s
const READ_ONLY_TIMEOUT_MS = 15_000;

const log = (msg: string) => process.stderr.write(`[cloud-health] ${msg}\n`);

// ── Core helpers ─────────────────────────────────────────────────────────────

/**
 * Trigger a report build via the Rust Docker image and capture a single file.
 * Runs `build.sh <target>` inside the container then cats `dist/<outFile>`;
 * build stdout is redirected to stderr so only the file content lands on stdout.
 */
async function triggerAndReadFile(target: string, outFile: string, timeoutMs: number): Promise<string> {
  const inner = `bash build.sh ${target} 1>&2 && cat dist/${outFile}`;
  const cmd = [
    "docker", "run", "--rm", "--network", "host",
    "-v", DAGU_VOLUME,
    "-v", SSH_KEYS_MOUNT,
    "-w", REPORTS_WORKDIR,
    "--entrypoint", "sh",
    REPORT_IMAGE,
    "-c", `'${inner.replace(/'/g, "'\\''")}'`,
  ].join(" ");
  log(`triggering ${target} → ${outFile} (timeout=${timeoutMs}ms)`);
  const res = await sshExecAsync(REPORT_VM, cmd, timeoutMs);
  if (res.exitCode !== 0) {
    throw new Error(`Report "${target}" failed (exit ${res.exitCode}): ${(res.stderr || "").slice(0, 400)}`);
  }
  return res.stdout || "";
}

/**
 * Read a file from the most recent run without triggering a new build.
 * Cats directly from the Dagu volume via a short-lived alpine container.
 */
async function readCachedFile(outFile: string): Promise<string> {
  const inner = `cat /data/cloud-data/reports/dist/${outFile} 2>/dev/null || echo '__MISSING__'`;
  const cmd = [
    "docker", "run", "--rm",
    "-v", "dagu_data:/data:ro",
    "--entrypoint", "sh",
    "alpine:3.19",
    "-c", `'${inner.replace(/'/g, "'\\''")}'`,
  ].join(" ");
  const res = await sshExecAsync(REPORT_VM, cmd, READ_ONLY_TIMEOUT_MS);
  const out = (res.stdout || "").replace(/__MISSING__\s*$/, "");
  return out;
}

async function safeRun(fn: () => Promise<string>): Promise<{ content: { type: "text"; text: string }[] }> {
  try {
    const text = await fn();
    return { content: [{ type: "text", text }] };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    return { content: [{ type: "text", text: `ERROR: ${msg}` }] };
  }
}

// ── Extract executive summary from the consolidated daily markdown ────────
function extractSection(md: string, startMarker: string, endMarker?: string): string {
  const start = md.indexOf(startMarker);
  if (start < 0) return "";
  const tail = md.slice(start);
  if (!endMarker) return tail;
  const end = tail.indexOf(endMarker, startMarker.length);
  return end < 0 ? tail : tail.slice(0, end);
}

// ── Tools ────────────────────────────────────────────────────────────────────

export function registerHealthCloudTools(server: McpServer): void {
  // ── obs.health.cloud — full consolidated report ───────────────────────────
  server.tool(
    "obs.health.cloud",
    "Full consolidated cloud health (11-layer + stack + Z-appendix). Triggers Rust cloud-health-full-daily and returns its markdown.",
    {},
    () =>
      safeRun(async () => {
        const md = await triggerAndReadFile("daily", "cloud_health_daily.md", FRESH_REPORT_TIMEOUT_MS);
        return md || "(empty report — check dagu logs)";
      }),
  );

  // ── obs.health.cloud_up — executive summary from most recent report ──────
  server.tool(
    "obs.health.cloud_up",
    "Quick UP check: reads executive summary from the most recent daily report (fast, cached). Call obs.health.cloud for a fresh full run.",
    {
      fresh: z.boolean().default(false).describe("Trigger a fresh run instead of reading the cached report"),
    },
    ({ fresh }) =>
      safeRun(async () => {
        const md = fresh
          ? await triggerAndReadFile("daily", "cloud_health_daily.md", FRESH_REPORT_TIMEOUT_MS)
          : await readCachedFile("cloud_health_daily.md");
        if (!md.trim()) return "(no report on disk — call obs.health.cloud first)";
        const summary = extractSection(md, "## Executive Summary", "\n---\n");
        const issues = extractSection(md, "### Top Issues", "\n---\n");
        const header = md.split("\n").slice(0, 10).join("\n");
        return [header, summary, issues].filter(Boolean).join("\n\n");
      }),
  );

  // ── obs.health.resources_all — VMs + containers + fleet stats ────────────
  server.tool(
    "obs.health.resources_all",
    "All VM + container resource stats (disk, mem, load, uptime). Reads cached daily.json.",
    {},
    () =>
      safeRun(async () => {
        const raw = await readCachedFile("cloud_health_daily.json");
        if (!raw.trim()) return "(no report on disk — call obs.health.cloud first)";
        const j = JSON.parse(raw);
        const slim = {
          date: j.date,
          time: j.time,
          fleet_running: j.fleet_running,
          fleet_total: j.fleet_total,
          fleet_unhealthy: j.fleet_unhealthy,
          exec_summary: j.exec_summary,
          vms: (j.vms ?? []).map((v: Record<string, unknown>) => ({
            name: v.name,
            ip: v.ip,
            status: v.status,
            disk_pct: v.disk_pct,
            mem_pct: v.mem_pct,
            load: v.load,
            uptime: v.uptime,
            containers_running: v.containers_running,
            containers_total: v.containers_total,
            containers_unhealthy: v.containers_unhealthy,
          })),
        };
        return JSON.stringify(slim, null, 2);
      }),
  );

  // ── obs.health.resources_vm — single VM deep-dive ────────────────────────
  server.tool(
    "obs.health.resources_vm",
    "Resource stats for one VM (containers, disk, mem, oom kills, ssh fails). Reads cached daily.json.",
    {
      vm: z.string().describe("VM name (e.g. oci-apps, oci-mail, gcp-proxy)"),
    },
    ({ vm }) =>
      safeRun(async () => {
        const raw = await readCachedFile("cloud_health_daily.json");
        if (!raw.trim()) return "(no report on disk — call obs.health.cloud first)";
        const j = JSON.parse(raw);
        const hit = (j.vms ?? []).find((v: Record<string, unknown>) => v.name === vm || v.ip === vm);
        if (!hit) return `VM "${vm}" not found in report. Available: ${(j.vms ?? []).map((v: { name: string }) => v.name).join(", ")}`;
        return JSON.stringify(hit, null, 2);
      }),
  );

  // ── obs.health.resources_db — DB health + sizes ──────────────────────────
  server.tool(
    "obs.health.resources_db",
    "Database inventory + runtime status (from cached daily.json).",
    {},
    () =>
      safeRun(async () => {
        const raw = await readCachedFile("cloud_health_daily.json");
        if (!raw.trim()) return "(no report on disk — call obs.health.cloud first)";
        const j = JSON.parse(raw);
        return JSON.stringify(j.databases ?? [], null, 2);
      }),
  );
}
