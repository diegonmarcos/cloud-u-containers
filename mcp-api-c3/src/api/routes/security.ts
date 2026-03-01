import { FastifyPluginAsync } from "fastify";
import { z } from "zod";
import { zodToJsonSchema } from "zod-to-json-schema";
import { securityScan, securityDocker, securitySshKeys, securityTokens } from "../../shared/security.js";
import { resolveVmId } from "../../shared/config.js";

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
        querystring: zodToJsonSchema(securityScanSchema, "securityScanSchema"),
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
        querystring: zodToJsonSchema(vmSchema, "vmSchema"),
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
        querystring: zodToJsonSchema(vmSchema, "vmSchema"),
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
};
