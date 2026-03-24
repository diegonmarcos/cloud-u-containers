// ── Crawlee Exec — "Run & Abort" (2 tools) ──
// Execute and abort crawl actors

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rawHttpRequest, type HttpResult } from "../../shared/http.js";
import { CRAWLEE_API_TOKEN_PATH } from "../../shared/paths.js";
import { readFileSync } from "fs";

// Crawlee Cloud API on oci-apps via WireGuard
const CRAWLEE_BASE = "http://10.0.0.6:3000";

let _token: string | null = null;

function getToken(): string {
  if (_token) return _token;

  // Env var first
  const envToken = process.env.CRAWLEE_API_TOKEN;
  if (envToken) {
    _token = envToken;
    return _token;
  }

  // Vault file fallback
  try {
    _token = readFileSync(CRAWLEE_API_TOKEN_PATH, "utf-8").trim();
    return _token;
  } catch {
    throw new Error(
      "Crawlee API token not found. Set CRAWLEE_API_TOKEN env var or create " +
      CRAWLEE_API_TOKEN_PATH
    );
  }
}

function crawleeApi(method: string, path: string, body?: string, timeout?: number): HttpResult {
  const token = getToken();
  return rawHttpRequest(method, `${CRAWLEE_BASE}${path}`, body, timeout ?? 30_000, {
    Authorization: `Bearer ${token}`,
  });
}

function formatResult(label: string, result: HttpResult): { content: { type: "text"; text: string }[]; isError: boolean } {
  const data = typeof result.data === "string"
    ? result.data
    : JSON.stringify(result.data, null, 2);

  const truncated = data.length > 10000
    ? `...(truncated)\n${data.slice(-10000)}`
    : data;

  return {
    content: [{
      type: "text" as const,
      text: `${label}: ${result.ok ? "OK" : "FAILED"} (HTTP ${result.status})\n\n${truncated}`,
    }],
    isError: !result.ok,
  };
}

export function registerCrawleeExecTools(server: McpServer) {
  server.tool(
    "crawlee_run_actor",
    "Start a crawl by running an actor with input JSON. Returns the run object with runId.",
    {
      actorId: z.string().describe("Actor ID or name"),
      input: z.string().optional().describe("JSON input for the actor (e.g. URLs, config)"),
      timeout: z.number().optional().describe("Run timeout in seconds"),
      memory: z.number().optional().describe("Memory limit in MB"),
    },
    async ({ actorId, input, timeout, memory }) => {
      const params = new URLSearchParams();
      if (timeout) params.set("timeout", String(timeout));
      if (memory) params.set("memory", String(memory));
      const qs = params.toString() ? `?${params}` : "";

      const result = crawleeApi(
        "POST",
        `/v2/acts/${encodeURIComponent(actorId)}/runs${qs}`,
        input,
        60_000, // actor start can take a moment
      );
      return formatResult(`POST /v2/acts/${actorId}/runs`, result);
    }
  );

  server.tool(
    "crawlee_abort_run",
    "Abort a running crawl",
    {
      runId: z.string().describe("Run ID to abort"),
    },
    async ({ runId }) => {
      const result = crawleeApi(
        "POST",
        `/v2/actor-runs/${encodeURIComponent(runId)}/abort`,
      );
      return formatResult(`POST /v2/actor-runs/${runId}/abort`, result);
    }
  );
}
