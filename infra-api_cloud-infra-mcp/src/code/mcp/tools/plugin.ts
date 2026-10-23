// infra_plugin: confined access to cloud-u-linux da_my-ai/data/claude/ (GitHub contents API, no shell).
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { PREFIX, pluginList, pluginRead, pluginWrite, pluginDeploy, type Fetch } from "../plugin-gh.js";

const token = () => process.env.GITHUB_TOKEN || process.env.GH_TOKEN || undefined;
const f: Fetch = (u, i) => fetch(u, i);
const run = async (fn: () => Promise<unknown>) => {
  try { return { content: [{ type: "text" as const, text: JSON.stringify(await fn(), null, 1) }] }; }
  catch (e) { return { content: [{ type: "text" as const, text: `ERROR: ${e instanceof Error ? e.message : String(e)}` }], isError: true as const }; }
};

export function registerPluginTools(server: McpServer): void {
  server.tool("plugin.plugin.list", `List plugin dir (read-only). cloud-u-linux ${PREFIX}`,
    { path: z.string().optional().describe(`repo path under ${PREFIX}; default root`) },
    (a: { path?: string }) => run(() => pluginList(f, a.path ?? PREFIX, token())));
  server.tool("plugin.plugin.read", `Read plugin file (read-only, <=64KB). cloud-u-linux ${PREFIX}`,
    { path: z.string().describe(`repo path starting ${PREFIX}`) },
    (a: { path: string }) => run(() => pluginRead(f, a.path, token())));
  server.tool("plugin.plugin.write", `Write plugin file: one-file commit to main of PUBLIC repo cloud-u-linux, confined to ${PREFIX}. Content is scanned and refused if it holds a secret or private/mesh IP. Max 64KB. Returns commit sha + CI run URL.`,
    {
      path: z.string().describe(`repo path starting ${PREFIX}`),
      content: z.string(),
      sha: z.string().describe("current blob sha (from plugin_read/plugin_list), or 'new' to create"),
      message: z.string().describe("commit message, <=200 chars"),
    },
    (a: { path: string; content: string; sha: string; message: string }) => run(() => pluginWrite(f, a, token())));
  server.tool("plugin.plugin.deploy", "Deploy plugin: dispatch the cloud-u-linux workflow running the my-ai dotfiles engine, or report not available yet.",
    (_extra: unknown) => run(() => pluginDeploy(f, token())));
}
