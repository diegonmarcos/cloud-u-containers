import type { FastifyInstance } from "fastify";

export async function registerHealth(app: FastifyInstance) {
  // GET /health — liveness. Public. No dependencies checked.
  app.get("/health", async () => ({ status: "ok" }));

  // GET /ready — readiness. Public. Confirms the process is past boot and
  // wired up. (We don't probe SMTP/analytics backends here on purpose:
  // a single flaky upstream should not flap the listener as a whole.)
  app.get("/ready", async () => ({ status: "ready" }));
}
