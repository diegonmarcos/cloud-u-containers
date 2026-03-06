import { readFileSync, existsSync } from "fs";
import { join } from "path";

export interface WGPeer {
  name: string;
  wg_ip: string;
  endpoint: string;
  role: "hub" | "spoke" | "client";
}

export function parseWireGuard(gitBase: string): WGPeer[] {
  // WireGuard peers are defined in home-manager nix configs
  // Parse from b_infra/home-manager/*/src/*.nix files
  const hmDir = join(gitBase, "cloud", "b_infra", "home-manager");
  if (!existsSync(hmDir)) return [];

  // Also check the SSH config for WG IPs (hostname field = WG IP for VM aliases)
  // The primary source is the SSH config which maps alias → WG IP
  // But for a complete mesh view, we parse WG configs from nix modules

  // Try to find wireguard.nix in home-manager modules
  const peers: WGPeer[] = [];
  const seen = new Set<string>();

  // Parse from cloud/b_infra/home-manager/modules/wireguard.nix
  const wgModulePath = join(hmDir, "modules", "wireguard.nix");
  if (existsSync(wgModulePath)) {
    const content = readFileSync(wgModulePath, "utf-8");
    extractPeersFromNix(content, peers, seen);
  }

  // Also scan per-VM config files
  try {
    const { readdirSync } = require("fs");
    const dirs = readdirSync(hmDir, { withFileTypes: true })
      .filter((d: any) => d.isDirectory() && !d.name.startsWith(".") && d.name !== "modules")
      .map((d: any) => d.name);

    for (const dir of dirs) {
      const nixFiles = [
        join(hmDir, dir, "src", `${dir}.nix`),
        join(hmDir, dir, "src", "wireguard.nix"),
      ];
      for (const nixFile of nixFiles) {
        if (existsSync(nixFile)) {
          const content = readFileSync(nixFile, "utf-8");
          extractPeersFromNix(content, peers, seen);
        }
      }
    }
  } catch {
    // ignore
  }

  return peers;
}

function extractPeersFromNix(content: string, peers: WGPeer[], seen: Set<string>): void {
  // Look for patterns like: Endpoint = "IP:PORT" and AllowedIPs = ["10.0.0.X/32"]
  // Or peer definitions with name, endpoint, allowed IPs

  // Pattern 1: WG peer blocks with name + endpoint + IP
  const peerBlocks = content.matchAll(/(?:name|alias)\s*=\s*"([^"]+)"[\s\S]*?(?:endpoint|Endpoint)\s*=\s*"([^"]*)"[\s\S]*?(?:allowedIPs|AllowedIPs)\s*=\s*\[\s*"([^"]+)/gi);
  for (const m of peerBlocks) {
    const name = m[1];
    if (seen.has(name)) continue;
    seen.add(name);
    const endpoint = m[2] || "dynamic";
    const wgIp = m[3].replace(/\/\d+$/, "");
    peers.push({
      name,
      wg_ip: wgIp,
      endpoint,
      role: endpoint === "dynamic" || endpoint === "" ? "client" : "spoke",
    });
  }

  // Pattern 2: Simple IP assignments like `Address = "10.0.0.X/24"`
  const addressMatch = content.match(/Address\s*=\s*"([^"]+)"/);
  if (addressMatch) {
    const ip = addressMatch[1].replace(/\/\d+$/, "");
    // This is the local peer — role determined by whether it has ListenPort
    const hasListenPort = content.includes("ListenPort");
    if (!seen.has(ip)) {
      seen.add(ip);
      // Don't add — this is the local host config, not a peer
    }
  }
}
