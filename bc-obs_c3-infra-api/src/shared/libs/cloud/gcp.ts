import { exec } from "../exec.js";
import type { z } from "zod";
import type { CloudInstanceSchema, CloudResourceSchema, CloudCostSchema } from "../schemas.js";

type CloudInstance = z.infer<typeof CloudInstanceSchema>;
type CloudResource = z.infer<typeof CloudResourceSchema>;
type CloudCost = z.infer<typeof CloudCostSchema>;

function gcloudCli(args: string[], timeout = 30_000): { ok: boolean; data: unknown; raw: string; error?: string } {
  const fullArgs = [...args, "--format=json"];
  const result = exec("gcloud", fullArgs, { timeout });
  if (!result.ok) {
    return { ok: false, data: null, raw: result.stderr, error: result.stderr || `exit ${result.exitCode}` };
  }
  try {
    const data = JSON.parse(result.stdout);
    return { ok: true, data, raw: result.stdout };
  } catch {
    return { ok: true, data: result.stdout, raw: result.stdout };
  }
}

// ── Instances ──

export function listInstances(): { ok: boolean; instances: CloudInstance[]; error?: string } {
  const result = gcloudCli(["compute", "instances", "list"], 60_000);

  if (!result.ok) {
    return { ok: false, instances: [], error: result.error };
  }

  const raw = result.data as Array<Record<string, unknown>>;
  const instances: CloudInstance[] = (raw ?? []).map((i) => {
    const networkInterfaces = i.networkInterfaces as Array<Record<string, unknown>> | undefined;
    const accessConfigs = networkInterfaces?.[0]?.accessConfigs as Array<Record<string, unknown>> | undefined;

    return {
      id: String(i.id ?? ""),
      name: String(i.name ?? ""),
      state: String(i.status ?? ""),
      shape: String(i.machineType ?? "").split("/").pop() ?? "",
      zone: String(i.zone ?? "").split("/").pop() ?? "",
      publicIp: String(accessConfigs?.[0]?.natIP ?? ""),
      privateIp: String(networkInterfaces?.[0]?.networkIP ?? ""),
    };
  });

  return { ok: true, instances };
}

export function getInstanceState(instanceName: string, zone: string): { ok: boolean; state: string; error?: string } {
  const result = gcloudCli([
    "compute", "instances", "describe", instanceName,
    "--zone", zone,
  ]);

  if (!result.ok) {
    return { ok: false, state: "UNKNOWN", error: result.error };
  }

  const raw = result.data as Record<string, unknown>;
  return { ok: true, state: String(raw.status ?? "UNKNOWN") };
}

export function instanceAction(
  instanceName: string,
  zone: string,
  action: "start" | "stop" | "reset",
): { ok: boolean; message: string } {
  const result = gcloudCli([
    "compute", "instances", action, instanceName,
    "--zone", zone,
  ], 60_000);

  return {
    ok: result.ok,
    message: result.ok ? `Instance ${action} initiated` : `Failed: ${result.error}`,
  };
}

// ── Resources ──

export function listResources(): { ok: boolean; resources: CloudResource[]; error?: string } {
  const resources: CloudResource[] = [];

  // Disks
  const diskResult = gcloudCli(["compute", "disks", "list"]);
  if (diskResult.ok) {
    const disks = diskResult.data as Array<Record<string, unknown>>;
    for (const d of disks ?? []) {
      resources.push({
        type: "disk",
        name: String(d.name ?? ""),
        id: String(d.id ?? ""),
        details: {
          sizeGb: d.sizeGb,
          status: d.status,
          zone: String(d.zone ?? "").split("/").pop(),
          type: String(d.type ?? "").split("/").pop(),
        },
      });
    }
  }

  // Networks
  const netResult = gcloudCli(["compute", "networks", "list"]);
  if (netResult.ok) {
    const nets = netResult.data as Array<Record<string, unknown>>;
    for (const n of nets ?? []) {
      resources.push({
        type: "network",
        name: String(n.name ?? ""),
        id: String(n.id ?? ""),
        details: { mode: n.x_gcloud_subnet_mode ?? n.autoCreateSubnetworks },
      });
    }
  }

  // Firewalls
  const fwResult = gcloudCli(["compute", "firewall-rules", "list"]);
  if (fwResult.ok) {
    const rules = fwResult.data as Array<Record<string, unknown>>;
    for (const r of rules ?? []) {
      resources.push({
        type: "firewall",
        name: String(r.name ?? ""),
        id: String(r.id ?? ""),
        details: {
          direction: r.direction,
          allowed: r.allowed,
          sourceRanges: r.sourceRanges,
          targetTags: r.targetTags,
        },
      });
    }
  }

  // Static external IPs
  const ipResult = gcloudCli(["compute", "addresses", "list"]);
  if (ipResult.ok) {
    const addresses = ipResult.data as Array<Record<string, unknown>>;
    for (const a of addresses ?? []) {
      resources.push({
        type: "external-ip",
        name: String(a.name ?? ""),
        id: String(a.id ?? ""),
        details: {
          address: a.address,
          status: a.status,
          region: String(a.region ?? "").split("/").pop(),
          addressType: a.addressType,
        },
      });
    }
  }

  return { ok: true, resources };
}

// ── Costs ──

// GCP free-tier eligible machine types (1 e2-micro per account in US regions)
const FREE_TIER_MACHINES = new Set(["e2-micro"]);
const US_REGION_PREFIXES = ["us-central1", "us-west1", "us-east1", "us-east4"];

// Approximate on-demand hourly rates (USD, us-central1) for cost estimation
const MACHINE_RATES: Record<string, number> = {
  "e2-micro": 0.0084, "e2-small": 0.0168, "e2-medium": 0.0336,
  "e2-standard-2": 0.0672, "e2-standard-4": 0.1344, "e2-standard-8": 0.2688,
  "n1-standard-1": 0.0475, "n1-standard-2": 0.0950, "n1-standard-4": 0.1900,
  "n1-standard-8": 0.3800, "n1-standard-16": 0.7600,
  "n2-standard-2": 0.0971, "n2-standard-4": 0.1942, "n2-standard-8": 0.3884,
};

// Approximate GPU hourly rates (USD, on-demand)
const GPU_RATES: Record<string, number> = {
  "nvidia-tesla-t4": 0.35,
  "nvidia-tesla-v100": 2.48,
  "nvidia-tesla-a100": 2.93,
  "nvidia-tesla-p4": 0.60,
  "nvidia-tesla-p100": 1.46,
  "nvidia-l4": 0.41,
};

function monthLabel(d: Date): string {
  return `${d.toLocaleString("en-US", { month: "long" })} ${d.getFullYear()}`;
}

export function getCosts(): { ok: boolean; costs: CloudCost[]; error?: string } {
  const costs: CloudCost[] = [];
  const now = new Date();
  const period = monthLabel(now);

  // Get billing account info
  const billingResult = gcloudCli(["billing", "accounts", "list"]);
  const accounts = billingResult.ok ? billingResult.data as Array<Record<string, unknown>> : [];
  const billingAccount = accounts?.[0];
  const currency = String(billingAccount?.currencyCode ?? "USD");
  const billingName = String(billingAccount?.displayName ?? "Unknown");

  // Get detailed instance info for cost classification
  const instanceResult = gcloudCli(["compute", "instances", "list"], 60_000);

  if (!instanceResult.ok) {
    return {
      ok: false,
      costs: [],
      error: `Failed to list GCP instances: ${instanceResult.error}`,
    };
  }

  const instances = instanceResult.data as Array<Record<string, unknown>>;
  let totalEstimate = 0;
  let hasFreeTierMicro = false;

  for (const inst of instances ?? []) {
    const name = String(inst.name ?? "");
    const machineType = String(inst.machineType ?? "").split("/").pop() ?? "";
    const zone = String(inst.zone ?? "").split("/").pop() ?? "";
    const status = String(inst.status ?? "");
    const scheduling = inst.scheduling as Record<string, unknown> | undefined;
    const isSpot = scheduling?.provisioningModel === "SPOT" || scheduling?.preemptible === true;
    const gpus = inst.guestAccelerators as Array<Record<string, unknown>> | undefined;
    const hasGpu = gpus && gpus.length > 0;

    // Free-tier check: 1 e2-micro in US regions
    const isUsRegion = US_REGION_PREFIXES.some((p) => zone.startsWith(p));
    const isFreeTier = FREE_TIER_MACHINES.has(machineType) && isUsRegion && !hasFreeTierMicro;
    if (isFreeTier) hasFreeTierMicro = true;

    if (isFreeTier) {
      costs.push({
        service: `${name} (${machineType}, ${zone})`,
        amount: 0,
        currency,
        period: `${period} — Free Tier`,
      });
      continue;
    }

    // Estimate cost for paid instances
    let estimate = 0;
    const hoursInMonth = (now.getTime() - new Date(now.getFullYear(), now.getMonth(), 1).getTime()) / 3_600_000;

    if (status === "RUNNING") {
      // Machine cost
      const baseRate = MACHINE_RATES[machineType] ?? 0.10;
      const spotFactor = isSpot ? 0.35 : 1.0;
      estimate += baseRate * spotFactor * hoursInMonth;

      // GPU cost
      if (hasGpu) {
        for (const gpu of gpus!) {
          const count = Number(gpu.guestAcceleratorCount ?? gpu.acceleratorCount ?? 1);
          const gpuType = String(gpu.acceleratorType ?? "").split("/").pop() ?? "";
          const gpuRate = GPU_RATES[gpuType] ?? 0.50;
          estimate += count * gpuRate * (isSpot ? 0.35 : 1.0) * hoursInMonth;
        }
      }
    }

    totalEstimate += estimate;
    const tier = isSpot ? "Spot" : "On-Demand";
    const gpuLabel = hasGpu
      ? ` + ${gpus!.map((g) => String(g.acceleratorType ?? "").split("/").pop()).join(",")}`
      : "";

    costs.push({
      service: `${name} (${machineType}${gpuLabel}, ${zone}, ${tier})`,
      amount: Math.round(estimate * 100) / 100,
      currency,
      period: status === "RUNNING"
        ? `${period} — estimated from running hours`
        : `${period} — ${status} (no charge while stopped)`,
    });
  }

  // Disk costs
  const diskResult = gcloudCli(["compute", "disks", "list"]);
  if (diskResult.ok) {
    const disks = diskResult.data as Array<Record<string, unknown>>;
    let totalDiskGb = 0;
    let diskCost = 0;
    const diskDetails: string[] = [];
    for (const d of disks ?? []) {
      const sizeGb = Number(d.sizeGb ?? 0);
      const diskType = String(d.type ?? "").split("/").pop() ?? "";
      const diskName = String(d.name ?? "");
      // pd-standard: ~$0.04/GB/mo, pd-ssd: ~$0.17/GB/mo, pd-balanced: ~$0.10/GB/mo
      const rate = diskType.includes("ssd") ? 0.17 : diskType.includes("balanced") ? 0.10 : 0.04;
      totalDiskGb += sizeGb;
      diskCost += sizeGb * rate;
      diskDetails.push(`${diskName}: ${sizeGb}GB ${diskType}`);
    }
    // Free tier: 30GB standard persistent disk
    const freeTierSavings = Math.min(30 * 0.04, diskCost);
    diskCost -= freeTierSavings;
    diskCost = Math.max(0, diskCost);
    totalEstimate += diskCost;

    costs.push({
      service: `Persistent Disks (${totalDiskGb}GB total, 30GB free tier)`,
      amount: Math.round(diskCost * 100) / 100,
      currency,
      period: `${period} — ${diskDetails.join("; ")}`,
    });
  }

  // Static external IPs (charged when NOT attached to a running VM)
  const ipResult = gcloudCli(["compute", "addresses", "list"]);
  if (ipResult.ok) {
    const addresses = ipResult.data as Array<Record<string, unknown>>;
    let unusedIpCount = 0;
    for (const a of addresses ?? []) {
      if (a.status === "RESERVED") unusedIpCount++;
    }
    if (unusedIpCount > 0) {
      const ipCost = unusedIpCount * 0.01 * 730; // ~$0.01/hr per unused IP
      totalEstimate += ipCost;
      costs.push({
        service: `Unused static IPs (${unusedIpCount})`,
        amount: Math.round(ipCost * 100) / 100,
        currency,
        period: `${period} — ~$0.01/hr per unattached IP`,
      });
    }
  }

  // Total
  costs.push({
    service: "GCP TOTAL ESTIMATED",
    amount: Math.round(totalEstimate * 100) / 100,
    currency,
    period: `${period} — Billing account: ${billingName} (estimates based on public pricing, actual invoice may differ)`,
  });

  return { ok: true, costs };
}
