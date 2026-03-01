import type { FastifyInstance } from "fastify";
import { profileContainer, profileVm } from "../../shared/diagnostics.js";
import { resolveVmId } from "../../shared/config.js";

export async function registerProfilingRoutes(app: FastifyInstance) {
  app.get<{ Params: { container: string } }>(
    "/profiling/:container",
    { schema: { tags: ["Profiling"] } },
    async (req) => {
      return profileContainer(req.params.container);
    },
  );

  app.get<{ Params: { vmId: string } }>(
    "/profiling/vm/:vmId",
    { schema: { tags: ["Profiling"] } },
    async (req) => {
      const vmId = resolveVmId(req.params.vmId);
      return profileVm(vmId);
    },
  );
}
