import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { parse as parseYaml } from "yaml";

export interface NtfyTopic {
  name: string;
  category: string;
  desc: string;
  publishers: string[];
}

export interface NtfyConfig {
  topics: NtfyTopic[];
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

  const topics = extractTopicsFromScanner(solutionsDir);

  return {
    topics,
    users: extractUsersFromCompose(solutionsDir),
    enable_login: doc?.["enable-login"] ?? false,
    auth_default_access: doc?.["auth-default-access"] ?? "read-write",
  };
}

function extractTopicsFromScanner(solutionsDir: string): NtfyTopic[] {
  const scannerPath = join(solutionsDir, "bc-obs_ntfy", "src", "topic-scanner.py");
  if (!existsSync(scannerPath)) return [];

  const content = readFileSync(scannerPath, "utf-8");

  // Extract CONFIGURED_TOPICS block
  const blockMatch = content.match(/CONFIGURED_TOPICS\s*=\s*\[([\s\S]*?)\]/);
  if (!blockMatch) return [];

  // Build publisher map from bridge scripts
  const publishers = extractPublisherMap(solutionsDir);

  const topics: NtfyTopic[] = [];
  // Match each "topic_name", with optional inline # comment
  for (const m of blockMatch[1].matchAll(/"([^"]+)"[^#\n]*(?:#\s*(.*))?/g)) {
    const name = m[1];
    const desc = m[2]?.trim() ?? name;
    const category = name.split("_")[0];
    topics.push({
      name,
      category,
      desc,
      publishers: publishers.get(name) ?? ["system"],
    });
  }

  return topics;
}

/** Scan bridge scripts for topic constants to build publisher mapping */
function extractPublisherMap(solutionsDir: string): Map<string, string[]> {
  const map = new Map<string, string[]>();
  const srcDir = join(solutionsDir, "bc-obs_ntfy", "src");

  const bridges: { file: string; publisher: string }[] = [
    { file: "github-rss-to-ntfy.py", publisher: "github-rss" },
    { file: "syslog-to-ntfy.py", publisher: "syslog-bridge" },
  ];

  for (const bridge of bridges) {
    const path = join(srcDir, bridge.file);
    if (!existsSync(path)) continue;
    const content = readFileSync(path, "utf-8");
    // Match TOPIC_* = 'name' or NTFY_TOPIC = 'name'
    for (const m of content.matchAll(/(?:TOPIC_\w+|NTFY_TOPIC)\s*=\s*['"]([^'"]+)['"]/g)) {
      const existing = map.get(m[1]) ?? [];
      existing.push(bridge.publisher);
      map.set(m[1], existing);
    }
  }

  return map;
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
