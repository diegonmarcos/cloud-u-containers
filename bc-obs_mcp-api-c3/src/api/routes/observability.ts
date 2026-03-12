// ── Observability Routes — "How it's doing" ──
// Health, profiling, diagnostics, testing, alerting, database

import { FastifyPluginAsync } from "fastify";
import { z } from "zod";
import { zodToJsonSchema } from "zod-to-json-schema";
import {
  healthAlive,
  healthDeclared,
  healthDeployed,
  healthDrift,
  healthStatus,
  checkTier1All,
  checkTier2All,
  checkTier3All,
  checkUp,
  checkHealth,
  checkReach,
} from "../../shared/health.js";
import { profileContainer, profileVm } from "../../shared/diagnostics.js";
import { runTestSuite } from "../../shared/tests.js";
import { getContainerLog, getVmStatus, getReport } from "../../shared/files.js";
import {
  sendNotification,
  alertHealthDown,
  alertHealthRecovered,
  alertCertExpiring,
  alertDiskFull,
} from "../../shared/notify.js";
import {
  getHealthHistory,
  getUptimeReport,
  getAuditLog,
  getDeployHistory,
  getAlertState,
  updateAlertState,
  pruneOldRecords,
} from "../../shared/db.js";
import { resolveVmId } from "../../shared/config.js";

// ── Zod schemas for validated endpoints ──

const sendSchema = z.object({
  title: z.string(),
  message: z.string(),
  priority: z.enum(["min", "low", "default", "high", "urgent"]).optional(),
  tags: z.array(z.string()).optional(),
});

const healthDownSchema = z.object({
  target: z.string(),
  details: z.string().optional(),
});

const healthRecoveredSchema = z.object({
  target: z.string(),
});

const certExpiringSchema = z.object({
  domain: z.string(),
  daysRemaining: z.number(),
});

const diskFullSchema = z.object({
  vm: z.string(),
  percent: z.string(),
});

const healthHistorySchema = z.object({
  vm: z.string(),
  limit: z.number().optional(),
});

const uptimeReportSchema = z.object({
  vm: z.string(),
  days: z.number().optional(),
});

const auditLogSchema = z.object({
  tool: z.string().optional(),
  target: z.string().optional(),
  limit: z.number().optional(),
});

const deployHistorySchema = z.object({
  service: z.string().optional(),
  limit: z.number().optional(),
});

const alertStateSchema = z.object({
  vm: z.string(),
});

const alertUpdateSchema = z.object({
  vm: z.string(),
  status: z.string(),
  notified: z.boolean(),
});

const pruneSchema = z.object({
  days: z.number().optional(),
});

type SuiteName = "connectivity" | "dns" | "tls" | "routes" | "containers" | "wireguard" | "full";
const VALID_SUITES = new Set<string>(["connectivity", "dns", "tls", "routes", "containers", "wireguard", "full"]);

const P_vmId = { type: "object" as const, properties: { vmId: { type: "string" as const } }, required: ["vmId"] };
const P_target = { type: "object" as const, properties: { target: { type: "string" as const } }, required: ["target"] };
const P_container = { type: "object" as const, properties: { container: { type: "string" as const } }, required: ["container"] };
const P_suite = { type: "object" as const, properties: { suite: { type: "string" as const } }, required: ["suite"] };
const P_suiteTarget = { type: "object" as const, properties: { suite: { type: "string" as const }, target: { type: "string" as const } }, required: ["suite", "target"] };
const P_vmContainer = { type: "object" as const, properties: { vmId: { type: "string" as const }, container: { type: "string" as const } }, required: ["vmId", "container"] };
const P_type = { type: "object" as const, properties: { type: { type: "string" as const } }, required: ["type"] };

export const registerObservabilityRoutes: FastifyPluginAsync = async (app) => {
  // ── Health (from health.ts) ──

  app.get("/health", { schema: { tags: ["Observability"] } }, async () => {
    return healthAlive();
  });

  app.get("/health/declared", { schema: { tags: ["Observability"] } }, async () => {
    return healthDeclared();
  });

  app.get("/health/deployed", { schema: { tags: ["Observability"] } }, async () => {
    return healthDeployed();
  });

  app.get<{ Params: { vmId: string } }>(
    "/health/deployed/:vmId",
    { schema: { tags: ["Observability"], params: P_vmId } },
    async (req) => {
      const vmId = resolveVmId(req.params.vmId);
      return healthDeployed(vmId);
    },
  );

  app.get("/health/drift", { schema: { tags: ["Observability"] } }, async () => {
    return healthDrift();
  });

  app.get("/health/status", { schema: { tags: ["Observability"] } }, async () => {
    return healthStatus();
  });

  app.get<{ Params: { vmId: string } }>(
    "/health/status/:vmId",
    { schema: { tags: ["Observability"], params: P_vmId } },
    async (req) => {
      const vmId = resolveVmId(req.params.vmId);
      return healthStatus(vmId);
    },
  );

  // Tiered health
  app.get("/health/tier1", { schema: { tags: ["Observability"] } }, async () => {
    return checkTier1All();
  });

  app.get<{ Params: { vmId: string } }>(
    "/health/tier1/:vmId",
    { schema: { tags: ["Observability"], params: P_vmId } },
    async (req) => {
      const vmId = resolveVmId(req.params.vmId);
      return checkTier1All(vmId);
    },
  );

  app.get("/health/tier2", { schema: { tags: ["Observability"] } }, async () => {
    return checkTier2All();
  });

  app.get<{ Params: { vmId: string } }>(
    "/health/tier2/:vmId",
    { schema: { tags: ["Observability"], params: P_vmId } },
    async (req) => {
      const vmId = resolveVmId(req.params.vmId);
      return checkTier2All(vmId);
    },
  );

  app.get("/health/tier3", { schema: { tags: ["Observability"] } }, async () => {
    return checkTier3All();
  });

  app.get<{ Params: { vmId: string } }>(
    "/health/tier3/:vmId",
    { schema: { tags: ["Observability"], params: P_vmId } },
    async (req) => {
      const vmId = resolveVmId(req.params.vmId);
      return checkTier3All(vmId);
    },
  );

  // ── Generic /up and /health — works for VMs, services, and containers ──

  app.get<{ Params: { target: string } }>(
    "/up/:target",
    {
      schema: {
        tags: ["Observability"],
        params: P_target,
        summary: "Quick TCP check — is the target up? (VM, service, or container)",
        description: "Fast check: VM=ssh-keyscan, service=VM reachable+containers running, container=docker state",
      },
    },
    async (req) => {
      return checkUp(req.params.target);
    },
  );

  app.get<{ Params: { target: string } }>(
    "/health/:target",
    {
      schema: {
        tags: ["Observability"],
        params: P_target,
        summary: "Full health check — SSH + docker health (VM, service, or container)",
        description: "Deep check: VM=full SSH auth, service=SSH+docker inspect health, container=docker health status",
      },
    },
    async (req) => {
      return checkHealth(req.params.target);
    },
  );

  app.get<{ Params: { target: string } }>(
    "/reach/:target",
    {
      schema: {
        tags: ["Observability"],
        params: P_target,
        summary: "Route reachability — probe HTTPS/HTTP/TCP through Caddy",
        description: "Tests actual route: looks up service domain from topology, probes HTTPS → HTTP → TCP. Verifies the full path (Cloudflare → Caddy → service) is working.",
      },
    },
    async (req) => {
      return checkReach(req.params.target);
    },
  );

  // ── Profiling (from profiling.ts) ──

  app.get<{ Params: { container: string } }>(
    "/profiling/:container",
    { schema: { tags: ["Observability"], params: P_container } },
    async (req) => {
      return profileContainer(req.params.container);
    },
  );

  app.get<{ Params: { vmId: string } }>(
    "/profiling/vm/:vmId",
    { schema: { tags: ["Observability"], params: P_vmId } },
    async (req) => {
      const vmId = resolveVmId(req.params.vmId);
      return profileVm(vmId);
    },
  );

  // ── Tests (from tests.ts) ──

  app.get<{ Params: { suite: string } }>(
    "/tests/run/:suite",
    { schema: { tags: ["Observability"], params: P_suite } },
    async (req, reply) => {
      const { suite } = req.params;
      if (!VALID_SUITES.has(suite)) {
        reply.code(400).send({ error: `Invalid suite: ${suite}. Valid: ${Array.from(VALID_SUITES).join(", ")}` });
        return;
      }
      return runTestSuite(suite as SuiteName);
    },
  );

  app.get<{ Params: { suite: string; target: string } }>(
    "/tests/run/:suite/:target",
    { schema: { tags: ["Observability"], params: P_suiteTarget } },
    async (req, reply) => {
      const { suite, target } = req.params;
      if (!VALID_SUITES.has(suite)) {
        reply.code(400).send({ error: `Invalid suite: ${suite}. Valid: ${Array.from(VALID_SUITES).join(", ")}` });
        return;
      }
      return runTestSuite(suite as SuiteName, target);
    },
  );

  // Convenience shortcuts
  for (const suite of VALID_SUITES) {
    app.get(`/tests/${suite}`, { schema: { tags: ["Observability"] } }, async () => {
      return runTestSuite(suite as SuiteName);
    });
  }

  // ── Workflows (GitHub Actions) ──

  app.get("/workflows", { schema: { tags: ["Observability"] } }, async () => {
    try {
      const resp = await fetch(
        "https://api.github.com/repos/diegonmarcos/cloud/actions/runs?per_page=15",
        { headers: { Accept: "application/vnd.github+json" }, signal: AbortSignal.timeout(10000) },
      );
      if (!resp.ok) return { runs: [], error: `GitHub API ${resp.status}` };
      const data = await resp.json() as { workflow_runs: Array<Record<string, unknown>> };
      return {
        runs: (data.workflow_runs || []).map((r: Record<string, unknown>) => ({
          name: r.name,
          branch: r.head_branch,
          status: r.status,
          conclusion: r.conclusion,
          created_at: r.created_at,
          url: r.html_url,
        })),
      };
    } catch (e: unknown) {
      return { runs: [], error: e instanceof Error ? e.message : String(e) };
    }
  });

  // ── Files: logs, status, reports (from files.ts) ──

  app.get<{ Params: { vmId: string; container: string }; Querystring: { lines?: string; since?: string } }>(
    "/files/logs/:vmId/:container",
    { schema: { tags: ["Observability"], params: P_vmContainer } },
    async (req) => {
      const vmId = resolveVmId(req.params.vmId);
      const lines = req.query.lines ? parseInt(req.query.lines, 10) : undefined;
      return { content: getContainerLog(vmId, req.params.container, lines, req.query.since) };
    },
  );

  app.get<{ Params: { vmId: string } }>(
    "/files/status/:vmId",
    { schema: { tags: ["Observability"], params: P_vmId } },
    async (req) => {
      const vmId = resolveVmId(req.params.vmId);
      return { content: getVmStatus(vmId) };
    },
  );

  app.get<{ Params: { type: string } }>(
    "/files/report/:type",
    { schema: { tags: ["Observability"], params: P_type } },
    async (req) => {
      return { content: getReport(req.params.type) };
    },
  );

  // ── Notifications (from notify.ts) ──

  app.post(
    "/notify/send",
    {
      schema: {
        tags: ["Observability"],
        summary: "Send a push notification",
        body: zodToJsonSchema(sendSchema),
        response: { 200: { type: "object" } },
      },
    },
    async (req) => {
      const data = sendSchema.parse(req.body);
      return sendNotification(data);
    }
  );

  app.post(
    "/notify/health/down",
    {
      schema: {
        tags: ["Observability"],
        summary: "Alert for VM/service down",
        body: zodToJsonSchema(healthDownSchema),
        response: { 200: { type: "object" } },
      },
    },
    async (req) => {
      const { target, details } = healthDownSchema.parse(req.body);
      return alertHealthDown(target, details ?? "");
    }
  );

  app.post(
    "/notify/health/recovered",
    {
      schema: {
        tags: ["Observability"],
        summary: "Alert for VM/service recovery",
        body: zodToJsonSchema(healthRecoveredSchema),
        response: { 200: { type: "object" } },
      },
    },
    async (req) => {
      const { target } = healthRecoveredSchema.parse(req.body);
      return alertHealthRecovered(target);
    }
  );

  app.post(
    "/notify/cert/expiring",
    {
      schema: {
        tags: ["Observability"],
        summary: "Alert for expiring TLS certificate",
        body: zodToJsonSchema(certExpiringSchema),
        response: { 200: { type: "object" } },
      },
    },
    async (req) => {
      const { domain, daysRemaining } = certExpiringSchema.parse(req.body);
      return alertCertExpiring(domain, daysRemaining);
    }
  );

  app.post(
    "/notify/disk/full",
    {
      schema: {
        tags: ["Observability"],
        summary: "Alert for disk space warning",
        body: zodToJsonSchema(diskFullSchema),
        response: { 200: { type: "object" } },
      },
    },
    async (req) => {
      const { vm, percent } = diskFullSchema.parse(req.body);
      return alertDiskFull(vm, percent);
    }
  );

  // ── Database (from database.ts) ──

  app.get(
    "/db/health/history",
    {
      schema: {
        tags: ["Observability"],
        summary: "Get health check history for a VM",
        querystring: zodToJsonSchema(healthHistorySchema),
        response: { 200: { type: "array" } },
      },
    },
    async (req) => {
      const { vm, limit } = healthHistorySchema.parse(req.query);
      return getHealthHistory({ vm, limit });
    }
  );

  app.get(
    "/db/uptime/report",
    {
      schema: {
        tags: ["Observability"],
        summary: "Get uptime statistics for a VM",
        querystring: zodToJsonSchema(uptimeReportSchema),
        response: { 200: { type: "object" } },
      },
    },
    async (req) => {
      const { vm, days } = uptimeReportSchema.parse(req.query);
      return getUptimeReport(vm, days);
    }
  );

  app.get(
    "/db/audit",
    {
      schema: {
        tags: ["Observability"],
        summary: "Get audit log entries",
        querystring: zodToJsonSchema(auditLogSchema),
        response: { 200: { type: "array" } },
      },
    },
    async (req) => {
      const { tool, limit } = auditLogSchema.parse(req.query);
      return getAuditLog({ tool, limit });
    }
  );

  app.get(
    "/db/deploy/history",
    {
      schema: {
        tags: ["Observability"],
        summary: "Get deployment history",
        querystring: zodToJsonSchema(deployHistorySchema),
        response: { 200: { type: "array" } },
      },
    },
    async (req) => {
      const { service, limit } = deployHistorySchema.parse(req.query);
      return getDeployHistory({ service, limit });
    }
  );

  app.get(
    "/db/alert/state",
    {
      schema: {
        tags: ["Observability"],
        summary: "Get current alert state",
        querystring: zodToJsonSchema(alertStateSchema),
        response: { 200: { type: "object", nullable: true } },
      },
    },
    async (req) => {
      const { vm } = alertStateSchema.parse(req.query);
      return getAlertState(vm);
    }
  );

  app.post(
    "/db/alert/update",
    {
      schema: {
        tags: ["Observability"],
        summary: "Update alert state",
        body: zodToJsonSchema(alertUpdateSchema),
        response: { 200: { type: "object" } },
      },
    },
    async (req) => {
      const { vm, status, notified } = alertUpdateSchema.parse(req.body);
      updateAlertState(vm, status, notified);
      return { ok: true, vm, status, notified };
    }
  );

  app.post(
    "/db/prune",
    {
      schema: {
        tags: ["Observability"],
        summary: "Remove old records from database",
        body: zodToJsonSchema(pruneSchema),
        response: { 200: { type: "object" } },
      },
    },
    async (req) => {
      const { days } = pruneSchema.parse(req.body);
      const result = pruneOldRecords(days);
      return { ok: true, ...result };
    }
  );
};
