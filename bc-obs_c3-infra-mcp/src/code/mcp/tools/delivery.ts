// ── Delivery Pillar — "How we ship" (6 tools) ──
// Build, deploy, Docker build, secrets, backup

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { exec } from "../../shared/libs/exec.js";
import { sshExec } from "../../shared/libs/ssh.js";
import { getConfig, getServiceDir, getServiceFolder, resolveVmId, getVmSshAlias } from "../../shared/libs/config.js";
import { BUILD_SCRIPT, SOLUTIONS_DIR } from "../../shared/libs/paths.js";
import { audit } from "../../shared/libs/audit.js";

const SAFE_NAME_RE = /^[a-zA-Z0-9_.-]+$/;

function validatePath(path: string): void {
  if (!SAFE_NAME_RE.test(path)) {
    throw new Error(`Invalid path component: ${path}`);
  }
}

export function registerDeliveryTools(server: McpServer) {
  // ── Build (2 tools, from build.ts) ──

  server.tool(
    "devops.build.service",
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
    "devops.build.all",
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

  // ── Ship & Docker (2 tools, from native-ops.ts) ──

  server.tool(
    "devops.build.ship",
    "Run full deployment pipeline: build → secrets → deploy → compose (build.sh ship)",
    {
      service: z.string().describe("Service name to deploy"),
    },
    async ({ service }) => {
      const svcDir = getServiceDir(service);
      const buildSh = join(svcDir, "build.sh");

      if (!existsSync(buildSh)) {
        return {
          content: [{ type: "text" as const, text: `No build.sh found for ${service} at ${svcDir}` }],
          isError: true,
        };
      }

      const result = exec("sh", [buildSh, "ship"], {
        timeout: 300_000,
        cwd: svcDir,
      });
      audit("devops.build.ship", service, result.ok ? "OK" : `FAILED (exit ${result.exitCode})`);

      return {
        content: [{
          type: "text" as const,
          text: [
            `Ship ${service}: ${result.ok ? "SUCCESS" : "FAILED"}`,
            `Exit code: ${result.exitCode}`,
            result.stdout ? `\n--- stdout ---\n${result.stdout.slice(-5000)}` : "",
            result.stderr ? `\n--- stderr ---\n${result.stderr.slice(-2000)}` : "",
          ].join("\n"),
        }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "devops.build.docker",
    "Build and push Docker image for a service (build.sh docker)",
    {
      service: z.string().describe("Service name"),
    },
    async ({ service }) => {
      const svcDir = getServiceDir(service);
      const buildSh = join(svcDir, "build.sh");

      if (!existsSync(buildSh)) {
        return {
          content: [{ type: "text" as const, text: `No build.sh found for ${service} at ${svcDir}` }],
          isError: true,
        };
      }

      const result = exec("sh", [buildSh, "docker"], {
        timeout: 600_000,
        cwd: svcDir,
      });

      return {
        content: [{
          type: "text" as const,
          text: [
            `Docker build ${service}: ${result.ok ? "SUCCESS" : "FAILED"}`,
            `Exit code: ${result.exitCode}`,
            result.stdout ? `\n--- stdout ---\n${result.stdout.slice(-5000)}` : "",
            result.stderr ? `\n--- stderr ---\n${result.stderr.slice(-2000)}` : "",
          ].join("\n"),
        }],
        isError: !result.ok,
      };
    }
  );

  // ── Secrets & Backup (2 tools, from native-ops.ts) ──

  server.tool(
    "devops.build.secrets_status",
    "Show secrets encryption status for services",
    {
      service: z.string().optional().describe("Service name (omit for all services)"),
    },
    async ({ service }) => {
      const config = getConfig();
      const services = service
        ? { [service]: config.services[service] }
        : config.services;

      if (service && !config.services[service]) {
        return {
          content: [{ type: "text" as const, text: `Unknown service: ${service}` }],
          isError: true,
        };
      }

      const lines: string[] = ["# Secrets Status", ""];

      for (const [name, svc] of Object.entries(services)) {
        if (!svc) continue;
        const svcDir = getServiceDir(name);
        const secretsYaml = join(svcDir, "src", "secrets.yaml");
        const secretsDir = join(svcDir, "dist", ".secrets");

        let status = "no secrets.yaml";
        if (existsSync(secretsYaml)) {
          try {
            const content = readFileSync(secretsYaml, "utf-8");
            const hasSops = content.includes("sops:") || content.includes("ENC[AES256_GCM");
            status = hasSops ? "encrypted (sops)" : "PLAINTEXT WARNING";
          } catch {
            status = "read error";
          }
        }

        const hasDistSecrets = existsSync(secretsDir);

        lines.push(`**${name}** (${svc.vm}): ${status}${hasDistSecrets ? " | dist/.secrets exists" : ""}`);
      }

      return {
        content: [{ type: "text" as const, text: lines.join("\n") }],
      };
    }
  );

  server.tool(
    "devops.build.backup",
    "Trigger backup for a service's data (borg=media files, bup=general files, db=database dump)",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      service: z.string().describe("Service name with backup configured"),
      type: z.enum(["borg", "bup", "db"]).optional().describe("Backup type (default: borg)"),
    },
    async ({ vm, service, type }) => {
      const vmId = resolveVmId(vm);
      const config = getConfig();
      const svc = config.services[service];

      if (!svc) {
        return {
          content: [{ type: "text" as const, text: `Unknown service: ${service}` }],
          isError: true,
        };
      }

      const remoteBase = config.remote_base;
      const folder = getServiceFolder(service);
      validatePath(folder);
      const remotePath = `${remoteBase}/${folder}`;
      const backupType = type ?? "borg";

      const cmd = `cd ${remotePath} && docker compose run --rm backup-${backupType} 2>&1 || docker compose run --rm backup 2>&1`;

      const result = sshExec(vmId, cmd, 300_000);
      audit("devops.build.backup", `${backupType} ${service}@${getVmSshAlias(vmId)}`, result.ok ? "OK" : `FAILED (exit ${result.exitCode})`);

      return {
        content: [{
          type: "text" as const,
          text: [
            `Backup ${backupType} for ${service}@${vm}: ${result.ok ? "SUCCESS" : "FAILED"}`,
            `Exit code: ${result.exitCode}`,
            result.stdout ? `\n--- output ---\n${result.stdout.slice(-3000)}` : "",
            result.stderr ? `\n--- stderr ---\n${result.stderr.slice(-1000)}` : "",
          ].join("\n"),
        }],
        isError: !result.ok,
      };
    }
  );
}
