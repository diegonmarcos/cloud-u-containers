import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { existsSync } from "fs";
import { join } from "path";
import { exec } from "../utils/exec.js";
import { getServiceDir } from "../config.js";
import { BUILD_SCRIPT, SOLUTIONS_DIR } from "../utils/paths.js";

export function registerBuildTools(server: McpServer) {
  server.tool(
    "build_service",
    "Run build.sh for a specific service (build/secrets/ship/clean/all)",
    {
      service: z.string().describe("Service name"),
      step: z
        .enum(["build", "secrets", "ship", "docker", "deploy", "compose", "clean", "all"])
        .optional()
        .describe("Build step (default: all)"),
    },
    async ({ service, step }) => {
      const svcDir = getServiceDir(service);
      const buildSh = join(svcDir, "build.sh");

      if (!existsSync(buildSh)) {
        return {
          content: [{ type: "text", text: `No build.sh found for ${service} at ${svcDir}` }],
          isError: true,
        };
      }

      const result = exec("sh", [buildSh, step ?? "all"], {
        timeout: 120_000,
        cwd: svcDir,
      });

      return {
        content: [
          {
            type: "text",
            text: [
              `Build ${service} (${step ?? "all"}): ${result.ok ? "SUCCESS" : "FAILED"}`,
              `Exit code: ${result.exitCode}`,
              result.stdout ? `\n--- stdout ---\n${result.stdout.slice(-3000)}` : "",
              result.stderr ? `\n--- stderr ---\n${result.stderr.slice(-1000)}` : "",
            ].join("\n"),
          },
        ],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "build_all",
    "Run the root build.sh orchestrator to build all services",
    {
      dryRun: z.boolean().optional().describe("Dry run mode (default: false)"),
    },
    async ({ dryRun }) => {
      const args = [BUILD_SCRIPT, "build"];
      if (dryRun) args.unshift("-n");

      const result = exec("sh", args, {
        timeout: 300_000,
        cwd: SOLUTIONS_DIR,
      });

      return {
        content: [
          {
            type: "text",
            text: [
              `Build all: ${result.ok ? "SUCCESS" : "FAILED"}`,
              `Exit code: ${result.exitCode}`,
              result.stdout ? `\n--- stdout ---\n${result.stdout.slice(-5000)}` : "",
              result.stderr ? `\n--- stderr ---\n${result.stderr.slice(-2000)}` : "",
            ].join("\n"),
          },
        ],
        isError: !result.ok,
      };
    }
  );
}
