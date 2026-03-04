use rmcp::model::{ClientCapabilities, ClientInfo, Implementation};
use rmcp::service::RunningService;
use rmcp::transport::StreamableHttpClientTransport;
use rmcp::RoleClient;
use rmcp::ServiceExt;
use tracing::{error, info};

/// Connect to the MCP server via Streamable HTTP and return the running client.
pub async fn connect_mcp(
    mcp_url: &str,
) -> Result<RunningService<RoleClient>, String> {
    info!(url = mcp_url, "Connecting to MCP server");

    let transport = StreamableHttpClientTransport::from_uri(mcp_url)
        .map_err(|e| format!("Failed to create MCP transport: {}", e))?;

    let client_info = ClientInfo {
        protocol_version: Default::default(),
        capabilities: ClientCapabilities::default(),
        client_info: Implementation {
            name: "rig-agentic".to_string(),
            version: "0.2.0".to_string(),
            ..Default::default()
        },
        ..Default::default()
    };

    let client = client_info
        .serve(transport)
        .await
        .map_err(|e| {
            error!(error = %e, "MCP connection failed");
            format!("MCP connection failed: {}", e)
        })?;

    info!("MCP client connected successfully");
    Ok(client)
}

/// List all available tools from the MCP server.
pub async fn list_mcp_tools(
    client: &RunningService<RoleClient>,
) -> Result<Vec<rmcp::model::Tool>, String> {
    let result = client
        .list_tools(Default::default())
        .await
        .map_err(|e| format!("Failed to list MCP tools: {}", e))?;

    info!(count = result.tools.len(), "Discovered MCP tools");
    Ok(result.tools)
}
