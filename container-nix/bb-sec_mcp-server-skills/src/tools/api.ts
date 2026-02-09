import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { exec } from "../utils/exec.js";
import { sshExec } from "../utils/ssh.js";
import { getConfig, resolveVmId } from "../config.js";

export function registerApiTools(server: McpServer) {
  server.tool(
    "api_call",
    "Call the Flask API (api.diegonmarcos.com) endpoint",
    {
      endpoint: z.string().describe("API endpoint path (e.g. /health, /vms/status)"),
      method: z.enum(["GET", "POST", "PUT", "DELETE"]).optional().describe("HTTP method (default: GET)"),
      body: z.string().optional().describe("JSON request body for POST/PUT"),
    },
    async ({ endpoint, method, body }) => {
      const httpMethod = method ?? "GET";
      const url = `https://api.diegonmarcos.com${endpoint}`;

      const args = ["-s", "-S", "-X", httpMethod, "-H", "Content-Type: application/json"];
      if (body && (httpMethod === "POST" || httpMethod === "PUT")) {
        args.push("-d", body);
      }
      args.push(url);

      const result = exec("curl", args, { timeout: 30_000 });

      return {
        content: [
          {
            type: "text",
            text: `${httpMethod} ${endpoint}: ${result.ok ? "OK" : "FAILED"}\n\n${result.stdout}${result.stderr ? `\nError: ${result.stderr}` : ""}`,
          },
        ],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "api_vm_control",
    "Start, stop, or reset a VM via OCI SDK / gcloud CLI",
    {
      vm: z.string().describe("VM ID or SSH alias"),
      action: z.enum(["start", "stop", "reset"]).describe("VM control action"),
    },
    async ({ vm, action }) => {
      const vmId = resolveVmId(vm);
      const config = getConfig();
      const vmConfig = config.vms[vmId];

      if (!vmConfig) {
        return { content: [{ type: "text", text: `Unknown VM: ${vm}` }], isError: true };
      }

      let result;

      if (vmConfig.method === "gcloud") {
        const instance = vmConfig.gcloud_instance!;
        const zone = vmConfig.gcloud_zone!;
        const gcloudAction = action === "reset" ? "reset" : action;
        result = exec(
          "gcloud",
          ["compute", "instances", gcloudAction, instance, "--zone", zone, "--quiet"],
          { timeout: 60_000 }
        );
      } else {
        // OCI VMs — use the Flask API to control
        const ociAction = action === "reset" ? "RESET" : action === "start" ? "START" : "STOP";
        const apiResult = exec(
          "curl",
          [
            "-s",
            "-S",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "-d",
            JSON.stringify({ vm: vmId, action: ociAction }),
            "https://api.diegonmarcos.com/vms/control",
          ],
          { timeout: 60_000 }
        );
        result = apiResult;
      }

      return {
        content: [
          {
            type: "text",
            text: `VM ${action} ${vmId}: ${result.ok ? "OK" : "FAILED"}\n\n${result.stdout}${result.stderr ? `\nError: ${result.stderr}` : ""}`,
          },
        ],
        isError: !result.ok,
      };
    }
  );
}
