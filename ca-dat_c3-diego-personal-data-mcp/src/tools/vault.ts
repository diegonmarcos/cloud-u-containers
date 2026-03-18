/**
 * Vault tools — READ-ONLY access to credential metadata.
 * NEVER exposes actual passwords, tokens, or secret values.
 * Only shows structure, existence, and metadata.
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { readFileSync, existsSync, readdirSync, statSync } from "fs";
import { join, basename } from "path";
import { getVaultPath } from "../config.js";

function listDirSafe(path: string): string[] {
  if (!existsSync(path)) return [];
  return readdirSync(path);
}

export function registerVaultTools(server: McpServer) {

  // ── Vault Structure ───────────────────────────────────────────────
  server.tool(
    "vault_structure",
    "Get the vault directory structure — shows what credential categories exist without exposing any secrets.",
    {},
    async () => {
      const vault = getVaultPath();
      if (!existsSync(vault)) {
        return { content: [{ type: "text" as const, text: "Vault path not found" }] };
      }

      const entries = readdirSync(vault, { withFileTypes: true });
      const structure = entries
        .filter(e => e.isDirectory() && !e.name.startsWith("."))
        .map(e => {
          const items = listDirSafe(join(vault, e.name));
          return `- **${e.name}/** (${items.length} items)`;
        })
        .join("\n");

      return {
        content: [{
          type: "text" as const,
          text: `# Vault Structure\n\n${structure}`,
        }],
      };
    }
  );

  // ── Providers Overview ────────────────────────────────────────────
  server.tool(
    "vault_providers",
    "List all credential providers (SSH, OAuth, cloud CLIs) — shows provider names and file counts, no secrets.",
    {},
    async () => {
      const providersDir = join(getVaultPath(), "A0_keys", "providers");
      if (!existsSync(providersDir)) {
        return { content: [{ type: "text" as const, text: "Providers directory not found" }] };
      }

      const providers = readdirSync(providersDir, { withFileTypes: true })
        .filter(e => e.isDirectory())
        .map(e => {
          const items = listDirSafe(join(providersDir, e.name));
          const fileList = items.map(f => {
            const stat = statSync(join(providersDir, e.name, f));
            return `  - ${f} (${stat.isDirectory() ? "dir" : `${stat.size}B`})`;
          }).join("\n");
          return `### ${e.name}\n${fileList || "  (empty)"}`;
        })
        .join("\n\n");

      return {
        content: [{
          type: "text" as const,
          text: `# Credential Providers\n\n${providers}`,
        }],
      };
    }
  );

  // ── SSH Keys Inventory ────────────────────────────────────────────
  server.tool(
    "vault_ssh_keys",
    "List SSH key files — shows key names and types (public only), never private key content.",
    {},
    async () => {
      const sshDir = join(getVaultPath(), "A0_keys", "ssh");
      if (!existsSync(sshDir)) {
        return { content: [{ type: "text" as const, text: "SSH directory not found" }] };
      }

      const files = readdirSync(sshDir)
        .filter(f => !f.startsWith("."))
        .map(f => {
          const isPublic = f.endsWith(".pub");
          const stat = statSync(join(sshDir, f));
          return `- ${f} (${isPublic ? "public" : "private"}, ${stat.size}B)`;
        })
        .join("\n");

      return {
        content: [{
          type: "text" as const,
          text: `# SSH Keys\n\n${files || "No keys found."}`,
        }],
      };
    }
  );

  // ── Passwords Summary ─────────────────────────────────────────────
  server.tool(
    "vault_passwords_summary",
    "Get a summary of stored passwords — service names and categories only, NEVER actual passwords.",
    {},
    async () => {
      const pwDir = join(getVaultPath(), "B0_Passwords");
      if (!existsSync(pwDir)) {
        return { content: [{ type: "text" as const, text: "Passwords directory not found" }] };
      }

      const files = readdirSync(pwDir)
        .filter(f => !f.startsWith("."))
        .map(f => `- ${basename(f, ".txt").replace(/_/g, " ")}`)
        .join("\n");

      return {
        content: [{
          type: "text" as const,
          text: `# Stored Passwords (${readdirSync(pwDir).filter(f => !f.startsWith(".")).length} entries)\n\n${files}\n\n_Actual passwords are NEVER exposed._`,
        }],
      };
    }
  );

  // ── 2FA Status ────────────────────────────────────────────────────
  server.tool(
    "vault_2fa_status",
    "List services with 2FA configured — names only, no TOTP seeds or recovery codes.",
    {},
    async () => {
      const tfaDir = join(getVaultPath(), "B1_2fa");
      if (!existsSync(tfaDir)) {
        return { content: [{ type: "text" as const, text: "2FA directory not found" }] };
      }

      const entries = readdirSync(tfaDir)
        .filter(f => !f.startsWith("."))
        .map(f => `- ${basename(f).replace(/\.(txt|json|yaml)$/, "").replace(/_/g, " ")}`)
        .join("\n");

      return {
        content: [{
          type: "text" as const,
          text: `# 2FA Configured Services\n\n${entries}\n\n_TOTP seeds and recovery codes are NEVER exposed._`,
        }],
      };
    }
  );
}
