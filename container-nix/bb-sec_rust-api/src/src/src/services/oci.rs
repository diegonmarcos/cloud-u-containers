use crate::config::AppConfig;
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use chrono::{Utc, Duration as ChronoDuration};
use ring::signature::{RsaKeyPair, RSA_PKCS1_SHA256};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs;

struct OciConfig {
    tenancy: String,
    user: String,
    fingerprint: String,
    region: String,
    key_file: String,
}

/// Parse OCI config file to extract tenancy, user, fingerprint, region, key_file.
fn parse_oci_config(path: &str) -> Option<OciConfig> {
    let content = fs::read_to_string(path).ok()?;
    let mut tenancy = None;
    let mut user = None;
    let mut fingerprint = None;
    let mut region = None;
    let mut key_file = None;

    for line in content.lines() {
        let line = line.trim();
        if line.starts_with('#') || line.starts_with('[') || !line.contains('=') {
            continue;
        }
        let (k, v) = line.split_once('=')?;
        match k.trim() {
            "tenancy" => tenancy = Some(v.trim().to_string()),
            "user" => user = Some(v.trim().to_string()),
            "fingerprint" => fingerprint = Some(v.trim().to_string()),
            "region" => region = Some(v.trim().to_string()),
            "key_file" => key_file = Some(v.trim().to_string()),
            _ => {}
        }
    }

    Some(OciConfig {
        tenancy: tenancy?,
        user: user?,
        fingerprint: fingerprint?,
        region: region.unwrap_or_else(|| "eu-marseille-1".into()),
        key_file: key_file?,
    })
}

/// Build OCI API base URL from region.
fn api_base(region: &str) -> String {
    format!("https://iaas.{region}.oraclecloud.com/20160918")
}

/// Sign an OCI API request using RSA-SHA256 (HTTP Signature scheme).
fn sign_request(
    oci_cfg: &OciConfig,
    method: &str,
    path: &str,
    host: &str,
    body: Option<&str>,
) -> Result<Vec<(String, String)>, String> {
    let date = Utc::now().format("%a, %d %b %Y %H:%M:%S GMT").to_string();
    let request_target = format!("{} {}", method.to_lowercase(), path);

    let mut headers = vec![
        ("date".to_string(), date.clone()),
        ("host".to_string(), host.to_string()),
    ];

    let signing_string;
    let signed_headers;

    if let Some(body) = body {
        let body_hash = B64.encode(Sha256::digest(body.as_bytes()));
        let content_len = body.len().to_string();

        headers.push(("content-type".to_string(), "application/json".to_string()));
        headers.push(("content-length".to_string(), content_len.clone()));
        headers.push(("x-content-sha256".to_string(), body_hash.clone()));

        signing_string = format!(
            "(request-target): {}\ndate: {}\nhost: {}\ncontent-type: application/json\ncontent-length: {}\nx-content-sha256: {}",
            request_target, date, host, content_len, body_hash
        );
        signed_headers = "(request-target) date host content-type content-length x-content-sha256";
    } else {
        signing_string = format!(
            "(request-target): {}\ndate: {}\nhost: {}",
            request_target, date, host
        );
        signed_headers = "(request-target) date host";
    }

    // Read PEM key
    let key_path = if oci_cfg.key_file.starts_with('~') {
        oci_cfg.key_file.replacen('~', &std::env::var("HOME").unwrap_or_default(), 1)
    } else {
        oci_cfg.key_file.clone()
    };
    let pem_data = fs::read_to_string(&key_path)
        .map_err(|e| format!("Failed to read OCI key at {key_path}: {e}"))?;

    // Parse PEM -> DER
    let der = pem_to_der(&pem_data)
        .ok_or_else(|| "Failed to parse PEM key".to_string())?;

    let key_pair = RsaKeyPair::from_pkcs8(&der)
        .map_err(|e| format!("Invalid RSA key: {e}"))?;

    let mut signature = vec![0u8; key_pair.public().modulus_len()];
    let rng = ring::rand::SystemRandom::new();
    key_pair
        .sign(&RSA_PKCS1_SHA256, &rng, signing_string.as_bytes(), &mut signature)
        .map_err(|e| format!("Signing failed: {e}"))?;

    let b64_sig = B64.encode(&signature);
    let key_id = format!("{}/{}/{}", oci_cfg.tenancy, oci_cfg.user, oci_cfg.fingerprint);
    let auth_header = format!(
        "Signature version=\"1\",keyId=\"{}\",algorithm=\"rsa-sha256\",headers=\"{}\",signature=\"{}\"",
        key_id, signed_headers, b64_sig
    );

    headers.push(("authorization".to_string(), auth_header));
    Ok(headers)
}

/// Decode PEM to DER bytes.
fn pem_to_der(pem: &str) -> Option<Vec<u8>> {
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

/// Get the lifecycle state of an OCI instance.
pub async fn get_instance_state(
    http: &reqwest::Client,
    config: &AppConfig,
    instance_id: &str,
) -> Result<String, String> {
    let oci_cfg = parse_oci_config(&config.oci_config_file)
        .ok_or("OCI config not found")?;

    let path = format!("/20160918/instances/{instance_id}");
    let host = format!("iaas.{}.oraclecloud.com", oci_cfg.region);
    let url = format!("{}/instances/{instance_id}", api_base(&oci_cfg.region));

    let headers = sign_request(&oci_cfg, "GET", &path, &host, None)?;

    let mut req = http.get(&url);
    for (k, v) in headers {
        req = req.header(&k, &v);
    }

    let resp = req.send().await.map_err(|e| format!("OCI API error: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("OCI API {status}: {body}"));
    }

    let json: serde_json::Value = resp.json().await.map_err(|e| format!("Parse error: {e}"))?;
    Ok(json["lifecycleState"]
        .as_str()
        .unwrap_or("UNKNOWN")
        .to_string())
}

/// Perform an action on an OCI instance (START, STOP, SOFTRESET, RESET).
pub async fn instance_action(
    http: &reqwest::Client,
    config: &AppConfig,
    instance_id: &str,
    action: &str,
) -> Result<String, String> {
    let oci_cfg = parse_oci_config(&config.oci_config_file)
        .ok_or("OCI config not found")?;

    let path = format!("/20160918/instances/{instance_id}?action={action}");
    let host = format!("iaas.{}.oraclecloud.com", oci_cfg.region);
    let url = format!("{}/instances/{instance_id}?action={action}", api_base(&oci_cfg.region));

    let headers = sign_request(&oci_cfg, "POST", &path, &host, Some(""))?;

    let mut req = http.post(&url).body("");
    for (k, v) in headers {
        req = req.header(&k, &v);
    }

    let resp = req.send().await.map_err(|e| format!("OCI API error: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("OCI API {status}: {body}"));
    }

    Ok(format!("{action} command sent"))
}

/// Query OCI Object Storage: list buckets and get approximate size/count.
pub async fn get_object_storage_info(
    http: &reqwest::Client,
    config: &AppConfig,
    quota_gb: f64,
) -> Result<serde_json::Value, String> {
    let oci_cfg = parse_oci_config(&config.oci_config_file)
        .ok_or("OCI config not found")?;

    let namespace = &config.oci_namespace;
    if namespace.is_empty() {
        return Err("OCI namespace not configured".into());
    }

    let host = format!("objectstorage.{}.oraclecloud.com", oci_cfg.region);

    // List buckets in compartment (tenancy = default compartment)
    let path = format!("/n/{namespace}/b/?compartmentId={}", oci_cfg.tenancy);
    let url = format!("https://{host}{path}");

    let headers = sign_request(&oci_cfg, "GET", &path, &host, None)?;
    let mut req = http.get(&url);
    for (k, v) in headers {
        req = req.header(&k, &v);
    }

    let resp = req.send().await.map_err(|e| format!("OCI ObjectStorage error: {e}"))?;
    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("OCI ObjectStorage API {status}: {body}"));
    }

    let buckets: Vec<serde_json::Value> = resp.json().await
        .map_err(|e| format!("Parse error: {e}"))?;

    let mut bucket_details = Vec::new();
    for bucket in &buckets {
        if let Some(name) = bucket["name"].as_str() {
            let detail_path = format!(
                "/n/{namespace}/b/{name}?fields=approximateSize,approximateCount"
            );
            let detail_url = format!("https://{host}{detail_path}");

            let hdrs = sign_request(&oci_cfg, "GET", &detail_path, &host, None)?;
            let mut req = http.get(&detail_url);
            for (k, v) in hdrs {
                req = req.header(&k, &v);
            }

            if let Ok(resp) = req.send().await {
                if resp.status().is_success() {
                    if let Ok(detail) = resp.json::<serde_json::Value>().await {
                        let used_bytes = detail["approximateSize"].as_i64().unwrap_or(0);
                        let approx_count = detail["approximateCount"].as_i64().unwrap_or(0);
                        let used_gb = (used_bytes as f64 / 1_073_741_824.0 * 100.0).round() / 100.0;

                        bucket_details.push(serde_json::json!({
                            "name": name,
                            "used_bytes": used_bytes,
                            "used_gb": used_gb,
                            "object_count": approx_count,
                            "storage_tier": detail["storageTier"].as_str().unwrap_or("Standard"),
                        }));
                    }
                }
            }
        }
    }

    let total_used_bytes: i64 = bucket_details.iter()
        .filter_map(|b| b["used_bytes"].as_i64()).sum();
    let total_used_gb: f64 = bucket_details.iter()
        .filter_map(|b| b["used_gb"].as_f64()).sum();
    let total_objects: i64 = bucket_details.iter()
        .filter_map(|b| b["object_count"].as_i64()).sum();
    let available_gb = (quota_gb - total_used_gb).max(0.0);
    let usage_pct = if quota_gb > 0.0 {
        ((total_used_gb / quota_gb * 1000.0).round()) / 10.0
    } else { 0.0 };

    Ok(json!({
        "provider": "oci",
        "region": oci_cfg.region,
        "namespace": namespace,
        "buckets": bucket_details,
        "summary": {
            "bucket_count": bucket_details.len(),
            "total_used_bytes": total_used_bytes,
            "total_used_gb": total_used_gb,
            "total_gb": quota_gb,
            "available_gb": available_gb,
            "usage_pct": usage_pct,
            "total_objects": total_objects,
        }
    }))
}

// ---------------------------------------------------------------------------
// Cloud provider endpoints — OCI
// ---------------------------------------------------------------------------

/// Signed GET helper returning parsed JSON.
async fn oci_get_json(
    http: &reqwest::Client,
    oci_cfg: &OciConfig,
    host: &str,
    path: &str,
) -> Result<Value, String> {
    let url = format!("https://{host}{path}");
    let headers = sign_request(oci_cfg, "GET", path, host, None)?;
    let mut req = http.get(&url);
    for (k, v) in headers {
        req = req.header(&k, &v);
    }
    let resp = req.send().await.map_err(|e| format!("OCI API error: {e}"))?;
    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("OCI API {status}: {body}"));
    }
    resp.json().await.map_err(|e| format!("Parse error: {e}"))
}

/// Signed POST helper returning parsed JSON.
async fn oci_post_json(
    http: &reqwest::Client,
    oci_cfg: &OciConfig,
    host: &str,
    path: &str,
    body: &str,
) -> Result<Value, String> {
    let url = format!("https://{host}{path}");
    let headers = sign_request(oci_cfg, "POST", path, host, Some(body))?;
    let mut req = http.post(&url).body(body.to_string());
    for (k, v) in headers {
        req = req.header(&k, &v);
    }
    let resp = req.send().await.map_err(|e| format!("OCI API error: {e}"))?;
    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("OCI API {status}: {body}"));
    }
    resp.json().await.map_err(|e| format!("Parse error: {e}"))
}

/// List all OCI compute instances in the tenancy compartment.
pub async fn list_instances(
    http: &reqwest::Client,
    config: &AppConfig,
) -> Result<Value, String> {
    let oci_cfg = parse_oci_config(&config.oci_config_file)
        .ok_or("OCI config not found")?;

    let host = format!("iaas.{}.oraclecloud.com", oci_cfg.region);
    let path = format!("/20160918/instances?compartmentId={}", oci_cfg.tenancy);

    let data = oci_get_json(http, &oci_cfg, &host, &path).await?;

    let instances: Vec<Value> = data.as_array().unwrap_or(&vec![]).iter().map(|i| {
        json!({
            "id": i["id"],
            "displayName": i["displayName"],
            "lifecycleState": i["lifecycleState"],
            "shape": i["shape"],
            "region": i["region"],
            "availabilityDomain": i["availabilityDomain"],
            "timeCreated": i["timeCreated"],
            "freeformTags": i["freeformTags"],
        })
    }).collect();

    Ok(json!({
        "provider": "oci",
        "region": oci_cfg.region,
        "instances": instances,
        "count": instances.len(),
    }))
}

/// List OCI networking and storage resources (VCNs, subnets, boot volumes).
pub async fn list_resources(
    http: &reqwest::Client,
    config: &AppConfig,
) -> Result<Value, String> {
    let oci_cfg = parse_oci_config(&config.oci_config_file)
        .ok_or("OCI config not found")?;

    let iaas_host = format!("iaas.{}.oraclecloud.com", oci_cfg.region);
    let compartment = &oci_cfg.tenancy;

    let vcns_path = format!("/20160918/vcns?compartmentId={compartment}");
    let subnets_path = format!("/20160918/subnets?compartmentId={compartment}");
    let boot_vols_path = format!("/20160918/bootVolumes?compartmentId={compartment}&availabilityDomain=");

    let (vcns_res, subnets_res, boot_vols_res) = tokio::join!(
        oci_get_json(http, &oci_cfg, &iaas_host, &vcns_path),
        oci_get_json(http, &oci_cfg, &iaas_host, &subnets_path),
        oci_get_json(http, &oci_cfg, &iaas_host, &boot_vols_path),
    );

    Ok(json!({
        "provider": "oci",
        "region": oci_cfg.region,
        "vcns": vcns_res.unwrap_or(json!([])),
        "subnets": subnets_res.unwrap_or(json!([])),
        "boot_volumes": boot_vols_res.unwrap_or(json!([])),
    }))
}

/// Query OCI Usage API for cost data over the last 30 days.
pub async fn get_usage_costs(
    http: &reqwest::Client,
    config: &AppConfig,
) -> Result<Value, String> {
    let oci_cfg = parse_oci_config(&config.oci_config_file)
        .ok_or("OCI config not found")?;

    let host = format!("usageapi.{}.oci.oraclecloud.com", oci_cfg.region);
    let path = "/20200107/usage";

    let now = Utc::now();
    let start = now - ChronoDuration::days(30);

    let body = json!({
        "tenantId": oci_cfg.tenancy,
        "timeUsageStarted": start.format("%Y-%m-%dT00:00:00Z").to_string(),
        "timeUsageEnded": now.format("%Y-%m-%dT00:00:00Z").to_string(),
        "granularity": "MONTHLY",
        "queryType": "COST",
        "groupBy": ["service"],
    }).to_string();

    let data = oci_post_json(http, &oci_cfg, &host, path, &body).await?;

    let items = data["items"].as_array().cloned().unwrap_or_default();
    let total_cost: f64 = items.iter()
        .filter_map(|i| i["computedAmount"].as_f64())
        .sum();

    Ok(json!({
        "provider": "oci",
        "region": oci_cfg.region,
        "period_days": 30,
        "items": items,
        "total_cost": (total_cost * 100.0).round() / 100.0,
        "currency": data["items"].as_array()
            .and_then(|a| a.first())
            .and_then(|i| i["currency"].as_str())
            .unwrap_or("USD"),
    }))
}
