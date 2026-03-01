import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import * as oci from "../../shared/cloud/oci.js";
import * as gcp from "../../shared/cloud/gcp.js";

function jsonText(label: string, data: unknown): { content: { type: "text"; text: string }[] } {
  const text = typeof data === "string" ? data : JSON.stringify(data, null, 2);
  return { content: [{ type: "text" as const, text: `${label}\n\n${text}` }] };
}

export function registerCloudTools(server: McpServer) {
  server.tool(
    "cloud_oci_instances",
    "List all OCI compute instances in the tenancy",
    {},
    async () => jsonText("OCI instances", oci.listInstances()),
  );

  server.tool(
    "cloud_gcp_instances",
    "List all GCP compute instances across zones",
    {},
    async () => jsonText("GCP instances", gcp.listInstances()),
  );

  server.tool(
    "cloud_oci_resources",
    "List OCI networking and storage resources (VCNs, subnets, boot volumes)",
    {},
    async () => jsonText("OCI resources", oci.listResources()),
  );

  server.tool(
    "cloud_gcp_resources",
    "List GCP disks, networks, and firewalls",
    {},
    async () => jsonText("GCP resources", gcp.listResources()),
  );

  server.tool(
    "cloud_oci_costs",
    "Get OCI usage costs for the last 30 days",
    {},
    async () => jsonText("OCI costs", oci.getCosts()),
  );

  server.tool(
    "cloud_gcp_costs",
    "Get GCP billing info for the project",
    {},
    async () => jsonText("GCP costs", gcp.getCosts()),
  );

  server.tool(
    "cloud_summary",
    "Combined cloud summary — all OCI + GCP instances, resources, and costs in one call",
    {},
    async () => {
      const summary = {
        oci: {
          instances: oci.listInstances(),
          resources: oci.listResources(),
          costs: oci.getCosts(),
        },
        gcp: {
          instances: gcp.listInstances(),
          resources: gcp.listResources(),
          costs: gcp.getCosts(),
        },
      };
      return jsonText("Cloud summary", summary);
    },
  );
}
