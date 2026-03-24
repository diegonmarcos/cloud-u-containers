#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

// ── Meta ────────────────────────────────────────
import { registerRegistryTools } from "./tools/registry.js";
import { registerProxyTools } from "./tools/proxy.js";

// ── Infra: ops, observability, automation ───────
import { registerGrafanaTools } from "./tools/grafana.js";
import { registerMatomoTools } from "./tools/matomo.js";
import { registerUmamiTools } from "./tools/umami.js";
import { registerNtfyTools } from "./tools/ntfy.js";
import { registerSyncthingTools } from "./tools/syncthing.js";
import { registerOllamaTools } from "./tools/ollama.js";
import { registerDaguTools } from "./tools/dagu.js";
import { registerWindmillTools } from "./tools/windmill.js";
import { registerCrawleeTools } from "./tools/crawlee.js";
import { registerStalwartTools } from "./tools/stalwart.js";
import { registerAutheliaTools } from "./tools/authelia.js";
import { registerNocodbTools } from "./tools/nocodb.js";

// ── User: apps, collaboration, personal ─────────
import { registerPhotoprismTools } from "./tools/photoprism.js";
import { registerFilebrowserTools } from "./tools/filebrowser.js";
import { registerGiteaTools } from "./tools/gitea.js";
import { registerGristTools } from "./tools/grist.js";
import { registerHedgedocTools } from "./tools/hedgedoc.js";
import { registerEtherpadTools } from "./tools/etherpad.js";
import { registerSnappymailTools } from "./tools/snappymail.js";
import { registerRadicaleTools } from "./tools/radicale.js";
import { registerVaultwardenTools } from "./tools/vaultwarden.js";

// ── Proxied child MCPs ──────────────────────────
import { registerProxiedTools } from "./tools/proxy-mcp.js";

const log = (msg: string) => process.stderr.write(`[c3-services] ${msg}\n`);

async function main() {
  const server = new McpServer({
    name: "c3-services",
    version: "2.1.0",
  });

  // ── Meta ──────────────────────────────────────────────────────
  registerRegistryTools(server);      //  5: list, info, spec, registry-mcp_search, registry-mcp_get
  registerProxyTools(server);         //  1: generic proxy

  // ═══════════════════════════════════════════════════════════════
  // INFRA — ops, observability, automation, platform
  // ═══════════════════════════════════════════════════════════════
  registerGrafanaTools(server);       // 10: health, dashboards, detail, datasources, alerts, state, annotations, create, folders, org
  registerMatomoTools(server);        //  5: visits, sites, actions, referrers, live
  registerUmamiTools(server);         //  6: websites, stats, pageviews, metrics, active, events
  registerNtfyTools(server);          //  5: health, publish, read, stats, tier
  registerSyncthingTools(server);     //  4: status, config, folders, devices
  registerOllamaTools(server);        //  3: models, generate, chat
  registerDaguTools(server);          //  2: list, trigger
  registerWindmillTools(server);      //  9: scripts, detail, run_script, flows, run_flow, jobs, job_detail, schedules, resources
  registerCrawleeTools(server);       //  8: actors, detail, run, runs, run_detail, abort, datasets, items
  registerStalwartTools(server);      //  7: users, user_detail, queue, config, metrics, queue_action, config_update
  registerAutheliaTools(server);      //  5: health, state, config, jwks, user_info
  registerNocodbTools(server);        //  7: bases, tables, rows, row_create, row_update, row_delete, table_info
                                      // ── infra subtotal: 71

  // ═══════════════════════════════════════════════════════════════
  // USER — apps, collaboration, personal
  // ═══════════════════════════════════════════════════════════════
  registerPhotoprismTools(server);    //  8: status, photos, detail, albums, album_photos, labels, faces, stats
  registerFilebrowserTools(server);   //  9: ls, info, search, mkdir, delete, move, shares, share_create, usage
  registerGiteaTools(server);         //  8: repos, detail, issues, issue_create, pulls, users, orgs, releases
  registerGristTools(server);         //  7: orgs, docs, tables, records, record_create, record_update, columns
  registerHedgedocTools(server);      //  7: notes, detail, content, create, delete, me, history
  registerEtherpadTools(server);      //  9: pads, text, html, create, set_text, delete, revisions, authors, users
  registerSnappymailTools(server);    //  3: health, domains, domain_config
  registerRadicaleTools(server);      //  3: calendars, contacts, events
  registerVaultwardenTools(server);   //  4: health, status, users, orgs
                                      // ── user subtotal: 58

  // ── Proxied child MCPs ────────────────────────────────────────
  // mattermost-mcp, mail-mcp, google-workspace-mcp, cloud-cgc-mcp
  await registerProxiedTools(server);

  const transport = new StdioServerTransport();
  log("Starting c3-services MCP server v2.1.0 (135 native tools)...");
  await server.connect(transport);
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
