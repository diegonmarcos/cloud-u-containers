//! Tier — the scan-cadence model for the tiered reports engine (Phase 1).
//!
//! Four tiers, cheaper→deeper, cadence + check-list data-driven from
//! `build-reports.json:.tiers` (source: `2_configs/src/inputs/reports-tiers.json`).
//! Binaries accept a `--tier <t0|t1|t2|t3>` flag; the crate maps the tier to
//! its `interval_secs`, `max_age_secs` (the staleness budget the renderer uses,
//! R1) and the list of check groups to run.
//!
//! This module is pure data + parsing — no I/O beyond reading the already-loaded
//! build-reports config, so it unit-tests without a filesystem.

use serde_json::Value;
use std::time::Duration;

/// The four scan tiers. `Ondemand` is a manual full-forensic run for one host.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tier {
    T0,
    T1,
    T2,
    T3,
    Ondemand,
}

impl Tier {
    /// The `tiers` block key this tier reads (Ondemand has no cadence block).
    pub fn key(&self) -> Option<&'static str> {
        match self {
            Tier::T0 => Some("t0"),
            Tier::T1 => Some("t1"),
            Tier::T2 => Some("t2"),
            Tier::T3 => Some("t3"),
            Tier::Ondemand => None,
        }
    }

    /// Parse a tier token (case-insensitive). Accepts `t0`..`t3`, `0`..`3`,
    /// and `on-demand`/`ondemand`.
    pub fn parse(s: &str) -> Option<Tier> {
        match s.trim().to_ascii_lowercase().as_str() {
            "t0" | "0" | "heartbeat" => Some(Tier::T0),
            "t1" | "1" | "probe" => Some(Tier::T1),
            "t2" | "2" | "deep" => Some(Tier::T2),
            "t3" | "3" | "forensic" => Some(Tier::T3),
            "ondemand" | "on-demand" | "on_demand" => Some(Tier::Ondemand),
            _ => None,
        }
    }
}

impl std::fmt::Display for Tier {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Tier::T0 => write!(f, "t0"),
            Tier::T1 => write!(f, "t1"),
            Tier::T2 => write!(f, "t2"),
            Tier::T3 => write!(f, "t3"),
            Tier::Ondemand => write!(f, "on-demand"),
        }
    }
}

/// Resolved cadence + check-list for a tier, pulled from the `tiers` block.
#[derive(Debug, Clone)]
pub struct TierSpec {
    pub tier: Tier,
    pub interval_secs: u64,
    pub max_age_secs: u64,
    pub checks: Vec<String>,
}

impl TierSpec {
    /// The staleness budget for the renderer (R1). Ondemand never goes stale
    /// (it's a one-shot manual run), so its budget is effectively infinite.
    pub fn max_age(&self) -> Duration {
        Duration::from_secs(self.max_age_secs)
    }

    pub fn interval(&self) -> Duration {
        Duration::from_secs(self.interval_secs)
    }
}

/// Resolve a `TierSpec` from a loaded `tiers` block (as embedded in
/// build-reports.json). Returns None if the tier's block is absent.
/// `Ondemand` yields a spec with a very large budget and no fixed check-list.
pub fn resolve(tiers: &Value, tier: Tier) -> Option<TierSpec> {
    if tier == Tier::Ondemand {
        return Some(TierSpec {
            tier,
            interval_secs: 0,
            max_age_secs: u64::MAX,
            checks: Vec::new(),
        });
    }
    let key = tier.key()?;
    let node = tiers.get(key)?;
    let interval_secs = node.get("interval_secs")?.as_u64()?;
    // max_age defaults to 4× the interval when unstamped, tolerating a missed run.
    let max_age_secs = node
        .get("max_age_secs")
        .and_then(|v| v.as_u64())
        .unwrap_or(interval_secs.saturating_mul(4));
    let checks = node
        .get("checks")
        .and_then(|v| v.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default();
    Some(TierSpec {
        tier,
        interval_secs,
        max_age_secs,
        checks,
    })
}

/// Extract a `--tier <val>` (or `--tier=<val>`) from a CLI arg list.
/// Returns the parsed `Tier`, or None if the flag is absent. An unparseable
/// value returns None (caller decides the default).
pub fn tier_from_args<I, S>(args: I) -> Option<Tier>
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    let mut it = args.into_iter();
    while let Some(a) = it.next() {
        let a = a.as_ref();
        if let Some(v) = a.strip_prefix("--tier=") {
            return Tier::parse(v);
        }
        if a == "--tier" {
            if let Some(next) = it.next() {
                return Tier::parse(next.as_ref());
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parse_tier_tokens() {
        assert_eq!(Tier::parse("t0"), Some(Tier::T0));
        assert_eq!(Tier::parse("T2"), Some(Tier::T2));
        assert_eq!(Tier::parse("3"), Some(Tier::T3));
        assert_eq!(Tier::parse("probe"), Some(Tier::T1));
        assert_eq!(Tier::parse("on-demand"), Some(Tier::Ondemand));
        assert_eq!(Tier::parse("bogus"), None);
    }

    #[test]
    fn tier_flag_from_args_both_forms() {
        let a = vec!["prog", "--tier", "t2", "--verbose"];
        assert_eq!(tier_from_args(a), Some(Tier::T2));
        let b = vec!["prog", "--tier=t3"];
        assert_eq!(tier_from_args(b), Some(Tier::T3));
        let c = vec!["prog", "--other", "x"];
        assert_eq!(tier_from_args(c), None);
        // trailing --tier with no value → None, not a panic
        let d = vec!["prog", "--tier"];
        assert_eq!(tier_from_args(d), None);
    }

    #[test]
    fn resolve_spec_reads_cadence_and_checks() {
        let tiers = json!({
            "t1": { "interval_secs": 120, "max_age_secs": 600, "checks": ["urls", "tls"] },
            "t2": { "interval_secs": 900, "checks": ["ssh", "psi"] }
        });
        let s1 = resolve(&tiers, Tier::T1).unwrap();
        assert_eq!(s1.interval_secs, 120);
        assert_eq!(s1.max_age_secs, 600);
        assert_eq!(s1.checks, vec!["urls", "tls"]);
        assert_eq!(s1.max_age(), Duration::from_secs(600));
        // missing max_age_secs → 4× interval default
        let s2 = resolve(&tiers, Tier::T2).unwrap();
        assert_eq!(s2.max_age_secs, 3600);
        // absent tier → None
        assert!(resolve(&tiers, Tier::T3).is_none());
    }

    #[test]
    fn resolve_ondemand_never_stale() {
        let tiers = json!({});
        let s = resolve(&tiers, Tier::Ondemand).unwrap();
        assert_eq!(s.max_age_secs, u64::MAX);
        assert!(s.checks.is_empty());
    }
}
