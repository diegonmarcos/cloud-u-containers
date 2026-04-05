import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rawHttpRequest } from "../../shared/http.js";

// ── Ollama instances from topology ──────────────────────────────────────
// Each instance gets its own set of tools, prefixed by instance name.
interface OllamaInstance {
  id: string;         // tool prefix: infra.ollama-<id>.models
  label: string;      // human label in descriptions
  base: string;       // http://wg_ip:port
}

const INSTANCES: OllamaInstance[] = [
  { id: "gpu",  label: "Ollama GPU (gcp-t4, T4 GPU)",    base: "http://10.0.0.8:11434" },
  { id: "arm",  label: "Ollama ARM (oci-apps, A1 CPU)",  base: "http://10.0.0.6:11435" },
];

function registerInstance(server: McpServer, inst: OllamaInstance) {
  const prefix = `infra.ollama-${inst.id}`;

  server.tool(
    `${prefix}.models`,
    `List available models on ${inst.label}`,
    {},
    async () => {
      const result = rawHttpRequest("GET", `${inst.base}/api/tags`);
      return {
        content: [{ type: "text" as const, text: JSON.stringify(result.ok ? result.data : { error: result.error }, null, 2) }],
      };
    }
  );

  server.tool(
    `${prefix}.generate`,
    `Generate text completion on ${inst.label}`,
    {
      model: z.string().describe("Model name (e.g. llama3)"),
      prompt: z.string().describe("Prompt text"),
    },
    async ({ model, prompt }) => {
      const result = rawHttpRequest("POST", `${inst.base}/api/generate`, JSON.stringify({
        model, prompt, stream: false,
      }), 120_000);
      return {
        content: [{ type: "text" as const, text: JSON.stringify(result.ok ? result.data : { error: result.error }, null, 2) }],
      };
    }
  );

  server.tool(
    `${prefix}.chat`,
    `Chat completion on ${inst.label}`,
    {
      model: z.string().describe("Model name (e.g. llama3)"),
      messages: z.array(z.object({
        role: z.string(),
        content: z.string(),
      })).describe("Chat messages"),
    },
    async ({ model, messages }) => {
      const result = rawHttpRequest("POST", `${inst.base}/api/chat`, JSON.stringify({
        model, messages, stream: false,
      }), 120_000);
      return {
        content: [{ type: "text" as const, text: JSON.stringify(result.ok ? result.data : { error: result.error }, null, 2) }],
      };
    }
  );
}

export function registerOllamaTools(server: McpServer) {
  for (const inst of INSTANCES) {
    registerInstance(server, inst);
  }
}
