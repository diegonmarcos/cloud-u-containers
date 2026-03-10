import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { parse as parseYaml } from "yaml";

export interface ComposeData {
  containers: string[];
  ports: string[];
  networks: string[];
}

export function parseCompose(solutionsDir: string, folder: string, projectName?: string): ComposeData {
  const empty: ComposeData = { containers: [], ports: [], networks: [] };

  const composePath = join(solutionsDir, folder, "dist", "docker-compose.yml");
  if (!existsSync(composePath)) return empty;

  let content: string;
  try {
    content = readFileSync(composePath, "utf-8");
  } catch {
    return empty;
  }

  let doc: any;
  try {
    doc = parseYaml(content);
  } catch {
    return empty;
  }

  if (!doc?.services) return empty;

  // Docker Compose runtime name: {project}-{service}-{instance}
  // Project name priority: compose `name:` field > projectName arg > folder basename
  const project = doc.name || projectName || folder.replace(/^[a-z]{2}-[a-z]{3}_/, "");

  const containers: string[] = [];
  const portsSet = new Set<string>();

  for (const [svcName, svcDef] of Object.entries(doc.services) as [string, any][]) {
    containers.push(svcDef?.container_name || `${project}-${svcName}-1`);
    if (Array.isArray(svcDef?.ports)) {
      for (const p of svcDef.ports) {
        portsSet.add(String(p).replace(/"/g, ""));
      }
    }
  }

  const networks: string[] = [];
  if (doc.networks) {
    for (const [netName, netDef] of Object.entries(doc.networks) as [string, any][]) {
      const realName = netDef?.name || netName;
      networks.push(realName);
    }
  }

  return {
    containers: containers.sort(),
    ports: [...portsSet],
    networks,
  };
}
