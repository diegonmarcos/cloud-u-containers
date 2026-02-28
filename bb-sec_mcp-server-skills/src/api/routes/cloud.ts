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
    return {
      oci: {
        instances: oci.listInstances(),
        resources: oci.listResources(),
        costs: oci.getCosts(),
      },
      gcp: {
        instances: gcp.listInstances(),
        resources: gcp.listResources(),
        costs: gcp.getCosts(),
      },
    };
  });
}
