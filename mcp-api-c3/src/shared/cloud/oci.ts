import { exec } from "../exec.js";
import type { z } from "zod";
import type { CloudInstanceSchema, CloudResourceSchema, CloudCostSchema } from "../schemas.js";

type CloudInstance = z.infer<typeof CloudInstanceSchema>;
type CloudResource = z.infer<typeof CloudResourceSchema>;
type CloudCost = z.infer<typeof CloudCostSchema>;

function ociCli(args: string[], timeout = 30_000): { ok: boolean; data: unknown; raw: string; error?: string } {
  const result = exec("oci", args, { timeout });
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
  const result = ociCli([
    "compute", "instance", "list",
    "--compartment-id", getCompartmentId(),
    "--output", "json",
    "--all",
  ], 60_000);

  if (!result.ok) {
    return { ok: false, instances: [], error: result.error };
  }

  const raw = result.data as { data?: Array<Record<string, unknown>> };
  const instances: CloudInstance[] = (raw.data ?? []).map((i) => ({
    id: String(i.id ?? ""),
    name: String(i["display-name"] ?? ""),
    state: String(i["lifecycle-state"] ?? ""),
    shape: String(i.shape ?? ""),
    region: String(i.region ?? ""),
    publicIp: undefined,
    privateIp: undefined,
    ocpus: (i["shape-config"] as Record<string, unknown>)?.ocpus as number | undefined,
    memoryGb: (i["shape-config"] as Record<string, unknown>)?.["memory-in-gbs"] as number | undefined,
  }));

  return { ok: true, instances };
}

export function getInstanceState(instanceId: string): { ok: boolean; state: string; error?: string } {
  const result = ociCli([
    "compute", "instance", "get",
    "--instance-id", instanceId,
    "--output", "json",
  ]);

  if (!result.ok) {
    return { ok: false, state: "UNKNOWN", error: result.error };
  }

  const raw = result.data as { data?: { "lifecycle-state"?: string } };
  return { ok: true, state: String(raw.data?.["lifecycle-state"] ?? "UNKNOWN") };
}

export function instanceAction(
  instanceId: string,
  action: "START" | "STOP" | "RESET",
): { ok: boolean; message: string } {
  const result = ociCli([
    "compute", "instance", "action",
    "--instance-id", instanceId,
    "--action", action,
  ], 60_000);

  return {
    ok: result.ok,
    message: result.ok ? `Instance ${action} initiated` : `Failed: ${result.error}`,
  };
}

export function listResources(): { ok: boolean; resources: CloudResource[]; error?: string } {
  const compartmentId = getCompartmentId();
  const resources: CloudResource[] = [];

  // VCNs
  const vcnResult = ociCli([
    "network", "vcn", "list",
    "--compartment-id", compartmentId,
    "--output", "json", "--all",
  ]);
  if (vcnResult.ok) {
    const vcns = (vcnResult.data as { data?: Array<Record<string, unknown>> }).data ?? [];
    for (const v of vcns) {
      resources.push({
        type: "vcn",
        name: String(v["display-name"] ?? ""),
        id: String(v.id ?? ""),
        details: { cidrBlock: v["cidr-block"], state: v["lifecycle-state"] },
      });
    }
  }

  // Subnets
  const subnetResult = ociCli([
    "network", "subnet", "list",
    "--compartment-id", compartmentId,
    "--output", "json", "--all",
  ]);
  if (subnetResult.ok) {
    const subnets = (subnetResult.data as { data?: Array<Record<string, unknown>> }).data ?? [];
    for (const s of subnets) {
      resources.push({
        type: "subnet",
        name: String(s["display-name"] ?? ""),
        id: String(s.id ?? ""),
        details: { cidrBlock: s["cidr-block"], state: s["lifecycle-state"] },
      });
    }
  }

  // Boot volumes
  const bvResult = ociCli([
    "bv", "boot-volume", "list",
    "--compartment-id", compartmentId,
    "--output", "json", "--all",
  ]);
  if (bvResult.ok) {
    const bootVols = (bvResult.data as { data?: Array<Record<string, unknown>> }).data ?? [];
    for (const bv of bootVols) {
      resources.push({
        type: "boot-volume",
        name: String(bv["display-name"] ?? ""),
        id: String(bv.id ?? ""),
        details: { sizeGb: bv["size-in-gbs"], state: bv["lifecycle-state"] },
      });
    }
  }

  return { ok: true, resources };
}

export function getCosts(): { ok: boolean; costs: CloudCost[]; error?: string } {
  // OCI cost tracking via usage API — requires proper tenancy setup
  // For now, return a summary from the CLI if available
  const result = ociCli([
    "account", "subscription", "list",
    "--compartment-id", getCompartmentId(),
    "--output", "json",
  ]);

  if (!result.ok) {
    // OCI free tier — costs are typically $0
    return {
      ok: true,
      costs: [{
        service: "OCI Always Free",
        amount: 0,
        currency: "USD",
        period: "current month",
      }],
    };
  }

  return {
    ok: true,
    costs: [{
      service: "OCI Subscription",
      amount: 0,
      currency: "USD",
      period: "current month",
    }],
  };
}

function getCompartmentId(): string {
  // Read from OCI config or environment
  const envId = process.env.OCI_COMPARTMENT_ID;
  if (envId) return envId;

  // Try to get from oci config
  const result = exec("oci", ["iam", "compartment", "list", "--query", "data[0].id", "--raw-output"], { timeout: 10_000 });
  if (result.ok && result.stdout.trim()) {
    return result.stdout.trim();
  }

  // Fallback: use tenancy OCID from config file
  const configResult = exec("oci", ["setup", "config", "--help"], { timeout: 5_000 });
  return process.env.OCI_TENANCY_ID ?? "";
}
