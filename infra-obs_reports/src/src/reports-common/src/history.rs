//! History ring — append-only JSONL for trend data.
//!
//! Keeps at most MAX_LINES entries in each JSONL file. On append, if the file
//! has ≥ MAX_LINES entries, the oldest (first line) is dropped before writing
//! the new entry. No database. No dependencies. One line = one observation.
//!
//! Convention: each line is a JSON object with `"ts"` (RFC3339) + metric fields.
//! Callers own the schema of the fields; this module only manages the ring.
//!
//! # Example
//! ```rust,no_run
//! use reports_common::history;
//! history::append(
//!     "/opt/history/psi.jsonl",
//!     100,
//!     serde_json::json!({"ts": "2026-07-07T00:00:00Z", "mem_psi": 12.3}),
//! ).unwrap();
//! let tail = history::tail("/opt/history/psi.jsonl", 10).unwrap_or_default();
//! ```

use anyhow::{Context, Result};
use serde_json::Value;
use std::io::{BufRead, Write};
use std::path::Path;

pub const DEFAULT_MAX_LINES: usize = 1440; // 24h at 1min cadence

/// Append one JSON object to a JSONL ring file.
/// If the file grows beyond `max_lines`, the oldest entry is evicted first.
/// Creates the file (and parent dirs) if it doesn't exist.
pub fn append(path: &str, max_lines: usize, entry: Value) -> Result<()> {
    let p = Path::new(path);
    if let Some(parent) = p.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("mkdir -p {}", parent.display()))?;
    }

    // Read existing lines
    let existing: Vec<String> = if p.exists() {
        let f = std::fs::File::open(p).with_context(|| format!("open {}", path))?;
        std::io::BufReader::new(f)
            .lines()
            .filter_map(|l| l.ok())
            .filter(|l| !l.trim().is_empty())
            .collect()
    } else {
        Vec::new()
    };

    // Build new line set: drop oldest if at cap
    let new_line = serde_json::to_string(&entry).context("serialise history entry")?;
    let mut lines: Vec<&str> = existing.iter().map(|s| s.as_str()).collect();
    while lines.len() >= max_lines {
        lines.remove(0);
    }

    // Write atomically
    let tmp = format!("{}.tmp.{}", path, std::process::id());
    let mut f = std::fs::File::create(&tmp).with_context(|| format!("create {}", tmp))?;
    for line in &lines {
        writeln!(f, "{}", line)?;
    }
    writeln!(f, "{}", new_line)?;
    std::fs::rename(&tmp, p).with_context(|| format!("rename {} -> {}", tmp, path))?;

    Ok(())
}

/// Return the last `n` entries from a JSONL file, parsed as JSON values.
pub fn tail(path: &str, n: usize) -> Result<Vec<Value>> {
    let p = Path::new(path);
    if !p.exists() {
        return Ok(Vec::new());
    }
    let f = std::fs::File::open(p).with_context(|| format!("open {}", path))?;
    let lines: Vec<Value> = std::io::BufReader::new(f)
        .lines()
        .filter_map(|l| l.ok())
        .filter(|l| !l.trim().is_empty())
        .filter_map(|l| serde_json::from_str(&l).ok())
        .collect();
    let start = lines.len().saturating_sub(n);
    Ok(lines[start..].to_vec())
}

/// Compute min/max/avg of a numeric field across history entries.
pub fn stats(entries: &[Value], field: &str) -> Option<(f64, f64, f64)> {
    let vals: Vec<f64> = entries
        .iter()
        .filter_map(|e| e[field].as_f64())
        .collect();
    if vals.is_empty() {
        return None;
    }
    let min = vals.iter().cloned().fold(f64::INFINITY, f64::min);
    let max = vals.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    let avg = vals.iter().sum::<f64>() / vals.len() as f64;
    Some((min, max, avg))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn tmp(label: &str) -> String {
        format!(
            "/tmp/history_test_{}_{}.jsonl",
            label,
            std::process::id()
        )
    }

    #[test]
    fn append_and_tail() {
        let path = tmp("basic");
        for i in 0..5 {
            append(&path, 100, json!({"ts": "2026-01-01", "v": i})).unwrap();
        }
        let t = tail(&path, 3).unwrap();
        assert_eq!(t.len(), 3);
        assert_eq!(t[2]["v"].as_u64(), Some(4));
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn ring_evicts_oldest() {
        let path = tmp("ring");
        for i in 0..15 {
            append(&path, 10, json!({"ts": "2026-01-01", "v": i})).unwrap();
        }
        let all = tail(&path, 1000).unwrap();
        assert_eq!(all.len(), 10);
        assert_eq!(all[0]["v"].as_u64(), Some(5)); // oldest kept is v=5
        assert_eq!(all[9]["v"].as_u64(), Some(14));
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn stats_correct() {
        let entries = vec![json!({"x": 1.0}), json!({"x": 3.0}), json!({"x": 2.0})];
        let (min, max, avg) = stats(&entries, "x").unwrap();
        assert_eq!(min, 1.0);
        assert_eq!(max, 3.0);
        assert!((avg - 2.0).abs() < 1e-9);
    }
}
