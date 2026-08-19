//! RunState — the cross-crate snapshot ABI for the daily reports pipeline.
//!
//! The master crate (`cloud-health-full-daily`) collects once and serialises a
//! `RunState` to `dist/_run_state.json`. The derive crates (mail / url / sec-*)
//! each load that snapshot, do only their unique work, and merge their slice
//! back into it via [`RunState::merge_section`]. After the derive fan-out the
//! master re-reads the (now enriched) snapshot to render the daily appendix.
//!
//! Why a snapshot instead of message-passing in process? The pipeline's
//! collectors are split across separate binaries (so each derive can also be
//! invoked standalone with its own cadence). The on-disk JSON is the
//! integration boundary that survives that split.
//!
//! ABI rules:
//!   - `version: u32` is bumped only when a *removal* or *type change* would
//!     break older readers. Adding a new optional field is silent.
//!   - Master-collected leaf data is stored as `serde_json::Value` so the rich
//!     leaf types (VmData, EndpointResult, ...) can keep living in the master
//!     crate without forcing a workspace-wide refactor on day 1. Each derive
//!     deserialises only the slice it needs.
//!   - `merge_section` takes an OS-level exclusive file lock around the
//!     read-modify-write so concurrent derives don't lose each other's writes.

use anyhow::{anyhow, Context, Result};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use std::fs::OpenOptions;
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::fleet::FleetState;

pub const RUN_STATE_VERSION: u32 = 1;
pub const RUN_STATE_FILENAME: &str = "_run_state.json";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunState {
    pub version: u32,
    pub generated_at: String,
    /// R1: the tier cadence (seconds) this snapshot was collected under. The
    /// renderer marks the report STALE once `age > max_age_secs`. Stamped at
    /// collection time so readers don't have to guess the cadence — a T2
    /// snapshot (15m) and a T3 snapshot (24h) carry their own freshness budget.
    #[serde(default)]
    pub max_age_secs: Option<u64>,
    #[serde(default)]
    pub master_duration_ms: Option<u64>,

    // ── Master-collected leaf data ────────────────────────────────
    // Stored as opaque Value so the leaf types stay in the master
    // crate. Derives deserialise only what they need.
    #[serde(default)]
    pub vms: Option<serde_json::Value>,
    #[serde(default)]
    pub endpoints: Option<serde_json::Value>,
    #[serde(default)]
    pub certs: Option<serde_json::Value>,
    #[serde(default)]
    pub dns: Option<serde_json::Value>,
    #[serde(default)]
    pub gha_runs: Option<serde_json::Value>,
    #[serde(default)]
    pub gha_workflows: Option<serde_json::Value>,
    #[serde(default)]
    pub ghcr: Option<serde_json::Value>,
    #[serde(default)]
    pub dags: Option<serde_json::Value>,
    #[serde(default)]
    pub cloud_buckets: Option<serde_json::Value>,
    #[serde(default)]
    pub cloud_costs: Option<serde_json::Value>,
    #[serde(default)]
    pub repos: Option<serde_json::Value>,
    #[serde(default)]
    pub matomo_sites: Option<serde_json::Value>,
    #[serde(default)]
    pub umami_sites: Option<serde_json::Value>,
    #[serde(default)]
    pub container_drift: Option<serde_json::Value>,
    #[serde(default)]
    pub storage_drift: Option<serde_json::Value>,

    // ── Strongly typed (lives in reports-common) ──────────────────
    #[serde(default)]
    pub fleet_state: Option<FleetState>,

    // ── Derive-written sections ───────────────────────────────────
    #[serde(default)]
    pub mail_full: Option<serde_json::Value>,
    #[serde(default)]
    pub url_health: Option<serde_json::Value>,
    #[serde(default)]
    pub sec_network: Option<serde_json::Value>,
    #[serde(default)]
    pub sec_data: Option<serde_json::Value>,

    // ── Optional unique sections ──────────────────────────────────
    #[serde(default)]
    pub stack: Option<serde_json::Value>,
    #[serde(default)]
    pub health_full_layers: Option<serde_json::Value>,
    #[serde(default)]
    pub master_perf: Option<serde_json::Value>,
}

impl RunState {
    pub fn new() -> Self {
        Self {
            version: RUN_STATE_VERSION,
            generated_at: chrono::Utc::now().to_rfc3339(),
            max_age_secs: None,
            master_duration_ms: None,
            vms: None,
            endpoints: None,
            certs: None,
            dns: None,
            gha_runs: None,
            gha_workflows: None,
            ghcr: None,
            dags: None,
            cloud_buckets: None,
            cloud_costs: None,
            repos: None,
            matomo_sites: None,
            umami_sites: None,
            container_drift: None,
            storage_drift: None,
            fleet_state: None,
            mail_full: None,
            url_health: None,
            sec_network: None,
            sec_data: None,
            stack: None,
            health_full_layers: None,
            master_perf: None,
        }
    }

    /// Load and validate. Errors on missing file, invalid JSON, or
    /// future-version schema we cannot read.
    pub fn load(path: &Path) -> Result<Self> {
        let bytes = std::fs::read(path)
            .with_context(|| format!("read {}", path.display()))?;
        let rs: RunState = serde_json::from_slice(&bytes)
            .with_context(|| format!("parse {}", path.display()))?;
        if rs.version > RUN_STATE_VERSION {
            return Err(anyhow!(
                "snapshot {} has version {} but reader knows only up to {}",
                path.display(),
                rs.version,
                RUN_STATE_VERSION
            ));
        }
        Ok(rs)
    }

    /// Atomic write: tempfile in same dir + rename. The rename is atomic
    /// on POSIX, so readers either see the old file or the complete new one.
    pub fn write_atomic(&self, path: &Path) -> Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("mkdir -p {}", parent.display()))?;
        }
        let tmp: PathBuf = match path.file_name() {
            Some(name) => {
                let mut t = path.to_path_buf();
                t.set_file_name(format!(
                    ".{}.tmp.{}",
                    name.to_string_lossy(),
                    std::process::id()
                ));
                t
            }
            None => return Err(anyhow!("path has no file name: {}", path.display())),
        };
        let json = serde_json::to_vec_pretty(self).context("serialise RunState")?;
        std::fs::write(&tmp, &json)
            .with_context(|| format!("write {}", tmp.display()))?;
        std::fs::rename(&tmp, path)
            .with_context(|| format!("rename {} → {}", tmp.display(), path.display()))?;
        Ok(())
    }

    /// Read-modify-write under an OS exclusive file lock. The lock covers the
    /// entire RMW so concurrent derives can each set distinct fields without
    /// races; on a missing snapshot a fresh `RunState::new()` is created.
    pub fn merge_section<F>(path: &Path, mutator: F) -> Result<()>
    where
        F: FnOnce(&mut RunState),
    {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("mkdir -p {}", parent.display()))?;
        }
        let lock_path: PathBuf = {
            let mut p = path.to_path_buf();
            let name = path
                .file_name()
                .ok_or_else(|| anyhow!("path has no file name"))?
                .to_string_lossy()
                .to_string();
            p.set_file_name(format!(".{}.lock", name));
            p
        };
        let lock = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .open(&lock_path)
            .with_context(|| format!("open lock {}", lock_path.display()))?;
        lock.lock_exclusive()
            .with_context(|| format!("lock {}", lock_path.display()))?;

        let result: Result<()> = (|| {
            let mut rs = if path.exists() {
                Self::load(path)?
            } else {
                Self::new()
            };
            mutator(&mut rs);
            rs.generated_at = chrono::Utc::now().to_rfc3339();
            rs.write_atomic(path)
        })();

        let _ = FileExt::unlock(&lock);
        result
    }

    /// True iff `generated_at` parses and is no older than `max_age`.
    pub fn is_fresh(&self, max_age: Duration) -> bool {
        let parsed = chrono::DateTime::parse_from_rfc3339(&self.generated_at);
        let Ok(ts) = parsed else { return false };
        let age = chrono::Utc::now().signed_duration_since(ts.with_timezone(&chrono::Utc));
        let max = chrono::Duration::from_std(max_age).unwrap_or(chrono::Duration::seconds(0));
        age <= max && age >= chrono::Duration::seconds(0)
    }

    /// Seconds since `generated_at`. Returns None if timestamp is unparseable.
    pub fn age_secs(&self) -> Option<i64> {
        let ts = chrono::DateTime::parse_from_rfc3339(&self.generated_at).ok()?;
        Some(chrono::Utc::now().signed_duration_since(ts.with_timezone(&chrono::Utc)).num_seconds())
    }

    /// Human-readable staleness label for report rendering.
    /// `max_age` is the tier cadence (T1=2m, T2=15m, T3=24h).
    /// Returns None when fresh, Some(description) when stale.
    /// R1: callers MUST show this prominently — a STALE report is worse than no
    /// report because it can mask real outages or produce false alarms.
    pub fn stale_label(&self, max_age: Duration) -> Option<String> {
        if self.is_fresh(max_age) {
            return None;
        }
        let secs = self.age_secs().unwrap_or(0);
        let desc = if secs < 3600 {
            format!("{}m old", secs / 60)
        } else if secs < 86400 {
            format!("{}h old", secs / 3600)
        } else {
            format!("{}d old", secs / 86400)
        };
        Some(format!(
            "⚠️  STALE REPORT ({}) — generated {} — findings may not reflect current state",
            desc,
            self.generated_at
        ))
    }

    /// R1: stamp the tier cadence at collection time so downstream readers
    /// don't have to know it. `stale_label_stamped` then needs no argument.
    pub fn stamp_max_age(&mut self, max_age: Duration) {
        self.max_age_secs = Some(max_age.as_secs());
    }

    /// R1: staleness using the stamped `max_age_secs`. Returns None (never
    /// stale) if no cadence was stamped — absence of a budget must not
    /// manufacture a STALE banner. Prefer this over `stale_label` when the
    /// collector stamped the cadence; use `stale_label(cadence)` otherwise.
    pub fn stale_label_stamped(&self) -> Option<String> {
        let secs = self.max_age_secs?;
        self.stale_label(Duration::from_secs(secs))
    }
}

impl Default for RunState {
    fn default() -> Self {
        Self::new()
    }
}

/// Read a typed slice from a stored snapshot in one step.
/// Returns `Ok(None)` if the field is absent; `Err` if present-but-mismatched.
pub fn get_section<T>(rs: &RunState, field: &Option<serde_json::Value>) -> Result<Option<T>>
where
    T: for<'de> Deserialize<'de>,
{
    let _ = rs;
    let Some(v) = field else { return Ok(None) };
    let parsed = serde_json::from_value::<T>(v.clone())
        .with_context(|| "deserialise RunState section")?;
    Ok(Some(parsed))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::thread;

    fn tmp_path(label: &str) -> PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "run_state_test_{}_{}_{}.json",
            label,
            std::process::id(),
            chrono::Utc::now().timestamp_nanos_opt().unwrap_or(0)
        ));
        p
    }

    #[test]
    fn round_trip_serialization() {
        let mut rs = RunState::new();
        rs.master_duration_ms = Some(1234);
        rs.mail_full = Some(serde_json::json!({"score": 0.9}));
        rs.fleet_state = Some(FleetState {
            vms: [("a".to_string(), crate::fleet::VmState::Running)]
                .into_iter()
                .collect(),
        });

        let path = tmp_path("round_trip");
        rs.write_atomic(&path).unwrap();
        let back = RunState::load(&path).unwrap();
        assert_eq!(back.version, RUN_STATE_VERSION);
        assert_eq!(back.master_duration_ms, Some(1234));
        assert_eq!(
            back.mail_full.as_ref().unwrap()["score"]
                .as_f64()
                .unwrap(),
            0.9
        );
        let fs = back.fleet_state.unwrap();
        assert_eq!(fs.classify("a"), crate::fleet::VmState::Running);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn merge_section_atomic_two_writers() {
        // Two concurrent writers setting distinct fields must both end up
        // visible in the final snapshot — the lock guarantees this even
        // though each writer does a full read-mutate-write.
        let path = Arc::new(tmp_path("merge_atomic"));
        let p1 = Arc::clone(&path);
        let p2 = Arc::clone(&path);

        let h1 = thread::spawn(move || {
            for _ in 0..20 {
                RunState::merge_section(&p1, |s| {
                    s.mail_full = Some(serde_json::json!({"writer": "mail"}));
                })
                .unwrap();
            }
        });
        let h2 = thread::spawn(move || {
            for _ in 0..20 {
                RunState::merge_section(&p2, |s| {
                    s.url_health = Some(serde_json::json!({"writer": "url"}));
                })
                .unwrap();
            }
        });
        h1.join().unwrap();
        h2.join().unwrap();

        let final_rs = RunState::load(&path).unwrap();
        assert!(final_rs.mail_full.is_some(), "mail slice lost");
        assert!(final_rs.url_health.is_some(), "url slice lost");
        let _ = std::fs::remove_file(&*path);
        let mut lock = (*path).clone();
        let lock_name = format!(
            ".{}.lock",
            path.file_name().unwrap().to_string_lossy()
        );
        lock.set_file_name(lock_name);
        let _ = std::fs::remove_file(&lock);
    }

    #[test]
    fn future_version_rejected() {
        let path = tmp_path("future_version");
        let payload = serde_json::json!({
            "version": RUN_STATE_VERSION + 99,
            "generated_at": chrono::Utc::now().to_rfc3339(),
        });
        std::fs::write(&path, serde_json::to_vec_pretty(&payload).unwrap()).unwrap();
        let err = RunState::load(&path).unwrap_err();
        assert!(err.to_string().contains("version"), "got: {err}");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn merge_creates_when_absent() {
        let path = tmp_path("merge_create");
        assert!(!path.exists());
        RunState::merge_section(&path, |s| {
            s.sec_network = Some(serde_json::json!({"hello": true}));
        })
        .unwrap();
        let rs = RunState::load(&path).unwrap();
        assert!(rs.sec_network.is_some());
        let _ = std::fs::remove_file(&path);
        let mut lock = path.clone();
        lock.set_file_name(format!(
            ".{}.lock",
            path.file_name().unwrap().to_string_lossy()
        ));
        let _ = std::fs::remove_file(&lock);
    }

    #[test]
    fn is_fresh_within_window() {
        let mut rs = RunState::new();
        rs.generated_at = chrono::Utc::now().to_rfc3339();
        assert!(rs.is_fresh(Duration::from_secs(60)));
    }

    #[test]
    fn is_fresh_rejects_stale() {
        let mut rs = RunState::new();
        let stale = chrono::Utc::now() - chrono::Duration::seconds(3600);
        rs.generated_at = stale.to_rfc3339();
        assert!(!rs.is_fresh(Duration::from_secs(60)));
    }

    #[test]
    fn r1_backdated_stamped_run_state_is_stale() {
        // Stamp a 2-minute (T1) cadence, then backdate the snapshot an hour.
        // stale_label_stamped must return Some(..) — the report is STALE.
        let mut rs = RunState::new();
        rs.stamp_max_age(Duration::from_secs(120));
        rs.generated_at = (chrono::Utc::now() - chrono::Duration::seconds(3600)).to_rfc3339();
        let label = rs.stale_label_stamped();
        assert!(label.is_some(), "backdated stamped snapshot must be STALE");
        assert!(label.unwrap().contains("STALE"));
    }

    #[test]
    fn r1_fresh_stamped_run_state_not_stale() {
        let mut rs = RunState::new();
        rs.stamp_max_age(Duration::from_secs(120));
        rs.generated_at = chrono::Utc::now().to_rfc3339();
        assert!(rs.stale_label_stamped().is_none());
    }

    #[test]
    fn r1_unstamped_run_state_never_stale() {
        // No cadence stamped → absence of a budget must not manufacture STALE.
        let mut rs = RunState::new();
        rs.generated_at = (chrono::Utc::now() - chrono::Duration::days(30)).to_rfc3339();
        assert!(rs.stale_label_stamped().is_none());
    }
}
