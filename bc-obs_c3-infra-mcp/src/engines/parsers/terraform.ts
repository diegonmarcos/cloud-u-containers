// terraform.ts — Extract VM specs + storage from b_infra/vps_*/src/main.tf
//
// Parses HCL resource blocks via regex (not a full HCL parser).
// Extracts: instance shapes/CPU/RAM/disk, object storage buckets, GPU info.

import { readFileSync, readdirSync, existsSync } from "fs";
import { join } from "path";

// --- Types ---

export interface VMSpecs {
  cpu: number;
  ram_gb: number;
  disk_gb: number;
  arch?: string;          // cpu architecture (e.g. "x86_64", "aarch64")
  shape?: string;
  machine_type?: string;
  gpu?: string;
  gpu_vram?: string;
  cloud_name?: string;    // actual instance name in cloud provider (e.g. "arch-1")
  cloud_zone?: string;    // zone/region
  cost?: string;          // cost tier (e.g. "Free", "Spot")
  instance_id?: string;   // cloud provider instance ID (OCI OCID or GCP resource path)
}

export interface StorageBucket {
  provider: string;
  name: string;
  tier: string;
}

export interface VPSProvider {
  name: string;          // "oci", "gcloud", "aws", etc.
  folder: string;        // "vps_oci"
  has_terraform: boolean;
  services: string[];    // what the provider manages (e.g. "SES email")
}

export interface FirewallRule {
  port: number | string;   // e.g. 22, "51820", "80-443"
  protocol: string;        // "tcp" | "udp" | "all"
  source: string;          // "0.0.0.0/0" or specific CIDR
  description?: string;
  target_tags?: string[];  // GCP only
}

export interface FirewallData {
  provider: string;        // "oci" | "gcloud"
  scope: string;           // "vps" (shared) or VM-specific
  rules: FirewallRule[];
}

export interface TerraformData {
  vm_specs: Record<string, VMSpecs>;   // keyed by display_name / instance name
  storage: StorageBucket[];
  providers: VPSProvider[];
  firewalls: FirewallData[];
}

// --- Helpers ---

/** Extract all top-level resource blocks of a given type from HCL text */
function extractBlocks(hcl: string, resourceType: string): { name: string; body: string }[] {
  const results: { name: string; body: string }[] = [];
  const pattern = new RegExp(
    `resource\\s+"${resourceType.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"\\s+"(\\w+)"\\s*\\{`,
    "g"
  );

  let match: RegExpExecArray | null;
  while ((match = pattern.exec(hcl)) !== null) {
    const name = match[1];
    const startIdx = match.index + match[0].length;

    // Find matching closing brace (track nesting)
    let depth = 1;
    let i = startIdx;
    while (i < hcl.length && depth > 0) {
      if (hcl[i] === "{") depth++;
      else if (hcl[i] === "}") depth--;
      i++;
    }

    results.push({ name, body: hcl.slice(startIdx, i - 1) });
  }
  return results;
}

/** Extract a simple key = value or key = "value" from an HCL block body */
function extractField(body: string, key: string): string | null {
  // Match: key = "value" or key = value or key = number
  const re = new RegExp(`^\\s*${key}\\s*=\\s*"?([^"\\n]+)"?`, "m");
  const m = body.match(re);
  return m ? m[1].trim().replace(/"/g, "") : null;
}

/** Extract a numeric field */
function extractNum(body: string, key: string): number {
  const v = extractField(body, key);
  return v ? parseFloat(v) : 0;
}

/** Extract a nested block's body */
function extractNestedBlock(body: string, blockName: string): string | null {
  const re = new RegExp(`${blockName}\\s*\\{`, "g");
  const m = re.exec(body);
  if (!m) return null;

  const startIdx = m.index + m[0].length;
  let depth = 1;
  let i = startIdx;
  while (i < body.length && depth > 0) {
    if (body[i] === "{") depth++;
    else if (body[i] === "}") depth--;
    i++;
  }
  return body.slice(startIdx, i - 1);
}

// --- OCI Parser ---

function parseOCIFirewalls(hcl: string): FirewallData[] {
  const firewalls: FirewallData[] = [];

  for (const block of extractBlocks(hcl, "oci_core_default_security_list")) {
    const rules: FirewallRule[] = [];

    // Extract all ingress_security_rules blocks
    const ingressRe = /ingress_security_rules\s*\{/g;
    let m: RegExpExecArray | null;
    while ((m = ingressRe.exec(block.body)) !== null) {
      const startIdx = m.index + m[0].length;
      let depth = 1;
      let i = startIdx;
      while (i < block.body.length && depth > 0) {
        if (block.body[i] === "{") depth++;
        else if (block.body[i] === "}") depth--;
        i++;
      }
      const ruleBody = block.body.slice(startIdx, i - 1);

      const source = extractField(ruleBody, "source") || "0.0.0.0/0";
      const protocolNum = extractField(ruleBody, "protocol") || "all";
      const description = extractField(ruleBody, "description") || undefined;

      // Map OCI protocol numbers to names
      const protoMap: Record<string, string> = { "6": "tcp", "17": "udp", "1": "icmp" };
      const protocol = protoMap[protocolNum] || protocolNum;

      // Extract port from tcp_options or udp_options
      let port: number | string = "all";
      const tcpOpts = extractNestedBlock(ruleBody, "tcp_options");
      const udpOpts = extractNestedBlock(ruleBody, "udp_options");
      const opts = tcpOpts || udpOpts;
      if (opts) {
        const min = extractNum(opts, "min");
        const max = extractNum(opts, "max");
        port = min === max ? min : `${min}-${max}`;
      }

      rules.push({ port, protocol, source, ...(description ? { description } : {}) });
    }

    if (rules.length > 0) {
      firewalls.push({ provider: "oci", scope: "vps", rules });
    }
  }

  return firewalls;
}

function parseOCI(hcl: string): { specs: Record<string, VMSpecs>; storage: StorageBucket[] } {
  const specs: Record<string, VMSpecs> = {};
  const storage: StorageBucket[] = [];

  // Instances
  for (const block of extractBlocks(hcl, "oci_core_instance")) {
    const displayName = extractField(block.body, "display_name");
    if (!displayName) continue;

    const shape = extractField(block.body, "shape") || "";

    // Boot volume size from source_details
    const sourceBlock = extractNestedBlock(block.body, "source_details");
    const diskGb = sourceBlock ? extractNum(sourceBlock, "boot_volume_size_in_gbs") : 0;

    // For flex shapes, get shape_config
    const shapeBlock = extractNestedBlock(block.body, "shape_config");
    let cpu = 0;
    let ramGb = 0;

    if (shapeBlock) {
      cpu = extractNum(shapeBlock, "ocpus");
      ramGb = extractNum(shapeBlock, "memory_in_gbs");
    } else {
      // Fixed shapes — derive from shape name
      if (shape.includes("E2.1.Micro")) {
        cpu = 1;
        ramGb = 1;
      } else if (shape.includes("E4.Flex") || shape.includes("E5.Flex")) {
        cpu = 1;
        ramGb = 16;
      }
    }

    specs[displayName] = { cpu, ram_gb: ramGb, disk_gb: diskGb, shape };
  }

  // Object Storage buckets
  for (const block of extractBlocks(hcl, "oci_objectstorage_bucket")) {
    const name = extractField(block.body, "name");
    const tier = extractField(block.body, "storage_tier") || "Standard";
    if (name) {
      storage.push({ provider: "oci", name, tier });
    }
  }

  return { specs, storage };
}

// --- GCP Parser ---

// Known GCP machine type specs
const GCP_SPECS: Record<string, { cpu: number; ram_gb: number }> = {
  "e2-micro":       { cpu: 2, ram_gb: 1 },
  "e2-small":       { cpu: 2, ram_gb: 2 },
  "e2-medium":      { cpu: 2, ram_gb: 4 },
  "n1-standard-1":  { cpu: 1, ram_gb: 3.75 },
  "n1-standard-2":  { cpu: 2, ram_gb: 7.5 },
  "n1-standard-4":  { cpu: 4, ram_gb: 15 },
  "n1-standard-8":  { cpu: 8, ram_gb: 30 },
  "n2-standard-2":  { cpu: 2, ram_gb: 8 },
  "n2-standard-4":  { cpu: 4, ram_gb: 16 },
};

function parseGCPFirewalls(hcl: string): FirewallData[] {
  const firewalls: FirewallData[] = [];
  const vpsRules: FirewallRule[] = [];
  const taggedRules: Map<string, FirewallRule[]> = new Map();

  for (const block of extractBlocks(hcl, "google_compute_firewall")) {
    const description = extractField(block.body, "name") || block.name;

    // Extract source_ranges
    const srcMatch = block.body.match(/source_ranges\s*=\s*\[([^\]]*)\]/);
    const source = srcMatch
      ? srcMatch[1].replace(/"/g, "").trim().split(/\s*,\s*/)[0]
      : "0.0.0.0/0";

    // Extract target_tags
    const tagMatch = block.body.match(/target_tags\s*=\s*\[([^\]]*)\]/);
    const targetTags = tagMatch
      ? tagMatch[1].replace(/"/g, "").trim().split(/\s*,\s*/).filter(Boolean)
      : [];

    // Extract allow blocks (may have multiple)
    const allowRe = /allow\s*\{/g;
    let m: RegExpExecArray | null;
    while ((m = allowRe.exec(block.body)) !== null) {
      const startIdx = m.index + m[0].length;
      let depth = 1;
      let i = startIdx;
      while (i < block.body.length && depth > 0) {
        if (block.body[i] === "{") depth++;
        else if (block.body[i] === "}") depth--;
        i++;
      }
      const allowBody = block.body.slice(startIdx, i - 1);

      const protocol = extractField(allowBody, "protocol") || "all";
      const portsMatch = allowBody.match(/ports\s*=\s*\[([^\]]*)\]/);
      const ports = portsMatch
        ? portsMatch[1].replace(/"/g, "").trim().split(/\s*,\s*/).filter(Boolean)
        : ["all"];

      for (const p of ports) {
        const rule: FirewallRule = {
          port: /^\d+$/.test(p) ? parseInt(p) : p,
          protocol,
          source,
          description,
          ...(targetTags.length > 0 ? { target_tags: targetTags } : {}),
        };

        if (targetTags.length > 0) {
          for (const tag of targetTags) {
            if (!taggedRules.has(tag)) taggedRules.set(tag, []);
            taggedRules.get(tag)!.push(rule);
          }
        } else {
          vpsRules.push(rule);
        }
      }
    }
  }

  if (vpsRules.length > 0) {
    firewalls.push({ provider: "gcloud", scope: "vps", rules: vpsRules });
  }
  for (const [tag, rules] of Array.from(taggedRules)) {
    firewalls.push({ provider: "gcloud", scope: tag, rules });
  }

  return firewalls;
}

function parseGCP(hcl: string): { specs: Record<string, VMSpecs>; storage: StorageBucket[] } {
  const specs: Record<string, VMSpecs> = {};

  for (const block of extractBlocks(hcl, "google_compute_instance")) {
    const name = extractField(block.body, "name");
    const machineType = extractField(block.body, "machine_type") || "";
    if (!name) continue;

    const known = GCP_SPECS[machineType] || { cpu: 0, ram_gb: 0 };

    // Boot disk size
    const bootDisk = extractNestedBlock(block.body, "boot_disk");
    const initParams = bootDisk ? extractNestedBlock(bootDisk, "initialize_params") : null;
    const diskGb = initParams ? extractNum(initParams, "size") : 0;

    // GPU
    const gpuBlock = extractNestedBlock(block.body, "guest_accelerator");
    let gpu: string | undefined;
    let gpuVram: string | undefined;
    if (gpuBlock) {
      const gpuType = extractField(gpuBlock, "type") || "";
      // Map common GPU types to friendly names
      if (gpuType.includes("t4")) { gpu = "NVIDIA T4"; gpuVram = "16GB"; }
      else if (gpuType.includes("a100")) { gpu = "NVIDIA A100"; gpuVram = "40GB"; }
      else if (gpuType.includes("v100")) { gpu = "NVIDIA V100"; gpuVram = "16GB"; }
      else if (gpuType.includes("l4")) { gpu = "NVIDIA L4"; gpuVram = "24GB"; }
      else { gpu = gpuType; }
    }

    specs[name] = {
      cpu: known.cpu,
      ram_gb: known.ram_gb,
      disk_gb: diskGb,
      machine_type: machineType,
      ...(gpu ? { gpu, gpu_vram: gpuVram } : {}),
    };
  }

  // GCP storage buckets
  const storage: StorageBucket[] = [];
  for (const block of extractBlocks(hcl, "google_storage_bucket")) {
    const name = extractField(block.body, "name");
    const storageClass = extractField(block.body, "storage_class") || "STANDARD";
    if (name) {
      storage.push({ provider: "gcp", name, tier: storageClass });
    }
  }

  return { specs, storage };
}

// --- Main ---

export function parseTerraform(infraDir: string): TerraformData {
  const vm_specs: Record<string, VMSpecs> = {};
  const storage: StorageBucket[] = [];
  const providers: VPSProvider[] = [];
  const firewalls: FirewallData[] = [];

  let dirs: string[];
  try {
    dirs = readdirSync(infraDir, { withFileTypes: true })
      .filter((d) => d.isDirectory() && d.name.startsWith("vps_"))
      .map((d) => d.name);
  } catch {
    return { vm_specs, storage, providers, firewalls };
  }

  for (const dir of dirs) {
    const providerName = dir.replace("vps_", "");
    const tfPath = join(infraDir, dir, "src", "main.tf");
    const hasTf = existsSync(tfPath);

    const provider: VPSProvider = {
      name: providerName,
      folder: dir,
      has_terraform: hasTf,
      services: [],
    };

    if (!hasTf) {
      providers.push(provider);
      continue;
    }

    const hcl = readFileSync(tfPath, "utf-8");

    // Also read terraform.json for instance names, buckets, etc.
    const tfJsonPath = join(infraDir, dir, "src", "terraform.json");
    let tfJson: any = {};
    try { tfJson = JSON.parse(readFileSync(tfJsonPath, "utf-8")); } catch {}

    // PRIMARY: Build specs from terraform.json (has resolved instance names)
    if (tfJson.instances) {
      for (const inst of tfJson.instances as any[]) {
        // Resolve instance_id: OCI uses "ocid", GCP uses "instance_id"
        const instanceId = inst.ocid || inst.instance_id || undefined;
        const spec: VMSpecs = {
          cpu: inst.ocpus || inst.cpu || 0,
          ram_gb: inst.memory_in_gbs || inst.ram_gb || 0,
          disk_gb: inst.boot_volume_size_in_gbs || inst.disk_gb || inst.disk_size_gb || 0,
          shape: inst.shape || inst.machine_type,
          machine_type: inst.machine_type,
          cloud_name: inst.name || inst.display_name,
          cloud_zone: inst.zone || tfJson.provider?.zone || tfJson.provider?.region || "",
          ...(instanceId ? { instance_id: instanceId } : {}),
        };
        // Store under ALL possible keys so gen-cloud-data can find it
        // OCI uses display_name as vmId, GCP uses gcloud_instance (=name)
        for (const key of [inst.display_name, inst.name, inst.alias].filter(Boolean)) {
          vm_specs[key as string] = { ...spec, ...(vm_specs[key as string] || {}) };
        }
      }
    }
    if (tfJson.buckets) {
      for (const b of tfJson.buckets as any[]) {
        storage.push({ provider: providerName, name: b.name, tier: b.storage_tier || b.access_type || "Standard" });
      }
    }

    // SECONDARY: Merge additional data from HCL (firewalls, GPU, etc.)
    if (providerName === "oci") {
      const result = parseOCI(hcl);
      // Merge HCL specs into terraform.json specs (HCL may have disk/GPU details)
      for (const [k, v] of Object.entries(result.specs)) {
        // Skip "each.value.*" keys from HCL
        if (k.includes("each.value")) continue;
        vm_specs[k] = { ...v, ...vm_specs[k] };
      }
      if (!tfJson.buckets) storage.push(...result.storage);
      firewalls.push(...parseOCIFirewalls(hcl));
      provider.services = [
        ...Object.keys(vm_specs).filter(k => !k.includes("each.value")).map((n) => `instance:${n}`),
        ...storage.filter(s => s.provider === providerName).map((b) => `bucket:${b.name}`),
      ];
    } else if (providerName === "gcloud") {
      const result = parseGCP(hcl);
      for (const [k, v] of Object.entries(result.specs)) {
        if (k.includes("each.value")) continue;
        vm_specs[k] = { ...v, ...vm_specs[k] };
      }
      if (!tfJson.buckets) storage.push(...result.storage);
      firewalls.push(...parseGCPFirewalls(hcl));
      provider.services = [
        ...Object.keys(vm_specs).filter(k => !k.includes("each.value")).map((n) => `instance:${n}`),
        ...storage.filter(s => s.provider === providerName).map((b) => `bucket:${b.name}`),
      ];
    } else if (providerName === "aws") {
      // AWS — detect SES, IAM, etc.
      if (hcl.includes("aws_ses_domain_identity")) {
        provider.services.push("ses-email");
      }
    }

    providers.push(provider);
  }

  return { vm_specs, storage, providers, firewalls };
}
