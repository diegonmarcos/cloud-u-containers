//! Mesh audit — T3 forensic check.
//!
//! Compares declared WireGuard peers (from consolidated JSON) against actual
//! handshake ages (read via `wg show all dump` over SSH). Detects:
//!   - Peer declared but handshake never happened (key mismatch / config error)
//!   - Peer handshake stale > threshold (silent tunnel death)
//!   - Peer present in `wg show` but undeclared in JSON (ghost peer)
//!
//! Runs as part of T3 forensic (daily) or on-demand. Requires WG up + SSH to
//! at least one hub peer (gcp-proxy is the hub; its `wg show` reveals all).

use serde::{Deserialize, Serialize};

pub const WG_STALE_SECS_DEFAULT: u64 = 180;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PeerStatus {
    pub name: String,
    pub pub_key: String,
    pub declared: bool,
    pub last_handshake_secs: Option<u64>,
    pub stale: bool,
    pub status: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MeshAuditResult {
    pub hub_vm: String,
    pub peers: Vec<PeerStatus>,
    pub stale_count: usize,
    pub undeclared_count: usize,
    pub never_connected_count: usize,
    pub ok: bool,
    pub summary: String,
}

/// Parse `wg show all dump` output into (pubkey, latest_handshake_unix_secs).
/// Format: interface pubkey preshared endpoint allowed_ips latest-handshake rx tx persistent-keepalive
pub fn parse_wg_dump(dump: &str, stale_secs: u64) -> Vec<PeerStatus> {
    let mut peers = Vec::new();
    for line in dump.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        // Peer lines have 9 fields; interface lines have different count
        if parts.len() < 9 {
            continue;
        }
        // Skip interface self-line (second field is "none" for preshared on self)
        if parts[1] == "(none)" || parts[0].starts_with("wg") {
            // Could be the interface header line — check if field 5 looks like a timestamp
            if let Ok(ts) = parts[4].parse::<u64>() {
                let _ = ts; // interface line has ts at pos 4 — skip
            }
            continue;
        }
        let pub_key = parts[0].to_string();
        let handshake_ts: Option<u64> = parts[4].parse().ok().filter(|&v| v > 0);
        let stale = handshake_ts
            .map(|ts| {
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs();
                now.saturating_sub(ts) > stale_secs
            })
            .unwrap_or(true); // never connected = stale
        peers.push(PeerStatus {
            name: String::new(), // resolved from consolidated JSON later
            pub_key,
            declared: false,
            last_handshake_secs: handshake_ts.map(|ts| {
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs()
                    .saturating_sub(ts)
            }),
            stale,
            status: if stale { "STALE".into() } else { "OK".into() },
        });
    }
    peers
}

/// Cross-reference parsed WG dump against declared peers in consolidated JSON.
pub fn correlate_peers(
    wg_peers: &mut Vec<PeerStatus>,
    consolidated: &serde_json::Value,
    stale_secs: u64,
) {
    let empty = serde_json::Map::new();
    let vms = consolidated["vms"].as_object().unwrap_or(&empty);

    for (vm_name, vm) in vms {
        let pub_key = match vm["wg_public_key"].as_str() {
            Some(k) => k,
            None => continue,
        };
        if let Some(peer) = wg_peers.iter_mut().find(|p| p.pub_key == pub_key) {
            peer.name = vm_name.clone();
            peer.declared = true;
        } else {
            // Declared but not seen in wg show — never connected or key mismatch
            wg_peers.push(PeerStatus {
                name: vm_name.clone(),
                pub_key: pub_key.to_string(),
                declared: true,
                last_handshake_secs: None,
                stale: true,
                status: "NEVER_CONNECTED".into(),
            });
            let _ = stale_secs;
        }
    }
    // Any remaining peer with declared=false is a ghost (in wg show but not in JSON)
    for p in wg_peers.iter_mut() {
        if !p.declared {
            p.status = "GHOST".into();
        }
    }
}

pub fn summarize(peers: &[PeerStatus]) -> MeshAuditResult {
    let stale: Vec<_> = peers.iter().filter(|p| p.stale && p.declared).collect();
    let undeclared: Vec<_> = peers.iter().filter(|p| !p.declared).collect();
    let never: Vec<_> = peers
        .iter()
        .filter(|p| p.status == "NEVER_CONNECTED")
        .collect();
    let ok = stale.is_empty() && undeclared.is_empty() && never.is_empty();
    let summary = if ok {
        format!("Mesh OK — {} peers all healthy", peers.len())
    } else {
        format!(
            "Mesh DEGRADED — stale:{} ghost:{} never:{}",
            stale.len(),
            undeclared.len(),
            never.len()
        )
    };
    MeshAuditResult {
        hub_vm: String::new(),
        peers: peers.to_vec(),
        stale_count: stale.len(),
        undeclared_count: undeclared.len(),
        never_connected_count: never.len(),
        ok,
        summary,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DUMP: &str = "\
wg0\tGHOST_KEY_abc\t(none)\t1.2.3.4:51820\t10.0.0.2/32\t1751000000\t1024\t2048\t25
wg0\tSTALE_KEY_def\t(none)\t5.6.7.8:51820\t10.0.0.3/32\t0\t0\t0\t25
wg0\tOK_KEY_ghi\t(none)\t9.10.11.12:51820\t10.0.0.4/32\t9999999999\t512\t1024\t25";

    #[test]
    fn parse_detects_stale() {
        let peers = parse_wg_dump(DUMP, 180);
        // STALE_KEY has ts=0 (never) → stale
        let stale = peers.iter().find(|p| p.pub_key == "STALE_KEY_def");
        assert!(stale.is_some());
        assert!(stale.unwrap().stale);
    }

    #[test]
    fn parse_detects_ok() {
        let peers = parse_wg_dump(DUMP, 180);
        // OK_KEY has a future-like timestamp → not stale
        let ok = peers.iter().find(|p| p.pub_key == "OK_KEY_ghi");
        assert!(ok.is_some());
        assert!(!ok.unwrap().stale);
    }
}
