import type { FastifyInstance } from "fastify";
import { runTestSuite } from "../../shared/tests.js";

type SuiteName = "connectivity" | "dns" | "tls" | "routes" | "containers" | "wireguard" | "full";
const VALID_SUITES = new Set<string>(["connectivity", "dns", "tls", "routes", "containers", "wireguard", "full"]);

export async function registerTestsRoutes(app: FastifyInstance) {
  app.get<{ Params: { suite: string } }>(
    "/tests/run/:suite",
    { schema: { tags: ["Tests"] } },
    async (req, reply) => {
      const { suite } = req.params;
      if (!VALID_SUITES.has(suite)) {
        reply.code(400).send({ error: `Invalid suite: ${suite}. Valid: ${Array.from(VALID_SUITES).join(", ")}` });
        return;
      }
      return runTestSuite(suite as SuiteName);
    },
  );

  app.get<{ Params: { suite: string; target: string } }>(
    "/tests/run/:suite/:target",
    { schema: { tags: ["Tests"] } },
    async (req, reply) => {
      const { suite, target } = req.params;
      if (!VALID_SUITES.has(suite)) {
        reply.code(400).send({ error: `Invalid suite: ${suite}. Valid: ${Array.from(VALID_SUITES).join(", ")}` });
        return;
      }
      return runTestSuite(suite as SuiteName, target);
    },
  );

  // Convenience shortcuts
  for (const suite of VALID_SUITES) {
    app.get(`/tests/${suite}`, { schema: { tags: ["Tests"] } }, async () => {
      return runTestSuite(suite as SuiteName);
    });
  }
}
