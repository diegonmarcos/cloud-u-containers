// ── Delivery Pillar — "How we ship" (7 tools) ──
// Build, deploy, Docker build, secrets, backup, repo create

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { exec } from "../../shared/libs/exec.js";
import { sshExec } from "../../shared/libs/ssh.js";
import { getConfig, getServiceDir, getServiceFolder, resolveVmId, getVmSshAlias, composeCd } from "../../shared/libs/config.js";
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
    "Run build.sh for a specific service (build/secrets/ship/clean/all). Executes on the oci-apps ARM runner via cloud-infra-mcp. For x86 builds use devops.workflows.gha_trigger (GHA runner).",
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
    "Run the root build.sh orchestrator to build all services. Executes on the oci-apps ARM runner via cloud-infra-mcp. For x86 or multi-arch use devops.workflows.gha_trigger.",
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
    "Run full deployment pipeline on the oci-apps ARM runner: build → secrets → deploy → compose (cloud/build.sh ship). For x86 services or multi-arch use devops.workflows.gha_trigger (GHA x86 runner, ship.yml).",
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
    "Build and push Docker image for a service on the oci-apps ARM runner (build.sh docker). Produces arm64 image only. For x86_64 or multi-arch images use devops.workflows.gha_trigger.",
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

      const cmd = `${composeCd(remotePath)} && (docker compose run --rm backup-${backupType} 2>&1 || docker compose run --rm backup 2>&1)`;

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

  // ── Repo (1 tool) ──

  server.tool(
    "devops.repo.create",
    "Create a GitHub repository via the gh CLI. Private by default — pass visibility 'public' to publish.",
    {
      name: z.string().describe("Repository name, or owner/name to create under an org"),
      visibility: z.enum(["private", "public"]).optional().describe("Visibility (default: private)"),
      description: z.string().optional().describe("Repository description"),
      dryRun: z.boolean().optional().describe("Print the gh command without running it (default: false)"),
    },
    async ({ name, visibility, description, dryRun }) => {
      for (const part of name.split("/")) validatePath(part);

      const args = ["repo", "create", name, `--${visibility ?? "private"}`];
      if (description) args.push("--description", description);

      if (dryRun) {
        return { content: [{ type: "text" as const, text: `DRY RUN: gh ${args.join(" ")}` }] };
      }

      const result = exec("gh", args, { timeout: 30_000 });
      audit("devops.repo.create", name, result.ok ? "OK" : `FAILED (exit ${result.exitCode})`);

      return {
        content: [{
          type: "text" as const,
          text: [
            `Create repo ${name} (${visibility ?? "private"}): ${result.ok ? "SUCCESS" : "FAILED"}`,
            `Exit code: ${result.exitCode}`,
            result.stdout ? `\n--- stdout ---\n${result.stdout.slice(-2000)}` : "",
            result.stderr ? `\n--- stderr ---\n${result.stderr.slice(-2000)}` : "",
          ].join("\n"),
        }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "devops.repo.rename",
    "Rename a GitHub repository via the gh CLI (owner unchanged). GitHub keeps a permanent-ish redirect from the old name.",
    {
      repo: z.string().describe("Existing repo as owner/name, e.g. diegonmarcos/cloud-data-my-ai-memory"),
      newName: z.string().describe("New repository name only (not owner/name)"),
      dryRun: z.boolean().optional().describe("Print the gh command without running it (default: false)"),
    },
    async ({ repo, newName, dryRun }) => {
      for (const part of repo.split("/")) validatePath(part);
      validatePath(newName);

      const args = ["repo", "rename", newName, "-R", repo, "--yes"];
      if (dryRun) {
        return { content: [{ type: "text" as const, text: `DRY RUN: gh ${args.join(" ")}` }] };
      }

      const result = exec("gh", args, { timeout: 30_000 });
      audit("devops.repo.rename", `${repo} -> ${newName}`, result.ok ? "OK" : `FAILED (exit ${result.exitCode})`);

      return {
        content: [{
          type: "text" as const,
          text: [
            `Rename ${repo} -> ${newName}: ${result.ok ? "SUCCESS" : "FAILED"}`,
            `Exit code: ${result.exitCode}`,
            result.stdout ? `\n--- stdout ---\n${result.stdout.slice(-2000)}` : "",
            result.stderr ? `\n--- stderr ---\n${result.stderr.slice(-2000)}` : "",
          ].join("\n"),
        }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "devops.repo.delete_branch",
    "Delete a branch (git ref) from a GitHub repository via the gh API. Irreversible for the ref; commits survive if merged elsewhere.",
    {
      repo: z.string().describe("owner/name, e.g. diegonmarcos/cloud"),
      branch: z.string().describe("Branch name to delete, e.g. feature/foo (may contain slashes)"),
      dryRun: z.boolean().optional().describe("Print the gh command without running it (default: false)"),
    },
    async ({ repo, branch, dryRun }) => {
      for (const part of repo.split("/")) validatePath(part);
      // branch names legitimately contain '/', so validate each path segment
      for (const part of branch.split("/")) validatePath(part);

      const ref = `/repos/${repo}/git/refs/heads/${branch}`;
      const args = ["api", "--method", "DELETE", ref];
      if (dryRun) {
        return { content: [{ type: "text" as const, text: `DRY RUN: gh ${args.join(" ")}` }] };
      }

      const result = exec("gh", args, { timeout: 30_000 });
      audit("devops.repo.delete_branch", `${repo}#${branch}`, result.ok ? "OK" : `FAILED (exit ${result.exitCode})`);

      return {
        content: [{
          type: "text" as const,
          text: [
            `Delete branch ${repo}#${branch}: ${result.ok ? "SUCCESS" : "FAILED"}`,
            `Exit code: ${result.exitCode}`,
            result.stdout ? `\n--- stdout ---\n${result.stdout.slice(-2000)}` : "",
            result.stderr ? `\n--- stderr ---\n${result.stderr.slice(-2000)}` : "",
          ].join("\n"),
        }],
        isError: !result.ok,
      };
    }
  );

  // ── GitHub Actions secrets (3 tools) ──
  // These are the *GHA* secrets a workflow reads via ${{ secrets.NAME }} — a
  // different store from the sops-encrypted service secrets that
  // devops.build.secrets_status reports on. Both are called "secrets"; they
  // never mix.

  server.tool(
    "devops.secrets.list",
    "List GitHub Actions secret NAMES for a repo (values are never retrievable — GitHub stores them write-only).",
    {
      repo: z.string().describe("owner/repo, e.g. diegonmarcos/cloud-unix"),
    },
    async ({ repo }) => {
      for (const part of repo.split("/")) validatePath(part);

      const result = exec("gh", ["secret", "list", "--repo", repo], { timeout: 30_000 });

      return {
        content: [{
          type: "text" as const,
          text: result.ok
            ? `GHA secrets in ${repo}:\n${result.stdout.trim() || "(none)"}`
            : `Failed to list secrets in ${repo} (exit ${result.exitCode})\n${result.stderr.slice(-2000)}`,
        }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "devops.secrets.set",
    "Create or update a GitHub Actions secret. Overwrites silently if the name already exists. The value is passed via stdin, never argv, so it cannot leak through the process table.",
    {
      repo: z.string().describe("owner/repo, e.g. diegonmarcos/cloud-unix"),
      name: z.string().describe("Secret name, e.g. BITWARDEN_PACKAGES_TOKEN"),
      value: z.string().describe("Secret value — written to stdin, not logged"),
    },
    async ({ repo, name, value }) => {
      for (const part of repo.split("/")) validatePath(part);
      validatePath(name);

      // --body - reads the value from stdin. Passing it as an argv element would
      // expose it to any process that can read /proc/<pid>/cmdline.
      const result = exec("gh", ["secret", "set", name, "--repo", repo, "--body", "-"], {
        timeout: 30_000,
        input: value,
      });
      // Never audit the value itself — name + repo only.
      audit("devops.secrets.set", `${repo}:${name}`, result.ok ? "OK" : `FAILED (exit ${result.exitCode})`);

      return {
        content: [{
          type: "text" as const,
          text: result.ok
            ? `Set secret ${name} in ${repo}: SUCCESS`
            : `Set secret ${name} in ${repo}: FAILED (exit ${result.exitCode})\n${result.stderr.slice(-2000)}`,
        }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "devops.secrets.delete",
    "Delete a GitHub Actions secret. Irreversible — any workflow reading it starts resolving it to the empty string on the next run.",
    {
      repo: z.string().describe("owner/repo, e.g. diegonmarcos/cloud-unix"),
      name: z.string().describe("Secret name to delete"),
    },
    async ({ repo, name }) => {
      for (const part of repo.split("/")) validatePath(part);
      validatePath(name);

      const result = exec("gh", ["secret", "delete", name, "--repo", repo], { timeout: 30_000 });
      audit("devops.secrets.delete", `${repo}:${name}`, result.ok ? "OK" : `FAILED (exit ${result.exitCode})`);

      return {
        content: [{
          type: "text" as const,
          text: result.ok
            ? `Deleted secret ${name} from ${repo}`
            : `Delete secret ${name} from ${repo}: FAILED (exit ${result.exitCode})\n${result.stderr.slice(-2000)}`,
        }],
        isError: !result.ok,
      };
    }
  );
}
