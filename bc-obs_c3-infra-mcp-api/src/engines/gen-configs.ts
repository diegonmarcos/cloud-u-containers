// gen-configs.ts — Generate cloud-data-configs.json + cloud-data-configs.md
//
// Sources:
//   cloud-data-topology.json                        → service inventory (primary)
//   a_solutions/bb-sec_caddy/dist/Caddyfile        → routes
//   a_solutions/bb-sec_authelia/dist/config/*.tpl   → ACL rules
//   a_solutions/ba-clo_hickory-dns/dist/zones/      → DNS records
//   a_solutions/bc-obs_ntfy/dist/etc/server.yml     → ntfy config
//   a_solutions/aa-sui_tools-mailu/src/flake.nix    → mailu config
//
// Outputs (written directly to cloud-data/ submodule, symlinked from repo root):
//   cloud-data/cloud-data-configs.json   → machine-readable per-service configs
//   cloud-data/cloud-data-configs.md     → human-readable tables (via Nunjucks)

import { readFileSync, writeFileSync, existsSync } from "fs";
import { join, resolve } from "path";
import { homedir } from "os";
import nunjucks from "nunjucks";
import { parseCaddyfile } from "./parsers/caddyfile.js";
import { parseAuthelia } from "./parsers/authelia.js";
import { parseDNSZones } from "./parsers/dns.js";
import { parseNtfy } from "./parsers/ntfy.js";
import { parseMailu } from "./parsers/mailu.js";

// --- Paths ----------------------------------------------------------------

const ENGINE_DIR = import.meta.dirname!;
const CLOUD_ROOT_DEFAULT = resolve(ENGINE_DIR, "../../../..");
const GIT_BASE = process.env.GIT_BASE ?? resolve(CLOUD_ROOT_DEFAULT, "..");
const CLOUD_ROOT = process.env.GIT_BASE ? join(GIT_BASE, "cloud") : CLOUD_ROOT_DEFAULT;
const SOLUTIONS_DIR = join(CLOUD_ROOT, "a_solutions");
const TEMPLATE_DIR = join(ENGINE_DIR, "templates");

const CLOUD_DATA_DIR = join(CLOUD_ROOT, "cloud-data");
const OUTPUT_JSON = join(CLOUD_DATA_DIR, "cloud-data-configs.json");
const OUTPUT_MD = join(CLOUD_DATA_DIR, "cloud-data-configs.md");

// --- Types ----------------------------------------------------------------

interface CloudConfigs {
  services: Record<string, unknown>[];
  infra: Record<string, unknown>;
  apps: Record<string, unknown>;
}

// --- Main -----------------------------------------------------------------

function main() {
  console.log("gen-configs: scanning sources...");

  const configs: CloudConfigs = {
    services: [],
    infra: {},
    apps: {},
  };

  // 0. Service list from cloud-data-topology.json
  const topologyPath = join(CLOUD_ROOT, "cloud-data-topology.json");
  if (existsSync(topologyPath)) {
    const topology = JSON.parse(readFileSync(topologyPath, "utf-8"));
    if (topology.services) {
      configs.services = Object.entries(topology.services)
        .map(([name, svc]: [string, any]) => ({
          name,
          category: svc.category ?? "—",
          vm: svc.vm ?? "—",
          description: svc.description ?? "—",
          domain: svc.domain ?? "—",
          ports: svc.ports ?? [],
          networks: svc.networks ?? [],
          containers: svc.containers ?? [],
        }))
        .sort((a, b) => a.vm.localeCompare(b.vm) || a.name.localeCompare(b.name));
      console.log(`  Topology: ${configs.services.length} services`);
    }
  }

  // 1. Caddy routes
  const routes = parseCaddyfile(SOLUTIONS_DIR);
  if (routes.length > 0) {
    configs.infra.caddy = { routes };
    console.log(`  Caddy: ${routes.length} routes`);
  }

  // 2. Authelia ACL
  const acl = parseAuthelia(SOLUTIONS_DIR);
  if (acl.length > 0) {
    configs.infra.authelia = { acl };
    console.log(`  Authelia: ${acl.length} ACL rules`);
  }

  // 3. DNS zones (also in topology, but configs shows the detail)
  const zones = parseDNSZones(SOLUTIONS_DIR);
  if (zones.length > 0) {
    configs.infra["hickory-dns"] = { zones };
    console.log(`  DNS: ${zones.length} zone(s)`);
  }

  // 4. ntfy
  const ntfy = parseNtfy(SOLUTIONS_DIR);
  if (ntfy) {
    configs.apps.ntfy = ntfy;
    console.log(`  ntfy: ${ntfy.topics.length} topics`);
  }

  // 5. Mailu
  const mailu = parseMailu(SOLUTIONS_DIR);
  if (mailu) {
    configs.apps.mailu = mailu;
    console.log(`  Mailu: ${mailu.mailboxes.length} mailboxes`);
  }

  // 6. Write cloud-data-configs.json
  const output = {
    _meta: {
      generated_by: "a_solutions/c3-infra-mcp-api/src/engines/gen-configs.ts",
      api_route: "GET /c3-api/cloud-data/configs",
      source: "cloud-data-topology.json + Caddy/Authelia/DNS flakes",
      generated_at: new Date().toISOString(),
    },
    ...configs,
  };
  writeFileSync(OUTPUT_JSON, JSON.stringify(output, null, 2) + "\n");
  console.log(`  Written: cloud-data-configs.json (${configs.services.length} services, ${Object.keys(configs.infra).length} infra, ${Object.keys(configs.apps).length} apps)`);

  // 7. Render cloud-configs.md
  const templatePath = join(TEMPLATE_DIR, "cloud-configs.md.njk");
  if (existsSync(templatePath)) {
    nunjucks.configure(TEMPLATE_DIR, { autoescape: false, trimBlocks: true, lstripBlocks: true });
    const md = nunjucks.render("cloud-configs.md.njk", { data: configs });
    writeFileSync(OUTPUT_MD, md);
    console.log(`  Written: cloud-data-configs.md`);
  } else {
    console.warn(`  WARN: template not found at ${templatePath}`);
  }

  console.log("gen-configs: done.");
}

main();
