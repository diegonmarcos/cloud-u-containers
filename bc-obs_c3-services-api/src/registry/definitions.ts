// Service definitions — data-driven from cloud-data topology
//
// Infrastructure fields (vm, wgIp, port, domain) come from cloud-data-topology.json.
// API metadata (type, specUrl, endpointCount, description) is service-specific and stays here.
//
// When a service moves VMs or changes ports, only cloud-data needs updating — not this file.

import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { homedir } from "os";
import type { ServiceDefinition, ApiCapability } from "./types.js";

// ── API metadata per service (static, service-specific) ──────────────────
// This is the ONLY thing that can't come from cloud-data.

const API_META: Record<string, ApiCapability & { displayName?: string }> = {
  nocodb: {
    displayName: "NocoDB",
    type: "openapi",
    endpointCount: 0,
    description: "NocoDB REST API — tables, rows, views, fields",
  },
  gitea: {
    displayName: "Gitea",
    type: "openapi",
    specPath: "/swagger.json",
    endpointCount: 0,
    description: "Gitea REST API — repos, users, orgs, issues",
  },
  mattermost: {
    displayName: "Mattermost",
    type: "openapi",
    specPath: "/api/v4/opengraph",
    endpointCount: 0,
    description: "Mattermost REST API v4 — channels, posts, users, teams",
  },
  vaultwarden: {
    displayName: "Vaultwarden",
    type: "openapi",
    endpointCount: 0,
    description: "Vaultwarden API — vaults, ciphers, organizations",
  },
  authelia: {
    displayName: "Authelia",
    type: "openapi",
    specPath: "/api/openapi.yml",
    endpointCount: 0,
    description: "Authelia API — configuration, user info, OIDC",
  },
  matomo: {
    displayName: "Matomo",
    type: "custom-rest",
    endpointCount: 5,
    description: "Matomo Reporting API — visits, sites, actions, referrers",
  },
  snappymail: {
    displayName: "SnappyMail",
    type: "custom-rest",
    endpointCount: 3,
    description: "SnappyMail — health, domain config (PHP admin panel, no REST API)",
  },
  syncthing: {
    displayName: "Syncthing",
    type: "custom-rest",
    endpointCount: 4,
    description: "Syncthing REST API — status, folders, devices, config",
  },
  ntfy: {
    displayName: "ntfy",
    type: "custom-rest",
    endpointCount: 5,
    description: "ntfy API — publish, read, health, stats, account",
  },
  ollama: {
    displayName: "Ollama GPU (gcp-t4)",
    type: "custom-rest",
    endpointCount: 3,
    description: "Ollama API — chat completion, model listing, generation (T4 GPU)",
  },
  "ollama-hai": {
    displayName: "Ollama ARM (oci-apps)",
    type: "custom-rest",
    endpointCount: 3,
    description: "Ollama API — chat completion, model listing, generation (A1 CPU)",
  },
  radicale: {
    displayName: "Radicale",
    type: "custom-protocol",
    endpointCount: 3,
    description: "Radicale CalDAV — calendars, contacts, events (XML→JSON wrapper)",
  },
  "rig-heavy": {
    displayName: "Rig Agent (Heavy)",
    type: "custom-rest",
    endpointCount: 5,
    description: "Rig Agent API — run tasks, list tasks, get results, health, status",
  },
  "rig-light": {
    displayName: "Rig Agent (Light)",
    type: "custom-rest",
    endpointCount: 5,
    description: "Rig Agent API — run tasks, list tasks, get results, health, status",
  },
  lgtm: {
    displayName: "Grafana (LGTM Stack)",
    type: "custom-rest",
    endpointCount: 10,
    description: "Grafana API — dashboards, alerts, datasources, annotations, folders",
  },
  grist: {
    displayName: "Grist",
    type: "custom-rest",
    endpointCount: 7,
    description: "Grist API — orgs, docs, tables, records, columns",
  },
  hedgedoc: {
    displayName: "HedgeDoc",
    type: "custom-rest",
    endpointCount: 7,
    description: "HedgeDoc API v2 — notes CRUD, user info, history",
  },
  filebrowser: {
    displayName: "FileBrowser",
    type: "custom-rest",
    endpointCount: 9,
    description: "FileBrowser API — files, dirs, search, shares, usage",
  },
  etherpad: {
    displayName: "Etherpad",
    type: "custom-rest",
    endpointCount: 9,
    description: "Etherpad HTTP API — pads, text, HTML, revisions, authors",
  },
  photoprism: {
    displayName: "PhotoPrism",
    type: "custom-rest",
    endpointCount: 8,
    description: "PhotoPrism API — photos, albums, labels, faces, stats",
  },
  crawlee: {
    displayName: "Crawlee Cloud",
    type: "openapi",
    specPath: "/openapi.json",
    endpointCount: 8,
    description: "Crawlee API — actors, runs, datasets, items",
  },
  umami: {
    displayName: "Umami",
    type: "custom-rest",
    endpointCount: 6,
    description: "Umami API — websites, stats, pageviews, metrics, events",
  },
  codeserver: {
    displayName: "Code Server",
    type: "no-api",
    endpointCount: 0,
    description: "No programmatic API",
  },
  affine: {
    displayName: "AFFiNE",
    type: "no-api",
    endpointCount: 0,
    description: "No programmatic API",
  },
  dagu: {
    displayName: "Dagu",
    type: "custom-rest",
    endpointCount: 2,
    description: "Dagu API — list DAGs, trigger runs",
  },
};

// ── Load cloud-data topology ─────────────────────────────────────────────

interface TopoVm {
  wg_ip?: string;
  ssh_alias?: string;
  [k: string]: unknown;
}
interface TopoService {
  vm?: string;
  domain?: string;
  port?: number;
  description?: string;
  [k: string]: unknown;
}
interface TopoData {
  vms: Record<string, TopoVm>;
  services: Record<string, TopoService>;
}

function loadTopology(): TopoData | null {
  const gitBase = process.env.GIT_BASE ?? join(homedir(), "git");
  const paths = [
    join(gitBase, "cloud-data", "cloud-data-topology.json"),
    join(gitBase, "cloud", "cloud-data", "cloud-data-topology.json"),
  ];
  for (const p of paths) {
    if (!existsSync(p)) continue;
    try {
      return JSON.parse(readFileSync(p, "utf-8")) as TopoData;
    } catch { /* skip */ }
  }
  return null;
}

// ── Build SERVICE_DEFINITIONS from cloud-data + API_META ─────────────────

function buildDefinitions(): ServiceDefinition[] {
  const topo = loadTopology();
  if (!topo) {
    console.error("[definitions] cloud-data-topology.json not found — using empty definitions");
    return [];
  }

  const defs: ServiceDefinition[] = [];

  for (const [svcName, meta] of Object.entries(API_META)) {
    const svc = topo.services[svcName];
    if (!svc) continue; // Service not in topology — skip

    const vmId = svc.vm;
    if (!vmId || vmId === "local") continue;

    const vm = topo.vms[vmId];
    if (!vm?.wg_ip) continue;

    const port = svc.port;
    if (!port) continue;

    // Build specUrl from service base URL + specPath (if defined)
    const baseUrl = `http://${vm.wg_ip}:${port}`;
    const specPath = (meta as any).specPath as string | undefined;
    const specUrl = meta.specUrl ?? (specPath ? `${baseUrl}${specPath}` : undefined);

    defs.push({
      name: svcName,
      displayName: meta.displayName ?? svcName,
      description: svc.description ?? meta.description,
      vm: vm.ssh_alias ?? vmId,
      wgIp: vm.wg_ip,
      port,
      ...(svc.domain ? { domain: svc.domain.split("/")[0] } : {}),
      api: {
        type: meta.type,
        ...(specUrl ? { specUrl } : {}),
        endpointCount: meta.endpointCount,
        description: meta.description,
      },
    });
  }

  console.error(`[definitions] loaded ${defs.length} service definitions from cloud-data`);
  return defs;
}

export const SERVICE_DEFINITIONS: ServiceDefinition[] = buildDefinitions();
