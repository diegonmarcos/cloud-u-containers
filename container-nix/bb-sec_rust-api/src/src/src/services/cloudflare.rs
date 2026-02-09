use crate::models::api_response::{CachePurgeRequest, DnsRecord, DnsRecordCreate, FirewallRule};
use reqwest::Client;
use serde_json::{json, Value};

const CF_API_BASE: &str = "https://api.cloudflare.com/client/v4";

pub struct CfClient<'a> {
    http: &'a Client,
    api_token: &'a str,
    zone_id: &'a str,
}

impl<'a> CfClient<'a> {
    pub fn new(http: &'a Client, api_token: &'a str, zone_id: &'a str) -> Self {
        Self { http, api_token, zone_id }
    }

    fn auth_header(&self) -> (&str, String) {
        ("Authorization", format!("Bearer {}", self.api_token))
    }

    fn zone_url(&self, path: &str) -> String {
        format!("{CF_API_BASE}/zones/{}{path}", self.zone_id)
    }

    // ── DNS ─────────────────────────────────────────────────────────────

    pub async fn list_dns(&self) -> Result<Vec<DnsRecord>, String> {
        let (hk, hv) = self.auth_header();
        let resp = self.http
            .get(self.zone_url("/dns_records?per_page=100"))
            .header(hk, hv)
            .send()
            .await
            .map_err(|e| format!("CF API error: {e}"))?;

        let json: Value = resp.json().await.map_err(|e| format!("Parse error: {e}"))?;
        if json["success"].as_bool() != Some(true) {
            return Err(format!("CF API error: {}", json["errors"]));
        }

        let records = json["result"]
            .as_array()
            .unwrap_or(&vec![])
            .iter()
            .map(|r| DnsRecord {
                id: r["id"].as_str().unwrap_or("").to_string(),
                record_type: r["type"].as_str().unwrap_or("").to_string(),
                name: r["name"].as_str().unwrap_or("").to_string(),
                content: r["content"].as_str().unwrap_or("").to_string(),
                proxied: r["proxied"].as_bool().unwrap_or(false),
                ttl: r["ttl"].as_u64().unwrap_or(1) as u32,
            })
            .collect();

        Ok(records)
    }

    pub async fn create_dns(&self, record: &DnsRecordCreate) -> Result<DnsRecord, String> {
        let (hk, hv) = self.auth_header();
        let resp = self.http
            .post(self.zone_url("/dns_records"))
            .header(hk, hv)
            .json(&json!({
                "type": record.record_type,
                "name": record.name,
                "content": record.content,
                "proxied": record.proxied,
                "ttl": record.ttl,
            }))
            .send()
            .await
            .map_err(|e| format!("CF API error: {e}"))?;

        let json: Value = resp.json().await.map_err(|e| format!("Parse error: {e}"))?;
        if json["success"].as_bool() != Some(true) {
            return Err(format!("CF API error: {}", json["errors"]));
        }

        let r = &json["result"];
        Ok(DnsRecord {
            id: r["id"].as_str().unwrap_or("").to_string(),
            record_type: r["type"].as_str().unwrap_or("").to_string(),
            name: r["name"].as_str().unwrap_or("").to_string(),
            content: r["content"].as_str().unwrap_or("").to_string(),
            proxied: r["proxied"].as_bool().unwrap_or(false),
            ttl: r["ttl"].as_u64().unwrap_or(1) as u32,
        })
    }

    pub async fn update_dns(&self, record_id: &str, record: &DnsRecordCreate) -> Result<DnsRecord, String> {
        let (hk, hv) = self.auth_header();
        let resp = self.http
            .patch(self.zone_url(&format!("/dns_records/{record_id}")))
            .header(hk, hv)
            .json(&json!({
                "type": record.record_type,
                "name": record.name,
                "content": record.content,
                "proxied": record.proxied,
                "ttl": record.ttl,
            }))
            .send()
            .await
            .map_err(|e| format!("CF API error: {e}"))?;

        let json: Value = resp.json().await.map_err(|e| format!("Parse error: {e}"))?;
        if json["success"].as_bool() != Some(true) {
            return Err(format!("CF API error: {}", json["errors"]));
        }

        let r = &json["result"];
        Ok(DnsRecord {
            id: r["id"].as_str().unwrap_or("").to_string(),
            record_type: r["type"].as_str().unwrap_or("").to_string(),
            name: r["name"].as_str().unwrap_or("").to_string(),
            content: r["content"].as_str().unwrap_or("").to_string(),
            proxied: r["proxied"].as_bool().unwrap_or(false),
            ttl: r["ttl"].as_u64().unwrap_or(1) as u32,
        })
    }

    pub async fn delete_dns(&self, record_id: &str) -> Result<(), String> {
        let (hk, hv) = self.auth_header();
        let resp = self.http
            .delete(self.zone_url(&format!("/dns_records/{record_id}")))
            .header(hk, hv)
            .send()
            .await
            .map_err(|e| format!("CF API error: {e}"))?;

        let json: Value = resp.json().await.map_err(|e| format!("Parse error: {e}"))?;
        if json["success"].as_bool() != Some(true) {
            return Err(format!("CF API error: {}", json["errors"]));
        }
        Ok(())
    }

    // ── Cache ────────────────────────────────────────────────────────────

    pub async fn purge_cache(&self, req: &CachePurgeRequest) -> Result<(), String> {
        let (hk, hv) = self.auth_header();
        let body = if req.purge_everything {
            json!({"purge_everything": true})
        } else {
            json!({"files": req.files})
        };

        let resp = self.http
            .post(self.zone_url("/purge_cache"))
            .header(hk, hv)
            .json(&body)
            .send()
            .await
            .map_err(|e| format!("CF API error: {e}"))?;

        let json: Value = resp.json().await.map_err(|e| format!("Parse error: {e}"))?;
        if json["success"].as_bool() != Some(true) {
            return Err(format!("CF API error: {}", json["errors"]));
        }
        Ok(())
    }

    // ── Zone ─────────────────────────────────────────────────────────────

    pub async fn zone_info(&self) -> Result<Value, String> {
        let (hk, hv) = self.auth_header();
        let resp = self.http
            .get(self.zone_url(""))
            .header(hk, hv)
            .send()
            .await
            .map_err(|e| format!("CF API error: {e}"))?;

        let json: Value = resp.json().await.map_err(|e| format!("Parse error: {e}"))?;
        if json["success"].as_bool() != Some(true) {
            return Err(format!("CF API error: {}", json["errors"]));
        }
        Ok(json["result"].clone())
    }

    // ── Firewall ─────────────────────────────────────────────────────────

    pub async fn list_firewall(&self) -> Result<Vec<FirewallRule>, String> {
        let (hk, hv) = self.auth_header();
        let resp = self.http
            .get(self.zone_url("/firewall/rules"))
            .header(hk, hv)
            .send()
            .await
            .map_err(|e| format!("CF API error: {e}"))?;

        let json: Value = resp.json().await.map_err(|e| format!("Parse error: {e}"))?;
        if json["success"].as_bool() != Some(true) {
            return Err(format!("CF API error: {}", json["errors"]));
        }

        let rules = json["result"]
            .as_array()
            .unwrap_or(&vec![])
            .iter()
            .map(|r| FirewallRule {
                id: r["id"].as_str().map(|s| s.to_string()),
                expression: r["filter"]["expression"].as_str().unwrap_or("").to_string(),
                action: r["action"].as_str().unwrap_or("").to_string(),
                description: r["description"].as_str().map(|s| s.to_string()),
            })
            .collect();

        Ok(rules)
    }

    pub async fn create_firewall(&self, rule: &FirewallRule) -> Result<Value, String> {
        let (hk, hv) = self.auth_header();
        let resp = self.http
            .post(self.zone_url("/firewall/rules"))
            .header(hk, hv)
            .json(&json!([{
                "filter": {"expression": rule.expression},
                "action": rule.action,
                "description": rule.description.as_deref().unwrap_or("")
            }]))
            .send()
            .await
            .map_err(|e| format!("CF API error: {e}"))?;

        let json: Value = resp.json().await.map_err(|e| format!("Parse error: {e}"))?;
        if json["success"].as_bool() != Some(true) {
            return Err(format!("CF API error: {}", json["errors"]));
        }
        Ok(json["result"].clone())
    }

    // ── Analytics ────────────────────────────────────────────────────────

    pub async fn analytics(&self) -> Result<Value, String> {
        let (hk, hv) = self.auth_header();
        let resp = self.http
            .get(self.zone_url("/analytics/dashboard?since=-1440&until=0"))
            .header(hk, hv)
            .send()
            .await
            .map_err(|e| format!("CF API error: {e}"))?;

        let json: Value = resp.json().await.map_err(|e| format!("Parse error: {e}"))?;
        if json["success"].as_bool() != Some(true) {
            return Err(format!("CF API error: {}", json["errors"]));
        }
        Ok(json["result"].clone())
    }
}
