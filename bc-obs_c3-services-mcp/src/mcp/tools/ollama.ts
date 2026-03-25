import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rawHttpRequest } from "../../shared/http.js";

const OLLAMA_BASE = "http://10.0.0.8:11434";

export function registerOllamaTools(server: McpServer) {
  server.tool(
    "infra.ollama.models",
    "List available Ollama models",
    {},
    async () => {
      const result = rawHttpRequest("GET", `${OLLAMA_BASE}/api/tags`);
      return {
        content: [{ type: "text" as const, text: JSON.stringify(result.ok ? result.data : { error: result.error }, null, 2) }],
      };
    }
  );

  server.tool(
    "infra.ollama.generate",
    "Generate text completion with Ollama",
    {
      model: z.string().describe("Model name (e.g. llama3)"),
      prompt: z.string().describe("Prompt text"),
    },
    async ({ model, prompt }) => {
      const result = rawHttpRequest("POST", `${OLLAMA_BASE}/api/generate`, JSON.stringify({
        model, prompt, stream: false,
      }), 120_000);
      return {
        content: [{ type: "text" as const, text: JSON.stringify(result.ok ? result.data : { error: result.error }, null, 2) }],
      };
    }
  );

  server.tool(
    "infra.ollama.chat",
    "Chat completion with Ollama",
    {
      model: z.string().describe("Model name (e.g. llama3)"),
      messages: z.array(z.object({
        role: z.string(),
        content: z.string(),
      })).describe("Chat messages"),
    },
    async ({ model, messages }) => {
      const result = rawHttpRequest("POST", `${OLLAMA_BASE}/api/chat`, JSON.stringify({
        model, messages, stream: false,
      }), 120_000);
      return {
        content: [{ type: "text" as const, text: JSON.stringify(result.ok ? result.data : { error: result.error }, null, 2) }],
      };
    }
  );
}
