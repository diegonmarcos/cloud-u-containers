// ── VPS Ops — Cloud provider CLI proxies (6 tools) ──
// Wraps gcloud, oci, wrangler, gh, hcloud, cloudflare API

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { execAsync } from "../../shared/exec.js";

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
  },
  oci: {
    "instances": ["compute", "instance", "list", "--compartment-id", "${OCI_COMPARTMENT_ID}", "--output", "table", "--query", "data[*].{Name:\"display-name\",State:\"lifecycle-state\",Shape:shape,AD:\"availability-domain\"}"],
    "volumes": ["bv", "volume", "list", "--compartment-id", "${OCI_COMPARTMENT_ID}", "--output", "table"],
    "vcn": ["network", "vcn", "list", "--compartment-id", "${OCI_COMPARTMENT_ID}", "--output", "table"],
    "budget": ["budgets", "budget", "list", "--compartment-id", "${OCI_TENANCY_ID}", "--output", "table"],
    "limits": ["limits", "service", "list", "--compartment-id", "${OCI_COMPARTMENT_ID}", "--output", "table"],
    "auth": ["iam", "region", "list", "--output", "table"],
  },
  gh: {
    "repos": ["repo", "list", "diegonmarcos", "--json", "name,visibility,updatedAt", "--jq", '.[] | "\\(.name) (\\(.visibility)) \\(.updatedAt[:10])"'],
    "issues": ["issue", "list", "--repo", "diegonmarcos/cloud", "--state", "open", "--json", "number,title,updatedAt"],
    "prs": ["pr", "list", "--repo", "diegonmarcos/cloud", "--state", "open", "--json", "number,title,headRefName"],
    "runs": ["run", "list", "--repo", "diegonmarcos/cloud", "--limit", "10", "--json", "name,status,conclusion,updatedAt"],
    "workflows": ["workflow", "list", "--repo", "diegonmarcos/cloud", "--json", "name,id,state"],
    "releases": ["release", "list", "--repo", "diegonmarcos/cloud", "--limit", "5"],
    "secrets": ["secret", "list", "--repo", "diegonmarcos/cloud"],
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
  },
  cloudflare: {
    // Cloudflare uses API, not CLI — we wrap curl calls
    "zones": ["__cf_api__", "/zones?per_page=50", "result[].{name,status,plan.name}"],
    "dns": ["__cf_api__", "/zones/${CF_ZONE_ID}/dns_records?per_page=100", "result[].{type,name,content,proxied}"],
    "workers": ["__cf_api__", "/accounts/${CF_ACCOUNT_ID}/workers/scripts", "result[].{id,modified_on}"],
    "firewall": ["__cf_api__", "/zones/${CF_ZONE_ID}/firewall/rules", "result[].{description,action,filter.expression}"],
    "analytics": ["__cf_api__", "/zones/${CF_ZONE_ID}/analytics/dashboard?since=-1440", "result.totals"],
    "auth": ["__cf_api__", "/user/tokens/verify", "result.status"],
  },
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
  const rawArgs = command.match(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g) ?? [command];
  const cleanArgs = rawArgs.map((a) => a.replace(/^["']|["']$/g, ""));

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
// TOOL REGISTRATION
// ──────────────────────────────────────────────────────────────────────────────

export function registerVpsOpsTools(server: McpServer): void {
  const providers = [
    { name: "vps_gcloud", cli: "gcloud", desc: "Google Cloud CLI proxy — instances, disks, billing, firewall, IAM" },
    { name: "vps_oci", cli: "oci", desc: "Oracle Cloud CLI proxy — instances, volumes, VCN, budgets, limits" },
    { name: "vps_gh", cli: "gh", desc: "GitHub CLI proxy — repos, issues, PRs, runs, workflows, secrets" },
    { name: "vps_wrangler", cli: "wrangler", desc: "Cloudflare Wrangler CLI proxy — workers, KV, R2, pages" },
    { name: "vps_hetzner", cli: "hcloud", desc: "Hetzner Cloud CLI proxy — servers, volumes, firewalls, networks" },
    { name: "vps_cloudflare", cli: "cloudflare", desc: "Cloudflare API proxy — zones, DNS, workers, firewall, analytics" },
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
