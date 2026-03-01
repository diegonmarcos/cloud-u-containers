// ── Inventory Routes — "What exists" ──
// Service catalog, topology, config, and discovery

import type { FastifyInstance } from "fastify";
import { listServices, getService, probeSpec, getAllSpecs } from "../../shared/discovery.js";
import { assembleTopology, getTopologyDrift } from "../../shared/topology.js";
import { getConfigFile } from "../../shared/files.js";

export async function registerInventoryRoutes(app: FastifyInstance) {
  // ── Services (from services.ts) ──

  app.get("/services", { schema: { tags: ["Inventory"] } }, async () => {
    return listServices();
  });

  app.get<{ Params: { service: string } }>(
    "/services/:service",
    { schema: { tags: ["Inventory"] } },
    async (req, reply) => {
      const info = getService(req.params.service);
      if (!info) {
        reply.code(404).send({ error: `Unknown service: ${req.params.service}` });
        return;
      }
      return info;
    },
  );

  app.get<{ Params: { service: string } }>(
    "/services/:service/spec",
    { schema: { tags: ["Inventory"] } },
    async (req, reply) => {
      const result = probeSpec(req.params.service);
      if (!result.ok) {
        reply.code(404).send({ error: result.error });
        return;
      }
      return result.spec;
    },
  );

  app.get("/services/all/specs", { schema: { tags: ["Inventory"] } }, async () => {
    return getAllSpecs();
  });

  // ── Topology (from topology.ts, minus security which goes to security routes) ──

  app.get("/topology", { schema: { tags: ["Inventory"] } }, async () => {
    return assembleTopology();
  });

  app.get("/topology/drift", { schema: { tags: ["Inventory"] } }, async () => {
    return getTopologyDrift();
  });

  // ── Files: config (from files.ts) ──

  app.get<{ Params: { service: string } }>(
    "/files/config/:service",
    { schema: { tags: ["Inventory"] } },
    async (req) => {
      return { content: getConfigFile(req.params.service) };
    },
  );

  app.get<{ Params: { service: string; file: string } }>(
    "/files/config/:service/:file",
    { schema: { tags: ["Inventory"] } },
    async (req) => {
      return { content: getConfigFile(req.params.service, req.params.file) };
    },
  );
}
