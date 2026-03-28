use rmcp::model::{ClientCapabilities, ClientInfo, Implementation};
use rmcp::transport::StreamableHttpClientTransport;
use rmcp::ServiceExt;
use tracing::{error, info};

/// Connect to the MCP server via Streamable HTTP.
/// Returns (tools, peer) ready to pass to .rmcp_tools().
pub async fn connect_mcp(
    mcp_url: &str,
) -> Result<(Vec<rmcp::model::Tool>, rmcp::service::ServerSink), String> {
    info!(url = mcp_url, "Connecting to MCP server");

    let transport = StreamableHttpClientTransport::from_uri(mcp_url);

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

    let tools = client
        .list_tools(Default::default())
        .await
        .map_err(|e| format!("Failed to list MCP tools: {}", e))?
        .tools;

    info!(count = tools.len(), "Discovered MCP tools");

    let peer = client.peer().to_owned();
    Ok((tools, peer))
}
