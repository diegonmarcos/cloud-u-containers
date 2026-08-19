use crate::run_state::RunState;
use crate::types::*;
use std::collections::HashMap;
use std::time::Duration;

/// R1: Render the report's top-line status, choosing STALE over the check
/// roll-up when the underlying snapshot is older than the tier cadence.
///
/// The precedence is deliberate: a STALE banner must WIN over a computed RED,
/// because a red verdict derived from stale data is not trustworthy — it can
/// mask a recovery (infra came back but the snapshot predates it) or invent an
/// outage. Callers pass the tier cadence as `max_age` (T1=2m, T2=15m, T3=24h).
///
/// Returns `(Status, headline)` — the caller prints the headline at the top of
/// the report and can branch on the Status (e.g. exit code, ntfy severity).
pub fn render_report_status(
    rs: &RunState,
    summary: &Summary,
    max_age: Duration,
    wg_gated_unknown: bool,
) -> (Status, String) {
    if let Some(stale) = rs.stale_label(max_age) {
        return (Status::Stale, format!("{} {}", Status::Stale.badge(), stale));
    }
    if wg_gated_unknown {
        return (
            Status::Unknown,
            format!(
                "{} UNKNOWN — WG mesh down from runner; SSH/DNS checks not evaluated (not an outage)",
                Status::Unknown.badge()
            ),
        );
    }
    let status = Status::from_summary(summary);
    let headline = format!(
        "{} {} — {}",
        status.badge(),
        status,
        build_result_summary(summary)
    );
    (status, headline)
}

/// Format a section of checks with icons, duration, severity
pub fn format_checks(checks: &[Check]) -> String {
    if checks.is_empty() {
        return "  (no checks)".to_string();
    }

    let mut lines = Vec::new();
    for c in checks {
        let icon = if c.passed {
            "\u{2705}"
        } else {
            match c.severity {
                Severity::Critical => "\u{274c}",
                Severity::Warning => "\u{26a0}\u{fe0f} ",
                Severity::Info => "\u{2139}\u{fe0f} ",
            }
        };

        let duration = if c.duration_ms > 0 {
            format!(" ({:.1}s)", c.duration_ms as f64 / 1000.0)
        } else {
            String::new()
        };

        let severity_tag = if !c.passed {
            format!(" [{}]", c.severity)
        } else {
            String::new()
        };

        lines.push(format!(
            "  {} {:30} {}{}{}",
            icon, c.name, c.details, duration, severity_tag,
        ));
    }

    // Summary line
    let total = checks.len();
    let passed = checks.iter().filter(|c| c.passed).count();
    let failed = total - passed;
    lines.push(String::new());
    lines.push(format!(
        "  Summary: {}/{} passed, {} failed",
        passed, total, failed
    ));

    lines.join("\n")
}

/// Build issues summary from a flat list of all checks
pub fn build_issues_summary(all_checks: &[&Check]) -> String {
    let failed: Vec<&&Check> = all_checks.iter().filter(|c| !c.passed).collect();

    if failed.is_empty() {
        return "  No issues found \u{2014} all checks passed.".into();
    }

    let critical: Vec<_> = failed
        .iter()
        .filter(|c| c.severity == Severity::Critical)
        .collect();
    let warnings: Vec<_> = failed
        .iter()
        .filter(|c| c.severity == Severity::Warning)
        .collect();
    let info: Vec<_> = failed
        .iter()
        .filter(|c| c.severity == Severity::Info)
        .collect();

    let mut lines = vec![format!(
        "  {} issues: {} critical, {} warnings, {} info",
        failed.len(),
        critical.len(),
        warnings.len(),
        info.len()
    )];
    lines.push(String::new());

    if !critical.is_empty() {
        lines.push("  CRITICAL:".into());
        for c in &critical {
            lines.push(format!("    \u{274c} {}: {}", c.name, c.details));
        }
    }

    if !warnings.is_empty() {
        lines.push("  WARNINGS:".into());
        for c in &warnings {
            lines.push(format!("    \u{26a0}\u{fe0f}  {}: {}", c.name, c.details));
        }
    }

    if !info.is_empty() {
        lines.push("  INFO:".into());
        for c in &info {
            lines.push(format!("    \u{2139}\u{fe0f}  {}: {}", c.name, c.details));
        }
    }

    lines.join("\n")
}

/// Build performance section from timers
pub fn build_performance(timers: &HashMap<String, u64>, total_ms: u64) -> String {
    let mut sorted: Vec<_> = timers.iter().collect();
    sorted.sort_by(|a, b| b.1.cmp(a.1));
    let mut lines = Vec::new();
    for (k, v) in sorted {
        lines.push(format!("  {:24} {:.1}s", k, *v as f64 / 1000.0));
    }
    lines.push(String::new());
    lines.push(format!(
        "  Total: {:.1}s | Engine: Rust (native async tokio)",
        total_ms as f64 / 1000.0
    ));
    lines.push("  Checks: TCP(native) HTTP(reqwest) DNS(trust-dns) SSH(mux)".to_string());
    lines.join("\n")
}

/// Build result summary string
pub fn build_result_summary(summary: &Summary) -> String {
    if summary.critical == 0 && summary.failed == 0 {
        format!(
            "ALL CLEAR -- {}/{} checks passed",
            summary.passed, summary.total_checks
        )
    } else if summary.critical > 0 {
        format!(
            "CRITICAL -- {}/{} passed, {} critical, {} warnings",
            summary.passed, summary.total_checks, summary.critical, summary.warnings
        )
    } else {
        format!(
            "DEGRADED -- {}/{} passed, {} warnings",
            summary.passed, summary.total_checks, summary.warnings
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn summary(critical: usize, warnings: usize) -> Summary {
        let failed = critical + warnings;
        Summary {
            total_checks: 10,
            passed: 10 - failed,
            failed,
            warnings,
            critical,
        }
    }

    #[test]
    fn r1_backdated_run_state_renders_stale_not_red() {
        // A snapshot older than the tier cadence with a CRITICAL summary must
        // render STALE — the stale banner outranks the computed RED so a red
        // verdict on stale data can't mask reality.
        let mut rs = RunState::new();
        rs.generated_at = (chrono::Utc::now() - chrono::Duration::hours(6)).to_rfc3339();
        let s = summary(3, 0); // would be RED if fresh
        let (status, headline) = render_report_status(&rs, &s, Duration::from_secs(120), false);
        assert_eq!(status, Status::Stale, "stale snapshot must not render RED");
        assert!(headline.contains("STALE"), "headline: {headline}");
    }

    #[test]
    fn r1_fresh_run_state_renders_computed_status() {
        let mut rs = RunState::new();
        rs.generated_at = chrono::Utc::now().to_rfc3339();
        // Fresh + critical → RED.
        let (status, _) = render_report_status(&rs, &summary(2, 0), Duration::from_secs(120), false);
        assert_eq!(status, Status::Red);
        // Fresh + only warnings → YELLOW.
        let (status, _) = render_report_status(&rs, &summary(0, 1), Duration::from_secs(120), false);
        assert_eq!(status, Status::Yellow);
        // Fresh + clean → GREEN.
        let (status, _) = render_report_status(&rs, &summary(0, 0), Duration::from_secs(120), false);
        assert_eq!(status, Status::Green);
    }

    #[test]
    fn r7_wg_gated_renders_unknown_not_red_even_with_criticals() {
        // Fresh snapshot, criticals present, but WG is down → the criticals are
        // un-judgeable, so the report is UNKNOWN, never RED.
        let mut rs = RunState::new();
        rs.generated_at = chrono::Utc::now().to_rfc3339();
        let (status, headline) =
            render_report_status(&rs, &summary(5, 0), Duration::from_secs(120), true);
        assert_eq!(status, Status::Unknown, "WG-down must gate to UNKNOWN");
        assert_ne!(status, Status::Red);
        assert!(headline.contains("UNKNOWN"), "headline: {headline}");
    }
}
