use reports_common::output;
use reports_common::types::{Check, Summary};
use std::collections::HashMap;

/// Build all template variables from check results
pub fn build_template_vars(
    port_checks: &[Check],
    tls_checks: &[Check],
    dns_checks: &[Check],
    wg_checks: &[Check],
    fw_checks: &[Check],
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

    // Per-section formatted checks
    vars.insert("PORT_SCAN".into(), output::format_checks(port_checks));
    vars.insert("TLS_AUDIT".into(), output::format_checks(tls_checks));
    vars.insert("WG_HEALTH".into(), output::format_checks(wg_checks));
    vars.insert("DNS_VALIDATION".into(), output::format_checks(dns_checks));
    vars.insert("FIREWALL_AUDIT".into(), output::format_checks(fw_checks));

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
        chrono::Utc::now().format("%Y-%m-%d %H:%M UTC").to_string(),
    );

    vars
}
