//! Markdown renderer — parity with HTML output.
//!
//! Fills `cloud_health_daily.md.tpl` placeholders with content built from
//! `ReportData`. Same data that drives the HTML email/web renderers.
//!
//! Template lookup order (same pattern as `cloud-health-full-2::template`):
//!   1. `$TEMPLATE_DIR/cloud_health_daily.md.tpl`
//!   2. `./cloud_health_daily.md.tpl` (cwd = reports/dist/ under build.sh)

use crate::types::*;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

const TEMPLATE_FILE: &str = "cloud_health_daily.md.tpl";
const OUTPUT_PATH: &str = "cloud_health_daily.md";

pub fn output_path() -> &'static str {
    OUTPUT_PATH
}

fn resolve_template_path() -> PathBuf {
    if let Ok(dir) = std::env::var("TEMPLATE_DIR") {
        let p = Path::new(&dir).join(TEMPLATE_FILE);
        if p.exists() {
            return p;
        }
    }
    PathBuf::from(TEMPLATE_FILE)
}

/// Render the daily markdown report. Returns the final string (caller writes it).
pub fn render(data: &ReportData) -> anyhow::Result<String> {
    let tpl_path = resolve_template_path();
    let template = std::fs::read_to_string(&tpl_path).map_err(|e| {
        anyhow::anyhow!("cloud_health_daily.md.tpl not found at {}: {}", tpl_path.display(), e)
    })?;
    let vars = build_vars(data);
    println!(
        "[md] template loaded ({} chars, {} vars) from {}",
        template.len(),
        vars.len(),
        tpl_path.display()
    );
    let filled = substitute(&template, &vars);
    Ok(filled)
}

fn substitute(template: &str, vars: &HashMap<String, String>) -> String {
    let mut out = template.to_string();
    let mut keys: Vec<&String> = vars.keys().collect();
    keys.sort_by(|a, b| b.len().cmp(&a.len())); // longest first — avoid partial matches
    for k in keys {
        let placeholder = format!("${}", k);
        if out.contains(&placeholder) {
            out = out.replace(&placeholder, &vars[k]);
        }
    }
    out
}

fn build_vars(d: &ReportData) -> HashMap<String, String> {
    let mut v = HashMap::new();
    v.insert("DATE".into(), d.date.clone());
    v.insert("TIME".into(), d.time.clone());
    v.insert("DURATION_S".into(), format!("{:.1}", d.generation_duration_ms as f64 / 1000.0));

    // Summary
    v.insert("TOTAL_VMS".into(), d.vms.len().to_string());
    v.insert("FLEET_RUNNING".into(), d.fleet_running.to_string());
    v.insert("FLEET_TOTAL".into(), d.fleet_total.to_string());
    v.insert("FLEET_UNHEALTHY".into(), d.fleet_unhealthy.to_string());
    v.insert("TOTAL_SERVICES".into(), d.total_services.to_string());
    v.insert("TOTAL_CONTAINERS".into(), d.total_containers.to_string());
    v.insert("TOTAL_DOMAINS".into(), d.total_domains.to_string());

    v.insert("EXEC_CRITICAL".into(), d.exec_summary.critical.to_string());
    v.insert("EXEC_WARNINGS".into(), d.exec_summary.warnings.to_string());
    v.insert("EXEC_OK".into(), d.exec_summary.ok.to_string());

    v.insert("ISSUES_TABLE".into(), render_issues(d));
    v.insert("VMS_TABLE".into(), render_vms(d));
    v.insert("ENDPOINTS_TABLE".into(), render_endpoints(d));
    v.insert("CERTS_TABLE".into(), render_certs(d));
    v.insert("DNS_TABLE".into(), render_dns(d));
    v.insert("DATABASES_TABLE".into(), render_databases(d));
    v.insert("BUCKETS_TABLE".into(), render_buckets(d));
    v.insert("DAGS_TABLE".into(), render_dags(d));
    v.insert("GHA_TABLE".into(), render_gha(d));
    v.insert("GHCR_TABLE".into(), render_ghcr(d));
    v.insert("DRIFT_TABLE".into(), render_drift(d));
    v.insert("FIREWALL_TABLE".into(), render_firewall(d));
    v.insert("FINOPS_TABLE".into(), render_finops(d));
    v.insert("MAIL_SUMMARY".into(), render_mail(d));
    v.insert("APPENDIX".into(), render_appendix(d));

    v
}

fn tb(header: &[&str]) -> String {
    let mut s = String::new();
    s.push_str("| ");
    s.push_str(&header.join(" | "));
    s.push_str(" |\n|");
    for _ in header {
        s.push_str(" --- |");
    }
    s.push('\n');
    s
}

fn render_issues(d: &ReportData) -> String {
    if d.exec_summary.top_issues.is_empty() {
        return "_No issues detected._\n".into();
    }
    let mut s = tb(&["Severity", "Message"]);
    for i in &d.exec_summary.top_issues {
        s.push_str(&format!("| {} | {} |\n", i.severity, i.message));
    }
    s
}

fn render_vms(d: &ReportData) -> String {
    let mut s = tb(&["VM", "IP", "Disk%", "Mem%", "Load", "Containers", "Status"]);
    for vm in &d.vms {
        s.push_str(&format!(
            "| {} | {} | {}% | {}% | {} | {}/{} ({} unhealthy) | {:?} |\n",
            vm.name,
            vm.ip,
            vm.disk_pct,
            vm.mem_pct,
            vm.load,
            vm.containers_running,
            vm.containers_total,
            vm.containers_unhealthy,
            vm.status,
        ));
    }
    s
}

fn render_endpoints(d: &ReportData) -> String {
    let mut s = tb(&["Service", "URL", "Status", "Latency"]);
    for ep in &d.endpoints {
        s.push_str(&format!(
            "| {} | {} | {} | {}ms |\n",
            ep.service, ep.url, ep.status_code, ep.latency_ms
        ));
    }
    s
}

fn render_certs(d: &ReportData) -> String {
    if d.certs.is_empty() {
        return "_No TLS cert data._\n".into();
    }
    let mut s = tb(&["Domain", "Days Left", "Expiry"]);
    for c in &d.certs {
        s.push_str(&format!(
            "| {} | {} | {} |\n",
            c.domain, c.days_left, c.expiry
        ));
    }
    s
}

fn render_dns(d: &ReportData) -> String {
    if d.dns.is_empty() {
        return "_No DNS data._\n".into();
    }
    let mut s = tb(&["Record", "Value"]);
    for r in &d.dns {
        s.push_str(&format!("| {} | {} |\n", r.record_type, r.value));
    }
    s
}

fn render_databases(d: &ReportData) -> String {
    if d.databases.is_empty() {
        return "_No database data._\n".into();
    }
    let mut s = tb(&["Service", "Type", "Container", "VM", "Enabled"]);
    for db in &d.databases {
        s.push_str(&format!(
            "| {} | {} | {} | {} | {} |\n",
            db.service, db.db_type, db.container, db.vm_alias, db.enabled
        ));
    }
    s
}

fn render_buckets(d: &ReportData) -> String {
    if d.cloud_buckets.is_empty() {
        return "_No bucket data._\n".into();
    }
    let mut s = tb(&["Provider", "Name", "Tier", "Size (B)"]);
    for b in &d.cloud_buckets {
        s.push_str(&format!(
            "| {} | {} | {} | {} |\n",
            b.provider, b.name, b.tier, b.size_bytes
        ));
    }
    s
}

fn render_dags(d: &ReportData) -> String {
    if d.dags.is_empty() {
        return "_No Dagu data._\n".into();
    }
    let mut s = tb(&["DAG", "Status", "Started", "Schedule"]);
    for dag in &d.dags {
        s.push_str(&format!(
            "| {} | {} | {} | {} |\n",
            dag.name, dag.status, dag.started_at, dag.schedule
        ));
    }
    s
}

fn render_gha(d: &ReportData) -> String {
    if d.gha_runs.is_empty() {
        return "_No recent GHA runs._\n".into();
    }
    let mut s = tb(&["Workflow", "Repo", "Conclusion", "When"]);
    for r in d.gha_runs.iter().take(20) {
        s.push_str(&format!(
            "| {} | {} | {} | {} |\n",
            r.name, r.repo, r.conclusion, r.created_at
        ));
    }
    s
}

fn render_ghcr(d: &ReportData) -> String {
    if d.ghcr_packages.is_empty() {
        return "_No GHCR data._\n".into();
    }
    let mut s = tb(&["Package", "Updated"]);
    for p in d.ghcr_packages.iter().take(20) {
        s.push_str(&format!("| {} | {} |\n", p.name, p.updated_at));
    }
    s
}

fn render_drift(d: &ReportData) -> String {
    if d.drift.is_empty() && d.container_drift.is_empty() {
        return "_No drift detected._\n".into();
    }
    let mut s = String::new();
    if !d.container_drift.is_empty() {
        s.push_str("**Container drift:**\n");
        s.push_str(&tb(&["VM", "Expected Not Running", "Unexpected Running"]));
        for cd in &d.container_drift {
            s.push_str(&format!(
                "| {} | {:?} | {:?} |\n",
                cd.vm_name, cd.expected_not_running, cd.running_not_declared
            ));
        }
    }
    s
}

fn render_firewall(d: &ReportData) -> String {
    if d.firewalls.is_empty() {
        return "_No firewall data._\n".into();
    }
    let mut s = tb(&["VM", "Public Ports", "OS Rules", "WG-only"]);
    for fw in &d.firewalls {
        s.push_str(&format!(
            "| {} | {} | {} | {} |\n",
            fw.vm_name,
            fw.public_ports.len(),
            fw.os_rules.len(),
            fw.wg_only
        ));
    }
    s
}

fn render_finops(d: &ReportData) -> String {
    if d.cloud_costs.is_empty() {
        return "_No cost data._\n".into();
    }
    let mut s = tb(&["Provider", "Month", "Service", "Amount", "Currency"]);
    for c in &d.cloud_costs {
        s.push_str(&format!(
            "| {} | {} | {} | {:.2} | {} |\n",
            c.provider, c.month, c.service, c.amount, c.currency
        ));
    }
    s
}

fn render_mail(d: &ReportData) -> String {
    match &d.mail_health {
        None => "_Mail health unavailable._\n".into(),
        Some(mh) => format!(
            "Checks: {} total · {} passed · {} failed · {} critical · {} warnings\n",
            mh.summary.total,
            mh.summary.passed,
            mh.summary.failed,
            mh.summary.critical,
            mh.summary.warnings,
        ),
    }
}

fn render_appendix(d: &ReportData) -> String {
    if d.appendix_md.trim().is_empty() {
        return "_Run `cloud-health-full-2` first for the 11-layer appendix._\n".into();
    }
    d.appendix_md.clone()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn substitute_replaces_longest_keys_first() {
        let mut vars = HashMap::new();
        vars.insert("FOO".to_string(), "X".to_string());
        vars.insert("FOO_BAR".to_string(), "Y".to_string());
        // $FOO_BAR must match fully before $FOO would partially match.
        assert_eq!(substitute("$FOO_BAR then $FOO", &vars), "Y then X");
    }

    #[test]
    fn substitute_leaves_unknown_vars() {
        let vars = HashMap::new();
        assert_eq!(substitute("$MISSING stays", &vars), "$MISSING stays");
    }
}
