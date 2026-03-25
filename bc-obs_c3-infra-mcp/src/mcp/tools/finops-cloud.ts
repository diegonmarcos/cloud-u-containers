// ── FinOps Pillar — "What it costs" (7 tools) ──
// Cloud provider operations and cost tracking

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import * as oci from "../../shared/cloud/oci.js";
import * as gcp from "../../shared/cloud/gcp.js";
import * as aws from "../../shared/cloud/aws.js";

function jsonText(label: string, data: unknown): { content: { type: "text"; text: string }[] } {
  const text = typeof data === "string" ? data : JSON.stringify(data, null, 2);
  return { content: [{ type: "text" as const, text: `${label}\n\n${text}` }] };
}

export function registerFinOpsCloudTools(server: McpServer) {
  server.tool(
    "obs.finops.oci_instances",
    "List all OCI compute instances in the tenancy",
    {},
    async () => jsonText("OCI instances", oci.listInstances()),
  );

  server.tool(
    "obs.finops.gcp_instances",
    "List all GCP compute instances across zones",
    {},
    async () => jsonText("GCP instances", gcp.listInstances()),
  );

  server.tool(
    "obs.finops.oci_resources",
    "List OCI networking and storage resources (VCNs, subnets, boot volumes)",
    {},
    async () => jsonText("OCI resources", oci.listResources()),
  );

  server.tool(
    "obs.finops.gcp_resources",
    "List GCP disks, networks, and firewalls",
    {},
    async () => jsonText("GCP resources", gcp.listResources()),
  );

  server.tool(
    "obs.finops.oci_costs",
    "Get OCI usage costs for the last 30 days",
    {},
    async () => jsonText("OCI costs", oci.getCosts()),
  );

  server.tool(
    "obs.finops.gcp_costs",
    "Get GCP billing info for the project",
    {},
    async () => jsonText("GCP costs", gcp.getCosts()),
  );

  server.tool(
    "obs.finops.aws_instances",
    "List all AWS EC2 instances",
    {},
    async () => jsonText("AWS instances", aws.listInstances()),
  );

  server.tool(
    "obs.finops.aws_resources",
    "List AWS resources (S3 buckets, VPCs, SES identities)",
    {},
    async () => jsonText("AWS resources", aws.listResources()),
  );

  server.tool(
    "obs.finops.aws_costs",
    "Get AWS usage costs for the current month via Cost Explorer",
    {},
    async () => jsonText("AWS costs", aws.getCosts()),
  );

  server.tool(
    "cloud-data-summary",
    "Combined cloud summary — all OCI + GCP + AWS instances, resources, and costs in one call",
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
        aws: {
          instances: aws.listInstances(),
          resources: aws.listResources(),
          costs: aws.getCosts(),
        },
      };
      return jsonText("Cloud summary", summary);
    },
  );
}
