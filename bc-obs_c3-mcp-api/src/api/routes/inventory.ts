// ── Inventory Routes — "What exists" ──
// Service catalog, topology, config, and discovery

import { readFileSync, existsSync } from "fs";
import type { FastifyInstance } from "fastify";
import { listServices, getService, probeSpec, getAllSpecs } from "../../shared/discovery.js";
import { getDriftReport } from "../../shared/config.js";
import { getConfigFile } from "../../shared/files.js";
import { CONFIG_PATH, CONFIGS_PATH } from "../../shared/paths.js";

export async function registerInventoryRoutes(app: FastifyInstance) {
  // ── Services (from services.ts) ──

  app.get("/services", { schema: { tags: ["Inventory"] } }, async () => {
    return listServices();
  });

  app.get<{ Params: { service: string } }>(
    "/services/:service",
    { schema: { tags: ["Inventory"], params: { type: "object" as const, properties: { service: { type: "string" as const } }, required: ["service"] } } },
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
    { schema: { tags: ["Inventory"], params: { type: "object" as const, properties: { service: { type: "string" as const } }, required: ["service"] } } },
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

  // ── Topology (serves cloud-topology.json directly) ──

  app.get("/topology", { schema: { tags: ["Inventory"] } }, async (_req, reply) => {
    if (!existsSync(CONFIG_PATH)) { reply.code(404).send({ error: "cloud-topology.json not generated yet" }); return; }
    return JSON.parse(readFileSync(CONFIG_PATH, "utf-8"));
  });

  app.get("/topology/drift", { schema: { tags: ["Inventory"] } }, async () => {
    const drift = getDriftReport();
    const parts: string[] = [];
    if (drift.onDiskOnly.length > 0) parts.push(`${drift.onDiskOnly.length} on disk only: ${drift.onDiskOnly.join(", ")}`);
    if (drift.configOnly.length > 0) parts.push(`${drift.configOnly.length} in config only: ${drift.configOnly.join(", ")}`);
    if (parts.length === 0) parts.push("No drift detected.");
    return { onDiskOnly: drift.onDiskOnly, configOnly: drift.configOnly, summary: parts.join(" | ") };
  });

  // ── Configs (serves cloud-configs.json directly) ──

  app.get("/configs", { schema: { tags: ["Inventory"] } }, async (_req, reply) => {
    if (!existsSync(CONFIGS_PATH)) { reply.code(404).send({ error: "cloud-configs.json not generated yet" }); return; }
    return JSON.parse(readFileSync(CONFIGS_PATH, "utf-8"));
  });

  // ── Files: config (from files.ts) ──

  app.get<{ Params: { service: string } }>(
    "/files/config/:service",
    { schema: { tags: ["Inventory"], params: { type: "object" as const, properties: { service: { type: "string" as const } }, required: ["service"] } } },
    async (req) => {
      return { content: getConfigFile(req.params.service) };
    },
  );

  app.get<{ Params: { service: string; file: string } }>(
    "/files/config/:service/:file",
    { schema: { tags: ["Inventory"], params: { type: "object" as const, properties: { service: { type: "string" as const }, file: { type: "string" as const } }, required: ["service", "file"] } } },
    async (req) => {
      return { content: getConfigFile(req.params.service, req.params.file) };
    },
  );
}
