import { FastifyPluginAsync } from "fastify";
import { z } from "zod";
import {
  sendNotification,
  alertHealthDown,
  alertHealthRecovered,
  alertCertExpiring,
  alertDiskFull,
} from "../../shared/notify.js";

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

export const registerNotifyRoutes: FastifyPluginAsync = async (app) => {
  app.post(
    "/notify/send",
    {
      schema: {
        tags: ["Notifications"],
        summary: "Send a push notification",
        body: sendSchema,
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
        tags: ["Notifications"],
        summary: "Alert for VM/service down",
        body: healthDownSchema,
        response: { 200: { type: "object" } },
      },
    },
    async (req) => {
      const { target, details } = healthDownSchema.parse(req.body);
      return alertHealthDown(target, details);
    }
  );

  app.post(
    "/notify/health/recovered",
    {
      schema: {
        tags: ["Notifications"],
        summary: "Alert for VM/service recovery",
        body: healthRecoveredSchema,
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
        tags: ["Notifications"],
        summary: "Alert for expiring TLS certificate",
        body: certExpiringSchema,
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
        tags: ["Notifications"],
        summary: "Alert for disk space warning",
        body: diskFullSchema,
        response: { 200: { type: "object" } },
      },
    },
    async (req) => {
      const { vm, percent } = diskFullSchema.parse(req.body);
      return alertDiskFull(vm, percent);
    }
  );
};
