use reqwest::Client;
use serde::Deserialize;
use tracing::{debug, warn};

#[derive(Clone)]
pub struct KgClient {
    client: Client,
    url: String,
    user: String,
    pass: String,
}

#[derive(Deserialize)]
struct SurrealResponse {
    #[serde(default)]
    result: serde_json::Value,
    status: String,
}

#[derive(Deserialize)]
struct CountResult {
    count: i64,
}

impl KgClient {
    pub fn new(url: &str, pass: &str) -> Self {
        Self {
            client: Client::new(),
            url: url.to_string(),
            user: "root".to_string(),
            pass: pass.to_string(),
        }
    }

    pub async fn query(&self, sql: &str) -> Result<Vec<serde_json::Value>, String> {
        let resp = self
            .client
            .post(format!("{}/sql", self.url))
            .header("Accept", "application/json")
            .header("surreal-ns", "infra")
            .header("surreal-db", "production")
            .basic_auth(&self.user, Some(&self.pass))
            .body(sql.to_string())
            .send()
            .await
            .map_err(|e| format!("HTTP error: {e}"))?;

        if !resp.status().is_success() {
            return Err(format!("SurrealDB returned {}", resp.status()));
        }

        let data: Vec<SurrealResponse> = resp
            .json()
            .await
            .map_err(|e| format!("JSON parse error: {e}"))?;

        let mut results = Vec::new();
        for item in data {
            if item.status != "OK" {
                warn!(status = %item.status, "SurrealDB query error");
                continue;
            }
            results.push(item.result);
        }
        Ok(results)
    }

    pub async fn count_table(&self, table: &str) -> Result<i64, String> {
        let sql = format!("SELECT count() FROM {table} GROUP ALL;");
        let results = self.query(&sql).await?;
        if let Some(first) = results.first() {
            if let Some(arr) = first.as_array() {
                if let Some(row) = arr.first() {
                    if let Ok(c) = serde_json::from_value::<CountResult>(row.clone()) {
                        return Ok(c.count);
                    }
                }
            }
        }
        Ok(0)
    }

    /// Fetch all VMs with their hosted services
    pub async fn get_vms_with_services(
        &self,
    ) -> Result<Vec<serde_json::Value>, String> {
        self.query(
            "SELECT *, <-hosted_on<-service.name AS services FROM vm;"
        ).await
    }

    /// Log an action to audit_log
    pub async fn audit_log(
        &self,
        workflow: &str,
        action: &str,
        command: Option<&str>,
        risk_level: &str,
        result: &str,
        detail: Option<&str>,
    ) -> Result<(), String> {
        let cmd = command.map(|c| format!("'{}'", c.replace('\'', "\\'"))).unwrap_or("NONE".into());
        let det = detail.map(|d| format!("'{}'", d.replace('\'', "\\'"))).unwrap_or("NONE".into());

        let sql = format!(
            "CREATE audit_log CONTENT {{
                workflow: '{workflow}',
                action: '{action}',
                command: {cmd},
                risk_level: '{risk_level}',
                human_approved: NONE,
                result: '{result}',
                detail: {det}
            }};"
        );
        self.query(&sql).await?;
        debug!(workflow, action, result, "Audit logged");
        Ok(())
    }

    /// Update a service's status in the KG
    pub async fn update_service_status(&self, name: &str, status: &str) -> Result<(), String> {
        let sql = format!(
            "UPDATE service SET status = '{status}', updated_at = time::now() WHERE name = '{name}';"
        );
        self.query(&sql).await?;
        Ok(())
    }

    /// Update a VM's status in the KG
    pub async fn update_vm_status(&self, alias: &str, status: &str) -> Result<(), String> {
        let sql = format!(
            "UPDATE vm SET status = '{status}', updated_at = time::now() WHERE alias = '{alias}';"
        );
        self.query(&sql).await?;
        Ok(())
    }
}
