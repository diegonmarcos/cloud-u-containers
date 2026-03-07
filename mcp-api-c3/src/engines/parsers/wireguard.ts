// wireguard.ts — Parse WireGuard topology + OS firewall rules from home-manager nix configs
//
// Sources:
//   b_infra/home-manager/_shared/wireguard.nix   → mesh topology (peers, IPs, roles)
//   b_infra/home-manager/*/src/{vm}.nix          → firewall.nix import (per-VM public ports)

import { readFileSync, readdirSync, existsSync } from "fs";
import { join } from "path";

// --- Types ---

export interface WGPeer {
  name: string;
  wg_ip: string;
  endpoint: string;
  role: "hub" | "spoke" | "client";
  port?: number;
}

export interface OSFirewallRule {
  port: number;
  proto: string;
  desc: string;
}

export interface OSFirewall {
  vm: string;         // SSH alias (e.g. "oci-apps")
  rules: OSFirewallRule[];
}

// --- Main ---

export function parseWireGuard(gitBase: string): WGPeer[] {
  const hmDir = join(gitBase, "cloud", "b_infra", "home-manager");

  // Primary source: _shared/wireguard.nix has the canonical topology
  const sharedWg = join(hmDir, "_shared", "wireguard.nix");
  if (existsSync(sharedWg)) {
    const content = readFileSync(sharedWg, "utf-8");
    const peers = parseNixTopology(content);
    if (peers.length > 0) return peers;
  }

  // Fallback: scan per-VM wireguard.nix files
  const peers: WGPeer[] = [];
  const seen = new Set<string>();
  try {
    const dirs = readdirSync(hmDir, { withFileTypes: true })
      .filter(d => d.isDirectory() && !d.name.startsWith(".") && d.name !== "_shared")
      .map(d => d.name);

    for (const dir of dirs) {
      const wgFile = join(hmDir, dir, "src", "wireguard.nix");
      if (existsSync(wgFile)) {
        const content = readFileSync(wgFile, "utf-8");
        for (const peer of parseNixTopology(content)) {
          if (!seen.has(peer.name)) {
            seen.add(peer.name);
            peers.push(peer);
          }
        }
      }
    }
  } catch { /* ignore */ }

  return peers;
}

export function parseOSFirewalls(gitBase: string): OSFirewall[] {
  const hmDir = join(gitBase, "cloud", "b_infra", "home-manager");
  const firewalls: OSFirewall[] = [];

  try {
    const dirs = readdirSync(hmDir, { withFileTypes: true })
      .filter(d => d.isDirectory() && !d.name.startsWith(".") && d.name !== "_shared")
      .map(d => d.name);

    for (const dir of dirs) {
      const vmNix = join(hmDir, dir, "src", `${dir}.nix`);
      if (!existsSync(vmNix)) continue;

      const content = readFileSync(vmNix, "utf-8");
      const rules = parseFirewallImport(content);
      firewalls.push({ vm: dir, rules });
    }
  } catch { /* ignore */ }

  return firewalls;
}

// --- Parsers ---

/** Parse the nix topology attrset from wireguard.nix */
function parseNixTopology(content: string): WGPeer[] {
  const peers: WGPeer[] = [];

  // Match: topology = { ... };
  const topoMatch = content.match(/topology\s*=\s*\{/);
  if (!topoMatch) return peers;

  // Find the topology block
  const startIdx = topoMatch.index! + topoMatch[0].length;
  let depth = 1;
  let i = startIdx;
  while (i < content.length && depth > 0) {
    if (content[i] === "{") depth++;
    else if (content[i] === "}") depth--;
    i++;
  }
  const topoBody = content.slice(startIdx, i - 1);

  // Match each peer block: name = { address = "..."; endpoint = "..."; ... };
  const peerRe = /(\w[\w-]*)\s*=\s*\{([^}]+)\}/g;
  let m: RegExpExecArray | null;

  while ((m = peerRe.exec(topoBody)) !== null) {
    const name = m[1];
    const body = m[2];

    // Skip comments-only blocks
    if (body.trim().startsWith("#")) continue;

    const address = extractNixField(body, "address");
    const endpoint = extractNixField(body, "endpoint");
    const port = extractNixField(body, "port");
    const role = extractNixField(body, "role") as "hub" | "spoke" | "client" | null;

    if (!address) continue;

    peers.push({
      name,
      wg_ip: address,
      endpoint: endpoint === "null" || !endpoint ? "dynamic" : `${endpoint}:${port || "51820"}`,
      role: role || "spoke",
      ...(port && port !== "null" ? { port: parseInt(port) } : {}),
    });
  }

  return peers;
}

/** Parse firewall.nix import from a VM's nix config to extract publicPorts */
function parseFirewallImport(content: string): OSFirewallRule[] {
  const rules: OSFirewallRule[] = [];

  // Match: (import ./modules/firewall.nix { ... publicPorts = [ ... ]; })
  const fwMatch = content.match(/import\s+\.\/modules\/firewall\.nix\s*\{([\s\S]*?)\}\s*\)/);
  if (!fwMatch) return rules;

  const fwBody = fwMatch[1];

  // Find publicPorts = [ ... ];
  const portsMatch = fwBody.match(/publicPorts\s*=\s*\[/);
  if (!portsMatch) return rules;

  const startIdx = portsMatch.index! + portsMatch[0].length;
  let depth = 1;
  let i = startIdx;
  while (i < fwBody.length && depth > 0) {
    if (fwBody[i] === "[") depth++;
    else if (fwBody[i] === "]") depth--;
    i++;
  }
  const portsBody = fwBody.slice(startIdx, i - 1);

  // Match each rule: { port = N; proto = "tcp"; desc = "..."; }
  const ruleRe = /\{([^}]+)\}/g;
  let rm: RegExpExecArray | null;
  while ((rm = ruleRe.exec(portsBody)) !== null) {
    const ruleBody = rm[1];
    const port = extractNixField(ruleBody, "port");
    const proto = extractNixField(ruleBody, "proto") || "tcp";
    const desc = extractNixField(ruleBody, "desc") || "";

    if (port) {
      rules.push({ port: parseInt(port), proto, desc });
    }
  }

  return rules;
}

/** Extract a simple field = "value" or field = value from nix attrset body */
function extractNixField(body: string, key: string): string | null {
  // Match: key = "value"; or key = value; or key = null;
  const re = new RegExp(`${key}\\s*=\\s*(?:"([^"]*)"|(\\w[\\w.-]*))\\s*;`);
  const m = body.match(re);
  if (!m) return null;
  return m[1] !== undefined ? m[1] : m[2];
}
