use crate::agent::run_agent_chat;
use crate::config::AppConfig;
use futures::{SinkExt, StreamExt};
use reqwest::Client;
use serde::Deserialize;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
use tokio::time::{sleep, Duration};
use tokio_tungstenite::{connect_async, tungstenite::Message as WsMessage};
use tracing::{debug, error, info, warn};

/// Per-channel conversation history (last N messages).
type ChatHistory = Arc<RwLock<HashMap<String, Vec<String>>>>;
const MAX_HISTORY: usize = 20;

/// Mattermost bot that listens for DMs and invokes the agentic loop.
pub async fn run_mattermost_bot(config: Arc<AppConfig>) {
    let token = match &config.mm_bot_token {
        Some(t) if !t.is_empty() => t.clone(),
        _ => {
            warn!("MM_BOT_TOKEN not set — Mattermost bot disabled");
            return;
        }
    };

    let history: ChatHistory = Arc::new(RwLock::new(HashMap::new()));

    loop {
        info!("Connecting to Mattermost WebSocket...");
        match connect_and_listen(&config, &token, &history).await {
            Ok(()) => info!("WebSocket connection closed cleanly"),
            Err(e) => error!(error = %e, "WebSocket connection failed"),
        }
        warn!("Reconnecting in 10s...");
        sleep(Duration::from_secs(10)).await;
    }
}

async fn connect_and_listen(
    config: &AppConfig,
    token: &str,
    history: &ChatHistory,
) -> Result<(), String> {
    // Build WebSocket URL: http://mattermost:8065 → ws://mattermost:8065/api/v4/websocket
    let ws_url = config
        .mm_url
        .replace("http://", "ws://")
        .replace("https://", "wss://");
    let ws_url = format!("{}/api/v4/websocket", ws_url.trim_end_matches('/'));

    let (ws_stream, _) = connect_async(&ws_url)
        .await
        .map_err(|e| format!("WebSocket connect failed: {}", e))?;

    let (mut write, mut read) = ws_stream.split();

    // Authenticate
    let auth_msg = serde_json::json!({
        "seq": 1,
        "action": "authentication_challenge",
        "data": { "token": token }
    });
    write
        .send(WsMessage::Text(auth_msg.to_string().into()))
        .await
        .map_err(|e| format!("Auth send failed: {}", e))?;

    info!("Mattermost WebSocket authenticated");

    // Get our bot user ID
    let bot_user_id = get_bot_user_id(&config.mm_url, token).await?;
    info!(bot_user_id = %bot_user_id, "Bot user identified");

    let http = Client::new();
    let config = Arc::new(config.clone());

    while let Some(msg) = read.next().await {
        let msg = match msg {
            Ok(WsMessage::Text(t)) => t.to_string(),
            Ok(WsMessage::Ping(_)) => continue,
            Ok(WsMessage::Close(_)) => {
                info!("WebSocket closed by server");
                break;
            }
            Err(e) => {
                error!(error = %e, "WebSocket read error");
                break;
            }
            _ => continue,
        };

        // Parse the event
        let event: serde_json::Value = match serde_json::from_str(&msg) {
            Ok(v) => v,
            Err(_) => continue,
        };

        let event_type = event.get("event").and_then(|e| e.as_str()).unwrap_or("");
        if event_type != "posted" {
            continue;
        }

        // Extract the post data
        let post_str = event
            .get("data")
            .and_then(|d| d.get("post"))
            .and_then(|p| p.as_str())
            .unwrap_or("");

        let post: MmPost = match serde_json::from_str(post_str) {
            Ok(p) => p,
            Err(_) => continue,
        };

        // Ignore our own messages
        if post.user_id == bot_user_id {
            continue;
        }

        // Only respond to DMs (channel type 'D') — check via data.channel_type
        let channel_type = event
            .get("data")
            .and_then(|d| d.get("channel_type"))
            .and_then(|t| t.as_str())
            .unwrap_or("");

        if channel_type != "D" {
            // Also check if bot was mentioned in non-DM channels
            if !post.message.contains("@ollama-14bq8-ai") {
                continue;
            }
        }

        let message = post.message.clone();
        let channel_id = post.channel_id.clone();
        let post_id = post.id.clone();
        let config_clone = config.clone();
        let http_clone = http.clone();
        let token_clone = token.to_string();
        let history_clone = history.clone();

        // Handle in background to not block the WS listener
        tokio::spawn(async move {
            handle_message(
                config_clone,
                &http_clone,
                &token_clone,
                &channel_id,
                &post_id,
                &message,
                &history_clone,
            )
            .await;
        });
    }

    Ok(())
}

#[derive(Deserialize)]
struct MmPost {
    id: String,
    user_id: String,
    channel_id: String,
    message: String,
}

async fn handle_message(
    config: Arc<AppConfig>,
    http: &Client,
    token: &str,
    channel_id: &str,
    post_id: &str,
    message: &str,
    history: &ChatHistory,
) {
    info!(channel = channel_id, message = message, "Handling message");

    // Handle special commands
    let trimmed = message.trim();
    if trimmed == "/clear" || trimmed == "/reset" {
        let mut h = history.write().await;
        h.remove(channel_id);
        post_reply(http, &config.mm_url, token, channel_id, post_id, "Context cleared.").await;
        return;
    }

    // Get conversation history
    let chat_history = {
        let h = history.read().await;
        h.get(channel_id).cloned().unwrap_or_default()
    };

    // Send "thinking" indicator
    post_reply(
        http,
        &config.mm_url,
        token,
        channel_id,
        post_id,
        ":hourglass: Thinking...",
    )
    .await;

    // Run the agent
    match run_agent_chat(config.clone(), message, chat_history).await {
        Ok(response) => {
            // Strip <think>...</think> tags from DeepSeek R1 reasoning
            let clean = strip_think_tags(&response);

            // Update history
            {
                let mut h = history.write().await;
                let entry = h.entry(channel_id.to_string()).or_default();
                entry.push(format!("User: {}", message));
                entry.push(format!("Assistant: {}", clean));
                // Keep last N messages
                while entry.len() > MAX_HISTORY * 2 {
                    entry.remove(0);
                }
            }

            // Post response (split if too long for Mattermost's 16383 char limit)
            let chunks = split_message(&clean, 15000);
            for chunk in chunks {
                post_reply(http, &config.mm_url, token, channel_id, post_id, &chunk).await;
            }
        }
        Err(e) => {
            error!(error = %e, "Agent failed");
            post_reply(
                http,
                &config.mm_url,
                token,
                channel_id,
                post_id,
                &format!(":x: Agent error: {}", e),
            )
            .await;
        }
    }
}

/// Post a reply in a Mattermost thread.
async fn post_reply(http: &Client, mm_url: &str, token: &str, channel_id: &str, root_id: &str, message: &str) {
    let url = format!("{}/api/v4/posts", mm_url);
    let body = serde_json::json!({
        "channel_id": channel_id,
        "root_id": root_id,
        "message": message,
    });

    match http
        .post(&url)
        .header("Authorization", format!("Bearer {}", token))
        .json(&body)
        .send()
        .await
    {
        Ok(r) if r.status().is_success() => {
            debug!("Reply posted to {}", channel_id);
        }
        Ok(r) => {
            let status = r.status();
            let text = r.text().await.unwrap_or_default();
            warn!(status = %status, body = %text, "Failed to post reply");
        }
        Err(e) => {
            error!(error = %e, "HTTP error posting reply");
        }
    }
}

/// Get the bot's own user ID from Mattermost.
async fn get_bot_user_id(mm_url: &str, token: &str) -> Result<String, String> {
    let url = format!("{}/api/v4/users/me", mm_url);
    let http = Client::new();
    let resp = http
        .get(&url)
        .header("Authorization", format!("Bearer {}", token))
        .send()
        .await
        .map_err(|e| format!("Failed to get bot user: {}", e))?;

    let body: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| format!("Failed to parse user response: {}", e))?;

    body.get("id")
        .and_then(|id| id.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| "No user id in response".to_string())
}

/// Strip <think>...</think> reasoning tags from DeepSeek R1 output.
fn strip_think_tags(text: &str) -> String {
    let mut result = String::new();
    let mut i = 0;
    let bytes = text.as_bytes();

    while i < bytes.len() {
        if text[i..].starts_with("<think>") {
            // Find closing tag
            if let Some(end) = text[i..].find("</think>") {
                i += end + "</think>".len();
                // Skip trailing newlines
                while i < bytes.len() && (bytes[i] == b'\n' || bytes[i] == b'\r') {
                    i += 1;
                }
                continue;
            }
        }
        result.push(bytes[i] as char);
        i += 1;
    }

    result.trim().to_string()
}

/// Split a message into chunks that fit Mattermost's limit.
fn split_message(text: &str, max_len: usize) -> Vec<String> {
    if text.len() <= max_len {
        return vec![text.to_string()];
    }

    let mut chunks = Vec::new();
    let mut remaining = text;

    while !remaining.is_empty() {
        if remaining.len() <= max_len {
            chunks.push(remaining.to_string());
            break;
        }
        // Try to split at a newline
        let split_at = remaining[..max_len]
            .rfind('\n')
            .unwrap_or(max_len);
        chunks.push(remaining[..split_at].to_string());
        remaining = &remaining[split_at..].trim_start_matches('\n');
    }

    chunks
}
