// cloudflare.ts — Extract DNS records from ba-clo_cloudflare/src/main.tf
//
// Parses `cloudflare_record` resources via regex (not a full HCL parser).
// Variables (var.xxx) are preserved as-is — the actual values are secrets.

import { readFileSync, existsSync } from "fs";
import { join } from "path";

export interface CloudflareDnsRecord {
  resource_name: string;
  name: string;
  type: string;
  content: string;
  proxied?: boolean;
  ttl?: number;
  priority?: number;
  comment?: string;
}

/**
 * Parse all `cloudflare_record` resources from ba-clo_cloudflare/src/main.tf
 */
export function parseCloudflareRecords(solutionsDir: string): CloudflareDnsRecord[] {
  const tfPath = join(solutionsDir, "ba-clo_cloudflare", "src", "main.tf");
  if (!existsSync(tfPath)) return [];

  const content = readFileSync(tfPath, "utf-8");
  const records: CloudflareDnsRecord[] = [];

  // Match all `resource "cloudflare_record" "name" { ... }` blocks
  const blockRegex = /resource\s+"cloudflare_record"\s+"(\w+)"\s*\{([^}]*(?:\{[^}]*\}[^}]*)*)\}/g;
  let match: RegExpExecArray | null;

  while ((match = blockRegex.exec(content)) !== null) {
    const resourceName = match[1];
    const body = match[2];

    const getString = (key: string): string | undefined => {
      // Match: key = "value" or key = var.xxx or key = "${var.xxx}.suffix"
      const m = body.match(new RegExp(`${key}\\s*=\\s*(?:"([^"]*)"|(var\\.[\\w]+))`));
      return m ? (m[1] ?? m[2]) : undefined;
    };

    const getBool = (key: string): boolean | undefined => {
      const m = body.match(new RegExp(`${key}\\s*=\\s*(true|false)`));
      return m ? m[1] === "true" : undefined;
    };

    const getNumber = (key: string): number | undefined => {
      const m = body.match(new RegExp(`${key}\\s*=\\s*(\d+)`));
      return m ? parseInt(m[1], 10) : undefined;
    };

    const name = getString("name");
    const type = getString("type");
    const contentVal = getString("content");

    if (!name || !type) continue;

    records.push({
      resource_name: resourceName,
      name,
      type,
      content: contentVal ?? "",
      proxied: getBool("proxied"),
      ttl: getNumber("ttl"),
      priority: getNumber("priority"),
      comment: getString("comment"),
    });
  }

  return records;
}
