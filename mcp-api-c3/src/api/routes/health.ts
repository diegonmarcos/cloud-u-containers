import type { FastifyInstance } from "fastify";
import {
  healthAlive,
  healthDeclared,
  healthDeployed,
  healthDrift,
  healthStatus,
  checkTier1All,
  checkTier2All,
  checkTier3All,
} from "../../shared/health.js";
import { resolveVmId } from "../../shared/config.js";

export async function registerHealthRoutes(app: FastifyInstance) {
  app.get("/health", { schema: { tags: ["Health"] } }, async () => {
    return healthAlive();
  });

  app.get("/health/declared", { schema: { tags: ["Health"] } }, async () => {
    return healthDeclared();
  });

  app.get("/health/deployed", { schema: { tags: ["Health"] } }, async () => {
    return healthDeployed();
  });

  app.get<{ Params: { vmId: string } }>(
    "/health/deployed/:vmId",
    { schema: { tags: ["Health"] } },
    async (req) => {
      const vmId = resolveVmId(req.params.vmId);
      return healthDeployed(vmId);
    },
  );

  app.get("/health/drift", { schema: { tags: ["Health"] } }, async () => {
    return healthDrift();
  });

  app.get("/health/status", { schema: { tags: ["Health"] } }, async () => {
    return healthStatus();
  });

  app.get<{ Params: { vmId: string } }>(
    "/health/status/:vmId",
    { schema: { tags: ["Health"] } },
    async (req) => {
      const vmId = resolveVmId(req.params.vmId);
      return healthStatus(vmId);
    },
  );

  // Tiered health
  app.get("/health/tier1", { schema: { tags: ["Health"] } }, async () => {
    return checkTier1All();
  });

  app.get<{ Params: { vmId: string } }>(
    "/health/tier1/:vmId",
    { schema: { tags: ["Health"] } },
    async (req) => {
      const vmId = resolveVmId(req.params.vmId);
      return checkTier1All(vmId);
    },
  );

  app.get("/health/tier2", { schema: { tags: ["Health"] } }, async () => {
    return checkTier2All();
  });

  app.get<{ Params: { vmId: string } }>(
    "/health/tier2/:vmId",
    { schema: { tags: ["Health"] } },
    async (req) => {
      const vmId = resolveVmId(req.params.vmId);
      return checkTier2All(vmId);
    },
  );

  app.get("/health/tier3", { schema: { tags: ["Health"] } }, async () => {
    return checkTier3All();
  });

  app.get<{ Params: { vmId: string } }>(
    "/health/tier3/:vmId",
    { schema: { tags: ["Health"] } },
    async (req) => {
      const vmId = resolveVmId(req.params.vmId);
      return checkTier3All(vmId);
    },
  );
}
