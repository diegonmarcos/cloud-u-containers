use serde::Serialize;
use std::collections::HashMap;

/// Severity of a check failure
#[derive(Debug, Clone, Serialize, PartialEq)]
pub enum Severity {
    Critical,
    Warning,
    Info,
}

impl std::fmt::Display for Severity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Severity::Critical => write!(f, "CRITICAL"),
            Severity::Warning => write!(f, "WARNING"),
            Severity::Info => write!(f, "INFO"),
        }
    }
}

/// Overall roll-up status of a report or a check group.
///
/// R1 + R7: `Stale` and `Unknown` are DISTINCT from `Red`. A stale report or a
/// check that couldn't run (WG mesh down) must never be rendered as CRITICAL —
/// doing so produces the exact false-RED the hardening plan exists to kill.
/// Ordering (for `.max()` roll-up): Green < Yellow < Unknown < Stale < Red is
/// intentionally NOT used — Stale/Unknown are orthogonal signals, so callers
/// pick them explicitly. `worst_of` below encodes the roll-up policy.
#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
pub enum Status {
    /// All checks passed.
    Green,
    /// Non-critical degradation (warnings only).
    Yellow,
    /// A critical check failed AND we had the capability to judge it.
    Red,
    /// Check could not be evaluated (e.g. WG mesh down from the runner). NOT a
    /// failure — the infra may be perfectly healthy but unreachable. R7.
    Unknown,
    /// Data underlying the report is older than its tier cadence. NOT Red —
    /// the finding may not reflect current state either way. R1.
    Stale,
}

impl std::fmt::Display for Status {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Status::Green => write!(f, "GREEN"),
            Status::Yellow => write!(f, "YELLOW"),
            Status::Red => write!(f, "RED"),
            Status::Unknown => write!(f, "UNKNOWN"),
            Status::Stale => write!(f, "STALE"),
        }
    }
}

impl Status {
    /// Emoji/badge for the status — used by the renderer.
    pub fn badge(&self) -> &'static str {
        match self {
            Status::Green => "\u{2705}",           // ✅
            Status::Yellow => "\u{26a0}\u{fe0f}",  // ⚠️
            Status::Red => "\u{274c}",             // ❌
            Status::Unknown => "\u{2754}",         // ❔
            Status::Stale => "\u{1f570}\u{fe0f}",  // 🕰️
        }
    }

    /// Roll up a report status from a check summary.
    /// STALE and UNKNOWN are supplied by the caller (staleness / capability
    /// gate) and take precedence over Green/Yellow but are kept distinct from
    /// Red so an outage is never masked by — nor mistaken for — a stale/ungated
    /// signal.
    pub fn from_summary(summary: &Summary) -> Self {
        if summary.critical > 0 {
            Status::Red
        } else if summary.warnings > 0 {
            Status::Yellow
        } else {
            Status::Green
        }
    }
}

/// A single diagnostic check result
#[derive(Debug, Clone, Serialize)]
pub struct Check {
    pub name: String,
    pub passed: bool,
    pub details: String,
    pub duration_ms: u64,
    pub error: Option<String>,
    pub severity: Severity,
}

/// Summary of all checks
#[derive(Debug, Serialize)]
pub struct Summary {
    pub total_checks: usize,
    pub passed: usize,
    pub failed: usize,
    pub warnings: usize,
    pub critical: usize,
}

impl Summary {
    pub fn from_checks(checks: &[&Check]) -> Self {
        let total_checks = checks.len();
        let passed = checks.iter().filter(|c| c.passed).count();
        let failed = total_checks - passed;
        let warnings = checks
            .iter()
            .filter(|c| !c.passed && c.severity == Severity::Warning)
            .count();
        let critical = checks
            .iter()
            .filter(|c| !c.passed && c.severity == Severity::Critical)
            .count();
        Summary {
            total_checks,
            passed,
            failed,
            warnings,
            critical,
        }
    }
}

/// VM information from cloud-data consolidated JSON
#[derive(Clone, Debug)]
pub struct VmInfo {
    pub vm_id: String,
    pub alias: String,
    pub pub_ip: String,
    pub wg_ip: String,
    pub cloud_name: String,
    pub cloud_zone: String,
    pub rescue_port: u16,
    pub cpus: u32,
    pub ram_gb: f64,
    pub shape: String,
    pub provider: String,
    pub cost: String,
    pub declared_services: Vec<String>,
    pub public_ports: Vec<PublicPort>,
}

#[derive(Clone, Debug)]
pub struct PublicPort {
    pub port: u16,
    pub proto: String,
    pub desc: String,
    /// CIDR this port is actually open to (e.g. "0.0.0.0/0" vs
    /// "10.0.0.0/24"). A VM can declare 443/tcp mesh-only — without this,
    /// callers can't tell a truly-public edge from a mesh-only listener
    /// that happens to share the same port/proto.
    pub source: String,
}

/// Service information from cloud-data consolidated JSON
#[derive(Clone, Debug)]
pub struct ServiceInfo {
    pub name: String,
    pub category: String,
    pub vm_id: String,
    pub vm_alias: String,
    pub folder: String,
    pub domain: Option<String>,
    pub port: Option<u16>,
    pub dns: Option<String>,
    pub upstream: Option<String>,
    pub containers: Vec<ContainerDecl>,
    pub enabled: bool,
}

#[derive(Clone, Debug)]
pub struct ContainerDecl {
    pub key: String,
    pub container_name: String,
    pub image: String,
    pub port: Option<u16>,
    pub dns: Option<String>,
    pub healthcheck: Option<String>,
}

/// Caddy route from build-caddy.json
#[derive(Clone, Debug)]
pub struct CaddyRoute {
    pub domain: String,
    pub upstream: String,
    pub comment: String,
    pub auth: Option<String>,
    /// WireGuard-mesh-only route (fail-closed default upstream in
    /// cloud-data-config-derive.ts). A failed *external* TLS handshake
    /// against a wg_only route is expected/correct behavior, not a bug —
    /// consumers (e.g. cloud-sec-network-report's external TLS audit) must
    /// check this before treating a handshake failure as CRITICAL.
    pub wg_only: bool,
}

/// Timer map for performance tracking
pub type Timers = HashMap<String, u64>;
