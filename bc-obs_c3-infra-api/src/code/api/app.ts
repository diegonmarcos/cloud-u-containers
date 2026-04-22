import Fastify from "fastify";
import cors from "@fastify/cors";
import swagger from "@fastify/swagger";
import swaggerUi from "@fastify/swagger-ui";
import { authPlugin } from "./plugins/auth.js";
import { errorHandler } from "./plugins/error-handler.js";

// ── 6 Pillars ────────────────────────────────────
import { registerInventoryRoutes } from "./routes/inventory.js";
import { registerOperationsRoutes } from "./routes/operations.js";
import { registerObservabilityRoutes } from "./routes/observability.js";
import { registerSecurityRoutes } from "./routes/security.js";
import { registerFinOpsRoutes } from "./routes/finops.js";

export async function buildApp() {
  const app = Fastify({
    logger: { level: "info" },
  });

  // CORS
  await app.register(cors, { origin: true, credentials: true });

  // OpenAPI / Swagger
  await app.register(swagger, {
    openapi: {
      info: {
        title: "C3 — Cloud Control Center API",
        version: "3.0.0",
        description: "Unified API for cloud infrastructure management. Replaces the Rust API.",
      },
      tags: [
        { name: "Inventory", description: "Service catalog, topology, config, and discovery" },
        { name: "Delivery", description: "Build, deploy, and CI/CD pipeline" },
        { name: "Operations", description: "VM, container, and service lifecycle control" },
        { name: "Observability", description: "Health, profiling, diagnostics, testing, and alerting" },
        { name: "Security", description: "Security scanning, auditing, and compliance" },
        { name: "FinOps", description: "Cloud provider operations and cost tracking" },
      ],
    },
  });

  await app.register(swaggerUi, {
    routePrefix: "/docs",
  });

  // Auth
  await app.register(authPlugin);

  // Error handler
  app.setErrorHandler(errorHandler);

  // Routes (no prefix — Caddy handle_path /c3-api/* strips the prefix)
  // Note: Delivery pillar is MCP-only (build/deploy), no REST routes
  await app.register(registerInventoryRoutes);
  await app.register(registerOperationsRoutes);
  await app.register(registerObservabilityRoutes);
  await app.register(registerSecurityRoutes);
  await app.register(registerFinOpsRoutes);

  return app;
}
