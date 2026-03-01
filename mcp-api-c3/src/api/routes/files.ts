import type { FastifyInstance } from "fastify";
import { getConfigFile, getContainerLog, getVmStatus, getReport, getSecretsStatus } from "../../shared/files.js";
import { resolveVmId } from "../../shared/config.js";

export async function registerFilesRoutes(app: FastifyInstance) {
  app.get<{ Params: { service: string } }>(
    "/files/config/:service",
    { schema: { tags: ["Files"] } },
    async (req) => {
      return { content: getConfigFile(req.params.service) };
    },
  );

  app.get<{ Params: { service: string; file: string } }>(
    "/files/config/:service/:file",
    { schema: { tags: ["Files"] } },
    async (req) => {
      return { content: getConfigFile(req.params.service, req.params.file) };
    },
  );

  app.get<{ Params: { vmId: string; container: string }; Querystring: { lines?: string; since?: string } }>(
    "/files/logs/:vmId/:container",
    { schema: { tags: ["Files"] } },
    async (req) => {
      const vmId = resolveVmId(req.params.vmId);
      const lines = req.query.lines ? parseInt(req.query.lines, 10) : undefined;
      return { content: getContainerLog(vmId, req.params.container, lines, req.query.since) };
    },
  );

  app.get<{ Params: { vmId: string } }>(
    "/files/status/:vmId",
    { schema: { tags: ["Files"] } },
    async (req) => {
      const vmId = resolveVmId(req.params.vmId);
      return { content: getVmStatus(vmId) };
    },
  );

  app.get<{ Params: { type: string } }>(
    "/files/report/:type",
    { schema: { tags: ["Files"] } },
    async (req) => {
      return { content: getReport(req.params.type) };
    },
  );

  app.get<{ Params: { service: string } }>(
    "/files/secrets/:service",
    { schema: { tags: ["Files"] } },
    async (req) => {
      return { content: getSecretsStatus(req.params.service) };
    },
  );
}
