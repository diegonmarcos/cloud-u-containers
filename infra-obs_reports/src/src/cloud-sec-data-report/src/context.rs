use crate::scan_config::{self, ScanConfig};
use anyhow::Result;
use reports_common::context;
use reports_common::types::VmInfo;
use serde_json::Value;

pub struct SecDataContext {
    pub consolidated: Value,
    pub vms: Vec<VmInfo>,
    pub bearer_token: Option<String>,
    pub siem_api_url: String,
    pub scan: ScanConfig,
}

pub fn load_context() -> Result<SecDataContext> {
    let consolidated = context::load_consolidated()?;
    let vms = context::parse_vms(&consolidated);
    let bearer_token = context::load_bearer_token();
    let siem_api_url = std::env::var("SIEM_API_URL")
        .unwrap_or_else(|_| "https://api.diegonmarcos.com/siem-api".to_string());
    let scan = scan_config::load()?;

    println!("Loaded {} VMs from consolidated JSON", vms.len());
    println!(
        "Bearer token: {}",
        if bearer_token.is_some() {
            "available"
        } else {
            "not found"
        }
    );
    println!("SIEM API: {}", siem_api_url);

    Ok(SecDataContext {
        consolidated,
        vms,
        bearer_token,
        siem_api_url,
        scan,
    })
}
