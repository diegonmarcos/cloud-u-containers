import type { FastifyInstance } from "fastify";
import * as oci from "../../shared/cloud/oci.js";
import * as gcp from "../../shared/cloud/gcp.js";

export async function registerCloudRoutes(app: FastifyInstance) {
  app.get("/cloud/oci/instances", { schema: { tags: ["Cloud"] } }, async () => {
    return oci.listInstances();
  });

  app.get("/cloud/gcp/instances", { schema: { tags: ["Cloud"] } }, async () => {
    return gcp.listInstances();
  });

  app.get("/cloud/oci/resources", { schema: { tags: ["Cloud"] } }, async () => {
    return oci.listResources();
  });

  app.get("/cloud/gcp/resources", { schema: { tags: ["Cloud"] } }, async () => {
    return gcp.listResources();
  });

  app.get("/cloud/oci/costs", { schema: { tags: ["Cloud"] } }, async () => {
    return oci.getCosts();
  });

  app.get("/cloud/gcp/costs", { schema: { tags: ["Cloud"] } }, async () => {
    return gcp.getCosts();
  });

  app.get("/cloud/summary", { schema: { tags: ["Cloud"] } }, async () => {
    const safe = <T>(fn: () => T): T | { ok: false; error: string } => {
      try { return fn(); }
      catch (e) { return { ok: false, error: e instanceof Error ? e.message : String(e) }; }
    };
    return {
      oci: {
        instances: safe(() => oci.listInstances()),
        resources: safe(() => oci.listResources()),
        costs: safe(() => oci.getCosts()),
      },
      gcp: {
        instances: safe(() => gcp.listInstances()),
        resources: safe(() => gcp.listResources()),
        costs: safe(() => gcp.getCosts()),
      },
    };
  });
}
