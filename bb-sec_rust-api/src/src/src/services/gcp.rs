use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use ring::signature::{RsaKeyPair, RSA_PKCS1_SHA256};
use serde::Deserialize;
use std::fs;
use std::sync::Arc;
use std::time::Instant;
use tokio::sync::RwLock;

const GCP_COMPUTE_BASE: &str = "https://compute.googleapis.com";
const GCP_TOKEN_URL: &str = "https://oauth2.googleapis.com/token";
const GCP_COMPUTE_SCOPE: &str = "https://www.googleapis.com/auth/cloud-platform";
const TOKEN_LIFETIME_SECS: u64 = 3600;
/// Refresh 60s before expiry to avoid edge-case failures.
const TOKEN_REFRESH_MARGIN_SECS: u64 = 60;

#[derive(Debug, Deserialize)]
pub struct ServiceAccountConfig {
    pub client_email: String,
    pub private_key: String,
    pub project_id: String,
}

pub type TokenCache = Arc<RwLock<Option<(String, Instant)>>>;

pub fn new_token_cache() -> TokenCache {
    Arc::new(RwLock::new(None))
}

/// Parse a GCP service account JSON key file.
pub fn parse_service_account(path: &str) -> Result<ServiceAccountConfig, String> {
    let content = fs::read_to_string(path)
        .map_err(|e| format!("Failed to read GCP service account at {path}: {e}"))?;
    serde_json::from_str(&content)
        .map_err(|e| format!("Failed to parse GCP service account JSON: {e}"))
}

/// Decode PEM private key to DER bytes.
fn pem_to_der(pem: &str) -> Option<Vec<u8>> {
    use base64::engine::general_purpose::STANDARD as B64;
    let mut b64 = String::new();
    let mut in_block = false;
    for line in pem.lines() {
        let line = line.trim();
        if line.contains("BEGIN") {
            in_block = true;
            continue;
        }
        if line.contains("END") {
            break;
        }
        if in_block {
            b64.push_str(line);
        }
    }
    B64.decode(&b64).ok()
}

/// Create a signed JWT for the GCP OAuth2 token exchange.
fn create_signed_jwt(sa: &ServiceAccountConfig) -> Result<String, String> {
    let now = chrono::Utc::now().timestamp() as u64;

    let header = serde_json::json!({"alg": "RS256", "typ": "JWT"});
    let claims = serde_json::json!({
        "iss": sa.client_email,
        "scope": GCP_COMPUTE_SCOPE,
        "aud": GCP_TOKEN_URL,
        "iat": now,
        "exp": now + TOKEN_LIFETIME_SECS,
    });

    let header_b64 = URL_SAFE_NO_PAD.encode(header.to_string().as_bytes());
    let claims_b64 = URL_SAFE_NO_PAD.encode(claims.to_string().as_bytes());
    let unsigned = format!("{header_b64}.{claims_b64}");

    // Parse the PEM private key
    let der = pem_to_der(&sa.private_key)
        .ok_or_else(|| "Failed to decode GCP service account PEM key".to_string())?;
    let key_pair = RsaKeyPair::from_pkcs8(&der)
        .map_err(|e| format!("Invalid GCP RSA key: {e}"))?;

    let mut signature = vec![0u8; key_pair.public().modulus_len()];
    let rng = ring::rand::SystemRandom::new();
    key_pair
        .sign(&RSA_PKCS1_SHA256, &rng, unsigned.as_bytes(), &mut signature)
        .map_err(|e| format!("JWT signing failed: {e}"))?;

    let sig_b64 = URL_SAFE_NO_PAD.encode(&signature);
    Ok(format!("{unsigned}.{sig_b64}"))
}

/// Get a valid OAuth2 access token, using the cache when possible.
pub async fn get_access_token(
    http: &reqwest::Client,
    sa: &ServiceAccountConfig,
    cache: &TokenCache,
) -> Result<String, String> {
    // Check cache
    {
        let guard = cache.read().await;
        if let Some((ref token, ref issued_at)) = *guard {
            let elapsed = issued_at.elapsed().as_secs();
            if elapsed < TOKEN_LIFETIME_SECS - TOKEN_REFRESH_MARGIN_SECS {
                return Ok(token.clone());
            }
        }
    }

    // Mint a new token
    let jwt = create_signed_jwt(sa)?;

    let resp = http
        .post(GCP_TOKEN_URL)
        .form(&[
            ("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer"),
            ("assertion", jwt.as_str()),
        ])
        .send()
        .await
        .map_err(|e| format!("GCP token request failed: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("GCP token exchange {status}: {body}"));
    }

    let json: serde_json::Value = resp.json().await
        .map_err(|e| format!("GCP token parse error: {e}"))?;
    let token = json["access_token"]
        .as_str()
        .ok_or("No access_token in GCP response")?
        .to_string();

    // Update cache
    {
        let mut guard = cache.write().await;
        *guard = Some((token.clone(), Instant::now()));
    }

    Ok(token)
}

/// Get the status of a GCP Compute Engine instance.
/// Returns: RUNNING, TERMINATED, STOPPED, STAGING, STOPPING, etc.
pub async fn get_instance_state(
    http: &reqwest::Client,
    sa: &ServiceAccountConfig,
    cache: &TokenCache,
    project: &str,
    zone: &str,
    instance_name: &str,
) -> Result<String, String> {
    let token = get_access_token(http, sa, cache).await?;

    let url = format!(
        "{GCP_COMPUTE_BASE}/compute/v1/projects/{project}/zones/{zone}/instances/{instance_name}"
    );

    let resp = http
        .get(&url)
        .bearer_auth(&token)
        .send()
        .await
        .map_err(|e| format!("GCP API error: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("GCP API {status}: {body}"));
    }

    let json: serde_json::Value = resp.json().await
        .map_err(|e| format!("GCP parse error: {e}"))?;
    Ok(json["status"]
        .as_str()
        .unwrap_or("UNKNOWN")
        .to_string())
}

/// Perform an action on a GCP instance: start, stop, or reset.
pub async fn instance_action(
    http: &reqwest::Client,
    sa: &ServiceAccountConfig,
    cache: &TokenCache,
    project: &str,
    zone: &str,
    instance_name: &str,
    action: &str,
) -> Result<String, String> {
    let token = get_access_token(http, sa, cache).await?;

    let url = format!(
        "{GCP_COMPUTE_BASE}/compute/v1/projects/{project}/zones/{zone}/instances/{instance_name}/{action}"
    );

    let resp = http
        .post(&url)
        .bearer_auth(&token)
        .send()
        .await
        .map_err(|e| format!("GCP API error: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("GCP API {status}: {body}"));
    }

    Ok(format!("{action} command sent"))
}

// ---------------------------------------------------------------------------
// Cloud provider endpoints — GCP
// ---------------------------------------------------------------------------

/// List all GCP compute instances (aggregated across zones).
pub async fn list_instances(
    http: &reqwest::Client,
    sa: &ServiceAccountConfig,
    cache: &TokenCache,
    project: &str,
) -> Result<serde_json::Value, String> {
    let token = get_access_token(http, sa, cache).await?;

    let url = format!(
        "{GCP_COMPUTE_BASE}/compute/v1/projects/{project}/aggregated/instances"
    );

    let resp = http.get(&url).bearer_auth(&token).send().await
        .map_err(|e| format!("GCP API error: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("GCP API {status}: {body}"));
    }

    let data: serde_json::Value = resp.json().await
        .map_err(|e| format!("GCP parse error: {e}"))?;

    // Flatten aggregated results
    let mut instances = Vec::new();
    if let Some(items) = data["items"].as_object() {
        for (_zone_key, zone_data) in items {
            if let Some(zone_instances) = zone_data["instances"].as_array() {
                for i in zone_instances {
                    instances.push(serde_json::json!({
                        "name": i["name"],
                        "status": i["status"],
                        "zone": i["zone"],
                        "machineType": i["machineType"],
                        "creationTimestamp": i["creationTimestamp"],
                        "networkInterfaces": i["networkInterfaces"],
                    }));
                }
            }
        }
    }

    Ok(serde_json::json!({
        "provider": "gcp",
        "project": project,
        "instances": instances,
        "count": instances.len(),
    }))
}

/// List GCP networking and storage resources (disks, networks, firewalls).
pub async fn list_resources(
    http: &reqwest::Client,
    sa: &ServiceAccountConfig,
    cache: &TokenCache,
    project: &str,
) -> Result<serde_json::Value, String> {
    let token = get_access_token(http, sa, cache).await?;

    let disks_url = format!(
        "{GCP_COMPUTE_BASE}/compute/v1/projects/{project}/aggregated/disks"
    );
    let networks_url = format!(
        "{GCP_COMPUTE_BASE}/compute/v1/projects/{project}/global/networks"
    );
    let firewalls_url = format!(
        "{GCP_COMPUTE_BASE}/compute/v1/projects/{project}/global/firewalls"
    );

    let token2 = token.clone();
    let token3 = token.clone();

    let (disks_res, networks_res, firewalls_res) = tokio::join!(
        async {
            http.get(&disks_url).bearer_auth(&token).send().await
                .map_err(|e| format!("GCP disks error: {e}"))
        },
        async {
            http.get(&networks_url).bearer_auth(&token2).send().await
                .map_err(|e| format!("GCP networks error: {e}"))
        },
        async {
            http.get(&firewalls_url).bearer_auth(&token3).send().await
                .map_err(|e| format!("GCP firewalls error: {e}"))
        },
    );

    let disks: serde_json::Value = match disks_res {
        Ok(r) if r.status().is_success() => r.json().await.unwrap_or(serde_json::json!({})),
        _ => serde_json::json!({"error": "failed to fetch disks"}),
    };
    let networks: serde_json::Value = match networks_res {
        Ok(r) if r.status().is_success() => r.json().await.unwrap_or(serde_json::json!({})),
        _ => serde_json::json!({"error": "failed to fetch networks"}),
    };
    let firewalls: serde_json::Value = match firewalls_res {
        Ok(r) if r.status().is_success() => r.json().await.unwrap_or(serde_json::json!({})),
        _ => serde_json::json!({"error": "failed to fetch firewalls"}),
    };

    Ok(serde_json::json!({
        "provider": "gcp",
        "project": project,
        "disks": disks,
        "networks": networks,
        "firewalls": firewalls,
    }))
}

/// Get GCP billing info for the project.
pub async fn get_billing_info(
    http: &reqwest::Client,
    sa: &ServiceAccountConfig,
    cache: &TokenCache,
    project: &str,
) -> Result<serde_json::Value, String> {
    let token = get_access_token(http, sa, cache).await?;

    let url = format!(
        "https://cloudbilling.googleapis.com/v1/projects/{project}/billingInfo"
    );

    let resp = http.get(&url).bearer_auth(&token).send().await
        .map_err(|e| format!("GCP Billing API error: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("GCP Billing API {status}: {body}"));
    }

    let data: serde_json::Value = resp.json().await
        .map_err(|e| format!("GCP billing parse error: {e}"))?;

    Ok(serde_json::json!({
        "provider": "gcp",
        "project": project,
        "billing_info": data,
    }))
}
