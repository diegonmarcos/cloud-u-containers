// ── Operations Routes — "How we run it" ──
// VM, container, and service lifecycle control + push events

import type { FastifyInstance } from "fastify";
import {
  vmStart, vmStop, vmReset,
  containerStart, containerStop, containerRestart,
  serviceStart, serviceStop,
} from "../../shared/control.js";
import { handlePushEvent } from "../../shared/ops.js";

const vmIdParams = { type: "object" as const, properties: { vmId: { type: "string" as const } }, required: ["vmId"] };
const vmContainerParams = { type: "object" as const, properties: { vmId: { type: "string" as const }, name: { type: "string" as const } }, required: ["vmId", "name"] };
const vmServiceParams = { type: "object" as const, properties: { vmId: { type: "string" as const }, service: { type: "string" as const } }, required: ["vmId", "service"] };

export async function registerOperationsRoutes(app: FastifyInstance) {
  // VM lifecycle
  app.post<{ Params: { vmId: string } }>(
    "/vms/:vmId/start",
    { schema: { tags: ["Operations"], params: vmIdParams } },
    async (req) => vmStart(req.params.vmId),
  );

  app.post<{ Params: { vmId: string } }>(
    "/vms/:vmId/stop",
    { schema: { tags: ["Operations"], params: vmIdParams } },
    async (req) => vmStop(req.params.vmId),
  );

  app.post<{ Params: { vmId: string } }>(
    "/vms/:vmId/reset",
    { schema: { tags: ["Operations"], params: vmIdParams } },
    async (req) => vmReset(req.params.vmId),
  );

  // Container lifecycle
  app.post<{ Params: { vmId: string; name: string } }>(
    "/vms/:vmId/containers/:name/start",
    { schema: { tags: ["Operations"], params: vmContainerParams } },
    async (req) => containerStart(req.params.vmId, req.params.name),
  );

  app.post<{ Params: { vmId: string; name: string } }>(
    "/vms/:vmId/containers/:name/stop",
    { schema: { tags: ["Operations"], params: vmContainerParams } },
    async (req) => containerStop(req.params.vmId, req.params.name),
  );

  app.post<{ Params: { vmId: string; name: string } }>(
    "/vms/:vmId/containers/:name/restart",
    { schema: { tags: ["Operations"], params: vmContainerParams } },
    async (req) => containerRestart(req.params.vmId, req.params.name),
  );

  // Service lifecycle
  app.post<{ Params: { vmId: string; service: string } }>(
    "/vms/:vmId/services/:service/start",
    { schema: { tags: ["Operations"], params: vmServiceParams } },
    async (req) => serviceStart(req.params.vmId, req.params.service),
  );

  app.post<{ Params: { vmId: string; service: string } }>(
    "/vms/:vmId/services/:service/stop",
    { schema: { tags: ["Operations"], params: vmServiceParams } },
    async (req) => serviceStop(req.params.vmId, req.params.service),
  );

  // ── Push event (GHA → C3 → Dagu) ──

  app.post<{ Body: {
    ref?: string;
    repo?: string;
    sender?: string;
    head_commit?: { id: string; message: string; timestamp: string };
    commits?: Array<{ id: string; message: string; added: string[]; modified: string[]; removed: string[] }>;
    modified_files?: string[];
  } }>(
    "/ops/push-event",
    {
      schema: {
        tags: ["Operations"],
        body: {
          type: "object" as const,
          properties: {
            ref: { type: "string" as const },
            repo: { type: "string" as const },
            sender: { type: "string" as const },
            head_commit: { type: "object" as const },
            commits: { type: "array" as const },
            modified_files: { type: "array" as const, items: { type: "string" as const } },
          },
        },
      },
    },
    async (req) => handlePushEvent(req.body),
  );
}
