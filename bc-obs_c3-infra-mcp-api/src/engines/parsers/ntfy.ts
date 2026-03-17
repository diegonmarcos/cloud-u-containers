import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { parse as parseYaml } from "yaml";

export interface NtfyConfig {
  topics: string[];
  users: string[];
  enable_login: boolean;
  auth_default_access: string;
}

export function parseNtfy(solutionsDir: string): NtfyConfig | null {
  // Parse server.yml from dist/
  const configPath = join(solutionsDir, "bc-obs_ntfy", "dist", "etc", "server.yml");
  if (!existsSync(configPath)) return null;

  let doc: any;
  try {
    doc = parseYaml(readFileSync(configPath, "utf-8"));
  } catch {
    return null;
  }

  // Extract topics from the flake.nix (ntfyTopics list)
  const topics = extractTopicsFromFlake(solutionsDir);

  return {
    topics,
    users: extractUsersFromCompose(solutionsDir),
    enable_login: doc?.["enable-login"] ?? false,
    auth_default_access: doc?.["auth-default-access"] ?? "read-write",
  };
}

function extractTopicsFromFlake(solutionsDir: string): string[] {
  const flakePath = join(solutionsDir, "bc-obs_ntfy", "src", "flake.nix");
  if (!existsSync(flakePath)) return [];

  const content = readFileSync(flakePath, "utf-8");

  // Look for ntfyTopics = [ "topic1" "topic2" ... ];
  const match = content.match(/ntfyTopics\s*=\s*\[([\s\S]*?)\]/);
  if (!match) return [];

  const topics: string[] = [];
  const tokenMatches = match[1].matchAll(/"([^"]+)"/g);
  for (const m of tokenMatches) {
    topics.push(m[1]);
  }

  return topics;
}

function extractUsersFromCompose(solutionsDir: string): string[] {
  // Users are created via CLI commands in compose or setup scripts
  // For now, extract from docker-compose.yml entrypoint/command if present
  const composePath = join(solutionsDir, "bc-obs_ntfy", "dist", "docker-compose.yml");
  if (!existsSync(composePath)) return [];

  const content = readFileSync(composePath, "utf-8");
  const users: string[] = [];

  // Look for `ntfy user add` commands
  const userMatches = content.matchAll(/ntfy\s+user\s+add\s+(\w+)/g);
  for (const m of userMatches) {
    users.push(m[1]);
  }

  return users;
}
