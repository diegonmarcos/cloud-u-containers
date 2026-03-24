import { readFileSync, existsSync } from "fs";
import { join } from "path";

export interface MailuConfig {
  domain: string;
  mailboxes: string[];
  relay: string;
}

export function parseMailu(solutionsDir: string): MailuConfig | null {
  const baseDir = join(solutionsDir, "aa-sui_tools-mailu");
  if (!existsSync(baseDir)) return null;

  // Parse from dist/mailu.env.tpl (built output with resolved values)
  const envPath = join(baseDir, "dist", "mailu.env.tpl");
  let domain = "diegonmarcos.com";
  let relay = "";

  if (existsSync(envPath)) {
    const content = readFileSync(envPath, "utf-8");
    const domainMatch = content.match(/^DOMAIN=(.+)$/m);
    if (domainMatch) domain = domainMatch[1].trim();
    const relayMatch = content.match(/^RELAYHOST=(.+)$/m);
    if (relayMatch) relay = relayMatch[1].trim();
  }

  // Extract mailboxes from setup.sh or init.sh
  const mailboxes = extractMailboxes(baseDir);

  if (!domain && mailboxes.length === 0) return null;

  return { domain, mailboxes, relay };
}

function extractMailboxes(baseDir: string): string[] {
  const mailboxes: string[] = [];

  for (const file of ["dist/setup.sh", "dist/init.sh"]) {
    const path = join(baseDir, file);
    if (!existsSync(path)) continue;
    const content = readFileSync(path, "utf-8");
    // Pattern: flask mailu user <name> <domain> — e.g. "flask mailu user no-reply diegonmarcos.com"
    const matches = content.matchAll(/flask\s+mailu\s+user\s+(\S+)\s+(\S+)/g);
    for (const m of matches) {
      const addr = `${m[1]}@${m[2]}`;
      if (!mailboxes.includes(addr)) mailboxes.push(addr);
    }
    // Also match "user@domain" directly
    const directMatches = content.matchAll(/(\w+@[\w.]+\.\w+)/g);
    for (const m of directMatches) {
      if (!mailboxes.includes(m[1]) && !m[1].includes("=")) mailboxes.push(m[1]);
    }
  }

  return mailboxes;
}
