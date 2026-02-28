import type { FastifyInstance } from "fastify";
import {
  vmStart, vmStop, vmReset,
  containerStart, containerStop, containerRestart,
  serviceStart, serviceStop,
} from "../../shared/control.js";

export async function registerControlRoutes(app: FastifyInstance) {
  // VM lifecycle
  app.post<{ Params: { vmId: string } }>(
    "/vms/:vmId/start",
    { schema: { tags: ["Control"] } },
    async (req) => vmStart(req.params.vmId),
  );

  app.post<{ Params: { vmId: string } }>(
    "/vms/:vmId/stop",
    { schema: { tags: ["Control"] } },
    async (req) => vmStop(req.params.vmId),
  );

  app.post<{ Params: { vmId: string } }>(
    "/vms/:vmId/reset",
    { schema: { tags: ["Control"] } },
    async (req) => vmReset(req.params.vmId),
  );

  // Container lifecycle
  app.post<{ Params: { vmId: string; name: string } }>(
    "/vms/:vmId/containers/:name/start",
    { schema: { tags: ["Control"] } },
    async (req) => containerStart(req.params.vmId, req.params.name),
  );

  app.post<{ Params: { vmId: string; name: string } }>(
    "/vms/:vmId/containers/:name/stop",
    { schema: { tags: ["Control"] } },
    async (req) => containerStop(req.params.vmId, req.params.name),
  );

  app.post<{ Params: { vmId: string; name: string } }>(
    "/vms/:vmId/containers/:name/restart",
    { schema: { tags: ["Control"] } },
    async (req) => containerRestart(req.params.vmId, req.params.name),
  );

  // Service lifecycle
  app.post<{ Params: { vmId: string; service: string } }>(
    "/vms/:vmId/services/:service/start",
    { schema: { tags: ["Control"] } },
    async (req) => serviceStart(req.params.vmId, req.params.service),
  );

  app.post<{ Params: { vmId: string; service: string } }>(
    "/vms/:vmId/services/:service/stop",
    { schema: { tags: ["Control"] } },
    async (req) => serviceStop(req.params.vmId, req.params.service),
  );
}
