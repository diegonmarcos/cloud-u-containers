use super::types::*;
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
            icon,
            c.name,
            c.details,
            duration,
            severity_tag,
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

/// Build all template variables from layer results
pub fn build_template_vars(results: &LayerResults) -> HashMap<String, String> {
    let mut vars = HashMap::new();

    vars.insert("GENERATED_DATE".into(), results.generated.clone());

    // Issues summary
    vars.insert("ISSUES_SUMMARY".into(), build_issues_summary(results));

    // Tier 0 summary dashboard
    vars.insert("TIER_CHECKS".into(), build_tier_checks(results));

    // Layer sections
    vars.insert("SELF_CHECK".into(), format_checks(&results.self_check));
    vars.insert("WG_MESH".into(), format_checks(&results.wg_mesh));
    vars.insert("PLATFORM".into(), format_checks(&results.platform));
    vars.insert("CONTAINERS".into(), format_checks(&results.containers));
    vars.insert("PRIVATE_URLS".into(), format_checks(&results.private_urls));
    vars.insert("PUBLIC_URLS".into(), format_checks(&results.public_urls));
    vars.insert("CROSS_CHECKS".into(), format_checks(&results.cross_checks));
    vars.insert("EXTERNAL".into(), format_checks(&results.external));
    vars.insert("DRIFT".into(), format_checks(&results.drift));
    vars.insert("SECURITY".into(), format_checks(&results.security));
    vars.insert("EMAIL_E2E".into(), format_checks(&results.email_e2e));

    // Performance
    vars.insert("PERFORMANCE".into(), build_performance(results));

    // Result summary
    vars.insert("RESULT_SUMMARY".into(), build_result_summary(results));

    vars
}

fn tier_score(checks: &[Check], filter: impl Fn(&str) -> bool) -> (usize, usize) {
    let matching: Vec<_> = checks.iter().filter(|c| filter(&c.name) || filter(&c.details)).collect();
    let passed = matching.iter().filter(|c| c.passed).count();
    (passed, matching.len())
}

fn tier_icon(passed: usize, total: usize) -> String {
    if total == 0 { return "—".into(); }
    let icon = if passed == total { "✅" } else if passed > 0 { "⚠️" } else { "❌" };
    format!("{} {}/{}", icon, passed, total)
}

fn build_tier_checks(results: &LayerResults) -> String {
    let mut lines = Vec::new();
    lines.push(format!("    {:20} {:16} {:16} {:16} {:16}", "Layer", "gcp-proxy", "oci-mail", "oci-apps", "oci-analytics"));
    lines.push(format!("    {:20} {:16} {:16} {:16} {:16}", "", "(front door)", "(mail)", "(apps)", "(analytics)"));
    lines.push(format!("    {}", "─".repeat(84)));

    // Self-check — single overall score
    let sc = tier_score(&results.self_check, |_| true);
    lines.push(format!("    {:20} {:48}", "1. Self-check", tier_icon(sc.0, sc.1)));

    // WG Mesh — gcp-proxy (hub) vs peers
    let wg_gcp = tier_score(&results.wg_mesh, |n| n.contains("gcp-proxy"));
    let wg_mail = tier_score(&results.wg_mesh, |n| n.contains("oci-mail"));
    let wg_apps = tier_score(&results.wg_mesh, |n| n.contains("oci-apps"));
    let wg_ana = tier_score(&results.wg_mesh, |n| n.contains("oci-analytics"));
    lines.push(format!("    {:20} {:16} {:16} {:16} {:16}",
        "2. WG Mesh", tier_icon(wg_gcp.0, wg_gcp.1), tier_icon(wg_mail.0, wg_mail.1),
        tier_icon(wg_apps.0, wg_apps.1), tier_icon(wg_ana.0, wg_ana.1)));

    // Platform — per VM
    let pl_gcp = tier_score(&results.platform, |n| n.contains("gcp-proxy"));
    let pl_mail = tier_score(&results.platform, |n| n.contains("oci-mail"));
    let pl_apps = tier_score(&results.platform, |n| n.contains("oci-apps"));
    let pl_ana = tier_score(&results.platform, |n| n.contains("oci-analytics"));
    lines.push(format!("    {:20} {:16} {:16} {:16} {:16}",
        "3. Platform", tier_icon(pl_gcp.0, pl_gcp.1), tier_icon(pl_mail.0, pl_mail.1),
        tier_icon(pl_apps.0, pl_apps.1), tier_icon(pl_ana.0, pl_ana.1)));

    // Containers — per VM
    let ct_gcp = tier_score(&results.containers, |n| n.contains("gcp-proxy"));
    let ct_mail = tier_score(&results.containers, |n| n.contains("oci-mail"));
    let ct_apps = tier_score(&results.containers, |n| n.contains("oci-apps"));
    let ct_ana = tier_score(&results.containers, |n| n.contains("oci-analytics"));
    lines.push(format!("    {:20} {:16} {:16} {:16} {:16}",
        "4. Containers", tier_icon(ct_gcp.0, ct_gcp.1), tier_icon(ct_mail.0, ct_mail.1),
        tier_icon(ct_apps.0, ct_apps.1), tier_icon(ct_ana.0, ct_ana.1)));

    // Private URLs — per VM (details contain WG IPs)
    let pv_gcp = tier_score(&results.private_urls, |n| n.contains("10.0.0.1"));
    let pv_mail = tier_score(&results.private_urls, |n| n.contains("10.0.0.3"));
    let pv_apps = tier_score(&results.private_urls, |n| n.contains("10.0.0.6"));
    let pv_ana = tier_score(&results.private_urls, |n| n.contains("10.0.0.4"));
    lines.push(format!("    {:20} {:16} {:16} {:16} {:16}",
        "5. Private URLs", tier_icon(pv_gcp.0, pv_gcp.1), tier_icon(pv_mail.0, pv_mail.1),
        tier_icon(pv_apps.0, pv_apps.1), tier_icon(pv_ana.0, pv_ana.1)));

    // Public URLs — overall (all go through gcp-proxy/Caddy)
    let pu = tier_score(&results.public_urls, |_| true);
    lines.push(format!("    {:20} {:48}", "6. Public URLs", tier_icon(pu.0, pu.1)));

    // Cross-checks — overall
    let cc = tier_score(&results.cross_checks, |_| true);
    lines.push(format!("    {:20} {:48}", "7. Cross-checks", tier_icon(cc.0, cc.1)));

    // External — overall
    let ext = tier_score(&results.external, |_| true);
    lines.push(format!("    {:20} {:48}", "8. External", tier_icon(ext.0, ext.1)));

    // Drift — overall
    let dr = tier_score(&results.drift, |_| true);
    lines.push(format!("    {:20} {:48}", "9. Drift", tier_icon(dr.0, dr.1)));

    // Security — overall
    let sec = tier_score(&results.security, |_| true);
    lines.push(format!("    {:20} {:48}", "10. Security", tier_icon(sec.0, sec.1)));

    // E2E Email — overall
    let em = tier_score(&results.email_e2e, |_| true);
    lines.push(format!("    {:20} {:48}", "11. E2E Email", tier_icon(em.0, em.1)));

    lines.join("\n")
}

fn build_issues_summary(results: &LayerResults) -> String {
    let all_checks: Vec<&Check> = results
        .self_check
        .iter()
        .chain(&results.wg_mesh)
        .chain(&results.platform)
        .chain(&results.containers)
        .chain(&results.private_urls)
        .chain(&results.public_urls)
        .chain(&results.cross_checks)
        .chain(&results.external)
        .chain(&results.drift)
        .chain(&results.security)
        .chain(&results.email_e2e)
        .collect();

    let failed: Vec<&&Check> = all_checks.iter().filter(|c| !c.passed).collect();

    if failed.is_empty() {
        return "  No issues found — all checks passed.".into();
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

fn build_performance(results: &LayerResults) -> String {
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
    lines.push(format!(
        "  Checks: TCP(native) HTTP(reqwest) DNS(trust-dns) SSH(rsync+mux)"
    ));
    lines.join("\n")
}

fn build_result_summary(results: &LayerResults) -> String {
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
