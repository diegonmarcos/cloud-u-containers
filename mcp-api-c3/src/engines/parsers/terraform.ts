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
  shape?: string;
  machine_type?: string;
  gpu?: string;
  gpu_vram?: string;
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

export interface TerraformData {
  vm_specs: Record<string, VMSpecs>;   // keyed by display_name / instance name
  storage: StorageBucket[];
  providers: VPSProvider[];
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

  let dirs: string[];
  try {
    dirs = readdirSync(infraDir, { withFileTypes: true })
      .filter((d) => d.isDirectory() && d.name.startsWith("vps_"))
      .map((d) => d.name);
  } catch {
    return { vm_specs, storage, providers };
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

    if (providerName === "oci") {
      const result = parseOCI(hcl);
      Object.assign(vm_specs, result.specs);
      storage.push(...result.storage);
      provider.services = [
        ...Object.keys(result.specs).map((n) => `instance:${n}`),
        ...result.storage.map((b) => `bucket:${b.name}`),
      ];
    } else if (providerName === "gcloud") {
      const result = parseGCP(hcl);
      // GCP uses instance "name" field, need to map to VM IDs
      Object.assign(vm_specs, result.specs);
      storage.push(...result.storage);
      provider.services = [
        ...Object.keys(result.specs).map((n) => `instance:${n}`),
        ...result.storage.map((b) => `bucket:${b.name}`),
      ];
    } else if (providerName === "aws") {
      // AWS — detect SES, IAM, etc.
      if (hcl.includes("aws_ses_domain_identity")) {
        provider.services.push("ses-email");
      }
    }

    providers.push(provider);
  }

  return { vm_specs, storage, providers };
}
