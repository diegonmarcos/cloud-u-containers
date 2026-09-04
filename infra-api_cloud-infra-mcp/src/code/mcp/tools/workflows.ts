// ── Workflows — GHA + Dagu workflow tools (10 tools) ──
// Full status, error reports, trigger workflows

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { execAsync } from "../../shared/libs/exec.js";
import { DAGU_API, DAGU_API_PATH, daguHeaders } from "../../shared/libs/ops.js";

const log = (msg: string) => process.stderr.write(`[workflows] ${msg}\n`);
// Resolve GitHub repo from cloud-data topology owner
function resolveGhRepo(): string {
  try {
    const { getConfig } = require("../../shared/libs/config.js");
    const config = getConfig();
    // 2026-09-04: was `${owner}/cloud` — the pre-rename name. `diegonmarcos/cloud`
    // still resolves (a stale repo holding one "Copilot" workflow), so every
    // enumeration silently returned the wrong repo instead of erroring.
    return `${config.owner?.github ?? "diegonmarcos"}/cloud-infra`;
  } catch {}
  return "diegonmarcos/cloud-infra";
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

// gh's unauthenticated message is a login tutorial, not an error anyone reading
// a workflow report would recognise. Rewrite it into the actual operator action.
function ghError(stderr: string): string {
  const text = stderr.trim() || "(no stderr)";
  if (/gh auth login|GH_TOKEN environment variable|authentication token/i.test(text)) {
    return `${text}\n→ The container has no GitHub credential. GITHUB_TOKEN comes from src/secrets.yaml (sops) via the .secrets env_file; re-run build.sh secrets and redeploy.`;
  }
  return text;
}

async function daguFetch(path: string, method = "GET", body?: string): Promise<{ ok: boolean; data: unknown; error?: string }> {
  try {
    const resp = await fetch(`${DAGU_API}${path}`, {
      method,
      headers: { "Content-Type": "application/json", ...daguHeaders() },
      body,
      signal: AbortSignal.timeout(10_000),
    });
    const text = await resp.text();
    if (!resp.ok) {
      return { ok: false, data: null, error: `HTTP ${resp.status} from ${DAGU_API}${path}: ${text.slice(0, 200)}` };
    }
    if (!text) {
      return { ok: false, data: null, error: `empty response body from ${DAGU_API}${path} (HTTP 200)` };
    }
    try {
      return { ok: true, data: JSON.parse(text) };
    } catch {
      return { ok: false, data: null, error: `non-JSON response from ${DAGU_API}${path}: ${text.slice(0, 200)}` };
    }
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    return { ok: false, data: null, error: `${msg} (DAGU_API=${DAGU_API})` };
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
  if (!r.ok) return { runs: [], error: ghError(r.stderr) };

  try {
    const all: GhaRun[] = JSON.parse(r.stdout);
    return { runs: all.filter((run) => run.updatedAt >= cutoff) };
  } catch {
    return { runs: [], error: "JSON parse failed" };
  }
}

interface GhaWorkflow { id: number; name: string; state: string; path: string }

// Returns the error instead of swallowing it. The previous version returned []
// on any failure, which turned "gh is not authenticated" into a convincing
// "Available workflows:" with nothing under it.
async function ghaWorkflows(repo: string = GH_REPO): Promise<{ workflows: GhaWorkflow[]; error?: string }> {
  const r = await gh(["workflow", "list", "--repo", repo, "--json", "id,name,state,path", "--all"], 10_000);
  if (!r.ok) return { workflows: [], error: ghError(r.stderr) };
  try {
    return { workflows: JSON.parse(r.stdout) as GhaWorkflow[] };
  } catch {
    return { workflows: [], error: `could not parse 'gh workflow list' output: ${r.stdout.slice(0, 200)}` };
  }
}

// Workflow names carry typographic characters ("Ship → terraform" — U+2192, and
// non-breaking spaces in some names). A caller retyping the name produces an
// ASCII "->", a hyphen, or nothing at all, and strict equality fails. Reduce
// both sides to their alphanumeric words: every separator — arrow, dash,
// punctuation, whitespace — collapses to a single space.
function normalizeName(s: string): string {
  return s.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

function fileName(path: string): string {
  return path.split("/").pop() ?? path;
}

// Match on ID, workflow file name (with or without .yml), exact name, normalized
// name, then normalized substring — in that order of confidence.
function matchWorkflow(workflows: GhaWorkflow[], wanted: string): GhaWorkflow | undefined {
  const norm = normalizeName(wanted);
  const base = fileName(wanted).replace(/\.ya?ml$/, "");
  return (
    workflows.find((w) => String(w.id) === wanted) ??
    workflows.find((w) => fileName(w.path).replace(/\.ya?ml$/, "") === base) ??
    workflows.find((w) => w.name === wanted) ??
    workflows.find((w) => normalizeName(w.name) === norm) ??
    workflows.find((w) => normalizeName(w.name).includes(norm))
  );
}

function listWorkflows(workflows: GhaWorkflow[]): string {
  return workflows
    .map((w) => `  ${w.state === "active" ? "✓" : "✗"} ${w.name}  (id: ${w.id}, file: ${fileName(w.path)})`)
    .join("\n");
}

// ──────────────────────────────────────────────────────────────────────────────
// DAGU DATA
// ──────────────────────────────────────────────────────────────────────────────

interface DaguDag {
  name: string;
  statusText?: string;
  startedAt?: string;
  finishedAt?: string;
  schedule?: string;
}

function mapV2Entry(d: any): DaguDag {
  return {
    name: d.dag?.name ?? d.fileName ?? d.name ?? "?",
    statusText: d.latestDAGRun?.statusLabel ?? d.latestRun?.statusLabel ?? d.status?.statusLabel,
    startedAt: d.latestDAGRun?.startedAt ?? d.latestRun?.startedAt ?? d.status?.startedAt,
    finishedAt: d.latestDAGRun?.finishedAt ?? d.latestRun?.finishedAt ?? d.status?.finishedAt,
    schedule: Array.isArray(d.dag?.schedule) ? d.dag.schedule.map((s: any) => s.expression ?? s).join(", ") : undefined,
  };
}

function mapV1Entry(d: any): DaguDag {
  return {
    name: d.DAG?.Name ?? d.Name ?? "?",
    statusText: d.Status?.StatusText,
    startedAt: d.Status?.StartedAt,
    finishedAt: d.Status?.FinishedAt,
    schedule: d.DAG?.Schedule,
  };
}

async function daguList(): Promise<{ dags: DaguDag[]; error?: string }> {
  const r = await daguFetch(`${DAGU_API_PATH}/dags`);
  if (!r.ok) return { dags: [], error: r.error };
  const data = r.data as any;

  // Dagu v2 (current): { dags: [{dag, latestDAGRun, ...}], pagination?: ... }
  if (Array.isArray(data?.dags)) return { dags: data.dags.map(mapV2Entry) };
  // Newer/paginated shapes occasionally seen in v2.5+
  if (Array.isArray(data?.items))   return { dags: data.items.map(mapV2Entry) };
  if (Array.isArray(data?.results)) return { dags: data.results.map(mapV2Entry) };
  if (Array.isArray(data?.data))    return { dags: data.data.map(mapV2Entry) };
  // Top-level array
  if (Array.isArray(data))          return { dags: data.map(mapV2Entry) };
  // Dagu v1 API fallback
  if (Array.isArray(data?.DAGs))    return { dags: data.DAGs.map(mapV1Entry) };

  // Unknown — surface the actual top-level keys + a preview so we can extend the parser
  const keys = data && typeof data === "object" ? Object.keys(data).slice(0, 20).join(",") : typeof data;
  const preview = JSON.stringify(data).slice(0, 200);
  return { dags: [], error: `unexpected format from ${DAGU_API}${DAGU_API_PATH}/dags (keys=[${keys}] preview=${preview})` };
}

async function daguHistory(dagName: string): Promise<unknown[]> {
  const r = await daguFetch(`${DAGU_API_PATH}/dags/${encodeURIComponent(dagName)}`);
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
  const { workflows: wfs, error: wfError } = await ghaWorkflows();
  sections.push(
    wfError
      ? `\nCould not list workflows in ${GH_REPO}: ${wfError}\n`
      : `\n${wfs.length} workflows registered (${wfs.filter((w) => w.state === "active").length} active)\n`,
  );

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

async function workflowsGhaTrigger(
  workflowName?: string,
  inputs?: Record<string, string>,
  repo: string = GH_REPO,
  ref: string = "main",
): Promise<string> {
  const sections: string[] = [];

  // workflow_dispatch inputs are passed as repeated `-f key=value`. Without
  // these a dispatch-only job guarded by `if: inputs.foo` can never fire — it
  // silently resolves false and the job is skipped, so the run still reports
  // green while doing nothing.
  const inputArgs = Object.entries(inputs ?? {}).flatMap(([k, v]) => ["-f", `${k}=${v}`]);

  if (!workflowName || workflowName === "all") {
    // Trigger all dispatchable workflows. Inputs are deliberately NOT forwarded
    // here — they are per-workflow and would be rejected by any workflow that
    // does not declare them.
    const { workflows: wfs, error } = await ghaWorkflows(repo);
    if (error) return `Could not list workflows in ${repo}: ${error}`;
    const active = wfs.filter((w) => w.state === "active");
    sections.push(`Triggering ${active.length} active workflows in ${repo}...`);
    const results = await Promise.allSettled(
      active.map(async (wf) => {
        const r = await gh(["workflow", "run", String(wf.id), "--repo", repo, "--ref", ref], 10_000);
        return { name: wf.name, ok: r.ok, error: r.stderr.trim() };
      }),
    );
    for (const r of results) {
      if (r.status === "fulfilled") {
        sections.push(`  ${r.value.ok ? "✓" : "✗"} ${r.value.name}${r.value.ok ? "" : ` — ${r.value.error}`}`);
      }
    }
  } else {
    // Trigger specific workflow. `gh workflow run` itself accepts an ID, a file
    // name or a name, so when enumeration is unavailable we hand the caller's
    // identifier straight through rather than refusing on an empty list.
    const { workflows: wfs, error } = await ghaWorkflows(repo);
    const match = matchWorkflow(wfs, workflowName);
    if (!match && wfs.length > 0) {
      return `Workflow not found in ${repo}: "${workflowName}"\nAvailable:\n${listWorkflows(wfs)}`;
    }
    const target = match ? String(match.id) : workflowName;
    const label = match ? match.name : `${workflowName} (unverified — ${error ?? "no workflows listed"})`;
    const r = await gh(["workflow", "run", target, "--repo", repo, "--ref", ref, ...inputArgs], 10_000);
    const withInputs = inputArgs.length ? ` (${Object.entries(inputs ?? {}).map(([k, v]) => `${k}=${v}`).join(", ")})` : "";
    sections.push(r.ok ? `✓ Triggered: ${label}${withInputs}` : `✗ Failed: ${label} — ${ghError(r.stderr)}`);
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

  const rows = dags.map((d) => [
    d.name,
    d.statusText ?? "unknown",
    d.startedAt ? timeAgo(d.startedAt) : "-",
    d.schedule ?? "-",
  ]);

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
    const statusText = (d.statusText ?? "").toLowerCase();
    const finishedAt = d.finishedAt ? new Date(d.finishedAt).getTime() : 0;

    if ((statusText === "error" || statusText === "failed" || statusText === "cancel") && finishedAt > cutoff) {
      failed.push({
        name: d.name,
        status: statusText,
        when: d.finishedAt ? timeAgo(d.finishedAt) : "?",
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
      const name = d.name;
      if (!name) continue;
      const r = await daguFetch(`${DAGU_API_PATH}/dags/${encodeURIComponent(name)}/start`, "POST", "{}");
      sections.push(`  ${r.ok ? "✓" : "✗"} ${name}${r.ok ? "" : ` — ${r.error}`}`);
    }
  } else {
    const r = await daguFetch(`${DAGU_API_PATH}/dags/${encodeURIComponent(dagName)}/start`, "POST", "{}");
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
    "GHA x86 runner (ubuntu-latest): all workflow runs last 24h — status, counts, per-workflow breakdown",
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
    "Trigger GHA workflow(s) on the GHA x86 runner (ubuntu-latest, ship.yml). This is the canonical build+deploy runner for cloud services. Specify workflow name or 'all' for all active workflows. Pass `inputs` to supply workflow_dispatch inputs, and `repo` to target a repo other than the default cloud one.",
    {
      workflow: z.string().optional().describe("Workflow ID (250165604), file name (ship-terraform.yml) or name ('Ship → terraform', partial match, arrow/dash variants tolerated), or 'all'. Omit to list available."),
      inputs: z.record(z.string()).optional().describe("workflow_dispatch inputs, e.g. {\"build_fork\":\"true\"}. Booleans must be the strings 'true'/'false'. Use devops.workflows.gha_definition to see which inputs a workflow declares. Ignored when workflow is 'all'."),
      repo: z.string().optional().describe("owner/repo to dispatch in (default: the cloud-infra repo). Works for any repo, e.g. diegonmarcos/cloud-u-linux."),
      ref: z.string().optional().describe("Git ref to run on (default: main)"),
    },
    ({ workflow, inputs, repo, ref }) => safeRun(async () => {
      if (!workflow) {
        const target = repo ?? GH_REPO;
        const { workflows: wfs, error } = await ghaWorkflows(target);
        if (error) return `Could not list workflows in ${target}: ${error}`;
        if (wfs.length === 0) return `No workflows registered in ${target}.`;
        return `Available workflows in ${target}:\n${listWorkflows(wfs)}`;
      }
      return workflowsGhaTrigger(workflow, inputs, repo, ref);
    }),
  );

  server.tool(
    "devops.workflows.gha_definition",
    "GHA: show a workflow's YAML definition (gh workflow view --yaml). Read this BEFORE devops.workflows.gha_trigger to discover which workflow_dispatch inputs the workflow actually declares — dispatching with undeclared inputs is rejected, and omitting a required one produces a green run that does nothing.",
    {
      workflow: z.string().describe("Workflow ID, file name (ship-terraform.yml) or name ('Ship → terraform')"),
      repo: z.string().optional().describe("owner/repo (default: the cloud-infra repo)"),
    },
    ({ workflow, repo }) => safeRun(async () => {
      const target = repo ?? GH_REPO;
      const { workflows: wfs } = await ghaWorkflows(target);
      const match = matchWorkflow(wfs, workflow);
      if (!match && wfs.length > 0) {
        return `Workflow not found in ${target}: "${workflow}"\nAvailable:\n${listWorkflows(wfs)}`;
      }
      const r = await gh(["workflow", "view", match ? String(match.id) : workflow, "--repo", target, "--yaml"], 20_000);
      if (!r.ok) return `ERROR: ${ghError(r.stderr)}`;
      return `${match ? `${match.name} (id: ${match.id}, file: ${fileName(match.path)})` : workflow} in ${target}\n${"═".repeat(70)}\n${r.stdout}`;
    }),
  );

  server.tool(
    "devops.workflows.gha_runs",
    "GHA: recent runs for one workflow (gh run list --workflow). Unlike devops.workflows.gha this is not capped at 24h — use it to follow a run you just dispatched.",
    {
      workflow: z.string().optional().describe("Workflow ID, file name or name. Omit for all workflows in the repo."),
      limit: z.number().optional().describe("How many runs to return (default: 10)"),
      repo: z.string().optional().describe("owner/repo (default: the cloud-infra repo)"),
    },
    ({ workflow, limit, repo }) => safeRun(async () => {
      const target = repo ?? GH_REPO;
      const args = ["run", "list", "--repo", target, "--limit", String(limit ?? 10),
        "--json", "databaseId,workflowName,status,conclusion,createdAt,displayTitle,headBranch"];
      if (workflow) {
        const { workflows: wfs } = await ghaWorkflows(target);
        const match = matchWorkflow(wfs, workflow);
        if (!match && wfs.length > 0) {
          return `Workflow not found in ${target}: "${workflow}"\nAvailable:\n${listWorkflows(wfs)}`;
        }
        args.push("--workflow", match ? String(match.id) : workflow);
      }
      const r = await gh(args, 20_000);
      if (!r.ok) return `ERROR: ${ghError(r.stderr)}`;
      let runs: Array<Record<string, string | number>>;
      try { runs = JSON.parse(r.stdout); } catch { return `Could not parse run list: ${r.stdout.slice(0, 200)}`; }
      if (runs.length === 0) return `No runs found in ${target}${workflow ? ` for "${workflow}"` : ""}.`;
      const rows = runs.map((run) => [
        String(run.databaseId),
        String(run.workflowName ?? "-"),
        String(run.conclusion || run.status),
        String(run.headBranch ?? "-"),
        timeAgo(String(run.createdAt)),
        String(run.displayTitle ?? "").slice(0, 40),
      ]);
      return `GHA RUNS — ${target}${workflow ? ` / ${workflow}` : ""}\n${"═".repeat(70)}\n${formatTable(["ID", "Workflow", "Result", "Branch", "When", "Title"], rows)}`;
    }),
  );

  server.tool(
    "devops.workflows.gha_run",
    "GHA: one run's jobs AND per-step status (gh run view --json jobs). Step granularity is what tells you WHICH step a run is stuck or failing on — the run-level conclusion does not.",
    {
      runId: z.string().describe("Run database ID (from devops.workflows.gha_runs)"),
      repo: z.string().optional().describe("owner/repo (default: the cloud-infra repo)"),
    },
    ({ runId, repo }) => safeRun(async () => {
      const target = repo ?? GH_REPO;
      const r = await gh(["run", "view", runId, "--repo", target,
        "--json", "databaseId,workflowName,status,conclusion,displayTitle,createdAt,url,jobs"], 30_000);
      if (!r.ok) return `ERROR: ${ghError(r.stderr)}`;
      let run: {
        workflowName?: string; status?: string; conclusion?: string; displayTitle?: string;
        createdAt?: string; url?: string;
        jobs?: Array<{ name: string; status: string; conclusion: string; steps?: Array<{ number: number; name: string; status: string; conclusion: string }> }>;
      };
      try { run = JSON.parse(r.stdout); } catch { return `Could not parse run view: ${r.stdout.slice(0, 200)}`; }
      const out: string[] = [];
      out.push(`RUN ${runId} — ${run.workflowName ?? "?"} (${target})`);
      out.push("═".repeat(70));
      out.push(`Result: ${run.conclusion || run.status}  |  ${run.createdAt ? timeAgo(run.createdAt) : "?"}  |  ${run.displayTitle ?? ""}`);
      if (run.url) out.push(run.url);
      for (const job of run.jobs ?? []) {
        out.push(`\n── ${job.name}: ${job.conclusion || job.status} ──`);
        for (const step of job.steps ?? []) {
          const state = step.conclusion || step.status;
          const marker = state === "success" ? "✓" : state === "failure" ? "✗" : state === "skipped" ? "-" : "…";
          out.push(`  ${marker} ${String(step.number).padStart(2)} ${step.name} (${state})`);
        }
      }
      return out.join("\n");
    }),
  );

  server.tool(
    "devops.workflows.gha_run_logs",
    "GHA: a run's logs (gh run view --log-failed, or --log for the full transcript). Failed-only by default — the full log of a ship run is megabytes.",
    {
      runId: z.string().describe("Run database ID (from devops.workflows.gha_runs)"),
      full: z.boolean().optional().describe("true = whole log (--log); default false = failed steps only (--log-failed)"),
      tail: z.number().optional().describe("Return only the last N lines (default: 200)"),
      repo: z.string().optional().describe("owner/repo (default: the cloud-infra repo)"),
    },
    ({ runId, full, tail, repo }) => safeRun(async () => {
      const target = repo ?? GH_REPO;
      const r = await gh(["run", "view", runId, "--repo", target, full ? "--log" : "--log-failed"], 120_000);
      if (!r.ok) return `ERROR: ${ghError(r.stderr)}`;
      const lines = r.stdout.trim().split("\n");
      if (!r.stdout.trim()) {
        return full ? `Run ${runId} has no logs (still queued, or expired).`
                    : `Run ${runId} has no failed-step logs — it may have succeeded, been cancelled, or still be running. Pass full: true for the whole log.`;
      }
      const n = tail ?? 200;
      const shown = lines.slice(-n);
      const header = `RUN ${runId} LOGS (${full ? "full" : "failed steps"}) — ${target}\n${"═".repeat(70)}`;
      const elided = lines.length > shown.length ? `… ${lines.length - shown.length} earlier line(s) elided; raise \`tail\` to see them\n` : "";
      return `${header}\n${elided}${shown.join("\n")}`;
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
        const st = (d.statusText ?? "").toLowerCase();
        const fin = d.finishedAt ? new Date(d.finishedAt).getTime() : 0;
        return (st === "success" || st === "done") && fin > cutoff;
      });
      if (ok.length === 0) return "No successful Dagu runs in the last 24 hours.";
      const rows = ok.map((d) => [d.name, d.finishedAt ? timeAgo(d.finishedAt) : "?"]);
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
        return `Available DAGs:\n${dags.map((d) => `  ${d.name} (${d.schedule ?? "manual"})`).join("\n")}`;
      }
      return workflowsDaguTrigger(dag);
    }),
  );
}
