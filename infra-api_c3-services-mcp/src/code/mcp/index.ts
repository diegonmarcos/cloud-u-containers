#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

// ── Meta ────────────────────────────────────────
import { registerRegistryTools } from "./tools/registry.js";
import { registerProxyTools } from "./tools/proxy.js";
import { registerDiscoveryTools } from "./tools/discovery.js";

// ── Infra: ops, observability, automation ───────
import { registerMatomoTools } from "./tools/matomo.js";
import { registerUmamiTools } from "./tools/umami.js";
import { registerNtfyTools } from "./tools/ntfy.js";
import { registerSyncthingTools } from "./tools/syncthing.js";
import { registerOllamaTools } from "./tools/ollama.js";
import { registerDaguTools } from "./tools/dagu.js";
import { registerScrappersTools } from "./tools/scrappers.js";
import { registerAutheliaTools } from "./tools/authelia.js";
import { registerNocodbTools } from "./tools/nocodb.js";
import { registerRigTools } from "./tools/rig.js";

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
import { registerProxiedInfraTools, registerProxiedUserTools, startProxyRetryLoop } from "./tools/proxy-mcp.js";

const log = (msg: string) => process.stderr.write(`[c3-services] ${msg}\n`);

async function main() {
  const server = new McpServer({
    name: "c3-services",
    version: "2.1.0",
  });

  // ── Meta ──────────────────────────────────────────────────────
  registerRegistryTools(server);      //  5: list, info, spec, registry-mcp_search, registry-mcp_get
  registerProxyTools(server);         //  1: generic proxy
  registerDiscoveryTools(server);     //  1: discovery drift

  // ═══════════════════════════════════════════════════════════════
  // INFRA — ops, observability, automation, platform
  // ═══════════════════════════════════════════════════════════════
  registerMatomoTools(server);        //  5: visits, sites, actions, referrers, live
  registerUmamiTools(server);         //  6: websites, stats, pageviews, metrics, active, events
  registerNtfyTools(server);          //  5: health, publish, read, stats, tier
  registerSyncthingTools(server);     //  4: status, config, folders, devices
  registerOllamaTools(server);        //  3: models, generate, chat
  registerDaguTools(server);          //  2: list, trigger
  registerScrappersTools(server);
  registerAutheliaTools(server);      //  5: health, state, config, jwks, user_info
  registerNocodbTools(server);        //  7: bases, tables, rows, row_create, row_update, row_delete, table_info
  registerRigTools(server);           //  5: status, health, run, tasks, task_detail
  await registerProxiedInfraTools(server); // cloud-cgc-mcp (code graph, cloud knowledge)
                                      // ── infra subtotal: 69 + proxied

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
  await registerProxiedUserTools(server); // mattermost-mcp, mail-mcp, google-workspace-mcp
                                      // ── user subtotal: 65 + proxied

  const transport = new StdioServerTransport();
  log("Starting c3-services MCP server v2.2.0 (140 native tools)...");
  await server.connect(transport);
  log("Connected via stdio transport");

  // Background retry for child MCPs that failed initial connect
  startProxyRetryLoop(server);
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
