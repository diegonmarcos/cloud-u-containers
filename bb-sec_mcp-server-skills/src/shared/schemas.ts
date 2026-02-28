import { z } from "zod";

// ── VM & Service Config ──────────────────────────────────────────────────

export const VmConfigSchema = z.object({
  ip: z.string(),
  user: z.string(),
  method: z.enum(["key", "gcloud"]),
  ssh_alias: z.string().optional(),
  gcloud_instance: z.string().optional(),
  gcloud_zone: z.string().optional(),
  description: z.string(),
});

export const ServiceCategorySchema = z.enum([
  "app", "mic", "sec", "tools", "cloud", "data", "fin", "agi",
]);

export const ServiceConfigSchema = z.object({
  category: ServiceCategorySchema,
  vm: z.string(),
  flake: z.string().optional(),
  subfolder: z.string().optional(),
  description: z.string(),
  discovered: z.boolean().optional(),
});

export const InfraConfigSchema = z.object({
  ssh_key: z.string(),
  remote_base: z.string(),
  vms: z.record(VmConfigSchema),
  services: z.record(ServiceConfigSchema),
});

// ── Health ────────────────────────────────────────────────────────────────

export const Tier1ResultSchema = z.object({
  vm: z.string(),
  alias: z.string(),
  ip: z.string(),
  reachable: z.boolean(),
  latencyMs: z.number().optional(),
  error: z.string().optional(),
});

export const Tier2ResultSchema = Tier1ResultSchema.extend({
  sshOk: z.boolean().optional(),
  sshError: z.string().optional(),
});

export const VmResourcesSchema = z.object({
  uptime: z.string().optional(),
  memoryTotal: z.string().optional(),
  memoryUsed: z.string().optional(),
  memoryFree: z.string().optional(),
  diskTotal: z.string().optional(),
  diskUsed: z.string().optional(),
  diskAvailable: z.string().optional(),
  diskPercent: z.string().optional(),
});

export const ContainerStatusSchema = z.object({
  name: z.string(),
  status: z.string(),
  image: z.string().optional(),
  ports: z.string().optional(),
});

export const Tier3ResultSchema = Tier2ResultSchema.extend({
  resources: VmResourcesSchema.optional(),
  containers: z.array(ContainerStatusSchema).optional(),
});

export const HealthDeclaredSchema = z.object({
  vms: z.record(VmConfigSchema),
  services: z.record(ServiceConfigSchema),
  vmCount: z.number(),
  serviceCount: z.number(),
});

export const DeployedContainerSchema = z.object({
  vm: z.string(),
  alias: z.string(),
  containers: z.array(ContainerStatusSchema),
  error: z.string().optional(),
});

export const DriftEntrySchema = z.object({
  service: z.string(),
  declared: z.boolean(),
  deployed: z.boolean(),
  status: z.enum(["ok", "missing", "extra", "unknown"]),
});

// ── Diagnostics (8-check profiling) ──────────────────────────────────────

export const DiagnosticCheckSchema = z.object({
  name: z.string(),
  passed: z.boolean(),
  details: z.string(),
  error: z.string().optional(),
  durationMs: z.number().optional(),
});

export const ProfilingResponseSchema = z.object({
  container: z.string(),
  vm: z.string().optional(),
  checks: z.array(DiagnosticCheckSchema),
  passed: z.number(),
  failed: z.number(),
  total: z.number(),
});

// ── Cloud ─────────────────────────────────────────────────────────────────

export const CloudInstanceSchema = z.object({
  id: z.string(),
  name: z.string(),
  state: z.string(),
  shape: z.string().optional(),
  region: z.string().optional(),
  zone: z.string().optional(),
  publicIp: z.string().optional(),
  privateIp: z.string().optional(),
  ocpus: z.number().optional(),
  memoryGb: z.number().optional(),
});

export const CloudResourceSchema = z.object({
  type: z.string(),
  name: z.string(),
  id: z.string().optional(),
  details: z.record(z.unknown()).optional(),
});

export const CloudCostSchema = z.object({
  service: z.string(),
  amount: z.number(),
  currency: z.string(),
  period: z.string().optional(),
});

// ── Topology (C3) ────────────────────────────────────────────────────────

export const TopologyVmSchema = z.object({
  id: z.string(),
  alias: z.string(),
  publicIp: z.string(),
  wgIp: z.string().optional(),
  provider: z.enum(["oci", "gcp"]),
  services: z.array(z.string()),
  containers: z.array(z.string()).optional(),
});

export const TopologyNetworkSchema = z.object({
  wgPeers: z.array(z.object({
    vm: z.string(),
    wgIp: z.string(),
    endpoint: z.string().optional(),
  })).optional(),
  caddyRoutes: z.array(z.object({
    domain: z.string(),
    upstream: z.string(),
    auth: z.string().optional(),
  })).optional(),
});

export const TopologySchema = z.object({
  vms: z.array(TopologyVmSchema),
  network: TopologyNetworkSchema.optional(),
  summary: z.object({
    vmCount: z.number(),
    serviceCount: z.number(),
    containerCount: z.number().optional(),
    domainCount: z.number().optional(),
  }),
});

// ── Tests (C3) ───────────────────────────────────────────────────────────

export const TestResultSchema = z.object({
  name: z.string(),
  target: z.string().optional(),
  passed: z.boolean(),
  timeMs: z.number(),
  details: z.string(),
  error: z.string().optional(),
});

export const TestSuiteResultSchema = z.object({
  suite: z.string(),
  tests: z.array(TestResultSchema),
  passed: z.number(),
  failed: z.number(),
  total: z.number(),
  timeMs: z.number(),
});

export const TestSuiteNameSchema = z.enum([
  "connectivity", "dns", "tls", "routes", "containers",
  "services", "wireguard", "security", "full",
]);

// ── Files (C3) ───────────────────────────────────────────────────────────

export const FileRetrievalSchema = z.object({
  category: z.enum(["config", "logs", "status", "reports", "secrets"]),
  target: z.string(),
  file: z.string().optional(),
  content: z.string(),
});

export const ReportTypeSchema = z.enum([
  "health", "topology", "security", "drift", "tests", "resources",
]);

// ── Service Discovery ────────────────────────────────────────────────────

export const ServiceInfoSchema = z.object({
  name: z.string(),
  domain: z.string().optional(),
  vm: z.string(),
  alias: z.string().optional(),
  category: z.string(),
  hasSpec: z.boolean().optional(),
  specUrl: z.string().optional(),
});
