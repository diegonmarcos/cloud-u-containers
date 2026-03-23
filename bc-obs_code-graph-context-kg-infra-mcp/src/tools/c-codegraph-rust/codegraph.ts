import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

// CodeGraph-Rust — https://github.com/Jakedismo/codegraph-rust
// AST-based code knowledge graph using SurrealDB + FAISS + Tree-sitter.
// Not yet deployed. These stubs exist as reference for future integration.

const NOT_DEPLOYED = "CodeGraph-Rust is not yet deployed. This tool is reserved for future integration.\nRepo: https://github.com/Jakedismo/codegraph-rust";

export function registerCodegraphTools(server: McpServer): void {
  server.tool(
    "codegraph_trace_call_path",
    "[Future] Trace the full call chain between two functions using CodeGraph-Rust's graph database",
    {
      from_function: z.string().describe("Source function name (e.g. 'handleLogin')"),
      to_function: z.string().describe("Target function name (e.g. 'queryDatabase')"),
    },
    async () => ({ content: [{ type: "text" as const, text: NOT_DEPLOYED }] })
  );

  server.tool(
    "codegraph_impact_analysis",
    "[Future] Analyze what code would be affected by changing a specific function or class",
    {
      target: z.string().describe("Function, class, or file to analyze impact for"),
      depth: z.number().optional().default(3).describe("How many hops deep to trace dependencies"),
    },
    async () => ({ content: [{ type: "text" as const, text: NOT_DEPLOYED }] })
  );

  server.tool(
    "codegraph_dependencies",
    "[Future] Query the full dependency graph for a module, file, or function",
    {
      target: z.string().describe("Module, file, or function to query dependencies for"),
      direction: z.enum(["upstream", "downstream", "both"]).optional().default("both").describe("Direction of dependencies to trace"),
    },
    async () => ({ content: [{ type: "text" as const, text: NOT_DEPLOYED }] })
  );
}
