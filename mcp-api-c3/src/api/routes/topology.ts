import type { FastifyInstance } from "fastify";
import { assembleTopology, getTopologyDrift, getSecurityTopology } from "../../shared/topology.js";

export async function registerTopologyRoutes(app: FastifyInstance) {
  app.get("/topology", { schema: { tags: ["Topology"] } }, async () => {
    return assembleTopology();
  });

  app.get("/topology/drift", { schema: { tags: ["Topology"] } }, async () => {
    return getTopologyDrift();
  });

  app.get("/topology/security", { schema: { tags: ["Topology"] } }, async () => {
    return getSecurityTopology();
  });
}
