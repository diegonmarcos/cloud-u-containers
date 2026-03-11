import { readFileSync, readdirSync, existsSync } from "fs";
import { join } from "path";

export interface BuildJsonEntry {
  name: string;
  category: string;
  vm: string;
  domain?: string;
  description: string;
  flake?: string;
  folder: string;
}

const CATEGORY_PREFIX: Record<string, string> = {
  app: "aa-sui_",
  mic: "ab-mic_",
  fin: "ac-fin_",
  agi: "ad-agi_",
  cloud: "ba-clo_",
  sec: "bb-sec_",
  tools: "bc-obs_",
  data: "ca-dat_",
};

const PREFIX_CATEGORY: Record<string, string> = {};
for (const [cat, prefix] of Object.entries(CATEGORY_PREFIX)) {
  PREFIX_CATEGORY[prefix] = cat;
}

export { CATEGORY_PREFIX, PREFIX_CATEGORY };

function deriveCategory(folder: string): string | undefined {
  for (const [prefix, cat] of Object.entries(PREFIX_CATEGORY)) {
    if (folder.startsWith(prefix)) return cat;
  }
  return undefined;
}

export function scanBuildJsons(solutionsDir: string): BuildJsonEntry[] {
  const entries: BuildJsonEntry[] = [];

  let dirs: string[];
  try {
    dirs = readdirSync(solutionsDir, { withFileTypes: true })
      .filter((d) => d.isDirectory() && !d.name.startsWith("z_archive") && !d.name.startsWith("."))
      .map((d) => d.name);
  } catch {
    return entries;
  }

  for (const folder of dirs) {
    const bjPath = join(solutionsDir, folder, "build.json");
    if (!existsSync(bjPath)) continue;

    try {
      const bj = JSON.parse(readFileSync(bjPath, "utf-8"));
      const name = bj.name;
      if (!name) continue;

      const category = bj.category || deriveCategory(folder) || "tools";
      const host = bj.deploy?.host ?? "local";

      const expectedFolder = CATEGORY_PREFIX[category]
        ? `${CATEGORY_PREFIX[category]}${name}`
        : name;
      const flake = folder !== expectedFolder
        ? folder.replace(/^[a-z]{2}-[a-z]{3}_/, "")
        : undefined;

      entries.push({
        name,
        category,
        vm: host,
        domain: bj.domain,
        description: bj.description || "",
        flake,
        folder,
      });
    } catch {
      console.warn(`  WARN: invalid build.json in ${folder}`);
    }
  }

  return entries;
}
