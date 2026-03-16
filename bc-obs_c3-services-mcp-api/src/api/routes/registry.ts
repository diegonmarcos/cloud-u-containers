import type { FastifyInstance } from "fastify";
import { registry } from "../../registry/index.js";

export async function registerRegistryRoutes(app: FastifyInstance) {
  app.get("/health", {
    schema: { hide: true },
  }, async () => {
    return { status: "ok", service: "c3-services-mcp-api", version: "1.0.0" };
  });

  app.get("/", {
    schema: {
      tags: ["Registry"],
      summary: "List all services with API status",
      response: {
        200: {
          type: "object",
          properties: {
            services: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  name: { type: "string" },
                  displayName: { type: "string" },
                  description: { type: "string" },
                  vm: { type: "string" },
                  apiType: { type: "string" },
                  endpointCount: { type: "number" },
                  hasSpec: { type: "boolean" },
                },
              },
            },
            total: { type: "number" },
          },
        },
      },
    },
  }, async () => {
    const services = registry.list().map((s) => ({
      name: s.name,
      displayName: s.displayName,
      description: s.description,
      vm: s.vm,
      apiType: s.api.type,
      endpointCount: s.api.endpointCount,
      hasSpec: !!s.api.specUrl,
    }));
    return { services, total: services.length };
  });

  app.get<{ Params: { service: string } }>("/:service", {
    schema: {
      tags: ["Registry"],
      summary: "Get service detail",
      params: {
        type: "object",
        properties: { service: { type: "string" } },
        required: ["service"],
      },
    },
  }, async (req, reply) => {
    const svc = registry.get(req.params.service);
    if (!svc) {
      reply.code(404);
      return { error: `Service '${req.params.service}' not found` };
    }
    return svc;
  });

  app.get<{ Params: { service: string } }>("/:service/spec", {
    schema: {
      tags: ["Registry"],
      summary: "Get OpenAPI spec for a service",
      params: {
        type: "object",
        properties: { service: { type: "string" } },
        required: ["service"],
      },
    },
  }, async (req, reply) => {
    const svc = registry.get(req.params.service);
    if (!svc) {
      reply.code(404);
      return { error: `Service '${req.params.service}' not found` };
    }
    if (!svc.api.specUrl) {
      reply.code(404);
      return { error: `Service '${req.params.service}' has no OpenAPI spec` };
    }
    const spec = await registry.fetchSpec(req.params.service);
    if (!spec) {
      reply.code(502);
      return { error: "Failed to fetch spec from service" };
    }
    return spec;
  });
}
