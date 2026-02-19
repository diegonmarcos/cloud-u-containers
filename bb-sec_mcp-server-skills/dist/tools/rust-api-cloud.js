import { rustApiGet } from "../utils/http.js";
function formatResult(label, result) {
    if (!result.ok) {
        return {
            content: [{ type: "text", text: `${label}: FAILED (HTTP ${result.status})\n${result.error ?? ""}\n${result.raw}` }],
            isError: true,
        };
    }
    const text = typeof result.data === "string" ? result.data : JSON.stringify(result.data, null, 2);
    return {
        content: [{ type: "text", text: `${label}: OK\n\n${text}` }],
    };
}
export function registerRustApiCloudTools(server) {
    // ── Cloud Provider Endpoints (7 tools) ──
    server.tool("cloud_oci_instances", "List all OCI compute instances in the tenancy", {}, async () => {
        const result = rustApiGet("/api/cloud/oci/instances", 30_000);
        return formatResult("OCI instances", result);
    });
    server.tool("cloud_gcp_instances", "List all GCP compute instances across zones", {}, async () => {
        const result = rustApiGet("/api/cloud/gcp/instances", 30_000);
        return formatResult("GCP instances", result);
    });
    server.tool("cloud_oci_resources", "List OCI networking and storage resources (VCNs, subnets, boot volumes)", {}, async () => {
        const result = rustApiGet("/api/cloud/oci/resources", 30_000);
        return formatResult("OCI resources", result);
    });
    server.tool("cloud_gcp_resources", "List GCP disks, networks, and firewalls", {}, async () => {
        const result = rustApiGet("/api/cloud/gcp/resources", 30_000);
        return formatResult("GCP resources", result);
    });
    server.tool("cloud_oci_costs", "Get OCI usage costs for the last 30 days", {}, async () => {
        const result = rustApiGet("/api/cloud/oci/costs", 30_000);
        return formatResult("OCI costs", result);
    });
    server.tool("cloud_gcp_costs", "Get GCP billing info for the project", {}, async () => {
        const result = rustApiGet("/api/cloud/gcp/costs", 30_000);
        return formatResult("GCP costs", result);
    });
    server.tool("cloud_summary", "Combined cloud summary — all OCI + GCP instances, resources, and costs in one call", {}, async () => {
        // 60s: fetches all 6 cloud endpoints in parallel server-side
        const result = rustApiGet("/api/cloud/summary", 60_000);
        return formatResult("Cloud summary", result);
    });
}
//# sourceMappingURL=rust-api-cloud.js.map