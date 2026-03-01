import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import Fastify from "fastify";
import cors from "@fastify/cors";
import swagger from "@fastify/swagger";
import swaggerUi from "@fastify/swagger-ui";
import { authPlugin } from "./plugins/auth.js";
import { errorHandler } from "./plugins/error-handler.js";
import { registerHealthRoutes } from "./routes/health.js";
import { registerProfilingRoutes } from "./routes/profiling.js";
import { registerControlRoutes } from "./routes/control.js";
import { registerCloudRoutes } from "./routes/cloud.js";
import { registerServicesRoutes } from "./routes/services.js";
import { registerTopologyRoutes } from "./routes/topology.js";
import { registerTestsRoutes } from "./routes/tests.js";
import { registerFilesRoutes } from "./routes/files.js";
import { registerSecurityRoutes } from "./routes/security.js";
import { registerNotifyRoutes } from "./routes/notify.js";
import { registerDatabaseRoutes } from "./routes/database.js";

export async function buildApp() {
  const app = Fastify({
    logger: { level: "info" },
  });

  // CORS
  await app.register(cors, { origin: true });

  // OpenAPI / Swagger
  await app.register(swagger, {
    openapi: {
      info: {
        title: "C3 — Cloud Control Center API",
        version: "3.0.0",
        description: "Unified API for cloud infrastructure management. Replaces the Rust API.",
      },
      tags: [
        { name: "Health", description: "Health checks and tiered probes" },
        { name: "Profiling", description: "Container and VM diagnostics" },
        { name: "Control", description: "VM, container, and service lifecycle" },
        { name: "Cloud", description: "OCI and GCP cloud provider operations" },
        { name: "Services", description: "Service discovery and API specs" },
        { name: "Topology", description: "Declarative topology assembly" },
        { name: "Tests", description: "Dynamic infrastructure tests" },
        { name: "Files", description: "Config files, logs, reports, and secrets status" },
        { name: "Security", description: "Security scanning and auditing" },
        { name: "Notifications", description: "Push notifications via ntfy" },
        { name: "Database", description: "SQLite persistence and audit logs" },
      ],
    },
  });

  await app.register(swaggerUi, {
    routePrefix: "/docs",
  });

  // Dashboard — read once at startup, serve at /dash
  const __dirname = dirname(fileURLToPath(import.meta.url));
  const dashboardHtml = readFileSync(join(__dirname, "static", "dashboard.html"), "utf-8");
  app.get("/dash", async (_req, reply) => {
    reply.type("text/html").send(dashboardHtml);
  });

  // Auth
  await app.register(authPlugin);

  // Error handler
  app.setErrorHandler(errorHandler);

  // Routes (no prefix — Caddy handle_path /c3-api/* strips the prefix)
  await app.register(registerHealthRoutes);
  await app.register(registerProfilingRoutes);
  await app.register(registerControlRoutes);
  await app.register(registerCloudRoutes);
  await app.register(registerServicesRoutes);
  await app.register(registerTopologyRoutes);
  await app.register(registerTestsRoutes);
  await app.register(registerFilesRoutes);
  await app.register(registerSecurityRoutes);
  await app.register(registerNotifyRoutes);
  await app.register(registerDatabaseRoutes);

  return app;
}
