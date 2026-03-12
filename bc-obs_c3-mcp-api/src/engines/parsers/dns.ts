import { readFileSync, readdirSync, existsSync } from "fs";
import { join, basename } from "path";

export interface DNSRecord {
  name: string;
  type: string;
  value: string;
  comment?: string;
}

export interface DNSZone {
  name: string;
  records: DNSRecord[];
}

export function parseDNSZones(solutionsDir: string): DNSZone[] {
  const zonesDir = join(solutionsDir, "ba-clo_hickory-dns", "dist", "zones");
  if (!existsSync(zonesDir)) return [];

  const zones: DNSZone[] = [];

  let files: string[];
  try {
    files = readdirSync(zonesDir).filter((f) => f.endsWith(".zone"));
  } catch {
    return [];
  }

  for (const file of files) {
    const zoneName = basename(file, ".zone");
    const content = readFileSync(join(zonesDir, file), "utf-8");
    const records: DNSRecord[] = [];

    for (const line of content.split("\n")) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("$") || trimmed.startsWith("@") || trimmed.startsWith(";")) continue;

      // Match: name IN TYPE value ; comment
      const match = trimmed.match(/^([\w.*-]+)\s+IN\s+(A|AAAA|CNAME|PTR|MX|TXT|NS|SRV)\s+(\S+)\s*(?:;\s*(.*))?$/);
      if (match) {
        records.push({
          name: match[1],
          type: match[2],
          value: match[3],
          ...(match[4] ? { comment: match[4].trim() } : {}),
        });
      }
    }

    if (records.length > 0) {
      zones.push({ name: zoneName, records });
    }
  }

  return zones;
}
