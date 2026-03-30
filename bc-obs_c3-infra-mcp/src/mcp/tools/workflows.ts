// ── Workflows — GHA + Dagu workflow tools (10 tools) ──
// Full status, error reports, trigger workflows

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { execAsync } from "../../shared/exec.js";
import { DAGU_API, daguHeaders } from "../../shared/ops.js";

const log = (msg: string) => process.stderr.write(`[workflows] ${msg}\n`);
// Resolve GitHub repo from cloud-data topology owner
function resolveGhRepo(): string {
  try {
    const { getConfig } = require("../../shared/config.js");
    const config = getConfig();
    return `${config.owner?.github ?? "diegonmarcos"}/cloud`;
  } catch {}
  return "diegonmarcos/cloud";
}
const GH_REPO = resolveGhRepo();

// ──────────────────────────────────────────────────────────────────────────────
// HELPERS
// ──────────────────────────────────────────────────────────────────────────────

function safeRun(fn: () => Promise<string>): Promise<{ content: [{ type: "text"; text: string }] }> {
  return fn()
    .then((text) => ({ content: [{ type: "text" as const, text }] }))
    .catch((err) => ({ content: [{ type: "text" as const, text: `ERROR: ${err instanceof Error ? err.message : String(err)}` }] }));
}

async function gh(args: string[], timeout = 15_000): Promise<{ ok: boolean; stdout: string; stderr: string }> {
  const r = await execAsync("gh", args, { timeout });
  return { ok: r.ok, stdout: r.stdout, stderr: r.stderr };
}

async function daguFetch(path: string, method = "GET", body?: string): Promise<{ ok: boolean; data: unknown; error?: string }> {
  try {
    const resp = await fetch(`${DAGU_API}${path}`, {
      method,
      headers: { "Content-Type": "application/json", ...daguHeaders() },
      body,
      signal: AbortSignal.timeout(10_000),
    });
    if (!resp.ok) {
      const text = await resp.text().catch(() => "");
      return { ok: false, data: null, error: `HTTP ${resp.status}: ${text.slice(0, 200)}` };
    }
    const data = await resp.json().catch(() => ({}));
    return { ok: true, data };
  } catch (e: unknown) {
    return { ok: false, data: null, error: e instanceof Error ? e.message : String(e) };
  }
}

function formatTable(headers: string[], rows: string[][]): string {
  const widths = headers.map((h, i) =>
    Math.max(h.length, ...rows.map((r) => (r[i] || "").length))
  );
  const sep = widths.map((w) => "─".repeat(w + 2)).join("┼");
  const fmtRow = (r: string[]) =>
    r.map((c, i) => ` ${(c || "").padEnd(widths[i])} `).join("│");
  return [fmtRow(headers), sep, ...rows.map(fmtRow)].join("\n");
}

function timeAgo(isoDate: string): string {
  const diff = Date.now() - new Date(isoDate).getTime();
  const mins = Math.floor(diff / 60_000);
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  return `${Math.floor(hrs / 24)}d ago`;
}

// ──────────────────────────────────────────────────────────────────────────────
// GHA DATA
// ──────────────────────────────────────────────────────────────────────────────

interface GhaRun {
  name: string;
  workflowName: string;
  status: string;
  conclusion: string;
  updatedAt: string;
  headBranch: string;
  databaseId: number;
  url?: string;
  event?: string;
}

async function ghaRuns24h(filter?: string): Promise<{ runs: GhaRun[]; error?: string }> {
  const cutoff = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const args = [
    "run", "list", "--repo", GH_REPO,
    "--limit", "100",
    "--json", "name,workflowName,status,conclusion,updatedAt,headBranch,databaseId,url,event",
  ];
  if (filter) args.push("--status", filter);

  const r = await gh(args, 20_000);
  if (!r.ok) return { runs: [], error: r.stderr.trim() };

  try {
    const all: GhaRun[] = JSON.parse(r.stdout);
    return { runs: all.filter((run) => run.updatedAt >= cutoff) };
  } catch {
    return { runs: [], error: "JSON parse failed" };
  }
}

async function ghaWorkflows(): Promise<{ id: number; name: string; state: string }[]> {
  const r = await gh(["workflow", "list", "--repo", GH_REPO, "--json", "id,name,state", "--all"], 10_000);
  if (!r.ok) return [];
  try { return JSON.parse(r.stdout); } catch { return []; }
}

// ──────────────────────────────────────────────────────────────────────────────
// DAGU DATA
// ──────────────────────────────────────────────────────────────────────────────

interface DaguDag {
  Name: string;
  Status?: { Status?: number; StatusText?: string; StartedAt?: string; FinishedAt?: string };
  Schedule?: string;
  NextRun?: string;
}

async function daguList(): Promise<{ dags: DaguDag[]; error?: string }> {
  const r = await daguFetch("/api/v2/dags");
  if (!r.ok) return { dags: [], error: r.error };
  const data = r.data as { DAGs?: Array<{ DAG?: DaguDag; Status?: unknown }> } | DaguDag[];
  if (Array.isArray(data)) return { dags: data };
  if (data?.DAGs) return { dags: data.DAGs.map((d) => ({ ...d.DAG, Status: d.Status } as DaguDag)) };
  return { dags: [], error: "unexpected format" };
}

async function daguHistory(dagName: string): Promise<unknown[]> {
  const r = await daguFetch(`/api/v2/dags/${encodeURIComponent(dagName)}`);
  if (!r.ok) return [];
  const data = r.data as { LogData?: unknown[]; RecentHistory?: unknown[] };
  return data?.RecentHistory ?? data?.LogData ?? [];
}

// ──────────────────────────────────────────────────────────────────────────────
// TOOL: workflows_gha
// ──────────────────────────────────────────────────────────────────────────────

async function workflowsGha(): Promise<string> {
  const sections: string[] = [];
  sections.push("GHA WORKFLOWS — LAST 24H");
  sections.push("═".repeat(70));

  // Available workflows
  const wfs = await ghaWorkflows();
  sections.push(`\n${wfs.length} workflows registered (${wfs.filter((w) => w.state === "active").length} active)\n`);

  // Recent runs
  const { runs, error } = await ghaRuns24h();
  if (error) {
    sections.push(`Error fetching runs: ${error}`);
    return sections.join("\n");
  }

  if (runs.length === 0) {
    sections.push("No runs in the last 24 hours.");
    return sections.join("\n");
  }

  // Summary counts
  const byConclusion = new Map<string, number>();
  for (const r of runs) {
    const key = r.conclusion || r.status;
    byConclusion.set(key, (byConclusion.get(key) || 0) + 1);
  }
  sections.push("Summary: " + [...byConclusion.entries()].map(([k, v]) => `${v} ${k}`).join(", "));
  sections.push("");

  // Table
  const rows = runs.map((r) => [
    r.workflowName.length > 35 ? r.workflowName.slice(0, 35) + "…" : r.workflowName,
    r.conclusion || r.status,
    r.headBranch,
    r.event ?? "-",
    timeAgo(r.updatedAt),
    String(r.databaseId),
  ]);
  sections.push(formatTable(["Workflow", "Result", "Branch", "Event", "When", "ID"], rows));

  // By workflow summary
  sections.push("\nBY WORKFLOW:");
  const byWf = new Map<string, { success: number; failure: number; other: number }>();
  for (const r of runs) {
    const prev = byWf.get(r.workflowName) ?? { success: 0, failure: 0, other: 0 };
    if (r.conclusion === "success") prev.success++;
    else if (r.conclusion === "failure") prev.failure++;
    else prev.other++;
    byWf.set(r.workflowName, prev);
  }
  for (const [name, counts] of [...byWf.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
    const parts: string[] = [];
    if (counts.success) parts.push(`${counts.success} ok`);
    if (counts.failure) parts.push(`${counts.failure} FAIL`);
    if (counts.other) parts.push(`${counts.other} other`);
    sections.push(`  ${name}: ${parts.join(", ")}`);
  }

  return sections.join("\n");
}

// ──────────────────────────────────────────────────────────────────────────────
// TOOL: workflows_gha_errors_24
// ──────────────────────────────────────────────────────────────────────────────

async function workflowsGhaErrors(): Promise<string> {
  const sections: string[] = [];
  sections.push("GHA FAILURES — LAST 24H");
  sections.push("═".repeat(70));

  const { runs, error } = await ghaRuns24h("failure");
  if (error) return `Error: ${error}`;

  if (runs.length === 0) {
    sections.push("No failures in the last 24 hours.");
    return sections.join("\n");
  }

  sections.push(`${runs.length} failed run(s)\n`);

  for (const r of runs) {
    sections.push(`── ${r.workflowName} (${timeAgo(r.updatedAt)}) ──`);
    sections.push(`  Branch: ${r.headBranch} | ID: ${r.databaseId}`);

    // Try to get failure logs
    const logResult = await gh([
      "run", "view", String(r.databaseId),
      "--repo", GH_REPO,
      "--log-failed",
    ], 15_000);

    if (logResult.ok && logResult.stdout.trim()) {
      const logLines = logResult.stdout.trim().split("\n");
      const relevant = logLines.slice(-15); // last 15 lines
      sections.push(`  Log (last ${relevant.length} lines):`);
      for (const line of relevant) {
        sections.push(`    ${line}`);
      }
    } else {
      sections.push("  (no failed logs available)");
    }
    sections.push("");
  }

  return sections.join("\n");
}

// ──────────────────────────────────────────────────────────────────────────────
// TOOL: workflows_gha_trigger
// ──────────────────────────────────────────────────────────────────────────────

async function workflowsGhaTrigger(workflowName?: string): Promise<string> {
  const sections: string[] = [];

  if (!workflowName || workflowName === "all") {
    // Trigger all dispatchable workflows
    const wfs = await ghaWorkflows();
    const active = wfs.filter((w) => w.state === "active");
    sections.push(`Triggering ${active.length} active workflows...`);
    const results = await Promise.allSettled(
      active.map(async (wf) => {
        const r = await gh(["workflow", "run", String(wf.id), "--repo", GH_REPO, "--ref", "main"], 10_000);
        return { name: wf.name, ok: r.ok, error: r.stderr.trim() };
      }),
    );
    for (const r of results) {
      if (r.status === "fulfilled") {
        sections.push(`  ${r.value.ok ? "✓" : "✗"} ${r.value.name}${r.value.ok ? "" : ` — ${r.value.error}`}`);
      }
    }
  } else {
    // Trigger specific workflow
    const wfs = await ghaWorkflows();
    const match = wfs.find((w) => w.name === workflowName || w.name.includes(workflowName) || String(w.id) === workflowName);
    if (!match) {
      return `Workflow not found: "${workflowName}"\nAvailable: ${wfs.map((w) => w.name).join(", ")}`;
    }
    const r = await gh(["workflow", "run", String(match.id), "--repo", GH_REPO, "--ref", "main"], 10_000);
    sections.push(r.ok ? `✓ Triggered: ${match.name}` : `✗ Failed: ${match.name} — ${r.stderr.trim()}`);
  }

  return sections.join("\n");
}

// ──────────────────────────────────────────────────────────────────────────────
// TOOL: workflows_dagu
// ──────────────────────────────────────────────────────────────────────────────

async function workflowsDagu(): Promise<string> {
  const sections: string[] = [];
  sections.push("DAGU WORKFLOWS");
  sections.push("═".repeat(70));

  const { dags, error } = await daguList();
  if (error) {
    sections.push(`Dagu API error: ${error}`);
    return sections.join("\n");
  }

  if (dags.length === 0) {
    sections.push("No DAGs found.");
    return sections.join("\n");
  }

  sections.push(`${dags.length} DAGs\n`);

  const rows = dags.map((d) => {
    const status = d.Status as Record<string, unknown> | undefined;
    const statusText = String(status?.StatusText ?? status?.Status ?? "unknown");
    const started = status?.StartedAt ? timeAgo(String(status.StartedAt)) : "-";
    return [
      d.Name ?? "?",
      statusText,
      started,
      d.Schedule ?? "-",
    ];
  });

  sections.push(formatTable(["DAG", "Status", "Last Run", "Schedule"], rows));

  return sections.join("\n");
}

// ──────────────────────────────────────────────────────────────────────────────
// TOOL: workflows_dagu_errors_24
// ──────────────────────────────────────────────────────────────────────────────

async function workflowsDaguErrors(): Promise<string> {
  const sections: string[] = [];
  sections.push("DAGU ERRORS — LAST 24H");
  sections.push("═".repeat(70));

  const { dags, error } = await daguList();
  if (error) return `Dagu API error: ${error}`;

  const cutoff = Date.now() - 24 * 60 * 60 * 1000;
  const failed: { name: string; status: string; when: string }[] = [];

  for (const d of dags) {
    const status = d.Status as Record<string, unknown> | undefined;
    const statusText = String(status?.StatusText ?? "").toLowerCase();
    const finishedAt = status?.FinishedAt ? new Date(String(status.FinishedAt)).getTime() : 0;

    if ((statusText === "error" || statusText === "failed" || statusText === "cancel") && finishedAt > cutoff) {
      failed.push({
        name: d.Name ?? "?",
        status: statusText,
        when: status?.FinishedAt ? timeAgo(String(status.FinishedAt)) : "?",
      });
    }
  }

  if (failed.length === 0) {
    sections.push("No Dagu failures in the last 24 hours.");
    return sections.join("\n");
  }

  sections.push(`${failed.length} failed DAG(s)\n`);
  for (const f of failed) {
    sections.push(`  ✗ ${f.name} — ${f.status} (${f.when})`);
  }

  return sections.join("\n");
}

// ──────────────────────────────────────────────────────────────────────────────
// TOOL: workflows_dagu_trigger
// ──────────────────────────────────────────────────────────────────────────────

async function workflowsDaguTrigger(dagName?: string): Promise<string> {
  const sections: string[] = [];

  if (!dagName || dagName === "all") {
    const { dags, error } = await daguList();
    if (error) return `Dagu API error: ${error}`;

    sections.push(`Triggering ${dags.length} DAGs...`);
    for (const d of dags) {
      const name = d.Name;
      if (!name) continue;
      const r = await daguFetch(`/api/v2/dags/${encodeURIComponent(name)}/start`, "POST", "{}");
      sections.push(`  ${r.ok ? "✓" : "✗"} ${name}${r.ok ? "" : ` — ${r.error}`}`);
    }
  } else {
    const r = await daguFetch(`/api/v2/dags/${encodeURIComponent(dagName)}/start`, "POST", "{}");
    sections.push(r.ok ? `✓ Triggered: ${dagName}` : `✗ Failed: ${dagName} — ${r.error}`);
  }

  return sections.join("\n");
}

// ──────────────────────────────────────────────────────────────────────────────
// TOOL REGISTRATION
// ──────────────────────────────────────────────────────────────────────────────

export function registerWorkflowTools(server: McpServer): void {
  // ── Full: GHA + Dagu combined ──
  server.tool(
    "devops.workflows.all",
    "Full workflow report: GHA + Dagu status, all runs last 24h",
    {},
    () => safeRun(async () => {
      log("workflows: fetching GHA + Dagu...");
      const [gha, dagu] = await Promise.allSettled([workflowsGha(), workflowsDagu()]);
      const parts: string[] = [];
      parts.push(gha.status === "fulfilled" ? gha.value : `GHA ERROR: ${gha.reason}`);
      parts.push("");
      parts.push(dagu.status === "fulfilled" ? dagu.value : `DAGU ERROR: ${dagu.reason}`);
      return parts.join("\n");
    }),
  );

  // ── GHA ──
  server.tool(
    "devops.workflows.gha",
    "GHA: all workflow runs last 24h — status, counts, per-workflow breakdown",
    {},
    () => safeRun(workflowsGha),
  );

  server.tool(
    "devops.workflows.gha_errors",
    "GHA: failed runs last 24h with failure logs",
    {},
    () => safeRun(workflowsGhaErrors),
  );

  server.tool(
    "devops.workflows.gha_ok",
    "GHA: successful runs last 24h",
    {},
    () => safeRun(async () => {
      const { runs, error } = await ghaRuns24h("success");
      if (error) return `Error: ${error}`;
      if (runs.length === 0) return "No successful runs in the last 24 hours.";
      const rows = runs.map((r) => [
        r.workflowName.length > 40 ? r.workflowName.slice(0, 40) + "…" : r.workflowName,
        r.headBranch,
        timeAgo(r.updatedAt),
      ]);
      return `GHA SUCCESSES — LAST 24H\n${"═".repeat(70)}\n${runs.length} successful run(s)\n\n${formatTable(["Workflow", "Branch", "When"], rows)}`;
    }),
  );

  server.tool(
    "devops.workflows.gha_trigger",
    "Trigger GHA workflow(s) — specify name or 'all' for all active workflows",
    {
      workflow: z.string().optional().describe("Workflow name (partial match) or 'all'. Omit to list available."),
    },
    ({ workflow }) => safeRun(async () => {
      if (!workflow) {
        const wfs = await ghaWorkflows();
        return `Available workflows:\n${wfs.map((w) => `  ${w.state === "active" ? "✓" : "✗"} ${w.name} (id: ${w.id})`).join("\n")}`;
      }
      return workflowsGhaTrigger(workflow);
    }),
  );

  // ── Dagu ──
  server.tool(
    "devops.workflows.dagu",
    "Dagu: all DAGs with status, schedule, last run",
    {},
    () => safeRun(workflowsDagu),
  );

  server.tool(
    "devops.workflows.dagu_errors",
    "Dagu: failed DAGs in last 24h",
    {},
    () => safeRun(workflowsDaguErrors),
  );

  server.tool(
    "devops.workflows.dagu_ok",
    "Dagu: successful DAGs in last 24h",
    {},
    () => safeRun(async () => {
      const { dags, error } = await daguList();
      if (error) return `Dagu API error: ${error}`;
      const cutoff = Date.now() - 24 * 60 * 60 * 1000;
      const ok = dags.filter((d) => {
        const s = d.Status as Record<string, unknown> | undefined;
        const st = String(s?.StatusText ?? "").toLowerCase();
        const fin = s?.FinishedAt ? new Date(String(s.FinishedAt)).getTime() : 0;
        return (st === "success" || st === "done") && fin > cutoff;
      });
      if (ok.length === 0) return "No successful Dagu runs in the last 24 hours.";
      const rows = ok.map((d) => {
        const s = d.Status as Record<string, unknown> | undefined;
        return [d.Name ?? "?", s?.FinishedAt ? timeAgo(String(s.FinishedAt)) : "?"];
      });
      return `DAGU SUCCESSES — LAST 24H\n${"═".repeat(70)}\n${ok.length} successful DAG(s)\n\n${formatTable(["DAG", "When"], rows)}`;
    }),
  );

  server.tool(
    "devops.workflows.dagu_trigger",
    "Trigger Dagu DAG(s) — specify name or 'all'",
    {
      dag: z.string().optional().describe("DAG name or 'all'. Omit to list available."),
    },
    ({ dag }) => safeRun(async () => {
      if (!dag) {
        const { dags, error } = await daguList();
        if (error) return `Dagu API error: ${error}`;
        return `Available DAGs:\n${dags.map((d) => `  ${d.Name} (${d.Schedule ?? "manual"})`).join("\n")}`;
      }
      return workflowsDaguTrigger(dag);
    }),
  );
}
