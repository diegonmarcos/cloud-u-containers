use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct PortScanResult {
    pub vm_alias: String,
    pub ip: String,
    pub scan_path: String, // "external" or "internal"
    pub declared_ports: Vec<u16>,
    pub open_ports: Vec<u16>,
    pub undeclared_open: Vec<u16>,
    pub declared_closed: Vec<u16>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TlsCertResult {
    pub domain: String,
    pub valid: bool,
    pub issuer: String,
    pub not_after: String,
    pub days_remaining: i64,
    pub protocol: String,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct WgPeerStatus {
    pub name: String,
    pub wg_ip: String,
    pub endpoint: String,
    pub last_handshake_secs: u64,
    pub transfer_rx: u64,
    pub transfer_tx: u64,
    pub healthy: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct DnsValidationResult {
    pub domain: String,
    pub record_type: String,
    pub resolver: String, // "external" or "hickory"
    pub expected: String,
    pub actual: String,
    pub matches: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct FirewallAuditResult {
    pub vm_alias: String,
    pub open_ports: Vec<u16>,
    pub declared_ports: Vec<u16>,
    pub rogue_ports: Vec<u16>,
}
