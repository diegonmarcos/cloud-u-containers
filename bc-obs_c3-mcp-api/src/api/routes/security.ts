// ── Security Routes — "Is it safe" ──
// Security scanning, auditing, topology, secrets status

import { FastifyPluginAsync } from "fastify";
import { z } from "zod";
import { zodToJsonSchema } from "zod-to-json-schema";
import { securityScan, securityDocker, securitySshKeys, securityTokens } from "../../shared/security.js";
import { sshExec } from "../../shared/ssh.js";
import { getConfig, getVmSshAlias, resolveVmId } from "../../shared/config.js";
import { getSecretsStatus } from "../../shared/files.js";
import { CONFIG_PATH } from "../../shared/paths.js";
import { readFileSync } from "fs";

const securityScanSchema = z.object({
  vm: z.string().optional(),
});

const vmSchema = z.object({
  vm: z.string(),
});

export const registerSecurityRoutes: FastifyPluginAsync = async (app) => {
  app.get(
    "/security/scan",
    {
      schema: {
        tags: ["Security"],
        summary: "Full security scan across VMs",
        querystring: zodToJsonSchema(securityScanSchema),
        response: { 200: { type: "object" } },
      },
    },
    async (req) => {
      const { vm } = securityScanSchema.parse(req.query);
      const vmId = vm ? resolveVmId(vm) : undefined;
      return securityScan(vmId);
    }
  );

  app.get(
    "/security/docker",
    {
      schema: {
        tags: ["Security"],
        summary: "Docker-specific security checks",
        querystring: zodToJsonSchema(vmSchema),
        response: { 200: { type: "object" } },
      },
    },
    async (req) => {
      const { vm } = vmSchema.parse(req.query);
      const vmId = resolveVmId(vm);
      return securityDocker(vmId);
    }
  );

  app.get(
    "/security/ssh",
    {
      schema: {
        tags: ["Security"],
        summary: "SSH key permissions and config check",
        querystring: zodToJsonSchema(vmSchema),
        response: { 200: { type: "object" } },
      },
    },
    async (req) => {
      const { vm } = vmSchema.parse(req.query);
      const vmId = resolveVmId(vm);
      return securitySshKeys(vmId);
    }
  );

  app.get(
    "/security/tokens",
    {
      schema: {
        tags: ["Security"],
        summary: "Check for exposed secrets/tokens in containers",
        response: { 200: { type: "object" } },
      },
    },
    async () => {
      return securityTokens();
    }
  );

  // ── Security topology (derived from cloud-topology.json) ──

  app.get(
    "/topology/security",
    { schema: { tags: ["Security"] } },
    async () => {
      const topo = JSON.parse(readFileSync(CONFIG_PATH, "utf-8"));
      const exposed = Object.entries(topo.services as Record<string, any>)
        .filter(([, s]) => s.domain)
        .map(([name, s]: [string, any]) => ({ name, domain: s.domain, vm: s.vm }));
      return { exposedServices: exposed, vms: Object.entries(topo.vms as Record<string, any>).map(([id, vm]: [string, any]) => ({ id, alias: vm.ssh_alias, ip: vm.ip, method: vm.method })) };
    }
  );

  // ── Network topology (from cloud-topology.json — networks per VM) ──

  app.get(
    "/topology/network",
    { schema: { tags: ["Security"], summary: "Docker networks and container isolation per VM" } },
    async () => {
      const topo = JSON.parse(readFileSync(CONFIG_PATH, "utf-8"));
      return Object.entries(topo.vms as Record<string, any>).map(([id, vm]: [string, any]) => {
        const vmServices = Object.entries(topo.services as Record<string, any>).filter(([, s]: [string, any]) => s.vm === id);
        const netMap: Record<string, string[]> = {};
        for (const [name, svc] of vmServices) {
          for (const n of (svc as any).networks || []) {
            if (!netMap[n]) netMap[n] = [];
            netMap[n].push(name);
          }
        }
        return {
          vm: vm.ssh_alias,
          networks: Object.entries(netMap).map(([name, svcs]) => ({ name, driver: "bridge", containers: svcs })),
        };
      });
    }
  );

  // ── WireGuard mesh status ──

  app.get(
    "/security/wireguard",
    { schema: { tags: ["Security"], summary: "WireGuard peer status across all VMs" } },
    async () => {
      const config = getConfig();
      const results: Array<{ vm: string; peers: Array<{ endpoint: string; allowedIps: string; latestHandshake: string; transfer: string }> }> = [];
      for (const vmId of Object.keys(config.vms)) {
        const alias = getVmSshAlias(vmId);
        const r = sshExec(vmId, "sudo wg show all 2>/dev/null || echo 'no-wg'", 8_000);
        if (!r.ok || r.stdout.includes("no-wg")) {
          results.push({ vm: alias, peers: [] });
          continue;
        }
        const peers: Array<{ endpoint: string; allowedIps: string; latestHandshake: string; transfer: string }> = [];
        const blocks = r.stdout.split(/\npeer: /);
        for (let i = 1; i < blocks.length; i++) {
          const b = blocks[i];
          const get = (k: string) => { const m = b.match(new RegExp(k + ":\\s*(.+)")); return m ? m[1].trim() : ""; };
          peers.push({
            endpoint: get("endpoint"),
            allowedIps: get("allowed ips"),
            latestHandshake: get("latest handshake"),
            transfer: get("transfer"),
          });
        }
        results.push({ vm: alias, peers });
      }
      return results;
    }
  );

  // ── Secrets status (from files.ts) ──

  app.get<{ Params: { service: string } }>(
    "/files/secrets/:service",
    { schema: { tags: ["Security"], params: { type: "object" as const, properties: { service: { type: "string" as const } }, required: ["service"] } } },
    async (req) => {
      return { content: getSecretsStatus(req.params.service) };
    },
  );
};
