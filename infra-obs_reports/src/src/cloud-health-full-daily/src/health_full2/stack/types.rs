use serde::Serialize;
use std::collections::HashMap;

#[allow(dead_code)]
/// Static context parsed from consolidated JSON
pub struct Context {
    pub consolidated: serde_json::Value,
    pub vms: Vec<VmInfo>,
    pub public_urls: Vec<UrlInfo>,
    pub private_dns: Vec<DnsEntry>,
    pub databases: Vec<DbEntry>,
    pub wg_peers: Vec<WgPeer>,
    pub mail_ports: Vec<MailPort>,
    pub caddy_l4: Vec<L4Route>,
    pub bearer_token: Option<String>,
}

#[derive(Clone, Debug)]
#[allow(dead_code)]
pub struct VmInfo {
    pub alias: String,
    pub vm_id: String,
    pub pub_ip: String,
    pub wg_ip: String,
    pub cloud_name: String,
    pub cloud_zone: String,
    pub rescue_port: u16,
    pub cpus: u32,
    pub ram_gb: String,
    pub disk_gb: String,
    pub shape: String,
    pub provider: String,
    pub cost: String,
    pub declared_ports: Vec<u16>,
}

#[derive(Clone, Debug)]
pub struct UrlInfo {
    pub url: String,
    pub upstream: String,
}

#[derive(Clone, Debug)]
pub struct DnsEntry {
    pub dns: String,
    pub container: String,
    pub port: u16,
    pub vm: String,
    pub host_port: bool,
}

#[derive(Clone, Debug)]
#[allow(dead_code)]
pub struct DbEntry {
    pub service: String,
    pub db_type: String,
    pub container: String,
    pub db_name: String,
    pub db_user: String,
    pub port: u16,
    pub vm: String,
    pub dns_access: String,
    pub enabled: bool,
    pub healthcheck: String,
    pub backup: bool,
}

#[derive(Clone, Debug)]
pub struct WgPeer {
    pub name: String,
    pub wg_ip: String,
    pub pub_ip: String,
    pub role: String,
}

#[derive(Clone, Debug)]
#[allow(dead_code)]
pub struct MailPort {
    pub host: String,
    pub port: u16,
    pub proto: String,
}

#[derive(Clone, Debug)]
#[allow(dead_code)]
pub struct L4Route {
    pub port: u16,
    pub upstream: String,
    pub comment: String,
}

/// Live collected data
#[derive(Debug, Serialize)]
pub struct LiveData {
    pub generated: String,
    pub duration_ms: u64,
    pub mesh: Vec<MeshResult>,
    pub public_urls: Vec<UrlResult>,
    pub private_endpoints: Vec<PrivateResult>,
    pub vm_data: Vec<VmLiveData>,
    pub mail_dns: MailDnsData,
    pub port_scan: Vec<PortScanResult>,
    pub db_health: Vec<DbHealthResult>,
    pub storage_health: Vec<StorageHealthResult>,
    pub timers: HashMap<String, u64>,
}

#[derive(Debug, Serialize, Clone)]
pub struct MeshResult {
    pub name: String,
    pub cloud_name: String,
    pub pub_ip: String,
    pub wg_ip: String,
    pub peer_type: String,
    pub vps_ok: bool,
    pub vps_status: String,
    pub pub_ok: bool,
    pub dropbear_ok: bool,
    pub wg_ok: bool,
    pub wg_handshake: String,
}

#[derive(Debug, Serialize, Clone)]
pub struct UrlResult {
    pub url: String,
    pub upstream: String,
    pub tcp: bool,
    pub http: bool,
    pub https: bool,
    pub auth: bool,
    pub code: String,
    pub auth_code: String,
}

#[derive(Debug, Serialize, Clone)]
pub struct PrivateResult {
    pub dns: String,
    pub container: String,
    pub port: u16,
    pub vm: String,
    pub tcp: bool,
    pub http: bool,
    pub code: String,
    pub resolved_ip: String,
    pub container_up: bool,
}

#[derive(Debug, Serialize, Clone)]
pub struct VmLiveData {
    pub alias: String,
    pub reachable: bool,
    pub mem_used: String,
    pub mem_total: String,
    pub mem_pct: u32,
    pub swap: String,
    pub disk_used: String,
    pub disk_total: String,
    pub disk_pct: String,
    #[serde(default)]
    pub disks: Vec<DiskMount>,
    pub load: String,
    pub uptime: String,
    // Network: per-VM throughput (1s /proc/net/dev delta), DNS, WireGuard mesh/VPN
    #[serde(default)]
    pub net_rx_rate: String,
    #[serde(default)]
    pub net_tx_rate: String,
    #[serde(default)]
    pub dns_servers: String,
    #[serde(default)]
    pub wg_handshake_epoch: u64,
    #[serde(default)]
    pub wg_peers: u32,
    #[serde(default)]
    pub now_epoch: u64,
    #[serde(default)]
    pub wg_rx: String,
    #[serde(default)]
    pub wg_tx: String,
    pub containers: Vec<ContainerState>,
    pub containers_running: u32,
    pub containers_total: u32,
}

#[derive(Debug, Serialize, Clone, Default)]
pub struct DiskMount {
    pub mount: String,
    pub used: String,
    pub total: String,
    pub pct: String,
    pub source: String,
}

impl VmLiveData {
    /// WireGuard/VPN up = at least one peer with a handshake inside the last 180s.
    pub fn wg_up(&self) -> bool {
        self.wg_peers > 0
            && self.wg_handshake_epoch > 0
            && self.now_epoch >= self.wg_handshake_epoch
            && (self.now_epoch - self.wg_handshake_epoch) < 180
    }

    /// Human "last handshake" age, e.g. "12s", "3m", "—".
    pub fn wg_handshake_age(&self) -> String {
        if self.wg_handshake_epoch == 0 || self.now_epoch < self.wg_handshake_epoch {
            return "—".into();
        }
        let s = self.now_epoch - self.wg_handshake_epoch;
        if s < 90 { format!("{}s", s) }
        else if s < 5400 { format!("{}m", s / 60) }
        else { format!("{}h", s / 3600) }
    }
}

#[derive(Debug, Serialize, Clone)]
pub struct ContainerState {
    pub name: String,
    pub status: String,
    pub health: String, // healthy, unhealthy, exited, starting, none
    pub docker_port: String,
    pub host_port: String,
}

#[derive(Debug, Serialize, Clone, Default)]
pub struct MailDnsData {
    pub mx: Vec<MxRecord>,
    pub spf: Vec<SpfEntry>,
    pub dkim: Vec<DkimEntry>,
    pub dmarc: String,
}

#[derive(Debug, Serialize, Clone)]
pub struct MxRecord {
    pub domain: String,
    pub priority: String,
    pub server: String,
    pub ip: String,
}

#[derive(Debug, Serialize, Clone)]
pub struct SpfEntry {
    pub domain: String,
    pub include: String,
    pub ips: String,
}

#[derive(Debug, Serialize, Clone)]
pub struct DkimEntry {
    pub selector: String,
    pub domain: String,
    pub signer: String,
    pub present: bool,
    pub key_size: String,
}

#[derive(Debug, Serialize, Clone)]
pub struct PortScanResult {
    pub name: String,
    pub ip: String,
    pub open_ports: Vec<u16>,
}

#[derive(Debug, Serialize, Clone)]
pub struct DbHealthResult {
    pub service: String,
    pub db_type: String,
    pub container: String,
    pub vm: String,
    pub port: u16,
    pub declared: bool,
    pub running: bool,
    pub healthy: bool,
    pub size: String,
    pub tcp_ok: bool,
    pub dns: String,
    pub backup: bool,
}

#[derive(Debug, Serialize, Clone)]
pub struct StorageHealthResult {
    pub name: String,
    pub provider: String,
    pub tier: String,
    pub accessible: bool,
    pub size: String,
    pub objects: String,
}
