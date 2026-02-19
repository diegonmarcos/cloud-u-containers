import { z } from "zod";
import { rawHttpRequest } from "../utils/http.js";
import { CRAWLEE_API_TOKEN_PATH } from "../utils/paths.js";
import { readFileSync } from "fs";
// Crawlee Cloud API on oci-apps via WireGuard
const CRAWLEE_BASE = "http://10.0.0.6:3000";
let _token = null;
function getToken() {
    if (_token)
        return _token;
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
    }
    catch {
        throw new Error("Crawlee API token not found. Set CRAWLEE_API_TOKEN env var or create " +
            CRAWLEE_API_TOKEN_PATH);
    }
}
function crawleeApi(method, path, body, timeout) {
    const token = getToken();
    return rawHttpRequest(method, `${CRAWLEE_BASE}${path}`, body, timeout ?? 30_000, {
        Authorization: `Bearer ${token}`,
    });
}
function formatResult(label, result) {
    const data = typeof result.data === "string"
        ? result.data
        : JSON.stringify(result.data, null, 2);
    const truncated = data.length > 10000
        ? `...(truncated)\n${data.slice(-10000)}`
        : data;
    return {
        content: [{
                type: "text",
                text: `${label}: ${result.ok ? "OK" : "FAILED"} (HTTP ${result.status})\n\n${truncated}`,
            }],
        isError: !result.ok,
    };
}
export function registerCrawleeTools(server) {
    server.tool("crawlee_list_actors", "List all actors in Crawlee Cloud", {}, async () => {
        const result = crawleeApi("GET", "/v2/acts");
        return formatResult("GET /v2/acts", result);
    });
    server.tool("crawlee_run_actor", "Start a crawl by running an actor with input JSON. Returns the run object with runId.", {
        actorId: z.string().describe("Actor ID or name"),
        input: z.string().optional().describe("JSON input for the actor (e.g. URLs, config)"),
        timeout: z.number().optional().describe("Run timeout in seconds"),
        memory: z.number().optional().describe("Memory limit in MB"),
    }, async ({ actorId, input, timeout, memory }) => {
        const params = new URLSearchParams();
        if (timeout)
            params.set("timeout", String(timeout));
        if (memory)
            params.set("memory", String(memory));
        const qs = params.toString() ? `?${params}` : "";
        const result = crawleeApi("POST", `/v2/acts/${encodeURIComponent(actorId)}/runs${qs}`, input, 60_000);
        return formatResult(`POST /v2/acts/${actorId}/runs`, result);
    });
    server.tool("crawlee_list_runs", "List all actor runs with statuses", {}, async () => {
        const result = crawleeApi("GET", "/v2/actor-runs");
        return formatResult("GET /v2/actor-runs", result);
    });
    server.tool("crawlee_get_run", "Get a single run's status and details", {
        runId: z.string().describe("Run ID"),
    }, async ({ runId }) => {
        const result = crawleeApi("GET", `/v2/actor-runs/${encodeURIComponent(runId)}`);
        return formatResult(`GET /v2/actor-runs/${runId}`, result);
    });
    server.tool("crawlee_get_results", "Get crawl output data (dataset items) from a completed run", {
        runId: z.string().describe("Run ID"),
        limit: z.number().optional().describe("Max items to return"),
        offset: z.number().optional().describe("Skip first N items"),
    }, async ({ runId, limit, offset }) => {
        const params = new URLSearchParams();
        if (limit)
            params.set("limit", String(limit));
        if (offset)
            params.set("offset", String(offset));
        const qs = params.toString() ? `?${params}` : "";
        const result = crawleeApi("GET", `/v2/actor-runs/${encodeURIComponent(runId)}/dataset/items${qs}`);
        return formatResult(`GET /v2/actor-runs/${runId}/dataset/items`, result);
    });
    server.tool("crawlee_get_logs", "Get logs from an actor run", {
        runId: z.string().describe("Run ID"),
        limit: z.number().optional().describe("Max log lines to return"),
    }, async ({ runId, limit }) => {
        const params = new URLSearchParams();
        if (limit)
            params.set("limit", String(limit));
        const qs = params.toString() ? `?${params}` : "";
        const result = crawleeApi("GET", `/v2/actor-runs/${encodeURIComponent(runId)}/logs${qs}`);
        return formatResult(`GET /v2/actor-runs/${runId}/logs`, result);
    });
    server.tool("crawlee_abort_run", "Abort a running crawl", {
        runId: z.string().describe("Run ID to abort"),
    }, async ({ runId }) => {
        const result = crawleeApi("POST", `/v2/actor-runs/${encodeURIComponent(runId)}/abort`);
        return formatResult(`POST /v2/actor-runs/${runId}/abort`, result);
    });
}
//# sourceMappingURL=crawlee.js.map