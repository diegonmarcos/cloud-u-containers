// ── obs.debug.vps_* — Cloud provider CLI proxies (7 tools) ──
// Wraps gcloud, oci, wrangler, gh, hcloud, cloudflare API, ghcr

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { execAsync } from "../../shared/libs/exec.js";

const log = (msg: string) => process.stderr.write(`[vps-ops] ${msg}\n`);

function safeRun(fn: () => Promise<string>): Promise<{ content: [{ type: "text"; text: string }] }> {
  return fn()
    .then((text) => ({ content: [{ type: "text" as const, text }] }))
    .catch((err) => ({ content: [{ type: "text" as const, text: `ERROR: ${err instanceof Error ? err.message : String(err)}` }] }));
}

async function runCli(cmd: string, args: string[], timeout = 30_000): Promise<string> {
  // Check if CLI is available
  const which = await execAsync("bash", ["-c", `command -v ${cmd}`], { timeout: 3_000 });
  if (!which.ok) return `${cmd} CLI not found. Install it first.`;

  const r = await execAsync(cmd, args, { timeout });
  if (r.ok) return r.stdout.trim() || "(no output)";
  return `EXIT ${r.exitCode}\n${r.stderr.trim()}\n${r.stdout.trim()}`.trim();
}

// ──────────────────────────────────────────────────────────────────────────────
// PRESETS — common subcommands for each provider
// ──────────────────────────────────────────────────────────────────────────────

const PRESETS: Record<string, Record<string, string[]>> = {
  gcloud: {
    "instances": ["compute", "instances", "list", "--format=table(name,zone,status,machineType,networkInterfaces[0].accessConfigs[0].natIP)"],
    "disks": ["compute", "disks", "list", "--format=table(name,zone,sizeGb,status,type)"],
    "billing": ["billing", "accounts", "list"],
    "projects": ["projects", "list", "--format=table(projectId,name,lifecycleState)"],
    "iam": ["iam", "service-accounts", "list", "--format=table(email,displayName,disabled)"],
    "firewall": ["compute", "firewall-rules", "list", "--format=table(name,direction,allowed,sourceRanges,targetTags)"],
    "snapshots": ["compute", "snapshots", "list", "--format=table(name,diskSizeGb,status,sourceDisk)"],
    "networks": ["compute", "networks", "list"],
    "regions": ["compute", "regions", "list", "--format=table(name,status,quotas.CPUS.limit)"],
    "auth": ["auth", "list"],
    "tf-plan": ["__terraform__", "plan"],
    "tf-apply": ["__terraform__", "apply"],
    "tf-drift": ["__terraform__", "plan", "-detailed-exitcode"],
    "tf-state": ["__terraform__", "state", "list"],
    "tf-output": ["__terraform__", "output", "-json"],
    "gpu-quota": ["__gpu_quota__"],
  },
  oci: {
    "instances": ["compute", "instance", "list", "--compartment-id", "${OCI_COMPARTMENT_ID}", "--output", "table", "--query", "data[*].{Name:\"display-name\",State:\"lifecycle-state\",Shape:shape,AD:\"availability-domain\"}"],
    "volumes": ["bv", "volume", "list", "--compartment-id", "${OCI_COMPARTMENT_ID}", "--output", "table"],
    "vcn": ["network", "vcn", "list", "--compartment-id", "${OCI_COMPARTMENT_ID}", "--output", "table"],
    "budget": ["budgets", "budget", "list", "--compartment-id", "${OCI_TENANCY_ID}", "--output", "table"],
    "limits": ["limits", "service", "list", "--compartment-id", "${OCI_COMPARTMENT_ID}", "--output", "table"],
    "auth": ["iam", "region", "list", "--output", "table"],
    "tf-plan": ["__terraform__", "plan"],
    "tf-apply": ["__terraform__", "apply"],
    "tf-drift": ["__terraform__", "plan", "-detailed-exitcode"],
    "tf-state": ["__terraform__", "state", "list"],
    "tf-output": ["__terraform__", "output", "-json"],
  },
  gh: {
    "repos": ["repo", "list", "diegonmarcos", "--json", "name,visibility,updatedAt", "--jq", '.[] | "\\(.name) (\\(.visibility)) \\(.updatedAt[:10])"'],
    "issues": ["issue", "list", "--repo", "diegonmarcos/cloud-infra", "--state", "open", "--json", "number,title,updatedAt"],
    "prs": ["pr", "list", "--repo", "diegonmarcos/cloud-infra", "--state", "open", "--json", "number,title,headRefName"],
    "runs": ["run", "list", "--repo", "diegonmarcos/cloud-infra", "--limit", "10", "--json", "name,status,conclusion,updatedAt"],
    "workflows": ["workflow", "list", "--repo", "diegonmarcos/cloud-infra", "--json", "name,id,state"],
    "releases": ["release", "list", "--repo", "diegonmarcos/cloud-infra", "--limit", "5"],
    "secrets": ["secret", "list", "--repo", "diegonmarcos/cloud-infra"],
    "auth": ["auth", "status"],
  },
  wrangler: {
    "workers": ["d1", "list"],
    "kv": ["kv", "namespace", "list"],
    "r2": ["r2", "bucket", "list"],
    "pages": ["pages", "project", "list"],
    "tail": ["tail", "--format", "pretty"],
    "auth": ["whoami"],
  },
  hcloud: {
    "servers": ["server", "list", "-o", "columns=id,name,status,server_type,datacenter,ipv4,ipv6"],
    "images": ["image", "list", "-o", "columns=id,type,name,description,disk_size,created"],
    "volumes": ["volume", "list", "-o", "columns=id,name,size,server,location"],
    "firewalls": ["firewall", "list", "-o", "columns=id,name,rules_count"],
    "ssh-keys": ["ssh-key", "list", "-o", "columns=id,name,fingerprint"],
    "networks": ["network", "list", "-o", "columns=id,name,ip_range"],
    "auth": ["context", "active"],
    "tf-plan": ["__terraform__", "plan"],
    "tf-apply": ["__terraform__", "apply"],
    "tf-drift": ["__terraform__", "plan", "-detailed-exitcode"],
    "tf-state": ["__terraform__", "state", "list"],
    "tf-output": ["__terraform__", "output", "-json"],
  },
  cloudflare: {
    // Cloudflare uses API, not CLI — we wrap curl calls
    "zones": ["__cf_api__", "/zones?per_page=50", "result[].{name,status,plan.name}"],
    "dns": ["__cf_api__", "/zones/${CF_ZONE_ID}/dns_records?per_page=100", "result[].{type,name,content,proxied}"],
    "workers": ["__cf_api__", "/accounts/${CF_ACCOUNT_ID}/workers/scripts", "result[].{id,modified_on}"],
    "firewall": ["__cf_api__", "/zones/${CF_ZONE_ID}/firewall/rules", "result[].{description,action,filter.expression}"],
    "analytics": ["__cf_api__", "/zones/${CF_ZONE_ID}/analytics/dashboard?since=-1440", "result.totals"],
    "auth": ["__cf_api__", "/user/tokens/verify", "result.status"],
    "tf-plan": ["__terraform__", "plan"],
    "tf-apply": ["__terraform__", "apply"],
    "tf-drift": ["__terraform__", "plan", "-detailed-exitcode"],
    "tf-state": ["__terraform__", "state", "list"],
    "tf-output": ["__terraform__", "output", "-json"],
  },
  ghcr: {
    "images": ["__ghcr__", "list"],
    "tags": ["__ghcr__", "tags"],
    "delete": ["__ghcr__", "delete"],
    "auth": ["__ghcr__", "auth"],
  },
};

// Terraform directories per provider
const TF_DIRS: Record<string, string> = {
  gcloud: "b_infra/terraform/gcp",
  oci: "b_infra/terraform/oci",
  cloudflare: "b_infra/terraform/cloudflare",
  hcloud: "b_infra/terraform/hetzner",
};

async function runCloudflareApi(path: string, jqFilter?: string): Promise<string> {
  const token = process.env.CF_API_TOKEN ?? process.env.CLOUDFLARE_API_TOKEN ?? "";
  if (!token) return "CF_API_TOKEN not set. Export it or add to .secrets.";

  // Expand env vars in path
  const expandedPath = path
    .replace("${CF_ZONE_ID}", process.env.CF_ZONE_ID ?? "")
    .replace("${CF_ACCOUNT_ID}", process.env.CF_ACCOUNT_ID ?? "");

  const url = `https://api.cloudflare.com/client/v4${expandedPath}`;
  const curlArgs = ["-sf", "--max-time", "10", "-H", `Authorization: Bearer ${token}`, "-H", "Content-Type: application/json", url];

  const r = await execAsync("curl", curlArgs, { timeout: 15_000 });
  if (!r.ok) return `API call failed: ${r.stderr.trim()}`;

  if (jqFilter) {
    const jq = await execAsync("bash", ["-c", `echo '${r.stdout.replace(/'/g, "'\\''")}' | jq '.${jqFilter}'`], { timeout: 5_000 });
    return jq.ok ? jq.stdout.trim() : r.stdout.trim();
  }

  // Pretty-print JSON
  const jq = await execAsync("bash", ["-c", `echo '${r.stdout.replace(/'/g, "'\\''")}' | jq '.'`], { timeout: 5_000 });
  return jq.ok ? jq.stdout.trim() : r.stdout.trim();
}

// ──────────────────────────────────────────────────────────────────────────────
// GENERIC HANDLER
// ──────────────────────────────────────────────────────────────────────────────

// Correct shell-like tokenizer for raw CLI arg strings (obs.debug.vps_* "raw
// args" path — presets never go through this). The previous implementation
// (`command.match(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g)` then a blanket
// `.replace(/^["']|["']$/g, "")` on each captured token) strips quote
// characters ONLY from the very start/end of a token, not wherever they
// actually open/close — so `--format="value(quotas.filter('X').limit)"`
// (a real gcloud filter expression: outer double-quotes around a format
// string, an inner single-quoted filter() argument) has its OPENING `"`
// preserved (it sits after `--format=`, not at token-start) while its
// CLOSING `"` gets stripped (it IS the token's last char) — the result is a
// dangling open quote, which gcloud rejects with "Unterminated [\"] quote".
// Since this proxy execs argv directly (no shell in between — see runCli /
// execAsync), no shell ever gets a chance to consume the outer quotes either,
// so they must be stripped HERE, correctly, character by character, exactly
// like a POSIX shell's word-splitting: unquoted whitespace splits tokens,
// a quote character (' or ") starts a literal run that ends at its own kind
// of matching quote (contents, including the OTHER quote character, kept
// verbatim), and quote markers are removed from the token but nothing inside
// them is otherwise touched. No backslash-escape handling — gcloud filter/
// format expressions never need it, and it is out of scope for this proxy.
function tokenizeShellLike(command: string): string[] {
  const tokens: string[] = [];
  let cur = "";
  let inToken = false;
  let quote: '"' | "'" | null = null;
  for (let i = 0; i < command.length; i++) {
    const ch = command[i];
    if (quote) {
      if (ch === quote) {
        quote = null;
      } else {
        cur += ch;
      }
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      inToken = true;
      continue;
    }
    if (/\s/.test(ch)) {
      if (inToken) {
        tokens.push(cur);
        cur = "";
        inToken = false;
      }
      continue;
    }
    cur += ch;
    inToken = true;
  }
  if (inToken) tokens.push(cur);
  return tokens.length > 0 ? tokens : [command];
}

// gcloud "gpu-quota" preset — a per-region NVIDIA_*_GPUS quota table
// (limit vs current usage), across every region the project has access to.
// `gcloud compute regions list` already returns each region's FULL quotas
// array (compute regions describe does too, one region at a time — list is
// one call for all of them), just hidden behind --format=table by the other
// presets here; this pulls --format=json and reduces it server-side instead
// of leaving the caller to hand-write a `--format=value(quotas.filter(...))`
// expression through the raw-args path (exactly the expression that exposed
// the tokenizer bug above, 2026-09-03, hunting GPU zonal stockouts across
// regions for the cgc GPU-embed VM). GPU-only + zero-limit regions dropped —
// a wall of 40 regions with limit 0 buries the ones that matter.
async function gpuQuotaReport(): Promise<string> {
  const r = await execAsync("gcloud", ["compute", "regions", "list", "--format=json"], { timeout: 30_000 });
  if (!r.ok) return `EXIT ${r.exitCode}\n${r.stderr.trim()}`;
  let regions: Array<{ name: string; quotas?: Array<{ metric: string; limit: number; usage: number }> }>;
  try {
    regions = JSON.parse(r.stdout);
  } catch {
    return `Failed to parse gcloud JSON output:\n${r.stdout.slice(0, 500)}`;
  }
  const rows: string[] = [];
  for (const region of regions) {
    const gpuQuotas = (region.quotas ?? []).filter(
      (q) => /^(PREEMPTIBLE_)?NVIDIA_/.test(q.metric) && !q.metric.includes("_VWS_") && q.limit > 0
    );
    if (gpuQuotas.length === 0) continue;
    for (const q of gpuQuotas) {
      rows.push(`${region.name.padEnd(16)} ${q.metric.padEnd(28)} limit=${q.limit} usage=${q.usage}`);
    }
  }
  if (rows.length === 0) return "No region reports a nonzero NVIDIA_*_GPUS quota.";
  return `GPU quota by region (limit > 0 only; PREEMPTIBLE_CPUS may still be 0 project-wide — check separately):\n${"─".repeat(70)}\n${rows.join("\n")}`;
}

async function handleVpsCommand(provider: string, command: string): Promise<string> {
  const presets = PRESETS[provider];
  const sections: string[] = [];

  // If no command, list available presets
  if (!command || command === "help") {
    sections.push(`${provider.toUpperCase()} — Available commands:`);
    sections.push("═".repeat(50));
    if (presets) {
      for (const [name, args] of Object.entries(presets)) {
        const preview = args[0] === "__cf_api__" ? `API: ${args[1]}` : args.join(" ").slice(0, 60);
        sections.push(`  ${name.padEnd(15)} ${preview}`);
      }
    }
    sections.push(`\n  Or pass raw args: any ${provider} CLI arguments`);
    return sections.join("\n");
  }

  // Check for preset
  if (presets?.[command]) {
    const args = presets[command];

    // Cloudflare API special handling
    if (args[0] === "__cf_api__") {
      return runCloudflareApi(args[1], args[2]);
    }

    // Terraform special handling
    if (args[0] === "__terraform__") {
      return runTerraform(provider, args.slice(1));
    }

    // GHCR special handling
    if (args[0] === "__ghcr__") {
      return runGhcr(args[1], command);
    }

    // GPU quota report (gcloud only)
    if (args[0] === "__gpu_quota__") {
      return gpuQuotaReport();
    }

    // Expand env vars in args
    const expandedArgs = args.map((a) =>
      a.replace(/\$\{(\w+)\}/g, (_, v) => process.env[v] ?? "")
    );

    sections.push(`${provider.toUpperCase()} → ${command}`);
    sections.push("─".repeat(50));
    sections.push(await runCli(provider === "cloudflare" ? "curl" : provider, expandedArgs));
    return sections.join("\n");
  }

  // Raw command — split by spaces (respecting quotes)
  const cleanArgs = tokenizeShellLike(command);

  sections.push(`${provider.toUpperCase()} → ${command}`);
  sections.push("─".repeat(50));

  if (provider === "cloudflare") {
    // For raw cloudflare, treat as API path
    sections.push(await runCloudflareApi(cleanArgs[0], cleanArgs[1]));
  } else {
    sections.push(await runCli(provider, cleanArgs));
  }

  return sections.join("\n");
}

// ──────────────────────────────────────────────────────────────────────────────
// TERRAFORM HANDLER
// ──────────────────────────────────────────────────────────────────────────────

async function runTerraform(provider: string, tfArgs: string[]): Promise<string> {
  const tfDir = TF_DIRS[provider];
  if (!tfDir) return `No terraform directory configured for ${provider}`;

  const GIT_BASE = process.env.GIT_BASE ?? require("os").homedir() + "/git";
  const fullPath = `${GIT_BASE}/cloud/${tfDir}`;

  const sections: string[] = [];
  sections.push(`TERRAFORM → ${provider.toUpperCase()} (${tfDir})`);
  sections.push("─".repeat(50));

  // Init if needed
  const initCheck = await execAsync("bash", ["-c", `test -d ${fullPath}/.terraform`], { timeout: 3_000 });
  if (!initCheck.ok) {
    sections.push("Running terraform init...");
    const init = await execAsync("terraform", ["-chdir=" + fullPath, "init", "-no-color"], { timeout: 60_000 });
    if (!init.ok) {
      sections.push(`Init failed: ${init.stderr.trim()}`);
      return sections.join("\n");
    }
  }

  const r = await execAsync("terraform", ["-chdir=" + fullPath, ...tfArgs, "-no-color"], { timeout: 120_000 });
  sections.push(r.stdout.trim());
  if (!r.ok && r.stderr.trim()) sections.push(`\nSTDERR: ${r.stderr.trim()}`);

  // For drift detection, exit code 2 = changes detected
  if (tfArgs[0] === "plan" && tfArgs.includes("-detailed-exitcode") && r.exitCode === 2) {
    sections.push("\n⚠️ DRIFT DETECTED — terraform plan shows pending changes");
  }

  return sections.join("\n");
}

// ──────────────────────────────────────────────────────────────────────────────
// GHCR HANDLER
// ──────────────────────────────────────────────────────────────────────────────

async function runGhcr(action: string, _command: string): Promise<string> {
  const sections: string[] = [];
  sections.push("GHCR (GitHub Container Registry)");
  sections.push("─".repeat(50));

  switch (action) {
    case "list": {
      const r = await execAsync("gh", [
        "api", "/user/packages?package_type=container&per_page=50",
        "--jq", '.[] | "\\(.name) (\\(.visibility)) updated:\\(.updated_at[:10])"',
      ], { timeout: 15_000 });
      if (!r.ok) {
        // Try org packages
        const r2 = await execAsync("gh", [
          "api", "/users/diegonmarcos/packages?package_type=container&per_page=50",
          "--jq", '.[] | "\\(.name) (\\(.visibility)) updated:\\(.updated_at[:10])"',
        ], { timeout: 15_000 });
        sections.push(r2.ok ? r2.stdout.trim() : `Error: ${r2.stderr.trim()}`);
      } else {
        sections.push(r.stdout.trim() || "No packages found");
      }
      break;
    }
    case "tags": {
      // List all packages first, then tags for each
      const pkgs = await execAsync("gh", [
        "api", "/users/diegonmarcos/packages?package_type=container&per_page=20",
        "--jq", ".[].name",
      ], { timeout: 15_000 });
      if (!pkgs.ok) { sections.push(`Error: ${pkgs.stderr.trim()}`); break; }
      for (const pkg of pkgs.stdout.trim().split("\n").filter(Boolean).slice(0, 10)) {
        const tags = await execAsync("gh", [
          "api", `/users/diegonmarcos/packages/container/${encodeURIComponent(pkg)}/versions?per_page=5`,
          "--jq", '.[] | "  \\(.metadata.container.tags | join(",")) \\(.updated_at[:10])"',
        ], { timeout: 10_000 });
        sections.push(`${pkg}:`);
        sections.push(tags.ok ? tags.stdout.trim() : "  (error fetching tags)");
      }
      break;
    }
    case "auth": {
      const r = await execAsync("gh", ["auth", "token"], { timeout: 5_000 });
      sections.push(r.ok ? "Authenticated (token available)" : "Not authenticated");
      break;
    }
    default:
      sections.push(`Unknown GHCR action: ${action}. Available: list, tags, auth`);
  }

  return sections.join("\n");
}

// ──────────────────────────────────────────────────────────────────────────────
// TOOL REGISTRATION
// ──────────────────────────────────────────────────────────────────────────────

export function registerVpsOpsTools(server: McpServer): void {
  const providers = [
    { name: "obs.debug.vps_gcloud", cli: "gcloud", desc: "Google Cloud CLI proxy — instances, disks, billing, firewall, IAM" },
    { name: "obs.debug.vps_oci", cli: "oci", desc: "Oracle Cloud CLI proxy — instances, volumes, VCN, budgets, limits" },
    { name: "obs.debug.vps_gh", cli: "gh", desc: "GitHub CLI proxy — repos, issues, PRs, runs, workflows, secrets" },
    { name: "obs.debug.vps_wrangler", cli: "wrangler", desc: "Cloudflare Wrangler CLI proxy — workers, KV, R2, pages" },
    { name: "obs.debug.vps_hetzner", cli: "hcloud", desc: "Hetzner Cloud CLI proxy — servers, volumes, firewalls, networks" },
    { name: "obs.debug.vps_cloudflare", cli: "cloudflare", desc: "Cloudflare API proxy — zones, DNS, workers, firewall, analytics, tf-*" },
    { name: "obs.debug.vps_ghcr", cli: "ghcr", desc: "GitHub Container Registry — list images, tags, auth" },
  ];

  for (const { name, cli, desc } of providers) {
    server.tool(
      name,
      desc,
      {
        command: z.string().optional().describe(
          `Preset command or raw CLI args. Presets: ${Object.keys(PRESETS[cli] ?? {}).join(", ")}. Omit for help.`
        ),
      },
      ({ command }) => safeRun(() => handleVpsCommand(cli, command ?? "help")),
    );
  }
}
