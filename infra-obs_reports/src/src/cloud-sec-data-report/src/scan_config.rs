use anyhow::{Context, Result};
use reports_common::context::find_cloud_data_file;
use serde::Deserialize;

#[derive(Debug, Deserialize, Clone)]
pub struct ScanConfig {
    #[serde(default)]
    pub phases: Phases,
    pub concurrency: Concurrency,
    pub limits: Limits,
    pub targets: Targets,
    pub evidence_files: Vec<String>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct Phases {
    #[serde(default = "default_true")]
    pub yara_enabled: bool,
    #[serde(default = "default_true")]
    pub export_enabled: bool,
    // When false, never call `docker cp` over SSH — evidence-vault snapshots
    // only. Keeps zero CPU load on tiny VMs at scan time.
    #[serde(default)]
    pub docker_cp_fallback_enabled: bool,
    #[serde(default = "default_true")]
    pub siem_enabled: bool,
    #[serde(default = "default_true")]
    pub threat_intel_enabled: bool,
    #[serde(default = "default_true")]
    pub journal_enabled: bool,
    #[serde(default = "default_true")]
    pub runtime_enabled: bool,
    #[serde(default = "default_true")]
    pub diff_enabled: bool,
    #[serde(default = "default_true")]
    pub repo_scan_enabled: bool,
}

impl Default for Phases {
    fn default() -> Self {
        Self {
            yara_enabled: true,
            export_enabled: true,
            docker_cp_fallback_enabled: false,
            siem_enabled: true,
            threat_intel_enabled: true,
            journal_enabled: true,
            runtime_enabled: true,
            diff_enabled: true,
            repo_scan_enabled: true,
        }
    }
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Deserialize, Clone)]
pub struct Concurrency {
    pub vm_parallel: usize,
    pub container_parallel: usize,
}

#[derive(Debug, Deserialize, Clone)]
pub struct Limits {
    pub max_bytes_per_dir: u64,
    pub ssh_timeout_secs: u64,
}

#[derive(Debug, Deserialize, Clone)]
pub struct Targets {
    pub scan_dirs: Vec<String>,
    pub skip_db_patterns: Vec<String>,
}

/// Load sec-scan config — migrated to build-reports.json:.sec_scan;
/// legacy cloud-data-sec-scan.json fallback during migration window.
pub fn load() -> Result<ScanConfig> {
    if let Some(section) = reports_common::context::load_build_reports_section("sec_scan") {
        return serde_json::from_value(section)
            .context("parsing build-reports.json:.sec_scan");
    }
    let path = find_cloud_data_file("cloud-data-sec-scan.json")
        .context("neither build-reports.json:.sec_scan nor cloud-data-sec-scan.json found")?;
    let bytes =
        std::fs::read(&path).with_context(|| format!("reading {}", path.display()))?;
    let cfg: ScanConfig = serde_json::from_slice(&bytes)
        .with_context(|| format!("parsing {}", path.display()))?;
    println!(
        "Loaded scan config from {} (vm_parallel={}, container_parallel={}, yara_enabled={})",
        path.display(),
        cfg.concurrency.vm_parallel,
        cfg.concurrency.container_parallel,
        cfg.phases.yara_enabled,
    );
    Ok(cfg)
}
