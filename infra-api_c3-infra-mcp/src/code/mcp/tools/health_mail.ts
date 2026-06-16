// ══════════════════════════════════════════════════════════════════════════════
// Mail Health — thin shim over the Rust `cloud-mail-health-full` derive.
//
// History (2026-04-23): the previous TypeScript implementation (~1060 LoC that
// re-implemented the 7-phase Maddy + Stalwart diagnostic) was retired. The
// consolidated Rust derive crate cloud-data/reports/src/cloud-mail-health-full
// is now the single source of truth. These MCP tools trigger that report via
// SSH+Docker on oci-analytics and return its rendered markdown / JSON directly.
//
// Tool surface (unchanged for callers):
//   obs.health.mail         — full 7-phase markdown (cloud_mail_full.md)
//   obs.health.mail_up      — quick UP check (executive summary, cached)
//   obs.health.mail_profile — deep JSON (cloud_mail_full.json)
//   obs.health.mail_inbound — E2E inbound section
//   obs.health.mail_outbound— outbound + DNS section
// ══════════════════════════════════════════════════════════════════════════════

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { sshExecAsync } from "../../shared/libs/ssh.js";

const REPORT_VM = "oci-analytics";
const REPORT_IMAGE = "ghcr.io/diegonmarcos/cloud-data-reports:latest";
const REPORTS_WORKDIR = "/var/lib/dagu/data/cloud-data/reports";
const SSH_KEYS_MOUNT = "/opt/ssh-keys/dagu:/root/.ssh:ro";
const DAGU_VOLUME = "dagu_data:/var/lib/dagu/data";

const FRESH_REPORT_TIMEOUT_MS = 180_000; // mail-full runs ~30-60s
const READ_ONLY_TIMEOUT_MS = 15_000;

const log = (msg: string) => process.stderr.write(`[mail-health] ${msg}\n`);

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
  return (res.stdout || "").replace(/__MISSING__\s*$/, "");
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

function extractSection(md: string, heading: string): string {
  // Find "## heading" and take until the next "## " or end.
  const lines = md.split("\n");
  const startRegex = new RegExp(`^##\\s+${heading.replace(/[.*+?^${}()|[\\]\\\\]/g, "\\$&")}`, "i");
  let i = lines.findIndex((l) => startRegex.test(l));
  if (i < 0) return "";
  const out: string[] = [lines[i]];
  for (let j = i + 1; j < lines.length; j++) {
    if (/^##\s+/.test(lines[j])) break;
    out.push(lines[j]);
  }
  return out.join("\n");
}

export function registerHealthMailTools(server: McpServer): void {
  // ── obs.health.mail — full 7-phase diagnostic ─────────────────────────────
  server.tool(
    "obs.health.mail",
    "Full mail diagnostic — 7 phases (path-checker, KPIs, preflight, containers, network+auth, DNS, internals, e2e). Triggers Rust cloud-mail-health-full.",
    {},
    () =>
      safeRun(async () => {
        const md = await triggerAndReadFile("mail", "cloud_mail_full.md", FRESH_REPORT_TIMEOUT_MS);
        return md || "(empty report — check dagu logs)";
      }),
  );

  // ── obs.health.mail_up — quick summary from cached run ────────────────────
  server.tool(
    "obs.health.mail_up",
    "Quick mail UP summary from most recent run. Reads cached cloud_mail_full.md.",
    {
      fresh: z.boolean().default(false).describe("Trigger a fresh run instead of reading cached"),
    },
    ({ fresh }) =>
      safeRun(async () => {
        const md = fresh
          ? await triggerAndReadFile("mail", "cloud_mail_full.md", FRESH_REPORT_TIMEOUT_MS)
          : await readCachedFile("cloud_mail_full.md");
        if (!md.trim()) return "(no mail report on disk — call obs.health.mail first)";
        const header = md.split("\n").slice(0, 20).join("\n");
        return header;
      }),
  );

  // ── obs.health.mail_profile — structured JSON ────────────────────────────
  server.tool(
    "obs.health.mail_profile",
    "Structured mail report JSON (all phases, all checks). Reads cached cloud_mail_full.json.",
    {},
    () =>
      safeRun(async () => {
        const raw = await readCachedFile("cloud_mail_full.json");
        return raw || "(no mail report on disk — call obs.health.mail first)";
      }),
  );

  // ── obs.health.mail_inbound — inbound-path checks ────────────────────────
  server.tool(
    "obs.health.mail_inbound",
    "E2E inbound delivery section + DNS MX checks from the mail report.",
    {},
    () =>
      safeRun(async () => {
        const md = await readCachedFile("cloud_mail_full.md");
        if (!md.trim()) return "(no mail report on disk — call obs.health.mail first)";
        const a = extractSection(md, "6\\. E2E DELIVERY");
        const b = extractSection(md, "4\\. DNS AUTH");
        return [a, b].filter(Boolean).join("\n\n") || "(section not found in report)";
      }),
  );

  // ── obs.health.mail_outbound — outbound + DNS auth ───────────────────────
  server.tool(
    "obs.health.mail_outbound",
    "Outbound path checks + SMTP relay + DNS auth section.",
    {},
    () =>
      safeRun(async () => {
        const md = await readCachedFile("cloud_mail_full.md");
        if (!md.trim()) return "(no mail report on disk — call obs.health.mail first)";
        const tier0 = extractSection(md, "Tier 0: Path Checker");
        const dns = extractSection(md, "4\\. DNS AUTH");
        const fallbackAll = (tier0 + "\n\n" + dns).trim();
        return fallbackAll || md.split("\n").slice(0, 40).join("\n");
      }),
  );
}
