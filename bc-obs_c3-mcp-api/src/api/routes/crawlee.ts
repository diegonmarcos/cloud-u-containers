// ── Crawlee Routes — "Web scraping proxy" ──
// Proxies to Crawlee Cloud API (oci-apps:3000) via WireGuard.
// Provides OpenAPI/Swagger docs for an API that doesn't have its own spec.

import type { FastifyInstance } from "fastify";
import { rawHttpRequest } from "../../shared/http.js";
import { CRAWLEE_API_TOKEN_PATH } from "../../shared/paths.js";
import { readFileSync } from "fs";

const CRAWLEE_BASE = "http://10.0.0.6:3000";

let _token: string | null = null;

function getToken(): string {
  if (_token) return _token;
  const envToken = process.env.CRAWLEE_API_TOKEN;
  if (envToken) { _token = envToken; return _token; }
  try {
    _token = readFileSync(CRAWLEE_API_TOKEN_PATH, "utf-8").trim();
    return _token;
  } catch {
    throw new Error("Crawlee API token not found");
  }
}

function crawlee(method: string, path: string, body?: string, timeout?: number) {
  const token = getToken();
  const result = rawHttpRequest(method, `${CRAWLEE_BASE}${path}`, body, timeout ?? 30_000, {
    Authorization: `Bearer ${token}`,
  });
  return result.data;
}

// Shared schema fragments
const P_actorId = {
  type: "object" as const,
  properties: { actorId: { type: "string" as const } },
  required: ["actorId"],
};
const P_runId = {
  type: "object" as const,
  properties: { runId: { type: "string" as const } },
  required: ["runId"],
};

export async function registerCrawleeRoutes(app: FastifyInstance) {
  app.get("/crawlee/actors", {
    schema: {
      tags: ["Crawlee"],
      summary: "List all actors",
    },
  }, async () => {
    return crawlee("GET", "/v2/acts");
  });

  app.get<{ Params: { actorId: string } }>("/crawlee/actors/:actorId", {
    schema: {
      tags: ["Crawlee"],
      summary: "Get actor details",
      params: P_actorId,
    },
  }, async (req) => {
    return crawlee("GET", `/v2/acts/${encodeURIComponent(req.params.actorId)}`);
  });

  app.post<{ Params: { actorId: string }; Body: { input?: string; timeout?: number; memory?: number } }>(
    "/crawlee/actors/:actorId/run",
    {
      schema: {
        tags: ["Crawlee"],
        summary: "Run an actor",
        params: P_actorId,
        body: {
          type: "object",
          properties: {
            input: { type: "string", description: "JSON input for the actor" },
            timeout: { type: "number", description: "Run timeout in seconds" },
            memory: { type: "number", description: "Memory limit in MB" },
          },
        },
      },
    },
    async (req) => {
      const { input, timeout, memory } = req.body ?? {};
      const params = new URLSearchParams();
      if (timeout) params.set("timeout", String(timeout));
      if (memory) params.set("memory", String(memory));
      const qs = params.toString() ? `?${params}` : "";
      return crawlee(
        "POST",
        `/v2/acts/${encodeURIComponent(req.params.actorId)}/runs${qs}`,
        input,
        60_000,
      );
    },
  );

  app.get("/crawlee/runs", {
    schema: {
      tags: ["Crawlee"],
      summary: "List all actor runs",
    },
  }, async () => {
    return crawlee("GET", "/v2/actor-runs");
  });

  app.get<{ Params: { runId: string } }>("/crawlee/runs/:runId", {
    schema: {
      tags: ["Crawlee"],
      summary: "Get run status and details",
      params: P_runId,
    },
  }, async (req) => {
    return crawlee("GET", `/v2/actor-runs/${encodeURIComponent(req.params.runId)}`);
  });

  app.get<{ Params: { runId: string }; Querystring: { limit?: number; offset?: number } }>(
    "/crawlee/runs/:runId/dataset",
    {
      schema: {
        tags: ["Crawlee"],
        summary: "Get crawl results (dataset items)",
        params: P_runId,
        querystring: {
          type: "object",
          properties: {
            limit: { type: "number", description: "Max items to return" },
            offset: { type: "number", description: "Skip first N items" },
          },
        },
      },
    },
    async (req) => {
      const params = new URLSearchParams();
      if (req.query.limit) params.set("limit", String(req.query.limit));
      if (req.query.offset) params.set("offset", String(req.query.offset));
      const qs = params.toString() ? `?${params}` : "";
      return crawlee("GET", `/v2/actor-runs/${encodeURIComponent(req.params.runId)}/dataset/items${qs}`);
    },
  );

  app.get<{ Params: { runId: string }; Querystring: { limit?: number } }>(
    "/crawlee/runs/:runId/logs",
    {
      schema: {
        tags: ["Crawlee"],
        summary: "Get logs from an actor run",
        params: P_runId,
        querystring: {
          type: "object",
          properties: {
            limit: { type: "number", description: "Max log lines" },
          },
        },
      },
    },
    async (req) => {
      const params = new URLSearchParams();
      if (req.query.limit) params.set("limit", String(req.query.limit));
      const qs = params.toString() ? `?${params}` : "";
      return crawlee("GET", `/v2/actor-runs/${encodeURIComponent(req.params.runId)}/logs${qs}`);
    },
  );

  app.post<{ Params: { runId: string } }>("/crawlee/runs/:runId/abort", {
    schema: {
      tags: ["Crawlee"],
      summary: "Abort a running crawl",
      params: P_runId,
    },
  }, async (req) => {
    return crawlee("POST", `/v2/actor-runs/${encodeURIComponent(req.params.runId)}/abort`);
  });
}
