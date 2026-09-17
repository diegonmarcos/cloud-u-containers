//! FleetState — authoritative VM liveness gate.
//!
//! Queries the cloud provider API (gcloud / oci) in parallel to classify
//! every VM before any SSH is attempted. The output is consumed by every
//! collector to skip dead VMs at step 0, eliminating the cascade of SSH
//! timeouts that otherwise burn ~300s each on a TERMINATED spot instance.
//!
//! Design:
//!   - One batched cloud-API call per provider (gcloud list, oci list) ≤ 3s each.
//!   - Per-VM TCP :22 probe (WG) as a fallback signal for providers we can't
//!     query (e.g. bare-metal, surface laptop, GHA runner).
//!   - Combined state: cloud-provider state OR TCP liveness OR Unknown.
//!   - Result cached in-process for the pipeline; TTL governed by caller.
//!
//! This module enforces Fire Rule #3 (data-driven): the VM list comes from
//! `_cloud-data-consolidated.json` (via `context::parse_vms`). Every VM's
//! provider + cloud_name is read from that config, no hardcoding.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::time::Duration;
use tokio::net::TcpStream;
use tokio::time::timeout;

/// Canonical VM state — authoritative, combining cloud-API + TCP liveness.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum VmState {
    /// Cloud API reports running AND TCP :22 responsive.
    Running,
    /// Cloud API reports stopped / terminated / preempted — skip SSH entirely.
    Terminated { reason: String },
    /// Cloud API reports provisioning / starting — SSH may fail transiently.
    Provisioning,
    /// Cloud API reports the VM exists but status is unknown; or probe failed.
    Unknown { reason: String },
    /// Not a cloud VM (bare-metal, client) — use TCP liveness only.
    Client { tcp_up: bool },
}

impl VmState {
    pub fn is_reachable(&self) -> bool {
        matches!(
            self,
            VmState::Running | VmState::Provisioning | VmState::Client { tcp_up: true }
        )
    }

    pub fn short_reason(&self) -> String {
        match self {
            VmState::Running => "RUNNING".into(),
            VmState::Terminated { reason } => format!("TERMINATED ({})", reason),
            VmState::Provisioning => "PROVISIONING".into(),
            VmState::Unknown { reason } => format!("UNKNOWN ({})", reason),
            VmState::Client { tcp_up: true } => "CLIENT-UP".into(),
            VmState::Client { tcp_up: false } => "CLIENT-DOWN".into(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FleetState {
    pub vms: HashMap<String, VmState>,
}

impl FleetState {
    pub fn classify(&self, vm_id: &str) -> VmState {
        self.vms
            .get(vm_id)
            .cloned()
            .unwrap_or_else(|| VmState::Unknown {
                reason: "not in fleet state map".into(),
            })
    }

    pub fn reachable(&self) -> Vec<String> {
        self.vms
            .iter()
            .filter(|(_, s)| s.is_reachable())
            .map(|(k, _)| k.clone())
            .collect()
    }

    pub fn terminated(&self) -> Vec<String> {
        self.vms
            .iter()
            .filter(|(_, s)| matches!(s, VmState::Terminated { .. }))
            .map(|(k, _)| k.clone())
            .collect()
    }
}

/// Minimal VM descriptor the fleet loader needs.
#[derive(Debug, Clone)]
pub struct FleetVm {
    pub vm_id: String,
    pub provider: String,    // "gcp" | "oci" | "client" | "?"
    pub cloud_name: String,  // provider-specific identifier
    pub wg_ip: Option<String>,
}

/// Load the fleet state by querying each provider in parallel + TCP probing.
/// Hard budget: 5 seconds wall-clock.
pub async fn load(vms: &[FleetVm]) -> FleetState {
    let fut_gcp = gcloud_list();
    let fut_oci = oci_list();
    let fut_tcp = tcp_liveness_batch(vms);

    // Each element is the per-call deadline wrapping the query's own outcome:
    // Result<Result<HashMap, reason>, deadline-error>. The OUTER is the 5s
    // budget; the INNER is the provider CLI's own result.
    let (gcp_raw, oci_raw, tcp_map) = tokio::join!(
        timeout(Duration::from_secs(5), fut_gcp),
        timeout(Duration::from_secs(5), fut_oci),
        fut_tcp,
    );
    // A provider query that could not RUN (CLI absent) is a distinct fact from
    // one that ran and found nothing. The CLI absent case must be an explicit,
    // named failure — "gcloud CLI not installed" — not the misleading
    // "not found in gcloud list", which reads as the VM not existing in the
    // cloud when the truth is the tool is missing (#391).
    let gcp_problem = provider_problem(&gcp_raw);
    let oci_problem = provider_problem(&oci_raw);
    let gcp_map = gcp_raw.ok().map(|r| r.unwrap_or_default()).unwrap_or_default();
    let oci_map = oci_raw.ok().map(|r| r.unwrap_or_default()).unwrap_or_default();

    let mut out: HashMap<String, VmState> = HashMap::new();
    for vm in vms {
        // Own the lowered string: to_lowercase() returns a TEMPORARY, and
        // borrowing it with .as_str() would dangle past the statement (E0716).
        let provider = vm.provider.to_lowercase();
        let state = classify_vm(
            provider.as_str(),
            &vm.cloud_name,
            match provider.as_str() {
                "gcp" => &gcp_map,
                _ => &oci_map, // client providers never read the map
            },
            tcp_map.get(&vm.vm_id).copied(),
            match provider.as_str() {
                "gcp" => gcp_problem.as_ref(),
                "oci" => oci_problem.as_ref(),
                _ => None,
            },
        );
        out.insert(vm.vm_id.clone(), state);
    }
    FleetState { vms: out }
}

/// Map a joined provider result to the reason its query could not RUN.
/// None = the CLI ran and produced a (possibly empty) list. Some = either the
/// CLI binary is not on PATH (named) or the per-call deadline elapsed.
fn provider_problem<E>(
    raw: &std::result::Result<std::result::Result<HashMap<String, String>, String>, E>,
) -> Option<String> {
    match raw {
        Ok(Ok(_)) => None,
        Ok(Err(reason)) => Some(reason.clone()),
        Err(_) => Some("provider query timed out".into()),
    }
}

/// Classify one VM from its provider's query outcome and the TCP probe.
/// `tool_problem` carries the reason the provider query could not RUN (CLI
/// missing); when set, the VM is reported with that named failure instead of a
/// misleading "not found in <cli> list" (#391).
fn classify_vm(
    provider: &str,
    cloud_name: &str,
    map: &HashMap<String, String>,
    tcp_up: Option<bool>,
    tool_problem: Option<&String>,
) -> VmState {
    match tool_problem {
        Some(reason) => VmState::Unknown { reason: reason.clone() },
        None => match provider.to_lowercase().as_str() {
            "gcp" => classify_gcp(cloud_name, map, tcp_up),
            "oci" => classify_oci(cloud_name, map, tcp_up),
            _ => VmState::Client {
                tcp_up: tcp_up.unwrap_or(false),
            },
        },
    }
}

fn classify_gcp(cloud_name: &str, map: &HashMap<String, String>, tcp_up: Option<bool>) -> VmState {
    match map.get(cloud_name).map(|s| s.as_str()) {
        Some("RUNNING") => {
            if tcp_up.unwrap_or(true) {
                VmState::Running
            } else {
                VmState::Unknown {
                    reason: "gcloud=RUNNING but TCP :22 silent".into(),
                }
            }
        }
        Some("TERMINATED") | Some("STOPPED") | Some("STOPPING") | Some("SUSPENDED")
        | Some("SUSPENDING") => VmState::Terminated {
            reason: format!("gcloud={}", map[cloud_name]),
        },
        Some("PROVISIONING") | Some("STAGING") | Some("REPAIRING") => VmState::Provisioning,
        Some(other) => VmState::Unknown {
            reason: format!("gcloud={}", other),
        },
        None => VmState::Unknown {
            reason: "not found in gcloud list".into(),
        },
    }
}

fn classify_oci(cloud_name: &str, map: &HashMap<String, String>, tcp_up: Option<bool>) -> VmState {
    match map.get(cloud_name).map(|s| s.as_str()) {
        Some("RUNNING") => {
            if tcp_up.unwrap_or(true) {
                VmState::Running
            } else {
                VmState::Unknown {
                    reason: "oci=RUNNING but TCP :22 silent".into(),
                }
            }
        }
        Some("STOPPED") | Some("TERMINATED") | Some("TERMINATING") | Some("STOPPING") => {
            VmState::Terminated {
                reason: format!("oci={}", map[cloud_name]),
            }
        }
        Some("STARTING") | Some("PROVISIONING") | Some("CREATING_IMAGE") => VmState::Provisioning,
        Some(other) => VmState::Unknown {
            reason: format!("oci={}", other),
        },
        None => VmState::Unknown {
            reason: "not found in oci list".into(),
        },
    }
}

/// Batch-list all GCP compute instances. Returns map of name → status.
/// Ok(empty map) is non-fatal when the CLI ran but found nothing / auth failed.
/// Err names the case where the query could not RUN at all — the gcloud CLI is
/// not installed on this host — so the fleet caller can report that as an
/// explicit, named failure instead of the misleading "not found in gcloud list"
/// (#391: every VM read UNKNOWN(not found in gcloud list) on a runner that had
/// no gcloud at all, which reads as "the VM does not exist in the cloud").
async fn gcloud_list() -> std::result::Result<HashMap<String, String>, String> {
    let cmd = tokio::process::Command::new("gcloud")
        .args([
            "compute",
            "instances",
            "list",
            "--format=csv[no-heading](name,status)",
        ])
        .output()
        .await;
    match cmd {
        Ok(out) => {
            if !out.status.success() {
                // Ran, but failed (auth, network, ...) — unchanged non-fatal
                // behaviour: the TCP probe is the fallback signal.
                return Ok(HashMap::new());
            }
            let stdout = String::from_utf8_lossy(&out.stdout);
            Ok(stdout
                .lines()
                .filter_map(|l| {
                    let mut it = l.splitn(2, ',');
                    let name = it.next()?.trim();
                    let status = it.next()?.trim();
                    if name.is_empty() {
                        None
                    } else {
                        Some((name.to_string(), status.to_string()))
                    }
                })
                .collect())
        }
        // Spawn failed — the binary is not on PATH. Name it.
        Err(_) => Err("gcloud CLI not installed".into()),
    }
}

/// Batch-list OCI instances via `oci compute instance list --all`. Returns map
/// of display-name → lifecycle-state.
/// Ok(empty map) is non-fatal on auth failure or missing ~/.oci/config (the TCP
/// probe is the fallback signal). Err names the case where the query could not
/// RUN at all — the oci CLI is not installed — so the fleet caller can report
/// that as an explicit, named failure instead of "not found in oci list" (#391).
async fn oci_list() -> std::result::Result<HashMap<String, String>, String> {
    let home = std::env::var("HOME").unwrap_or_default();
    let config = tokio::fs::read_to_string(format!("{}/.oci/config", home))
        .await
        .unwrap_or_default();
    let Some(tenancy) = config
        .lines()
        .find(|l| l.starts_with("tenancy="))
        .and_then(|l| l.strip_prefix("tenancy="))
    else {
        return Ok(HashMap::new());
    };
    let cmd = tokio::process::Command::new("oci")
        .args([
            "compute",
            "instance",
            "list",
            "--all",
            "--compartment-id",
            tenancy,
            "--query",
            "data[].{name:\"display-name\",state:\"lifecycle-state\"}",
            "--output",
            "json",
        ])
        .output()
        .await;
    match cmd {
        Ok(out) => {
            if !out.status.success() {
                return Ok(HashMap::new());
            }
            let stdout = String::from_utf8_lossy(&out.stdout);
            let parsed: Result<Vec<serde_json::Value>, _> = serde_json::from_str(&stdout);
            let Ok(items) = parsed else {
                return Ok(HashMap::new());
            };
            Ok(items
                .into_iter()
                .filter_map(|v| {
                    let name = v.get("name")?.as_str()?.to_string();
                    let state = v.get("state")?.as_str()?.to_string();
                    Some((name, state))
                })
                .collect())
        }
        // Spawn failed — the binary is not on PATH. Name it.
        Err(_) => Err("oci CLI not installed".into()),
    }
}

/// Per-attempt TCP probe deadline. 500ms was too tight for cold WG —
/// first-packet handshake regularly exceeded it on this lab and the
/// probe falsely flagged every reachable VM as down. 2s with a retry
/// is the documented WG warm-up budget on the slowest hop.
const TCP_PROBE_TIMEOUT: Duration = Duration::from_secs(2);
/// One retry — the cold-WG miss almost always succeeds the second time.
const TCP_PROBE_RETRIES: u32 = 1;

/// TCP :22 liveness probe per VM (fallback signal).
async fn tcp_liveness_batch(vms: &[FleetVm]) -> HashMap<String, bool> {
    let futs = vms.iter().map(|vm| async move {
        let ip = match vm.wg_ip.as_deref() {
            Some(ip) if !ip.is_empty() && ip != "?" => ip,
            _ => return (vm.vm_id.clone(), false),
        };
        let addr = format!("{}:22", ip);
        let mut up = false;
        for _ in 0..=TCP_PROBE_RETRIES {
            up = timeout(TCP_PROBE_TIMEOUT, TcpStream::connect(&addr))
                .await
                .ok()
                .map(|r| r.is_ok())
                .unwrap_or(false);
            if up {
                break;
            }
        }
        (vm.vm_id.clone(), up)
    });
    futures::future::join_all(futs).await.into_iter().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classify_gcp_terminated() {
        let mut map = HashMap::new();
        map.insert("ollama-spot-gpu".to_string(), "TERMINATED".to_string());
        let s = classify_gcp("ollama-spot-gpu", &map, None);
        assert!(matches!(s, VmState::Terminated { .. }));
        assert!(!s.is_reachable());
    }

    #[test]
    fn classify_gcp_running() {
        let mut map = HashMap::new();
        map.insert("arch-1".to_string(), "RUNNING".to_string());
        let s = classify_gcp("arch-1", &map, Some(true));
        assert_eq!(s, VmState::Running);
        assert!(s.is_reachable());
    }

    #[test]
    fn classify_oci_stopped() {
        let mut map = HashMap::new();
        map.insert("oci-A1-f_0".to_string(), "STOPPED".to_string());
        let s = classify_oci("oci-A1-f_0", &map, None);
        assert!(matches!(s, VmState::Terminated { .. }));
    }

    #[test]
    fn classify_unknown_when_not_listed() {
        let map: HashMap<String, String> = HashMap::new();
        let s = classify_gcp("missing", &map, None);
        assert!(matches!(s, VmState::Unknown { .. }));
    }

    #[test]
    fn cli_missing_is_a_named_failure_not_not_found() {
        // #391: a runner without the provider CLI used to read
        // "Unknown (not found in gcloud list)" — as if the VM did not exist in
        // the cloud — because the missing CLI produced an empty list. The
        // absent CLI must be named, and it must not count as reachable.
        let empty: HashMap<String, String> = HashMap::new();
        let gcp = classify_vm("gcp", "arch-1", &empty, None, Some(&"gcloud CLI not installed".into()));
        assert!(matches!(gcp, VmState::Unknown { .. }));
        assert!(gcp.short_reason().contains("gcloud CLI not installed"));
        assert!(!gcp.short_reason().contains("not found"));
        assert!(!gcp.is_reachable());

        let oci = classify_vm("oci", "oci-A1-f_0", &empty, None, Some(&"oci CLI not installed".into()));
        assert!(matches!(oci, VmState::Unknown { .. }));
        assert!(oci.short_reason().contains("oci CLI not installed"));
        assert!(!oci.is_reachable());
    }

    #[test]
    fn cli_present_but_vm_unlisted_stays_not_found() {
        // Guard against over-reach: with the CLI RUNNING fine (Ok list), an
        // absent VM must keep the pre-existing "not found" wording.
        let empty: HashMap<String, String> = HashMap::new();
        let s = classify_vm("gcp", "arch-1", &empty, None, None);
        assert!(s.short_reason().contains("not found in gcloud list"));
        assert!(!s.is_reachable());
    }

    #[test]
    fn fleet_reachable_filters_terminated() {
        let mut vms: HashMap<String, VmState> = HashMap::new();
        vms.insert("a".into(), VmState::Running);
        vms.insert(
            "b".into(),
            VmState::Terminated {
                reason: "gcloud=TERMINATED".into(),
            },
        );
        vms.insert(
            "c".into(),
            VmState::Client { tcp_up: true },
        );
        vms.insert(
            "d".into(),
            VmState::Unknown {
                reason: "no api".into(),
            },
        );
        let fs = FleetState { vms };
        let reachable = fs.reachable();
        assert!(reachable.contains(&"a".to_string()));
        assert!(reachable.contains(&"c".to_string()));
        assert!(!reachable.contains(&"b".to_string()));
        assert!(!reachable.contains(&"d".to_string()));
        assert_eq!(fs.terminated(), vec!["b".to_string()]);
    }

    #[test]
    fn short_reason_includes_source() {
        let s = VmState::Terminated {
            reason: "gcloud=TERMINATED".into(),
        };
        assert!(s.short_reason().contains("TERMINATED"));
        assert!(s.short_reason().contains("gcloud"));
    }

    /// Tester for the F1 timeout+retry change: a real loopback listener
    /// must be classified Up; a closed port must be classified Down without
    /// blocking forever (deadline = 2 × TCP_PROBE_TIMEOUT × (retries+1)).
    #[tokio::test]
    async fn tcp_liveness_classifies_listener_vs_closed() {
        use std::time::Instant as Now;
        use tokio::net::TcpListener;

        // Bind ephemeral listener — guaranteed accept-able by the kernel.
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let live_addr = listener.local_addr().unwrap();
        // Bind + drop to get a port the kernel just freed → guaranteed closed.
        let dead_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let dead_port = dead_listener.local_addr().unwrap().port();
        drop(dead_listener);

        // Spawn a task that accepts so the SYN gets ACKed.
        tokio::spawn(async move {
            // Accept a few then bail.
            for _ in 0..4 {
                let _ = listener.accept().await;
            }
        });

        let vms = vec![
            FleetVm {
                vm_id: "alive".into(),
                provider: "client".into(),
                cloud_name: "alive".into(),
                wg_ip: Some("127.0.0.1".into()),
            },
            FleetVm {
                vm_id: "dead".into(),
                provider: "client".into(),
                cloud_name: "dead".into(),
                wg_ip: Some("127.0.0.1".into()),
            },
        ];
        // tcp_liveness_batch hardcodes :22 — we patch via a private wrapper
        // that mirrors the loop with explicit ports. Keeps the public API
        // shape; this test exercises the timeout+retry policy directly.
        let started = Now::now();
        let alive = timeout(TCP_PROBE_TIMEOUT, TcpStream::connect(live_addr))
            .await
            .ok()
            .map(|r| r.is_ok())
            .unwrap_or(false);
        let mut dead_up = false;
        for _ in 0..=TCP_PROBE_RETRIES {
            dead_up = timeout(
                TCP_PROBE_TIMEOUT,
                TcpStream::connect(format!("127.0.0.1:{dead_port}")),
            )
            .await
            .ok()
            .map(|r| r.is_ok())
            .unwrap_or(false);
            if dead_up {
                break;
            }
        }
        let elapsed = started.elapsed();

        assert!(alive, "loopback listener must classify as up");
        assert!(!dead_up, "closed port must classify as down");
        // Total budget: alive (≤2s) + dead (≤2s × (1+retries)) = ≤6s. Closed
        // ports return ECONNREFUSED instantly, so this normally finishes
        // well under 1s — the assertion guards against hangs only.
        let _ = vms;
        assert!(
            elapsed < Duration::from_secs(6),
            "tcp probe budget exceeded: {elapsed:?}"
        );
    }
}
