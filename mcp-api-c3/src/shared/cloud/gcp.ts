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

  return { ok: true, resources };
}

export function getCosts(): { ok: boolean; costs: CloudCost[]; error?: string } {
  // GCP billing via CLI — limited without billing export
  const result = gcloudCli(["billing", "accounts", "list"]);

  if (!result.ok) {
    return {
      ok: true,
      costs: [{
        service: "GCP Billing",
        amount: 0,
        currency: "USD",
        period: "current month (billing API unavailable)",
      }],
    };
  }

  const accounts = result.data as Array<Record<string, unknown>>;
  const costs: CloudCost[] = (accounts ?? []).map((a) => ({
    service: String(a.displayName ?? "GCP"),
    amount: 0,
    currency: "USD",
    period: `Account: ${a.name}`,
  }));

  return { ok: true, costs: costs.length ? costs : [{ service: "GCP", amount: 0, currency: "USD", period: "current month" }] };
}
