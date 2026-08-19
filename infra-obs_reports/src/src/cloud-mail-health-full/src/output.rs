use crate::types::*;
use std::collections::HashMap;

/// Format a section of checks with icons, duration, severity
pub fn format_checks(checks: &[Check]) -> String {
    if checks.is_empty() {
        return "  (no checks)".to_string();
    }

    let mut lines = Vec::new();
    for c in checks {
        let icon = if c.passed { "✅" } else {
            match c.severity {
                Severity::Critical => "❌",
                Severity::Warning => "⚠️ ",
                Severity::Info => "ℹ️ ",
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

/// Build all template variables from results
pub fn build_template_vars(results: &MailHealthResult) -> HashMap<String, String> {
    let mut vars = HashMap::new();

    vars.insert("GENERATED_DATE".into(), results.generated.clone());

    // Issues summary
    vars.insert("ISSUES_SUMMARY".into(), build_issues_summary(results));

    // Phase sections
    vars.insert(
        "INSTANT_KPIS".into(),
        format_checks(&results.instant_kpis),
    );
    vars.insert("PREFLIGHT".into(), format_checks(&results.preflight));
    vars.insert("CONTAINERS".into(), format_checks(&results.containers));
    vars.insert("NETWORK".into(), format_checks(&results.network));
    vars.insert("DNS_AUTH".into(), format_checks(&results.dns_auth));
    vars.insert("INTERNALS".into(), format_checks(&results.internals));
    vars.insert(
        "E2E_DELIVERY".into(),
        format_checks(&results.e2e_delivery),
    );

    // Performance
    vars.insert("PERFORMANCE".into(), build_performance(results));

    // Result summary
    vars.insert("RESULT_SUMMARY".into(), build_result_summary(results));

    vars
}

fn build_issues_summary(results: &MailHealthResult) -> String {
    let all_checks: Vec<&Check> = results
        .instant_kpis
        .iter()
        .chain(&results.preflight)
        .chain(&results.containers)
        .chain(&results.network)
        .chain(&results.dns_auth)
        .chain(&results.internals)
        .chain(&results.e2e_delivery)
        .collect();

    let failed: Vec<&&Check> = all_checks.iter().filter(|c| !c.passed).collect();

    if failed.is_empty() {
        return "  No issues found -- all checks passed.".into();
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
            lines.push(format!("    ❌ {}: {}", c.name, c.details));
        }
    }

    if !warnings.is_empty() {
        lines.push("  WARNINGS:".into());
        for c in &warnings {
            lines.push(format!("    ⚠️  {}: {}", c.name, c.details));
        }
    }

    if !info.is_empty() {
        lines.push("  INFO:".into());
        for c in &info {
            lines.push(format!("    ℹ️  {}: {}", c.name, c.details));
        }
    }

    lines.join("\n")
}

fn build_performance(results: &MailHealthResult) -> String {
    let mut sorted: Vec<_> = results.timers.iter().collect();
    sorted.sort_by(|a, b| b.1.cmp(a.1));
    let mut lines = Vec::new();
    for (k, v) in sorted {
        lines.push(format!(
            "  {:24} {:.1}s",
            k,
            *v as f64 / 1000.0
        ));
    }
    lines.push(String::new());
    lines.push(format!(
        "  Total: {:.1}s | Engine: Rust (native async tokio)",
        results.duration_ms as f64 / 1000.0
    ));
    lines.push("  Checks: TCP(native) HTTP(reqwest) DNS(trust-dns) SSH(mux) TLS(openssl)".into());
    lines.join("\n")
}

fn build_result_summary(results: &MailHealthResult) -> String {
    let s = &results.summary;
    if s.critical == 0 && s.failed == 0 {
        format!(
            "ALL CLEAR -- {}/{} checks passed",
            s.passed, s.total_checks
        )
    } else if s.critical > 0 {
        format!(
            "CRITICAL -- {}/{} passed, {} critical, {} warnings",
            s.passed, s.total_checks, s.critical, s.warnings
        )
    } else {
        format!(
            "DEGRADED -- {}/{} passed, {} warnings",
            s.passed, s.total_checks, s.warnings
        )
    }
}
