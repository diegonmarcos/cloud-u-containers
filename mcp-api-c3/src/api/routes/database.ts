import { FastifyPluginAsync } from "fastify";
import { z } from "zod";
import {
  getHealthHistory,
  getUptimeReport,
  getAuditLog,
  getDeployHistory,
  getAlertState,
  updateAlertState,
  pruneOldRecords,
} from "../../shared/db.js";

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

export const registerDatabaseRoutes: FastifyPluginAsync = async (app) => {
  app.get(
    "/db/health/history",
    {
      schema: {
        tags: ["Database"],
        summary: "Get health check history for a VM",
        querystring: healthHistorySchema,
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
        tags: ["Database"],
        summary: "Get uptime statistics for a VM",
        querystring: uptimeReportSchema,
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
        tags: ["Database"],
        summary: "Get audit log entries",
        querystring: auditLogSchema,
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
        tags: ["Database"],
        summary: "Get deployment history",
        querystring: deployHistorySchema,
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
        tags: ["Database"],
        summary: "Get current alert state",
        querystring: alertStateSchema,
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
        tags: ["Database"],
        summary: "Update alert state",
        body: alertUpdateSchema,
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
        tags: ["Database"],
        summary: "Remove old records from database",
        body: pruneSchema,
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
