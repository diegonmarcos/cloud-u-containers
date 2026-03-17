import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { parse as parseYaml } from "yaml";

export interface AutheliaACL {
  domain: string;
  policy: string;
  resources?: string[];
}

export function parseAuthelia(solutionsDir: string): AutheliaACL[] {
  const configPath = join(solutionsDir, "bb-sec_authelia", "dist", "config", "configuration.yml.tpl");
  if (!existsSync(configPath)) return [];

  let content: string;
  try {
    content = readFileSync(configPath, "utf-8");
  } catch {
    return [];
  }

  // Replace ${...} env vars with placeholder strings so YAML parses
  content = content.replace(/\$\{[^}]+\}/g, "PLACEHOLDER");

  let doc: any;
  try {
    doc = parseYaml(content);
  } catch {
    return [];
  }

  const rules = doc?.access_control?.rules;
  if (!Array.isArray(rules)) return [];

  const acl: AutheliaACL[] = [];
  for (const rule of rules) {
    if (!rule.domain || !rule.policy) continue;
    const entry: AutheliaACL = {
      domain: rule.domain,
      policy: rule.policy,
    };
    if (Array.isArray(rule.resources) && rule.resources.length > 0) {
      entry.resources = rule.resources;
    }
    acl.push(entry);
  }

  return acl;
}
