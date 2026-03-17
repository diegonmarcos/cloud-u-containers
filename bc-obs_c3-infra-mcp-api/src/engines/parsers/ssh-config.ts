import { readFileSync, existsSync } from "fs";

export interface SSHHost {
  alias: string;
  hostname: string;
  user: string;
  identityFile?: string;
  commented: boolean;
}

export function parseSSHConfig(path: string): SSHHost[] {
  if (!existsSync(path)) return [];
  const content = readFileSync(path, "utf-8");
  const hosts: SSHHost[] = [];
  let current: Partial<SSHHost> | null = null;
  let inComment = false;

  for (const line of content.split("\n")) {
    const trimmed = line.trim();

    const commentedHost = trimmed.match(/^#\s*Host\s+(\S+)/);
    if (commentedHost) {
      if (current?.alias) hosts.push(current as SSHHost);
      current = { alias: commentedHost[1], commented: true };
      inComment = true;
      continue;
    }

    const hostMatch = trimmed.match(/^Host\s+(\S+)/);
    if (hostMatch) {
      if (current?.alias) hosts.push(current as SSHHost);
      current = { alias: hostMatch[1], commented: false };
      inComment = false;
      continue;
    }

    if (!current) continue;

    const directive = inComment ? trimmed.replace(/^#\s*/, "") : trimmed;
    const kvMatch = directive.match(/^(\w+)\s+(.+)$/);
    if (kvMatch) {
      const [, key, value] = kvMatch;
      switch (key.toLowerCase()) {
        case "hostname":
          current.hostname = value;
          break;
        case "user":
          current.user = value;
          break;
        case "identityfile":
          current.identityFile = value;
          break;
      }
    }

    if (inComment && trimmed !== "" && !trimmed.startsWith("#")) {
      inComment = false;
    }
  }
  if (current?.alias) hosts.push(current as SSHHost);

  return hosts.filter(
    (h) => h.hostname && !h.alias.includes(".") && h.alias !== "*"
  );
}
