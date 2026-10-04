use reports_common::output;
use reports_common::types::{Check, Summary};
use std::collections::HashMap;

/// Build template variables for the markdown report
pub fn build_template_vars(
    export_checks: &[Check],
    yara_checks: &[Check],
    siem_checks: &[Check],
    ti_checks: &[Check],
    journal_checks: &[Check],
    runtime_checks: &[Check],
    diff_checks: &[Check],
    repo_checks: &[Check],
    corr_checks: &[Check],
    all_checks: &[&Check],
    summary: &Summary,
    timers: &HashMap<String, u64>,
    duration_ms: u64,
) -> HashMap<String, String> {
    let mut vars = HashMap::new();

    // Issues summary
    vars.insert(
        "ISSUES_SUMMARY".into(),
        output::build_issues_summary(all_checks),
    );

    // Export status
    vars.insert(
        "EXPORT_STATUS".into(),
        output::format_checks(export_checks),
    );

    // YARA summary (checks only)
    vars.insert(
        "YARA_SUMMARY".into(),
        output::format_checks(yara_checks),
    );

    // YARA hits detail
    let yara_failed: Vec<&Check> = yara_checks.iter().filter(|c| !c.passed).collect();
    let yara_hits_text = if yara_failed.is_empty() {
        "  No YARA matches detected.".into()
    } else {
        yara_failed
            .iter()
            .map(|c| format!("  - {}: {}", c.name, c.details))
            .collect::<Vec<_>>()
            .join("\n")
    };
    vars.insert("YARA_HITS".into(), yara_hits_text);

    // SIEM summary
    vars.insert(
        "SIEM_SUMMARY".into(),
        output::format_checks(siem_checks),
    );

    // SIEM alerts detail
    let siem_failed: Vec<&Check> = siem_checks.iter().filter(|c| !c.passed).collect();
    let siem_alerts_text = if siem_failed.is_empty() {
        "  No critical SIEM alerts.".into()
    } else {
        siem_failed
            .iter()
            .map(|c| format!("  - {}: {}", c.name, c.details))
            .collect::<Vec<_>>()
            .join("\n")
    };
    vars.insert("SIEM_ALERTS".into(), siem_alerts_text);

    // Threat intel
    vars.insert(
        "THREAT_INTEL".into(),
        output::format_checks(ti_checks),
    );

    // Journal analysis
    let journal_failed: Vec<&Check> = journal_checks.iter().filter(|c| !c.passed).collect();
    let journal_text = if journal_failed.is_empty() {
        format!(
            "{}\n\n  No suspicious journal entries detected.",
            output::format_checks(journal_checks)
        )
    } else {
        let details = journal_failed
            .iter()
            .map(|c| format!("  - {}: {}", c.name, c.details))
            .collect::<Vec<_>>()
            .join("\n");
        format!(
            "{}\n\n### Journal Alert Details\n\n{}",
            output::format_checks(journal_checks),
            details
        )
    };
    vars.insert("JOURNAL_ANALYSIS".into(), journal_text);

    // Runtime analysis
    let runtime_failed: Vec<&Check> = runtime_checks.iter().filter(|c| !c.passed).collect();
    let runtime_text = if runtime_failed.is_empty() {
        format!(
            "{}\n\n  No runtime security issues detected.",
            output::format_checks(runtime_checks)
        )
    } else {
        let details = runtime_failed
            .iter()
            .map(|c| format!("  - {}: {}", c.name, c.details))
            .collect::<Vec<_>>()
            .join("\n");
        format!(
            "{}\n\n### Runtime Issue Details\n\n{}",
            output::format_checks(runtime_checks),
            details
        )
    };
    vars.insert("RUNTIME_ANALYSIS".into(), runtime_text);

    // Diff analysis
    let diff_failed: Vec<&Check> = diff_checks.iter().filter(|c| !c.passed).collect();
    let diff_text = if diff_failed.is_empty() {
        format!(
            "{}\n\n  No significant container changes detected.",
            output::format_checks(diff_checks)
        )
    } else {
        let details = diff_failed
            .iter()
            .map(|c| format!("  - {}: {}", c.name, c.details))
            .collect::<Vec<_>>()
            .join("\n");
        format!(
            "{}\n\n### Diff Change Details\n\n{}",
            output::format_checks(diff_checks),
            details
        )
    };
    vars.insert("DIFF_ANALYSIS".into(), diff_text);

    // Repo scan
    let repo_failed: Vec<&Check> = repo_checks.iter().filter(|c| !c.passed).collect();
    let repo_text = if repo_checks.is_empty() {
        "  Repo scan disabled.".into()
    } else if repo_failed.is_empty() {
        format!(
            "{}\n\n  No secret leaks detected across scanned repos.",
            output::format_checks(repo_checks)
        )
    } else {
        let details = repo_failed
            .iter()
            .map(|c| format!("  - {}: {}", c.name, c.details))
            .collect::<Vec<_>>()
            .join("\n");
        format!(
            "{}\n\n### Repo Leak Candidates\n\n{}",
            output::format_checks(repo_checks),
            details
        )
    };
    vars.insert("REPO_SCAN".into(), repo_text);

    // Correlations
    vars.insert(
        "CORRELATIONS".into(),
        output::format_checks(corr_checks),
    );

    // Performance
    vars.insert(
        "PERFORMANCE".into(),
        output::build_performance(timers, duration_ms),
    );

    // Result summary
    vars.insert(
        "RESULT_SUMMARY".into(),
        output::build_result_summary(summary),
    );

    // Generated date
    vars.insert(
        "GENERATED_DATE".into(),
        chrono::Utc::now().format("%Y-%m-%d %H:%M:%S UTC").to_string(),
    );

    vars
}
