//! Per-step wall-clock instrumentation.
//!
//! Every collector / phase wraps its work in `Perf::time(...)` or the
//! `time!` / `time_async!` macros. The thread-safe `PerfTracker` collects
//! ordered `(name, duration_ms, started_at_ms_offset, ok)` records and
//! emits both:
//!   - a structured JSON section the report writes to its `.json`
//!   - a human-readable "PERFORMANCE" markdown table
//!
//! Why a tracker (not just println!): we already println timings, but they
//! are scattered, ad-hoc, and not machine-readable. The tracker is the
//! single source of truth; renderers project from it.
//!
//! Fire Rule #4 — tested below.

use serde::Serialize;
use std::sync::Mutex;
use std::time::Instant;

#[derive(Debug, Clone, Serialize)]
pub struct PerfRecord {
    pub name: String,
    pub started_at_ms: u64,
    pub duration_ms: u64,
    pub ok: bool,
    pub error: Option<String>,
}

#[derive(Debug, Default, Serialize)]
pub struct PerfReport {
    pub started_at: String,
    pub total_ms: u64,
    pub records: Vec<PerfRecord>,
}

impl PerfReport {
    /// Render a Markdown table sorted by duration descending.
    pub fn to_markdown(&self) -> String {
        let mut sorted = self.records.clone();
        sorted.sort_by(|a, b| b.duration_ms.cmp(&a.duration_ms));

        let mut s = String::new();
        s.push_str("| Step | Duration | Status |\n");
        s.push_str("|---|---:|---|\n");
        for r in &sorted {
            let status = if r.ok { "✅" } else { "❌" };
            let dur = if r.duration_ms >= 1000 {
                format!("{:.2}s", r.duration_ms as f64 / 1000.0)
            } else {
                format!("{}ms", r.duration_ms)
            };
            s.push_str(&format!("| {} | {} | {} |\n", r.name, dur, status));
        }
        s.push_str(&format!(
            "| **TOTAL** | **{:.2}s** | |\n",
            self.total_ms as f64 / 1000.0
        ));
        s
    }
}

/// Per-process tracker. Pipelines pass an `Arc<PerfTracker>` to collectors
/// so all timing lands in one ordered list. Cheap mutex; only contended
/// briefly at end of each step.
pub struct PerfTracker {
    started: Instant,
    records: Mutex<Vec<PerfRecord>>,
}

impl Default for PerfTracker {
    fn default() -> Self {
        Self::new()
    }
}

impl PerfTracker {
    pub fn new() -> Self {
        Self {
            started: Instant::now(),
            records: Mutex::new(Vec::new()),
        }
    }

    /// Record a step result. Use `ok=false` + `error` for failed steps.
    pub fn record(&self, name: impl Into<String>, duration_ms: u64, ok: bool, error: Option<String>) {
        let started_at_ms = self.started.elapsed().as_millis() as u64 - duration_ms.min(self.started.elapsed().as_millis() as u64);
        let mut g = self.records.lock().unwrap_or_else(|p| p.into_inner());
        g.push(PerfRecord {
            name: name.into(),
            started_at_ms,
            duration_ms,
            ok,
            error,
        });
    }

    /// Time a synchronous closure. Always records, even on panic-free errors.
    pub fn time<T, F>(&self, name: impl Into<String>, f: F) -> T
    where
        F: FnOnce() -> T,
    {
        let t0 = Instant::now();
        let out = f();
        let dur = t0.elapsed().as_millis() as u64;
        self.record(name, dur, true, None);
        out
    }

    /// Time an async future. Records `ok=true` regardless of inner Result —
    /// callers can pass `Result<T,E>` via `time_result` to capture failure.
    pub async fn time_async<T, F>(&self, name: impl Into<String>, fut: F) -> T
    where
        F: std::future::Future<Output = T>,
    {
        let t0 = Instant::now();
        let out = fut.await;
        let dur = t0.elapsed().as_millis() as u64;
        self.record(name, dur, true, None);
        out
    }

    /// Time an async future returning a `Result`; records ok/err accordingly.
    pub async fn time_result<T, E, F>(&self, name: impl Into<String>, fut: F) -> Result<T, E>
    where
        F: std::future::Future<Output = Result<T, E>>,
        E: std::fmt::Display,
    {
        let t0 = Instant::now();
        let out = fut.await;
        let dur = t0.elapsed().as_millis() as u64;
        let ok = out.is_ok();
        let error = out.as_ref().err().map(|e| e.to_string());
        self.record(name, dur, ok, error);
        out
    }

    /// Snapshot the records into a `PerfReport`.
    pub fn finish(&self) -> PerfReport {
        let records = {
            let g = self.records.lock().unwrap_or_else(|p| p.into_inner());
            g.clone()
        };
        PerfReport {
            started_at: chrono::Utc::now().to_rfc3339(),
            total_ms: self.started.elapsed().as_millis() as u64,
            records,
        }
    }

    /// Number of recorded steps so far.
    pub fn len(&self) -> usize {
        self.records.lock().unwrap_or_else(|p| p.into_inner()).len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn time_records_a_step() {
        let p = PerfTracker::new();
        p.time("step.x", || std::thread::sleep(std::time::Duration::from_millis(10)));
        let r = p.finish();
        assert_eq!(r.records.len(), 1);
        assert_eq!(r.records[0].name, "step.x");
        assert!(r.records[0].duration_ms >= 10);
        assert!(r.records[0].ok);
    }

    #[tokio::test]
    async fn time_async_records_a_step() {
        let p = PerfTracker::new();
        let v: i32 = p
            .time_async("async.step", async {
                tokio::time::sleep(std::time::Duration::from_millis(15)).await;
                42
            })
            .await;
        assert_eq!(v, 42);
        let r = p.finish();
        assert_eq!(r.records.len(), 1);
        assert!(r.records[0].duration_ms >= 15);
    }

    #[tokio::test]
    async fn time_result_captures_failure() {
        let p = PerfTracker::new();
        let r: Result<(), &str> = p
            .time_result("step.fails", async { Err::<(), &str>("nope") })
            .await;
        assert!(r.is_err());
        let report = p.finish();
        assert_eq!(report.records.len(), 1);
        assert!(!report.records[0].ok);
        assert_eq!(report.records[0].error.as_deref(), Some("nope"));
    }

    #[test]
    fn markdown_sorts_by_duration_desc() {
        let p = PerfTracker::new();
        p.record("fast", 5, true, None);
        p.record("slow", 500, true, None);
        p.record("medium", 50, true, None);
        let md = p.finish().to_markdown();
        let slow_pos = md.find("slow").unwrap();
        let medium_pos = md.find("medium").unwrap();
        let fast_pos = md.find("fast").unwrap();
        assert!(slow_pos < medium_pos);
        assert!(medium_pos < fast_pos);
        assert!(md.contains("**TOTAL**"));
    }

    #[test]
    fn shared_across_threads_via_arc() {
        use std::sync::Arc;
        let p = Arc::new(PerfTracker::new());
        let handles: Vec<_> = (0..4)
            .map(|i| {
                let p = p.clone();
                std::thread::spawn(move || {
                    p.time(format!("t.{}", i), || {
                        std::thread::sleep(std::time::Duration::from_millis(5));
                    });
                })
            })
            .collect();
        for h in handles {
            h.join().unwrap();
        }
        let r = p.finish();
        assert_eq!(r.records.len(), 4);
    }
}
