use crate::types::*;
use chrono::Datelike;
use std::fmt::Write;

#[derive(Clone, Copy, PartialEq)]
pub enum OutputMode {
    Web,
    Email,
}

fn diagram_or_css(
    h: &mut String,
    mode: OutputMode,
    title: &str,
    diagram_fn: impl FnOnce() -> (String, &'static str),
    css_fn: impl FnOnce(&mut String),
) {
    match mode {
        OutputMode::Web => {
            let (svg, tool) = diagram_fn();
            embed_diagram(h, title, tool, &svg);
        }
        OutputMode::Email => css_fn(h),
    }
}

fn topo_topic_header(h: &mut String, title: &str) {
    write!(h, r#"<tr><td style="padding:16px 8px 4px;border-bottom:1px solid {BG_HEAD};">
<span style="color:{C_OK};font-size:14px;font-weight:bold;font-family:{FONT};letter-spacing:1px;">{title}</span>
</td></tr>"#).unwrap();
}

fn mermaid_to_div(mermaid_src: &str) -> String {
    if mermaid_src.is_empty() { return String::new(); }
    format!(r#"<div class="mermaid">{}</div>"#, mermaid_src)
}

fn embed_diagram(h: &mut String, title: &str, tool: &str, svg: &str) {
    if svg.is_empty() {
        write!(h, r#"<tr><td style="padding:12px 8px;">
<div style="border-left:3px solid {C_DIM};padding:6px 12px;background:{BG_CARD};border-radius:0 4px 4px 0;">
<span style="color:{C_DIM};font-size:12px;font-family:{FONT};">{title}</span>
<span style="color:{C_CRIT};font-size:10px;font-family:{FONT};margin-left:8px;">({tool} not available)</span>
</div></td></tr>"#).unwrap();
        return;
    }
    if tool == "mermaid" {
        // Mermaid renders client-side — wrap source in a <div class="mermaid">
        write!(h, r#"<tr><td style="padding:12px 8px;">
<div style="border-left:3px solid {C_OK};padding:6px 12px;background:{BG_CARD};border-radius:0 4px 4px 0;margin-bottom:8px;">
<span style="color:{C_TEXT};font-size:13px;font-weight:bold;font-family:{FONT};">{title}</span>
<span style="color:{C_DIM};font-size:10px;font-family:{FONT};margin-left:8px;">rendered by {tool}</span>
</div>
{svg}
</td></tr>"#).unwrap();
    } else {
        write!(h, r#"<tr><td style="padding:12px 8px;">
<div style="border-left:3px solid {C_OK};padding:6px 12px;background:{BG_CARD};border-radius:0 4px 4px 0;margin-bottom:8px;">
<span style="color:{C_TEXT};font-size:13px;font-weight:bold;font-family:{FONT};">{title}</span>
<span style="color:{C_DIM};font-size:10px;font-family:{FONT};margin-left:8px;">rendered by {tool}</span>
</div>
<div style="text-align:center;overflow-x:auto;padding:4px;max-height:500px;">{svg}</div>
</td></tr>"#).unwrap();
    }
}

// ── Color constants ─────────────────────────────────────────────────
const C_OK: &str = "#00d68f";
const C_WARN: &str = "#ffaa00";
const C_CRIT: &str = "#ff3d71";
const C_DIM: &str = "#8899aa";
const BG_BODY: &str = "#1a1a2e";
const BG_CARD: &str = "#16213e";
const BG_HEAD: &str = "#0f3460";
const BG_BAR: &str = "#2a2a4e";
const C_TEXT: &str = "#e0e0e0";
const FONT: &str = "'Courier New',Consolas,monospace";

fn pct_color(pct: u32) -> &'static str {
    if pct > 90 { C_CRIT } else if pct > 75 { C_WARN } else { C_OK }
}

fn progress_bar(pct: u32) -> String {
    let color = pct_color(pct);
    format!(
        r#"<div style="display:inline-block;background:{BG_BAR};border-radius:4px;height:14px;width:80px;vertical-align:middle;"><div style="background:{color};border-radius:4px;height:14px;width:{pct}%;"></div></div> <span style="color:{color};font-size:12px;">{pct}%</span>"#
    )
}

fn status_badge(status: &VmStatus) -> String {
    let (color, label) = match status {
        VmStatus::Healthy => (C_OK, "HEALTHY"),
        VmStatus::Warning => (C_WARN, "WARNING"),
        VmStatus::Critical => (C_CRIT, "CRITICAL"),
        VmStatus::Unknown => (C_DIM, "UNKNOWN"),
    };
    format!(
        r#"<span style="display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:bold;background:{color};color:{BG_BODY};">{label}</span>"#
    )
}

fn code_badge(code: u16) -> String {
    let color = match code {
        200..=399 => C_OK,
        400..=499 => C_WARN,
        _ => C_CRIT,
    };
    format!(
        r#"<span style="display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:bold;background:{color};color:{BG_BODY};font-family:{FONT};">{code}</span>"#
    )
}

fn label_badge(label: &str, color: &str) -> String {
    format!(
        r#"<span style="display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:bold;background:{color};color:{BG_BODY};font-family:{FONT};">{label}</span>"#
    )
}

fn render_latency_bar(latency_ms: u64) -> String {
    let color = if latency_ms < 100 { C_OK } else if latency_ms < 500 { C_WARN } else { C_CRIT };
    let pct = std::cmp::min(latency_ms * 100 / 500, 100);
    format!(
        r#"<div style="display:inline-block;background:{BG_BAR};border-radius:4px;height:12px;width:60px;vertical-align:middle;"><div style="background:{color};border-radius:4px;height:12px;width:{pct}%;"></div></div> <span style="color:{color};font-size:11px;">{latency_ms}ms</span>"#
    )
}

// ── Table helpers ───────────────────────────────────────────────────

fn section_title(h: &mut String, letter: &str, title: &str) {
    let anchor = format!("{}-{}", letter.to_lowercase(), title.to_lowercase().replace(' ', "-"));
    write!(h, r#"<tr><td style="padding:20px 8px 4px 8px;" id="sec-{anchor}">
<table width="100%" cellpadding="0" cellspacing="0">
<tr><td style="padding:10px 16px;border-bottom:2px solid {C_OK};font-family:{FONT};">
<span style="color:{C_OK};font-size:16px;font-weight:bold;letter-spacing:2px;">{letter}</span>
<span style="color:{C_TEXT};font-size:16px;font-weight:bold;letter-spacing:1px;margin-left:8px;">{title}</span>
</td></tr></table></td></tr>"#).unwrap();
}

fn section_start(h: &mut String, title: &str, cols: u8) {
    write!(h, r#"<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:{BG_CARD};border-radius:6px;">
<tr><td colspan="{cols}" style="padding:12px 16px;background:{BG_HEAD};border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:{C_TEXT};font-family:{FONT};">{title}</td></tr>"#).unwrap();
}

fn section_end(h: &mut String) {
    h.push_str("</table></td></tr>\n");
}

fn th(label: &str, align: &str) -> String {
    format!(
        r#"<th style="text-align:{align};color:{C_DIM};font-size:10px;padding:6px 8px;border-bottom:1px solid {BG_HEAD};font-family:{FONT};">{label}</th>"#
    )
}

fn td(val: &str, color: &str, size: &str, align: &str) -> String {
    format!(
        r#"<td style="padding:3px 8px;color:{color};font-size:{size};text-align:{align};border-bottom:1px solid rgba(15,52,96,0.3);font-family:{FONT};">{val}</td>"#
    )
}

// ── Main render function ────────────────────────────────────────────

pub fn render(data: &ReportData, mode: OutputMode) -> String {
    let mut h = String::with_capacity(96 * 1024);

    // HTML boilerplate — differs between Web and Email modes
    match mode {
        OutputMode::Web => {
            write!(h, r#"<!DOCTYPE html>
<html><head><meta charset="UTF-8">
<script src="https://cdn.jsdelivr.net/npm/mermaid/dist/mermaid.min.js"></script>
<script>
mermaid.initialize({{
    theme: 'dark',
    themeVariables: {{
        primaryColor: '#16213e',
        primaryTextColor: '#e0e0e0',
        primaryBorderColor: '#00d68f',
        lineColor: '#00d68f',
        secondaryColor: '#0f3460',
        tertiaryColor: '#1a1a2e'
    }},
    startOnLoad: true
}});
</script>
<style>
body {{ margin:0; padding:20px; background:{BG_BODY}; color:{C_TEXT}; font-family:{FONT}; }}
table {{ width:100%; border-collapse:collapse; margin:8px 0; }}
td, th {{ font-family:{FONT}; }}
.mermaid {{ margin:16px 0; padding:16px; background:{BG_CARD}; border-radius:8px; border:1px solid {BG_HEAD}; }}
a {{ color:{C_OK}; text-decoration:none; }}
a:hover {{ text-decoration:underline; }}
</style>
</head>
<body>
<div style="max-width:1200px;margin:0 auto;">
<table width="100%" cellpadding="0" cellspacing="0">
<tr><td style="background:{BG_HEAD};padding:20px 24px;text-align:center;border-radius:8px 8px 0 0;">
<h1 style="margin:0;font-size:20px;color:{C_TEXT};font-family:{FONT};letter-spacing:1px;">C3 Daily Ops Report</h1>
<p style="margin:4px 0 0;color:{C_DIM};font-size:12px;font-family:{FONT};">{date} &mdash; Generated at {time}</p>
</td></tr>
<tr><td style="background:{BG_CARD};padding:8px 12px;text-align:center;border-bottom:1px solid {BG_HEAD};">"#,
                date = data.date, time = data.time
            ).unwrap();
        }
        OutputMode::Email => {
            write!(h, r#"<!DOCTYPE html>
<html><head><meta charset="UTF-8"><style>
body{{margin:0;padding:0;background:{BG_BODY}}}
td,th{{font-family:{FONT}}}
</style></head>
<body style="margin:0;padding:0;background:{BG_BODY};">
<center>
<table width="100%" cellpadding="0" cellspacing="0" style="background:{BG_BODY};"><tr><td align="center">
<table width="700" cellpadding="0" cellspacing="0" style="max-width:700px;width:100%;">
<tr><td style="background:{BG_HEAD};padding:20px 24px;text-align:center;border-radius:8px 8px 0 0;">
<h1 style="margin:0;font-size:20px;color:{C_TEXT};font-family:{FONT};letter-spacing:1px;">C3 Daily Ops Report</h1>
<p style="margin:4px 0 0;color:{C_DIM};font-size:12px;font-family:{FONT};">{date} &mdash; Generated at {time}</p>
</td></tr>
<tr><td style="background:{BG_CARD};padding:8px 12px;text-align:center;border-bottom:1px solid {BG_HEAD};">"#,
                date = data.date, time = data.time
            ).unwrap();
        }
    }

    // Nav bar links — grouped by hierarchy level, left-aligned within centered container
    h.push_str(&format!("<div style=\"display:inline-block;text-align:left;line-height:1.8;\">"));
    let nav_groups: &[&[(&str, &str)]] = &[
        &[("a0-services","A0 Services"),("a1-containers","A1 Containers"),("a2-databases","A2 Databases"),("a3-secrets","A3 Secrets"),("a4-workflows","A4 Workflows"),("a5-topology","A5 Topology")],
        &[("b0-security-infos","B0 Sec Infos"),("b1-security-data","B1 Sec Data"),("b2-security-network","B2 Sec Network")],
        &[("c0-finops","C0 FinOps"),("c1-analytics","C1 Analytics")],
        &[("d0-mail","D0 Mail"),("d1-ai","D1 AI"),("d2-backups","D2 Backups"),("d3-others","D3 Others")],
    ];
    for (gi, group) in nav_groups.iter().enumerate() {
        if gi > 0 {
            h.push_str("<br/>");
        }
        for (i, (anchor, label)) in group.iter().enumerate() {
            if i > 0 {
                h.push_str(&format!("<span style=\"color:{};\"> &middot; </span>", C_DIM));
            }
            h.push_str(&format!(
                "<a href=\"#sec-{}\" style=\"color:{};font-size:11px;font-family:{};text-decoration:none;\">{}</a>",
                anchor, C_OK, FONT, label
            ));
        }
    }
    h.push_str("</div>");
    h.push_str("</td></tr>");

    // Executive Summary (NEW)
    render_exec_summary(&mut h, data);

    // Fleet Dashboard (enhanced with stat cards + swap)
    render_fleet_dashboard(&mut h, data);

    // ═══════════════════════════════════════════════════════════
    // A0) SERVICES
    // ═══════════════════════════════════════════════════════════
    section_title(&mut h, "A0", "SERVICES");
    diagram_or_css(&mut h, mode, "Service Mesh",
        || (crate::diagrams::service_mesh_dot(data), "graphviz"),
        |h| render_topo_routing(h, data),
    );
    render_services_all_unified(&mut h, data);
    render_services_api_endpoints(&mut h, data);
    render_services_mcps(&mut h, data);

    // ═══════════════════════════════════════════════════════════
    // A1) CONTAINERS
    // ═══════════════════════════════════════════════════════════
    section_title(&mut h, "A1", "CONTAINERS");
    diagram_or_css(&mut h, mode, "Container Distribution",
        || (crate::diagrams::container_distribution_dot(data), "graphviz"),
        |h| render_topo_containers(h, data),
    );
    render_container_inventory(&mut h, data);
    render_container_resources(&mut h, data);
    render_log_errors(&mut h, data);
    render_container_drift(&mut h, data);
    render_restarts(&mut h, data);
    render_docker_disk(&mut h, data);

    // ═══════════════════════════════════════════════════════════
    // A2) DATABASES
    // ═══════════════════════════════════════════════════════════
    section_title(&mut h, "A2", "DATABASES");
    diagram_or_css(&mut h, mode, "Data Flow",
        || (crate::diagrams::data_flow_plantuml(data), "plantuml"),
        |h| render_topo_data(h, data),
    );
    render_database_report(&mut h, data);
    render_object_storage(&mut h, data);
    render_ghcr(&mut h, data);
    render_repos(&mut h, data);
    render_runtime_volumes(&mut h, data);
    render_drift(&mut h, data);

    // ═══════════════════════════════════════════════════════════
    // A3) SECRETS — sops-encrypted secrets inventory
    // ═══════════════════════════════════════════════════════════
    section_title(&mut h, "A3", "SECRETS");
    render_secrets_inventory(&mut h, data);

    // ═══════════════════════════════════════════════════════════
    // A4) WORKFLOWS
    // ═══════════════════════════════════════════════════════════
    section_title(&mut h, "A4", "WORKFLOWS");
    diagram_or_css(&mut h, mode, "CI/CD Pipeline",
        || (crate::diagrams::cicd_pipeline_d2(data), "d2"),
        |h| render_topo_cicd(h, data),
    );
    render_dags(&mut h, data);
    render_gha_workflows(&mut h, data);
    render_gha(&mut h, data);

    // ═══════════════════════════════════════════════════════════
    // A5) TOPOLOGY
    // ═══════════════════════════════════════════════════════════
    section_title(&mut h, "A5", "TOPOLOGY");
    render_topology(&mut h, data, mode);

    // ═══════════════════════════════════════════════════════════
    // B0) SECURITY INFOS — topology stack, firewall, certs
    // ═══════════════════════════════════════════════════════════
    section_title(&mut h, "B0", "SECURITY INFOS");
    diagram_or_css(&mut h, mode, "Full Security Stack",
        || (crate::diagrams::security_layers_d2(data), "d2"),
        |h| render_topo_security(h, data),
    );
    render_firewall_summary(&mut h, data);
    render_certs(&mut h, data);
    render_dns(&mut h, data);
    render_wireguard(&mut h, data);

    // ═══════════════════════════════════════════════════════════
    // B1) SECURITY DATA — secrets, OOM, failed units
    // ═══════════════════════════════════════════════════════════
    section_title(&mut h, "B1", "SECURITY DATA");
    render_oom_kills(&mut h, data);
    render_failed_units(&mut h, data);

    // ═══════════════════════════════════════════════════════════
    // B2) SECURITY NETWORK — SSH events, login attempts
    // ═══════════════════════════════════════════════════════════
    section_title(&mut h, "B2", "SECURITY NETWORK");
    render_security(&mut h, data);

    // ═══════════════════════════════════════════════════════════
    // C0) FINOPS
    // ═══════════════════════════════════════════════════════════
    section_title(&mut h, "C0", "FINOPS");
    diagram_or_css(&mut h, mode, "VM Resource Allocation",
        || (crate::diagrams::vm_resource_d2(data), "d2"),
        |h| render_topo_resources(h, data),
    );
    render_finops_costs(&mut h, data);
    render_finops_vms(&mut h, data);
    render_finops_providers(&mut h, data);
    render_finops_assets(&mut h, data);

    // ═══════════════════════════════════════════════════════════
    // C1) ANALYTICS
    // ═══════════════════════════════════════════════════════════
    section_title(&mut h, "C1", "ANALYTICS");
    render_analytics_web(&mut h, data);
    render_matomo_comparison(&mut h, data);
    render_analytics_containers(&mut h, data);

    // ═══════════════════════════════════════════════════════════
    // D0) MAIL — full mail health (incorporated from cloud-mail-full-report)
    // ═══════════════════════════════════════════════════════════
    section_title(&mut h, "D0", "MAIL");
    render_mail_health(&mut h, data);

    // ═══════════════════════════════════════════════════════════
    // D1) AI
    // ═══════════════════════════════════════════════════════════
    section_title(&mut h, "D1", "AI");
    diagram_or_css(&mut h, mode, "AI Model Usage",
        || (mermaid_to_div(&crate::mermaid::ai_models(data)), "mermaid"),
        |h| render_topo_ai(h, data),
    );
    render_ai_section(&mut h, data);

    // ═══════════════════════════════════════════════════════════
    // D2) BACKUPS
    // ═══════════════════════════════════════════════════════════
    section_title(&mut h, "D2", "BACKUPS");
    render_backup_dags(&mut h, data);
    render_backup_buckets(&mut h, data);
    render_backup_status(&mut h, data);

    // ═══════════════════════════════════════════════════════════
    // D3) OTHERS
    // ═══════════════════════════════════════════════════════════
    section_title(&mut h, "D3", "OTHERS");
    render_wg_traffic(&mut h, data);
    render_system_info(&mut h, data);
    render_report_metadata(&mut h, data);

    // ── Appendix — full 11-layer diagnostic (from cloud-health-full-2) ─
    render_appendix(&mut h, data);

    // ── Footer ──────────────────────────────────────────────────
    write!(h, r#"<tr><td style="text-align:center;padding:16px;color:{C_DIM};font-size:11px;font-family:{FONT};">
C3 Daily Ops Report &mdash; {date} {time}<br>
<a href="http://10.0.0.3:8070" style="color:{C_OK};">Dagu Dashboard</a>
</td></tr>
</table>"#,
        date = data.date, time = data.time
    ).unwrap();

    match mode {
        OutputMode::Web => {
            h.push_str("\n</div>\n</body>\n</html>");
        }
        OutputMode::Email => {
            h.push_str("\n</td></tr></table>\n</center>\n</body>\n</html>");
        }
    }

    h
}

// ── Executive Summary ───────────────────────────────────────────────

fn render_exec_summary(h: &mut String, data: &ReportData) {
    let es = &data.exec_summary;

    // Traffic light cards: 3-column layout
    write!(h, r#"<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:{BG_CARD};border-radius:6px;">
<tr><td colspan="3" style="padding:12px 16px;background:{BG_HEAD};border-radius:6px 6px 0 0;font-size:14px;font-weight:bold;color:{C_TEXT};font-family:{FONT};">Executive Summary</td></tr>
<tr>"#).unwrap();

    // Critical card
    write!(h, r#"<td style="padding:8px;width:33%;">
<div style="border-left:4px solid {C_CRIT};background:{BG_CARD};padding:8px 12px;border-radius:0 4px 4px 0;">
<span style="font-size:20px;font-weight:bold;color:{C_CRIT};font-family:{FONT};">{}</span>
<br><span style="font-size:10px;color:{C_DIM};font-family:{FONT};">CRITICAL</span>
</div></td>"#, es.critical).unwrap();

    // Warning card
    write!(h, r#"<td style="padding:8px;width:33%;">
<div style="border-left:4px solid {C_WARN};background:{BG_CARD};padding:8px 12px;border-radius:0 4px 4px 0;">
<span style="font-size:20px;font-weight:bold;color:{C_WARN};font-family:{FONT};">{}</span>
<br><span style="font-size:10px;color:{C_DIM};font-family:{FONT};">WARNING</span>
</div></td>"#, es.warnings).unwrap();

    // OK card
    write!(h, r#"<td style="padding:8px;width:34%;">
<div style="border-left:4px solid {C_OK};background:{BG_CARD};padding:8px 12px;border-radius:0 4px 4px 0;">
<span style="font-size:20px;font-weight:bold;color:{C_OK};font-family:{FONT};">{}</span>
<br><span style="font-size:10px;color:{C_DIM};font-family:{FONT};">OK</span>
</div></td>"#, es.ok).unwrap();

    h.push_str("</tr>\n");

    // Top issues
    if !es.top_issues.is_empty() {
        write!(h, r#"<tr><td colspan="3" style="padding:4px 16px 8px;">"#).unwrap();
        for issue in &es.top_issues {
            let color = if issue.severity == "CRIT" { C_CRIT } else { C_WARN };
            let badge = label_badge(&issue.severity, color);
            write!(h, r#"<div style="padding:3px 0;font-family:{FONT};font-size:11px;color:{C_TEXT};">{badge} {msg}</div>"#,
                msg = issue.message).unwrap();
        }
        h.push_str("</td></tr>\n");
    }

    section_end(h);
}

// ── Stat Cards ──────────────────────────────────────────────────────

fn render_stat_cards(h: &mut String, data: &ReportData) {
    let vm_count = data.vms.len();
    // 2xx/3xx counts as OK, EXCEPT a 200 that is actually the edge wormhole
    // fallback (false-green) — exclude those so the headline stat is truthful.
    let ep_ok = data.endpoints.iter()
        .filter(|e| (200..=399).contains(&e.status_code) && !e.edge_fallback)
        .count();
    let certs_ok = data.certs.iter().filter(|c| c.days_left >= 7).count();

    write!(h, r#"<tr>
<td style="padding:6px 4px;width:25%;"><div style="border-left:4px solid {C_OK};background:{BG_CARD};padding:6px 10px;border-radius:0 4px 4px 0;">
<span style="font-size:18px;font-weight:bold;color:{C_TEXT};font-family:{FONT};">{vm_count}</span>
<br><span style="font-size:10px;color:{C_DIM};font-family:{FONT};">VMs</span>
</div></td>
<td style="padding:6px 4px;width:25%;"><div style="border-left:4px solid {C_OK};background:{BG_CARD};padding:6px 10px;border-radius:0 4px 4px 0;">
<span style="font-size:18px;font-weight:bold;color:{C_TEXT};font-family:{FONT};">{run}/{tot}</span>
<br><span style="font-size:10px;color:{C_DIM};font-family:{FONT};">Containers</span>
</div></td>
<td style="padding:6px 4px;width:25%;"><div style="border-left:4px solid {C_OK};background:{BG_CARD};padding:6px 10px;border-radius:0 4px 4px 0;">
<span style="font-size:18px;font-weight:bold;color:{C_TEXT};font-family:{FONT};">{ep_ok}/{ep_tot}</span>
<br><span style="font-size:10px;color:{C_DIM};font-family:{FONT};">Endpoints</span>
</div></td>
<td style="padding:6px 4px;width:25%;"><div style="border-left:4px solid {C_OK};background:{BG_CARD};padding:6px 10px;border-radius:0 4px 4px 0;">
<span style="font-size:18px;font-weight:bold;color:{C_TEXT};font-family:{FONT};">{certs_ok}/{certs_tot}</span>
<br><span style="font-size:10px;color:{C_DIM};font-family:{FONT};">Certs</span>
</div></td>
</tr>"#,
        run = data.fleet_running, tot = data.fleet_total,
        ep_tot = data.endpoints.len(), certs_tot = data.certs.len(),
    ).unwrap();
}

fn render_fleet_dashboard(h: &mut String, data: &ReportData) {
    section_start(h, "Fleet Dashboard", 8);

    // Stat cards row
    render_stat_cards(h, data);

    // VM table header (8 columns with Swap)
    h.push_str("<tr>");
    for label in &["VM", "Status", "Uptime", "Load", "Mem", "Disk", "Swap", "Ctrs"] {
        write!(h, r#"<th style="text-align:left;color:{C_DIM};font-size:11px;padding:8px;border-bottom:1px solid {BG_HEAD};font-family:{FONT};">{label}</th>"#).unwrap();
    }
    h.push_str("</tr>\n");

    for vm in &data.vms {
        let badge = status_badge(&vm.status);
        let load1 = vm.load.split_whitespace().next().unwrap_or("?");
        let mbar = progress_bar(vm.mem_pct);
        let dbar = progress_bar(vm.disk_pct);
        let sbar = if vm.swap == "N/A" || vm.swap.is_empty() {
            format!(r#"<span style="color:{C_DIM};font-size:11px;font-family:{FONT};">N/A</span>"#)
        } else {
            progress_bar(vm.swap_pct)
        };
        write!(h, r#"<tr>
<td style="padding:6px 8px;color:{C_TEXT};font-size:12px;font-weight:bold;border-bottom:1px solid rgba(15,52,96,0.5);font-family:{FONT};">{name}</td>
<td style="padding:6px 8px;border-bottom:1px solid rgba(15,52,96,0.5);">{badge}</td>
<td style="padding:6px 8px;color:{C_DIM};font-size:11px;border-bottom:1px solid rgba(15,52,96,0.5);font-family:{FONT};">{uptime}</td>
<td style="padding:6px 8px;color:{C_TEXT};font-size:12px;border-bottom:1px solid rgba(15,52,96,0.5);font-family:{FONT};">{load1}</td>
<td style="padding:6px 8px;border-bottom:1px solid rgba(15,52,96,0.5);">{mbar}</td>
<td style="padding:6px 8px;border-bottom:1px solid rgba(15,52,96,0.5);">{dbar}</td>
<td style="padding:6px 8px;border-bottom:1px solid rgba(15,52,96,0.5);">{sbar}</td>
<td style="padding:6px 8px;color:{C_TEXT};font-size:12px;border-bottom:1px solid rgba(15,52,96,0.5);font-family:{FONT};">{run}/{tot}</td>
</tr>"#,
            name = vm.name, uptime = vm.uptime,
            run = vm.containers_running, tot = vm.containers_total,
        ).unwrap();
    }
    section_end(h);
}

fn render_container_inventory(h: &mut String, data: &ReportData) {
    section_start(h, "Full Container Inventory", 4);
    for vm in &data.vms {
        if vm.container_list.is_empty() { continue; }
        write!(h, r#"<tr><td colspan="4" style="padding:8px 8px 2px;color:{C_TEXT};font-size:12px;font-weight:bold;border-bottom:1px solid {BG_HEAD};font-family:{FONT};">{} ({}/{} running)</td></tr>"#,
            vm.name, vm.containers_running, vm.containers_total).unwrap();
        h.push_str("<tr>");
        for label in &["Name", "Image", "Status", "Uptime"] {
            write!(h, r#"<th style="text-align:left;color:{C_DIM};font-size:10px;padding:4px 8px;border-bottom:1px solid {BG_HEAD};font-family:{FONT};">{label}</th>"#).unwrap();
        }
        h.push_str("</tr>\n");
        for c in &vm.container_list {
            let scolor = if c.status.contains("Exited") || c.status.contains("dead") || c.status.contains("Created") {
                C_CRIT
            } else if c.status.contains("unhealthy") || c.status.contains("restarting") {
                C_WARN
            } else {
                C_OK
            };
            let short_image = if c.image.len() > 40 {
                format!("...{}", &c.image[c.image.len()-37..])
            } else {
                c.image.clone()
            };
            write!(h, "<tr>{}{}{}{}</tr>\n",
                td(&c.name, C_TEXT, "11px", "left"),
                td(&short_image, C_DIM, "10px", "left"),
                td(&c.status, scolor, "11px", "left"),
                td(&c.running_for, C_DIM, "11px", "left"),
            ).unwrap();
        }
    }
    section_end(h);
}

fn render_database_report(h: &mut String, data: &ReportData) {
    let enabled: Vec<_> = data.databases.iter().filter(|d| d.enabled).collect();
    if enabled.is_empty() { return; }

    section_start(h, "Database Report", 5);
    h.push_str("<tr>");
    for (label, align) in &[("Service","left"),("Type","left"),("Container","left"),("Size","right"),("VM","left")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");

    for db in &enabled {
        let type_color = match db.db_type.as_str() {
            "postgres" => "#4169E1",
            "mariadb" => "#C0765A",
            "sqlite" => "#57A6D6",
            "redis" => "#DC382D",
            "s3" => "#FF9900",
            "loki" => "#F2994A",
            "mimir" => "#E07C4F",
            "tempo" => "#D4633F",
            "grafana" => "#F46800",
            _ => C_DIM,
        };
        let size = data.vms.iter()
            .filter(|v| v.ip == db.wg_ip)
            .flat_map(|v| v.db_sizes.iter())
            .find(|(svc, _)| svc == &db.service)
            .map(|(_, s)| s.as_str())
            .unwrap_or("N/A");

        write!(h, "<tr>{}{}{}{}{}</tr>\n",
            td(&db.service, C_TEXT, "11px", "left"),
            td(&db.db_type, type_color, "11px", "left"),
            td(&db.container, C_DIM, "10px", "left"),
            td(size, C_TEXT, "11px", "right"),
            td(&db.vm_alias, C_DIM, "11px", "left"),
        ).unwrap();
    }
    section_end(h);
}

fn render_object_storage(h: &mut String, data: &ReportData) {
    // ── Cloud Provider Buckets (Terraform-declared) ─────────────────
    let has_buckets = !data.cloud_buckets.is_empty();
    // ── Docker S3/MinIO (from databases.json) ───────────────────────
    let s3_declared: Vec<_> = data.databases.iter()
        .filter(|d| d.enabled && d.db_type == "s3")
        .collect();

    if !has_buckets && s3_declared.is_empty() { return; }

    section_start(h, "Object &amp; File Storage", 5);

    // ── Cloud Provider Buckets (sorted by tier) ───────────────────
    if has_buckets {
        let bucket_total: u64 = data.cloud_buckets.iter().map(|b| b.size_bytes).sum();
        let bucket_total_str = if bucket_total > 0 { format!(" — {}", human_size(bucket_total)) } else { String::new() };
        write!(h, r#"<tr><td colspan="5" style="padding:8px 8px 2px;color:{C_TEXT};font-size:12px;font-weight:bold;border-bottom:1px solid {BG_HEAD};font-family:{FONT};">Cloud Provider Buckets ({} via Terraform{})</td></tr>"#,
            data.cloud_buckets.len(), bucket_total_str).unwrap();
        h.push_str("<tr>");
        for (label, align) in &[("Bucket","left"),("Provider","left"),("Tier","left"),("Size","right"),("Retrieval","left")] {
            h.push_str(&th(label, align));
        }
        h.push_str("</tr>\n");

        // Sort by tier priority: Standard first, then Archive/InfrequentAccess/DeepArchive
        let tier_order = |t: &str| -> u8 {
            match t {
                "Standard" => 0,
                "InfrequentAccess" => 1,
                "Archive" => 2,
                "DeepArchive" => 3,
                _ => 4,
            }
        };
        let mut sorted_buckets: Vec<_> = data.cloud_buckets.iter().collect();
        sorted_buckets.sort_by_key(|b| tier_order(&b.tier));

        for bucket in &sorted_buckets {
            let (tier_color, retrieval) = match bucket.tier.as_str() {
                "Standard" => (C_OK, "Instant"),
                "InfrequentAccess" => ("#57A6D6", "Instant (higher cost)"),
                "Archive" => (C_WARN, "3-5 hours"),
                "DeepArchive" => (C_DIM, "12-48 hours"),
                other => (C_DIM, other),
            };
            let size_str = if bucket.size_bytes > 0 { human_size(bucket.size_bytes) } else { "0 B".into() };
            write!(h, "<tr>{}{}{}{}{}</tr>\n",
                td(&bucket.name, "#FF9900", "11px", "left"),
                td(&bucket.provider.to_uppercase(), C_DIM, "11px", "left"),
                td(&bucket.tier, tier_color, "11px", "left"),
                td(&size_str, C_TEXT, "11px", "right"),
                td(retrieval, tier_color, "10px", "left"),
            ).unwrap();
        }
    }

    // ── Docker S3/MinIO Containers ──────────────────────────────────
    if !s3_declared.is_empty() {
        write!(h, r#"<tr><td colspan="5" style="padding:8px 8px 2px;color:{C_TEXT};font-size:12px;font-weight:bold;border-bottom:1px solid {BG_HEAD};font-family:{FONT};">Docker S3 / MinIO</td></tr>"#).unwrap();
        h.push_str("<tr>");
        for (label, align) in &[("Service","left"),("Container","left"),("Volume","left"),("Size","right")] {
            h.push_str(&th(label, align));
        }
        h.push_str("</tr>\n");

        for db in &s3_declared {
            let vol = data.vms.iter()
                .filter(|v| v.ip == db.wg_ip)
                .flat_map(|v| v.runtime_volumes.iter())
                .find(|v| v.container == db.container);

            let size = vol.map(|v| if v.size.is_empty() { "?" } else { &*v.size }).unwrap_or("N/A");
            let vol_name = vol.map(|v| v.name.as_str()).unwrap_or("—");

            write!(h, "<tr>{}{}{}{}</tr>\n",
                td(&db.service, C_TEXT, "11px", "left"),
                td(&db.container, C_DIM, "10px", "left"),
                td(vol_name, C_DIM, "10px", "left"),
                td(size, "#FF9900", "11px", "right"),
            ).unwrap();
        }
    }

    section_end(h);
}

fn render_backup_dags(h: &mut String, data: &ReportData) {
    let backup_dags: Vec<&DagStatus> = data.dags.iter()
        .filter(|d| {
            let n = d.name.to_lowercase();
            n.contains("backup") || n.contains("restic") || n.contains("dump") || n.contains("snapshot")
        })
        .collect();

    if backup_dags.is_empty() { return; }

    let ok = backup_dags.iter().filter(|d| d.status == "done" || d.status == "success").count();
    let failed = backup_dags.iter().filter(|d| d.status == "failed" || d.status == "error").count();
    section_start(h, &format!("Backup DAGs ({} total, {} OK, {} failed)", backup_dags.len(), ok, failed), 4);
    h.push_str("<tr>");
    for (label, align) in &[("DAG","left"),("Schedule","left"),("Status","center"),("Last Run","left")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");
    for dag in &backup_dags {
        let (label, color) = match dag.status.as_str() {
            "done" | "success" => ("OK", C_OK),
            "failed" | "error" => ("FAIL", C_CRIT),
            "running" => ("RUN", C_WARN),
            other => (other, C_DIM),
        };
        let badge = label_badge(label, color);
        write!(h, "<tr>{}{}<td style=\"padding:3px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);\">{badge}</td>{}</tr>\n",
            td(&dag.name, C_TEXT, "11px", "left"),
            td(&dag.schedule, C_DIM, "10px", "left"),
            td(&dag.started_at, C_DIM, "10px", "left"),
        ).unwrap();
    }
    section_end(h);
}

fn render_backup_buckets(h: &mut String, data: &ReportData) {
    let backup_buckets: Vec<&CloudBucket> = data.cloud_buckets.iter()
        .filter(|b| b.name.contains("backup"))
        .collect();

    if backup_buckets.is_empty() { return; }

    let total_bytes: u64 = backup_buckets.iter().map(|b| b.size_bytes).sum();
    let total_str = if total_bytes > 0 { human_size(total_bytes) } else { "0 B".into() };
    section_start(h, &format!("Backup S3 Buckets ({} — {} total)", backup_buckets.len(), total_str), 4);
    h.push_str("<tr>");
    for (label, align) in &[("Bucket","left"),("Provider","left"),("Size","right"),("Tier","left")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");
    for bucket in &backup_buckets {
        let size_str = if bucket.size_bytes > 0 { human_size(bucket.size_bytes) } else { "0 B".into() };
        let (tier_color, _) = match bucket.tier.as_str() {
            "Standard" => (C_OK, "Instant"),
            "Archive" => (C_WARN, "3-5h"),
            _ => (C_DIM, "?"),
        };
        write!(h, "<tr>{}{}{}{}</tr>\n",
            td(&bucket.name, "#FF9900", "11px", "left"),
            td(&bucket.provider.to_uppercase(), C_DIM, "11px", "left"),
            td(&size_str, C_TEXT, "11px", "right"),
            td(&bucket.tier, tier_color, "11px", "left"),
        ).unwrap();
    }
    section_end(h);
}

fn render_backup_status(h: &mut String, data: &ReportData) {
    let has_backups = data.vms.iter().any(|v| !v.backups.is_empty());
    if !has_backups { return; }

    section_start(h, "Backup Status", 4);
    h.push_str("<tr>");
    for (label, align) in &[("VM","left"),("File","left"),("Size","right"),("Age","right")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");

    let now = chrono::Utc::now().timestamp() as f64;
    for vm in &data.vms {
        for bk in &vm.backups {
            let size = human_size(bk.size_bytes);
            let (age_str, age_color) = if bk.epoch > 0.0 {
                let hours = ((now - bk.epoch) / 3600.0) as u64;
                if hours < 24 { (format!("{}h ago", hours), C_OK) }
                else if hours < 72 { (format!("{}d", hours / 24), C_WARN) }
                else { (format!("{}d", hours / 24), C_CRIT) }
            } else {
                ("unknown".into(), C_DIM)
            };
            write!(h, "<tr>{}{}{}{}</tr>\n",
                td(&vm.name, C_TEXT, "11px", "left"),
                td(&bk.file, C_TEXT, "11px", "left"),
                td(&size, C_DIM, "11px", "right"),
                td(&age_str, age_color, "11px", "right"),
            ).unwrap();
        }
    }
    section_end(h);
}

fn render_endpoints(h: &mut String, data: &ReportData) {
    if data.endpoints.is_empty() { return; }
    section_start(h, "Service Endpoints", 4);
    h.push_str("<tr>");
    for (label, align) in &[("Service","left"),("URL","left"),("Status","center"),("Latency","center")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");

    for ep in &data.endpoints {
        let badge = code_badge(ep.status_code);
        let latency = render_latency_bar(ep.latency_ms);
        write!(h, r#"<tr>{}{}<td style="padding:3px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);">{badge}</td><td style="padding:3px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);">{latency}</td></tr>
"#,
            td(&ep.service, C_TEXT, "11px", "left"),
            td(&ep.url, C_DIM, "10px", "left"),
        ).unwrap();
    }
    section_end(h);
}

fn render_secrets_inventory(h: &mut String, data: &ReportData) {
    // List services that use .secrets files (env_file: true in cloud-data)
    // Also scan the cloud repo filesystem if accessible
    let cloud_root = std::path::Path::new("../../a_solutions");
    let mut secrets_files: Vec<(String, String, bool)> = Vec::new(); // (service, vm, sops_encrypted)

    if cloud_root.exists() {
        // Scan cloud repo for secrets.yaml and .secrets files
        if let Ok(entries) = std::fs::read_dir(cloud_root) {
            for entry in entries.flatten() {
                let svc_dir = entry.path();
                let svc_name = entry.file_name().to_string_lossy()
                    .trim_start_matches(|c: char| c.is_ascii_alphanumeric() || c == '-')
                    .to_string();
                let svc_name = entry.file_name().to_string_lossy().to_string();

                let has_secrets_yaml = svc_dir.join("src/secrets.yaml").exists();
                let has_dot_secrets = svc_dir.join("dist/.secrets").exists();
                if has_secrets_yaml || has_dot_secrets {
                    let vm = data.services.iter()
                        .find(|s| svc_name.contains(&s.name) || s.name.contains(svc_name.split('_').last().unwrap_or("")))
                        .map(|s| s.vm.clone())
                        .unwrap_or_else(|| "?".into());
                    secrets_files.push((svc_name, vm, has_secrets_yaml));
                }
            }
        }
    } else {
        // Fallback: derive from service data (services with env_file containers)
        for svc in &data.services {
            if svc.enabled {
                secrets_files.push((svc.name.clone(), svc.vm.clone(), true));
            }
        }
    }

    secrets_files.sort_by(|a, b| a.1.cmp(&b.1).then(a.0.cmp(&b.0)));

    let total = secrets_files.len();
    let sops_count = secrets_files.iter().filter(|(_, _, sops)| *sops).count();
    section_start(h, &format!("SOPS Secrets Inventory ({} services, {} sops-encrypted)", total, sops_count), 3);
    h.push_str("<tr>");
    for (label, align) in &[("Service","left"),("VM","left"),("SOPS","center")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");

    for (svc, vm, sops) in &secrets_files {
        let sops_badge = if *sops {
            label_badge("SOPS", C_OK)
        } else {
            label_badge("PLAIN", C_WARN)
        };
        write!(h, "<tr>{}<td style=\"padding:3px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);\">{sops_badge}</td>{}</tr>\n",
            td(svc, C_TEXT, "11px", "left"),
            td(vm, C_DIM, "11px", "left"),
        ).unwrap();
    }
    section_end(h);
}

fn render_certs(h: &mut String, data: &ReportData) {
    if data.certs.is_empty() { return; }
    section_start(h, "Certificate Expiry", 3);
    h.push_str("<tr>");
    for (label, align) in &[("Domain","left"),("Days Left","right"),("Expires","left")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");

    for cert in &data.certs {
        let color = if cert.days_left < 0 { C_CRIT }
            else if cert.days_left < 7 { C_CRIT }
            else if cert.days_left < 30 { C_WARN }
            else { C_OK };
        write!(h, "<tr>{}{}{}</tr>\n",
            td(&cert.domain, C_TEXT, "11px", "left"),
            td(&format!("{}d", cert.days_left), color, "11px", "right"),
            td(&cert.expiry, C_DIM, "11px", "left"),
        ).unwrap();
    }
    section_end(h);
}

fn render_dns(h: &mut String, data: &ReportData) {
    if data.dns.is_empty() { return; }
    section_start(h, "DNS Status (diegonmarcos.com)", 3);
    h.push_str("<tr>");
    for (label, align) in &[("Record","left"),("Status","center"),("Value","left")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");

    for rec in &data.dns {
        let (status, color) = if rec.value.is_empty() {
            ("FAIL", C_CRIT)
        } else {
            ("PASS", C_OK)
        };
        let short_val = if rec.value.len() > 60 {
            format!("{}...", &rec.value[..57])
        } else if rec.value.is_empty() {
            "not found".into()
        } else {
            rec.value.clone()
        };
        let badge = label_badge(status, color);
        write!(h, r#"<tr>
{rec_td}
<td style="padding:3px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);">{badge}</td>
{val_td}
</tr>
"#,
            rec_td = td(&rec.record_type, C_TEXT, "11px", "left"),
            val_td = td(&short_val, C_DIM, "10px", "left"),
        ).unwrap();
    }
    section_end(h);
}

fn render_mail_health(h: &mut String, data: &ReportData) {
    let mh = match &data.mail_health {
        Some(m) => m,
        None => {
            // Fallback: just show queue stats if no mail health data
            let mail_vm = data.vms.iter().find(|v| v.mail_queue.is_some());
            if let Some(vm) = mail_vm {
                let mq = vm.mail_queue.unwrap_or(0);
                let md = vm.mail_delivered.unwrap_or(0);
                let mf = vm.mail_failed.unwrap_or(0);
                section_start(h, "Mail Queue &amp; Stats (24h)", 2);
                let mq_color = if mq > 20 { C_CRIT } else if mq > 5 { C_WARN } else { C_OK };
                let mf_color = if mf > 5 { C_CRIT } else if mf > 0 { C_WARN } else { C_OK };
                for (label, val, color) in &[("Queued", mq, mq_color), ("Delivered (24h)", md, C_OK), ("Failed (24h)", mf, mf_color)] {
                    write!(h, "<tr>{}{}</tr>\n",
                        td(label, C_DIM, "12px", "left"),
                        td(&val.to_string(), color, "12px", "left"),
                    ).unwrap();
                }
                section_end(h);
            }
            return;
        }
    };

    // Summary bar
    let s = &mh.summary;
    section_start(h, &format!("Mail Health — {} checks ({} passed, {} failed, {} critical)",
        s.total, s.passed, s.failed, s.critical), 1);
    let summary_color = if s.critical > 0 { C_CRIT } else if s.failed > 0 { C_WARN } else { C_OK };
    write!(h, r#"<tr><td style="padding:8px 16px;">
<div style="display:flex;gap:12px;flex-wrap:wrap;font-family:{FONT};font-size:12px;">
<span style="color:{C_OK};">PASS {passed}</span>
<span style="color:{C_WARN};">WARN {warnings}</span>
<span style="color:{C_CRIT};">CRIT {critical}</span>
<span style="color:{summary_color};font-weight:bold;">{pct:.0}% healthy</span>
</div></td></tr>"#,
        passed = s.passed, warnings = s.warnings, critical = s.critical,
        pct = if s.total > 0 { s.passed as f64 / s.total as f64 * 100.0 } else { 0.0 },
    ).unwrap();
    section_end(h);

    // Check group renderer
    fn render_check_group(h: &mut String, title: &str, checks: &[crate::types::MailCheck]) {
        if checks.is_empty() { return; }
        section_start(h, title, 4);
        h.push_str("<tr>");
        for (label, align) in &[("Check","left"),("Status","center"),("Details","left"),("ms","right")] {
            h.push_str(&th(label, align));
        }
        h.push_str("</tr>\n");
        for c in checks {
            let badge = if c.passed {
                label_badge("PASS", C_OK)
            } else {
                match c.severity.as_str() {
                    "critical" => label_badge("CRIT", C_CRIT),
                    "warning" => label_badge("WARN", C_WARN),
                    _ => label_badge("FAIL", C_WARN),
                }
            };
            write!(h, "<tr>{}<td style=\"padding:3px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);\">{badge}</td>{}{}</tr>\n",
                td(&c.name, C_TEXT, "11px", "left"),
                td(&c.details, C_DIM, "10px", "left"),
                td(&format!("{}", c.duration_ms), C_DIM, "10px", "right"),
            ).unwrap();
        }
        section_end(h);
    }

    // Outbound path
    render_check_group(h, "Outbound Path — Maddy → OCI Relay → Destination", &mh.outbound_path);

    // Inbound path
    render_check_group(h, "Inbound Path — Resend/CF → Worker → Caddy → http-to-smtp-proxy-api → Maddy → INBOX", &mh.inbound_path);

    // DNS Authentication
    render_check_group(h, "DNS Authentication (MX · DKIM · SPF · DMARC)", &mh.dns_auth);

    // TLS Ports
    render_check_group(h, "TLS Port Checks (mail.diegonmarcos.com)", &mh.tls_ports);

    // Container Health
    render_check_group(h, "Mail Containers (oci-mail)", &mh.containers);

    // Mail Internals
    render_check_group(h, "Mail Internals", &mh.internals);

    // Stalwart + JMAP
    render_check_group(h, "Stalwart Shadow Mode (JMAP · IMAP · SMTP · ManageSieve · WebAdmin)", &mh.stalwart);
}

fn render_gha(h: &mut String, data: &ReportData) {
    if data.gha_runs.is_empty() { return; }

    // Group runs by repo
    let mut by_repo: std::collections::BTreeMap<String, Vec<&GhaRun>> = std::collections::BTreeMap::new();
    for run in &data.gha_runs {
        by_repo.entry(run.repo.clone()).or_default().push(run);
    }

    let total = data.gha_runs.len();
    let ok = data.gha_runs.iter().filter(|r| r.conclusion == "success").count();
    let failed = data.gha_runs.iter().filter(|r| r.conclusion == "failure").count();

    section_start(h, &format!("GHA Recent Runs ({} total, {} OK, {} failed)", total, ok, failed), 4);
    h.push_str("<tr>");
    for (label, align) in &[("Workflow","left"),("Repo","left"),("Status","center"),("Time","left")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");

    for (repo, runs) in &by_repo {
        // Repo sub-header
        write!(h, r#"<tr><td colspan="4" style="padding:5px 8px;font-weight:bold;font-size:11px;color:{C_TEXT};background:rgba(15,52,96,0.15);font-family:{FONT};border-bottom:1px solid rgba(15,52,96,0.3);">{repo} ({} runs)</td></tr>"#, runs.len()).unwrap();

        for run in runs.iter().take(10) {
            let (label, color) = match run.conclusion.as_str() {
                "success" => ("OK", C_OK),
                "failure" => ("FAIL", C_CRIT),
                "cancelled" => ("SKIP", C_WARN),
                other => (other, C_DIM),
            };
            let badge = label_badge(label, color);
            let time = run.created_at.replace('T', " ").replace('Z', "");
            // Trim time to just date + HH:MM
            let time_short = if time.len() > 16 { &time[..16] } else { &time };
            write!(h, r#"<tr>
{}
{}
<td style="padding:3px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);">{badge}</td>
{}
</tr>
"#,
                td(&run.name, C_TEXT, "11px", "left"),
                td(&run.repo, C_DIM, "10px", "left"),
                td(time_short, C_DIM, "10px", "left"),
            ).unwrap();
        }
        if runs.len() > 10 {
            write!(h, r#"<tr><td colspan="4" style="padding:2px 8px;font-size:10px;color:{C_DIM};font-family:{FONT};text-align:right;border-bottom:1px solid rgba(15,52,96,0.3);">... and {} more</td></tr>"#, runs.len() - 10).unwrap();
        }
    }
    section_end(h);
}

fn render_gha_workflows(h: &mut String, data: &ReportData) {
    if data.gha_workflows.is_empty() { return; }

    // Group by repo
    let mut by_repo: std::collections::BTreeMap<String, Vec<&GhaWorkflow>> = std::collections::BTreeMap::new();
    for wf in &data.gha_workflows {
        by_repo.entry(wf.repo.clone()).or_default().push(wf);
    }

    let total = data.gha_workflows.len();
    let active = data.gha_workflows.iter().filter(|w| w.state == "active").count();

    section_start(h, &format!("GHA Workflow Registry ({} workflows, {} active)", total, active), 5);
    h.push_str("<tr>");
    for (label, align) in &[("Workflow","left"),("Repo","left"),("File","left"),("State","center"),("Last Run","center")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");

    for (repo, workflows) in &by_repo {
        write!(h, r#"<tr><td colspan="5" style="padding:5px 8px;font-weight:bold;font-size:11px;color:{C_TEXT};background:rgba(15,52,96,0.15);font-family:{FONT};border-bottom:1px solid rgba(15,52,96,0.3);">{repo} ({} workflows)</td></tr>"#, workflows.len()).unwrap();

        for wf in workflows {
            let state_badge = match wf.state.as_str() {
                "active" => label_badge("ACTIVE", C_OK),
                "disabled_manually" => label_badge("OFF", C_DIM),
                other => label_badge(other, C_WARN),
            };
            let run_badge = match wf.last_conclusion.as_str() {
                "success" => label_badge("OK", C_OK),
                "failure" => label_badge("FAIL", C_CRIT),
                "cancelled" => label_badge("SKIP", C_WARN),
                "never_run" => label_badge("NEVER", C_DIM),
                other => label_badge(other, C_DIM),
            };
            // Show just the filename, not full path
            let file_short = wf.path.rsplit('/').next().unwrap_or(&wf.path);
            write!(h, r#"<tr>
{}
{}
{}
<td style="padding:2px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);">{state_badge}</td>
<td style="padding:2px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);">{run_badge}</td>
</tr>
"#,
                td(&wf.name, C_TEXT, "11px", "left"),
                td(&wf.repo, C_DIM, "10px", "left"),
                td(file_short, C_DIM, "10px", "left"),
            ).unwrap();
        }
    }
    section_end(h);
}

fn render_ghcr(h: &mut String, data: &ReportData) {
    if data.ghcr_packages.is_empty() { return; }

    let disk_str = if data.github_disk_kb > 1048576 {
        format!("{:.1} GB", data.github_disk_kb as f64 / 1048576.0)
    } else if data.github_disk_kb > 1024 {
        format!("{:.0} MB", data.github_disk_kb as f64 / 1024.0)
    } else if data.github_disk_kb > 0 {
        format!("{} KB", data.github_disk_kb)
    } else {
        "?".into()
    };

    section_start(h, &format!("GHCR Container Registry ({} images — {} total GitHub storage)", data.ghcr_total, disk_str), 2);
    h.push_str("<tr>");
    h.push_str(&th("Package", "left"));
    h.push_str(&th("Updated", "left"));
    h.push_str("</tr>\n");

    for pkg in &data.ghcr_packages {
        let time = pkg.updated_at.replace('T', " ").replace('Z', "");
        write!(h, "<tr>{}{}</tr>\n",
            td(&pkg.name, C_TEXT, "11px", "left"),
            td(&time, C_DIM, "10px", "left"),
        ).unwrap();
    }
    section_end(h);
}

fn render_dags(h: &mut String, data: &ReportData) {
    let ok = data.dags.iter().filter(|d| matches!(d.status.as_str(), "succeeded" | "success" | "finished" | "done")).count();
    let failed = data.dags.iter().filter(|d| matches!(d.status.as_str(), "failed" | "error")).count();
    let running = data.dags.iter().filter(|d| d.status == "running").count();

    let title = if data.dags.is_empty() {
        "Dagu DAGs (0 — API unreachable)".to_string()
    } else {
        format!("Dagu DAGs ({} total, {} OK, {} failed, {} running)", data.dags.len(), ok, failed, running)
    };

    section_start(h, &title, 4);

    if data.dags.is_empty() {
        write!(h, r#"<tr><td colspan="4" style="padding:8px;color:{C_WARN};font-size:12px;font-family:{FONT};">No DAGs returned. Check: DAGU_USERNAME/DAGU_PASSWORD env vars, API at 10.0.0.4:8070</td></tr>"#).unwrap();
        section_end(h);
        return;
    }

    h.push_str("<tr>");
    for (label, align) in &[("DAG","left"),("Schedule","left"),("Status","center"),("Last Run","left")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");

    for dag in &data.dags {
        let (label, color) = match dag.status.as_str() {
            "succeeded" | "success" | "finished" | "done" => ("OK", C_OK),
            "failed" | "error" => ("FAIL", C_CRIT),
            "running" => ("RUN", "#3498DB"),
            "cancelled" | "cancel" => ("SKIP", C_WARN),
            "not_started" | "none" => ("IDLE", C_DIM),
            _ => (&*dag.status, C_DIM),
        };
        let badge = label_badge(label, color);
        let time = dag.started_at.replace('T', " ").replace('Z', "");
        let time_short = if time.len() > 16 { &time[..16] } else { &time };
        let sched = if dag.schedule.is_empty() { "manual" } else { &dag.schedule };
        write!(h, r#"<tr>
{}
{}
<td style="padding:2px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);">{badge}</td>
{}
</tr>
"#,
            td(&dag.name, C_TEXT, "11px", "left"),
            td(sched, C_DIM, "10px", "left"),
            td(time_short, C_DIM, "10px", "left"),
        ).unwrap();
    }
    section_end(h);
}

fn render_container_resources(h: &mut String, data: &ReportData) {
    for vm in &data.vms {
        if vm.container_stats.is_empty() && vm.unhealthy_names.is_empty() && vm.exited_names.is_empty() {
            continue; // skip VMs with no data (SSH fallback)
        }
        section_start(h, &format!("Container Resources — {} ({} containers)", vm.name, vm.containers_running), 4);

        for name in &vm.unhealthy_names {
            write!(h, r#"<tr><td colspan="4" style="padding:4px 8px;color:{C_CRIT};font-size:12px;font-family:{FONT};">UNHEALTHY: {name}</td></tr>"#).unwrap();
        }
        for name in &vm.exited_names {
            write!(h, r#"<tr><td colspan="4" style="padding:4px 8px;color:{C_WARN};font-size:12px;font-family:{FONT};">EXITED: {name}</td></tr>"#).unwrap();
        }

        if !vm.container_stats.is_empty() {
            h.push_str("<tr>");
            for (label, align) in &[("Container","left"),("CPU","right"),("Mem Usage","right"),("Mem %","right")] {
                h.push_str(&th(label, align));
            }
            h.push_str("</tr>\n");

            for s in &vm.container_stats {
                write!(h, "<tr>{}{}{}{}</tr>\n",
                    td(&s.name, C_TEXT, "11px", "left"),
                    td(&s.cpu, C_TEXT, "11px", "right"),
                    td(&s.mem_usage, C_TEXT, "11px", "right"),
                    td(&s.mem_pct, C_TEXT, "11px", "right"),
                ).unwrap();
            }
        }
        section_end(h);
    }
}

// ── Log Errors (NEW) ────────────────────────────────────────────────

fn render_log_errors(h: &mut String, data: &ReportData) {
    let has_errors = data.vms.iter().any(|v| !v.log_errors.is_empty());
    if !has_errors { return; }

    section_start(h, "Container Log Errors (24h)", 3);
    h.push_str("<tr>");
    for (label, align) in &[("Container","left"),("Error Count","right"),("Severity","center")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");

    for vm in &data.vms {
        if vm.log_errors.is_empty() { continue; }
        write!(h, r#"<tr><td colspan="3" style="padding:6px 8px;color:{C_TEXT};font-size:12px;font-weight:bold;border-bottom:1px solid {BG_HEAD};font-family:{FONT};">{}</td></tr>"#, vm.name).unwrap();
        for (name, count) in &vm.log_errors {
            let (sev_label, sev_color) = if *count > 100 {
                ("HIGH", C_CRIT)
            } else if *count > 10 {
                ("MED", C_WARN)
            } else {
                ("LOW", C_DIM)
            };
            let badge = label_badge(sev_label, sev_color);
            write!(h, r#"<tr>{}{}<td style="padding:3px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);">{badge}</td></tr>
"#,
                td(name, C_TEXT, "11px", "left"),
                td(&count.to_string(), sev_color, "11px", "right"),
            ).unwrap();
        }
    }
    section_end(h);
}

// ── OOM Kills (NEW) ─────────────────────────────────────────────────

fn render_oom_kills(h: &mut String, data: &ReportData) {
    let has_oom = data.vms.iter().any(|v| !v.oom_kills.is_empty());
    if !has_oom { return; }

    section_start(h, "OOM Kills", 1);
    for vm in &data.vms {
        if vm.oom_kills.is_empty() { continue; }
        write!(h, r#"<tr><td style="padding:6px 8px;color:{C_TEXT};font-size:12px;font-weight:bold;border-bottom:1px solid {BG_HEAD};font-family:{FONT};">{}</td></tr>"#, vm.name).unwrap();
        for line in &vm.oom_kills {
            let short = if line.len() > 80 { format!("{}...", &line[..77]) } else { line.clone() };
            write!(h, r#"<tr><td style="padding:4px 8px;">
<div style="border-left:4px solid {C_CRIT};background:{BG_CARD};padding:4px 10px;border-radius:0 4px 4px 0;">
<span style="font-size:10px;color:{C_CRIT};font-family:{FONT};">{short}</span>
</div></td></tr>"#).unwrap();
        }
    }
    section_end(h);
}

fn render_security(h: &mut String, data: &ReportData) {
    section_start(h, "Security Events (24h)", 4);
    h.push_str("<tr>");
    for (label, align) in &[("VM","left"),("SSH OK","right"),("SSH Fail","right"),("sudo","right")] {
        write!(h, r#"<th style="text-align:{align};color:{C_DIM};font-size:11px;padding:8px;border-bottom:1px solid {BG_HEAD};font-family:{FONT};">{label}</th>"#).unwrap();
    }
    h.push_str("</tr>\n");

    for vm in &data.vms {
        let sf_color = if vm.ssh_fails > 50 { C_CRIT } else if vm.ssh_fails > 10 { C_WARN } else { C_OK };
        write!(h, "<tr>{}{}{}{}</tr>\n",
            td(&vm.name, C_TEXT, "12px", "left"),
            td(&vm.ssh_accepts.to_string(), C_OK, "12px", "right"),
            td(&vm.ssh_fails.to_string(), sf_color, "12px", "right"),
            td(&vm.sudo_count.to_string(), C_TEXT, "12px", "right"),
        ).unwrap();
    }

    let has_fails = data.vms.iter().any(|v| !v.top_fail_ips.is_empty());
    if has_fails {
        write!(h, r#"<tr><td colspan="4" style="padding:8px 8px 4px;color:{C_DIM};font-size:11px;font-family:{FONT};">Top failed IPs:</td></tr>"#).unwrap();
        for vm in &data.vms {
            for (ip, count) in &vm.top_fail_ips {
                write!(h, r#"<tr><td colspan="4" style="padding:2px 16px;color:{C_WARN};font-size:11px;font-family:{FONT};">{}: {} ({} attempts)</td></tr>"#,
                    vm.name, ip, count).unwrap();
            }
        }
    }
    section_end(h);
}

fn render_docker_disk(h: &mut String, data: &ReportData) {
    section_start(h, "Docker Disk Usage", 4);
    for vm in &data.vms {
        if vm.docker_df.is_empty() { continue; }
        write!(h, r#"<tr><td colspan="4" style="padding:6px 8px;color:{C_TEXT};font-size:12px;font-weight:bold;border-bottom:1px solid {BG_HEAD};font-family:{FONT};">{}</td></tr>"#, vm.name).unwrap();
        for df in &vm.docker_df {
            write!(h, "<tr>{}{}{}{}</tr>\n",
                td(&df.dtype, C_DIM, "11px", "left"),
                td(&df.count, C_TEXT, "11px", "right"),
                td(&df.size, C_TEXT, "11px", "right"),
                td(&format!("reclaimable: {}", df.reclaimable), C_DIM, "11px", "right"),
            ).unwrap();
        }
    }
    section_end(h);
}

fn render_wireguard(h: &mut String, data: &ReportData) {
    let has_wg = data.vms.iter().any(|v| !v.wg_peers.is_empty());
    if !has_wg { return; }

    // Build pubkey→(name, wg_ip) lookup from all VMs
    // WG peers report other VMs' pubkeys — match by cross-referencing all known VMs
    let vm_lookup: Vec<(&str, &str)> = data.vms.iter()
        .map(|v| (v.name.as_str(), v.ip.as_str()))
        .collect();

    let total_peers: usize = data.vms.iter().map(|v| v.wg_peers.len()).sum();
    section_start(h, &format!("WireGuard Mesh ({} peers across {} VMs)", total_peers, data.vms.iter().filter(|v| !v.wg_peers.is_empty()).count()), 5);
    h.push_str("<tr>");
    for (label, align) in &[("Peer","left"),("Pubkey","left"),("WG IP","left"),("Last Handshake","left"),("Status","center")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");

    let now = chrono::Utc::now().timestamp() as u64;
    for vm in &data.vms {
        if vm.wg_peers.is_empty() { continue; }
        write!(h, r#"<tr><td colspan="5" style="padding:6px 8px;color:{C_TEXT};font-size:12px;font-weight:bold;border-bottom:1px solid {BG_HEAD};font-family:{FONT};">{} (wg0 — {})</td></tr>"#, vm.name, vm.ip).unwrap();

        for (peer_key, ts) in &vm.wg_peers {
            let short_key = if peer_key.len() > 12 { format!("{}...", &peer_key[..12]) } else { peer_key.clone() };

            // Try to identify peer by matching known VM pubkeys or by position
            // For now show the peer index as name since we don't have pubkey→name in cloud-data
            let peer_name = "peer".to_string();

            let (age_str, status_badge) = if *ts == 0 {
                ("never".into(), label_badge("DEAD", C_CRIT))
            } else {
                let diff = now.saturating_sub(*ts);
                let age = if diff < 60 { format!("{}s ago", diff) }
                    else if diff < 3600 { format!("{}m ago", diff / 60) }
                    else if diff < 86400 { format!("{}h ago", diff / 3600) }
                    else { format!("{}d ago", diff / 86400) };
                let badge = if diff < 180 {
                    label_badge("LIVE", C_OK)
                } else if diff < 600 {
                    label_badge("IDLE", C_WARN)
                } else {
                    label_badge("STALE", C_CRIT)
                };
                (age, badge)
            };

            // Try to find WG IP for this peer from WG transfer data
            let wg_ip = data.vms.iter()
                .find(|other| other.name != vm.name && other.wg_transfer.iter().any(|t| t.peer == *peer_key))
                .map(|other| other.ip.as_str())
                .unwrap_or("?");

            write!(h, "<tr>{}{}{}{}<td style=\"padding:3px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);\">{status_badge}</td></tr>\n",
                td(&peer_name, C_TEXT, "11px", "left"),
                td(&short_key, C_DIM, "10px", "left"),
                td(wg_ip, C_OK, "11px", "left"),
                td(&age_str, C_TEXT, "11px", "left"),
            ).unwrap();
        }
    }
    section_end(h);

    // WG Transfer stats
    let has_transfer = data.vms.iter().any(|v| !v.wg_transfer.is_empty());
    if has_transfer {
        section_start(h, "WireGuard Transfer", 4);
        h.push_str("<tr>");
        for (label, align) in &[("VM","left"),("Peer","left"),("RX","right"),("TX","right")] {
            h.push_str(&th(label, align));
        }
        h.push_str("</tr>\n");
        for vm in &data.vms {
            for t in &vm.wg_transfer {
                let rx = human_size(t.rx_bytes);
                let tx = human_size(t.tx_bytes);
                let short_peer = if t.peer.len() > 12 { format!("{}...", &t.peer[..12]) } else { t.peer.clone() };
                write!(h, "<tr>{}{}{}{}</tr>\n",
                    td(&vm.name, C_TEXT, "11px", "left"),
                    td(&short_peer, C_DIM, "10px", "left"),
                    td(&rx, C_OK, "11px", "right"),
                    td(&tx, C_WARN, "11px", "right"),
                ).unwrap();
            }
        }
        section_end(h);
    }
}

fn render_runtime_volumes(h: &mut String, data: &ReportData) {
    let has_vols = data.vms.iter().any(|v| !v.runtime_volumes.is_empty());
    if !has_vols { return; }

    section_start(h, "Runtime Volumes (Discovered via SSH)", 4);
    h.push_str("<tr>");
    for (label, align) in &[("Volume", "left"), ("Size", "right"), ("Container", "left"), ("Mount", "left")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");

    for vm in &data.vms {
        if vm.runtime_volumes.is_empty() { continue; }
        write!(h, r#"<tr><td colspan="4" style="padding:8px 8px 2px;color:{C_TEXT};font-size:12px;font-weight:bold;border-bottom:1px solid {BG_HEAD};font-family:{FONT};">{} ({} volumes)</td></tr>"#,
            vm.name, vm.runtime_volumes.len()).unwrap();

        // Sort by size descending (larger first), treat "?" and empty as smallest
        let mut sorted: Vec<_> = vm.runtime_volumes.iter().collect();
        sorted.sort_by(|a, b| {
            let parse_size = |s: &str| -> u64 {
                let s = s.trim();
                if s.is_empty() || s == "?" { return 0; }
                let (num_str, mult) = if s.ends_with('G') { (&s[..s.len()-1], 1_073_741_824u64) }
                    else if s.ends_with('M') { (&s[..s.len()-1], 1_048_576) }
                    else if s.ends_with('K') { (&s[..s.len()-1], 1024) }
                    else { (s, 1) };
                num_str.parse::<f64>().unwrap_or(0.0) as u64 * mult
            };
            parse_size(&b.size).cmp(&parse_size(&a.size))
        });

        for v in &sorted {
            let size_color = if v.size.is_empty() || v.size == "?" { C_DIM } else { C_TEXT };
            let size_display = if v.size.is_empty() { "?" } else { &v.size };
            let ctr_color = if v.container == "(orphan)" { C_WARN } else { C_DIM };
            let short_mount = if v.mount_point.len() > 25 {
                format!("...{}", &v.mount_point[v.mount_point.len()-22..])
            } else {
                v.mount_point.clone()
            };
            write!(h, "<tr>{}{}{}{}</tr>\n",
                td(&v.name, C_TEXT, "10px", "left"),
                td(size_display, size_color, "11px", "right"),
                td(&v.container, ctr_color, "10px", "left"),
                td(&short_mount, C_DIM, "10px", "left"),
            ).unwrap();
        }
    }
    section_end(h);
}

fn render_failed_units(h: &mut String, data: &ReportData) {
    let has_failed = data.vms.iter().any(|v| !v.failed_units.is_empty());
    if !has_failed { return; }

    section_start(h, "Failed Systemd Units", 2);
    for vm in &data.vms {
        for unit in &vm.failed_units {
            write!(h, "<tr>{}{}</tr>\n",
                td(&vm.name, C_TEXT, "12px", "left"),
                td(unit, C_CRIT, "12px", "left"),
            ).unwrap();
        }
    }
    section_end(h);
}

fn render_restarts(h: &mut String, data: &ReportData) {
    let has_restarts = data.vms.iter().any(|v| !v.restarts.is_empty());
    if !has_restarts { return; }

    section_start(h, "Container Restarts (24h)", 3);
    for vm in &data.vms {
        for (name, count) in &vm.restarts {
            let color = if *count > 10 { C_CRIT } else if *count > 3 { C_WARN } else { C_OK };
            write!(h, "<tr>{}{}{}</tr>\n",
                td(&vm.name, C_TEXT, "12px", "left"),
                td(name, C_TEXT, "11px", "left"),
                td(&count.to_string(), color, "11px", "right"),
            ).unwrap();
        }
    }
    section_end(h);
}

// ── Container Drift (rewritten to use manifests) ────────────────────

fn render_container_drift(h: &mut String, data: &ReportData) {
    if data.container_drift.is_empty() { return; }

    section_start(h, "Container Drift (Manifest vs Running)", 3);
    h.push_str("<tr>");
    for (label, align) in &[("VM","left"),("Containers","left"),("Status","center")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");

    for drift in &data.container_drift {
        // Expected but not running (MISSING)
        if !drift.expected_not_running.is_empty() {
            let mut names = drift.expected_not_running.clone();
            names.sort();
            let badge = label_badge("MISSING", C_CRIT);
            write!(h, r#"<tr>
{vm_td}
{names_td}
<td style="padding:3px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);">{badge}</td>
</tr>
"#,
                vm_td = td(&drift.vm_name, C_TEXT, "11px", "left"),
                names_td = td(&names.join(", "), C_CRIT, "10px", "left"),
            ).unwrap();
        }

        // Running but not declared (UNDECLARED)
        if !drift.running_not_declared.is_empty() {
            let mut names = drift.running_not_declared.clone();
            names.sort();
            let badge = label_badge("UNDECLARED", C_WARN);
            write!(h, r#"<tr>
{vm_td}
{names_td}
<td style="padding:3px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);">{badge}</td>
</tr>
"#,
                vm_td = td(&drift.vm_name, C_TEXT, "11px", "left"),
                names_td = td(&names.join(", "), C_WARN, "10px", "left"),
            ).unwrap();
        }

        // Image mismatch
        if !drift.image_mismatch.is_empty() {
            for (ctr, running, declared) in &drift.image_mismatch {
                let badge = label_badge("MISMATCH", C_WARN);
                let detail = format!("{}: running={} declared={}", ctr, running, declared);
                write!(h, r#"<tr>
{vm_td}
{detail_td}
<td style="padding:3px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);">{badge}</td>
</tr>
"#,
                    vm_td = td(&drift.vm_name, C_TEXT, "11px", "left"),
                    detail_td = td(&detail, C_WARN, "10px", "left"),
                ).unwrap();
            }
        }
    }
    section_end(h);
}

fn render_drift(h: &mut String, data: &ReportData) {
    if data.drift.is_empty() { return; }

    section_start(h, "Storage Drift (Declared vs Runtime)", 3);
    h.push_str("<tr>");
    for (label, align) in &[("Category","left"),("Containers","left"),("Status","center")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");

    for d in &data.drift {
        if !d.declared_only.is_empty() {
            let badge = label_badge("MISSING", C_CRIT);
            write!(h, r#"<tr>
{}
{}
<td style="padding:3px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);">{badge}</td>
</tr>
"#,
                td("Declared, not running", C_TEXT, "11px", "left"),
                td(&d.declared_only.join(", "), C_CRIT, "10px", "left"),
            ).unwrap();
        }

        if !d.runtime_only.is_empty() {
            let badge = label_badge("UNDECLARED", C_WARN);
            write!(h, r#"<tr>
{}
{}
<td style="padding:3px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);">{badge}</td>
</tr>
"#,
                td("Running, not declared", C_TEXT, "11px", "left"),
                td(&d.runtime_only.join(", "), C_WARN, "10px", "left"),
            ).unwrap();
        }

        if !d.matched.is_empty() {
            let badge = label_badge("OK", C_OK);
            write!(h, r#"<tr>
{}
{}
<td style="padding:3px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);">{badge}</td>
</tr>
"#,
                td("Declared & running", C_TEXT, "11px", "left"),
                td(&d.matched.join(", "), C_OK, "10px", "left"),
            ).unwrap();
        }
    }
    section_end(h);
}

fn render_services_all_unified(h: &mut String, data: &ReportData) {
    // All enabled services — public (with domain) and internal (without)
    let mut public: Vec<_> = data.services.iter()
        .filter(|s| s.enabled && !s.domain.is_empty() && s.service_type != "mcp")
        .collect();
    let mut internal: Vec<_> = data.services.iter()
        .filter(|s| s.enabled && s.domain.is_empty() && s.service_type != "mcp" && s.service_type != "infra")
        .collect();
    public.sort_by_key(|s| &s.name);
    internal.sort_by_key(|s| &s.name);

    let total = public.len() + internal.len();
    section_start(h, &format!("All Services ({} enabled)", total), 7);
    h.push_str("<tr>");
    for (label, align) in &[("Service","left"),("Category","left"),("URL","left"),("Status","center"),("Latency","right"),("API","center"),("Web","center")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");

    // Public services
    if !public.is_empty() {
        write!(h, r#"<tr><td colspan="7" style="padding:6px 8px 2px;color:{C_DIM};font-size:10px;font-weight:bold;border-bottom:1px solid {BG_HEAD};font-family:{FONT};">Public ({} with domains)</td></tr>"#,
            public.len()).unwrap();
        for svc in &public {
            render_service_unified_row(h, svc, data);
        }
    }

    // Internal services
    if !internal.is_empty() {
        write!(h, r#"<tr><td colspan="7" style="padding:6px 8px 2px;color:{C_DIM};font-size:10px;font-weight:bold;border-bottom:1px solid {BG_HEAD};font-family:{FONT};">Internal ({} no public domain)</td></tr>"#,
            internal.len()).unwrap();
        for svc in &internal {
            render_service_unified_row(h, svc, data);
        }
    }

    section_end(h);
}

fn render_services_api_endpoints(h: &mut String, data: &ReportData) {
    // Only services with actual known API paths (exclude MCPs — they have their own table)
    let mut apis: Vec<_> = data.services.iter()
        .filter(|s| s.enabled && s.has_api && !s.api_path.is_empty() && s.service_type != "mcp")
        .collect();
    apis.sort_by_key(|s| &s.name);
    if apis.is_empty() { return; }

    section_start(h, &format!("API Endpoints ({} services)", apis.len()), 4);
    h.push_str("<tr>");
    for (label, align) in &[("Service","left"),("API Path","left"),("Full API URL","left"),("Status","center")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");

    for svc in &apis {
        let full_url = if !svc.api_url.is_empty() {
            svc.api_url.clone()
        } else if !svc.domain.is_empty() {
            format!("https://{}{}", svc.domain, svc.api_path)
        } else {
            format!("internal :{}{}", svc.port, svc.api_path)
        };
        let ep = data.endpoints.iter().find(|e| e.service == svc.name);
        let status_html = match ep {
            Some(e) => code_badge(e.status_code),
            None => label_badge("—", C_DIM),
        };
        let url_link = if full_url.starts_with("https://") {
            format!(r#"<a href="{}" style="color:{C_OK};font-size:10px;text-decoration:none;font-family:{FONT};">{}</a>"#, full_url, full_url)
        } else {
            format!(r#"<span style="color:{C_DIM};font-size:10px;font-family:{FONT};">{}</span>"#, full_url)
        };
        write!(h, r#"<tr>
{}{}
<td style="padding:3px 8px;border-bottom:1px solid rgba(15,52,96,0.3);">{url_link}</td>
<td style="padding:3px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);">{status_html}</td>
</tr>
"#,
            td(&svc.name, C_TEXT, "11px", "left"),
            td(&svc.api_path, "#FF9900", "10px", "left"),
        ).unwrap();
    }
    section_end(h);
}

fn render_services_mcps(h: &mut String, data: &ReportData) {
    if data.mcp_servers.is_empty() { return; }

    section_start(h, &format!("MCP Servers ({} configured)", data.mcp_servers.len()), 4);
    h.push_str("<tr>");
    for (label, align) in &[("Server","left"),("Command","left"),("Transport","left"),("Source","left")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");

    for mcp in &data.mcp_servers {
        let cmd_color = if mcp.command == "?" { C_WARN } else { C_OK };
        let short_source = if mcp.source_path.len() > 45 {
            format!("...{}", &mcp.source_path[mcp.source_path.len()-42..])
        } else if mcp.source_path.is_empty() {
            "(remote/docker)".into()
        } else {
            mcp.source_path.clone()
        };
        write!(h, "<tr>{}{}{}{}</tr>\n",
            td(&mcp.name, C_TEXT, "11px", "left"),
            td(&mcp.command, cmd_color, "10px", "left"),
            td(&mcp.transport, C_DIM, "10px", "left"),
            td(&short_source, C_DIM, "10px", "left"),
        ).unwrap();
    }
    section_end(h);
}

fn category_color(cat: &str) -> &'static str {
    match cat {
        "app" => "#57A6D6",
        "sec" => "#DC382D",
        "tools" | "obs" => "#F46800",
        "data" => "#4169E1",
        "fin" => "#00d68f",
        "agi" => "#C0765A",
        "cloud" => "#8899aa",
        "mic" => "#9B59B6",
        _ => C_DIM,
    }
}

fn render_service_unified_row(h: &mut String, svc: &ServiceEntry, data: &ReportData) {
    let ep = data.endpoints.iter().find(|e| e.service == svc.name);
    let cat_color = category_color(&svc.category);

    // URL column — clickable link or "internal :port"
    let url_cell = if !svc.domain.is_empty() {
        let url = if svc.domain.starts_with("http") { svc.domain.clone() } else { format!("https://{}", svc.domain) };
        let color = ep.map(|e| if e.status_code >= 200 && e.status_code < 400 { C_OK } else { C_CRIT }).unwrap_or(C_TEXT);
        format!(r#"<td style="padding:3px 8px;border-bottom:1px solid rgba(15,52,96,0.3);font-family:{FONT};"><a href="{}" style="color:{};font-size:10px;text-decoration:none;">{}</a></td>"#, url, color, svc.domain)
    } else {
        td(&format!("internal :{}", svc.port), C_DIM, "10px", "left")
    };

    // Status badge
    let status_html = match ep {
        Some(e) => code_badge(e.status_code),
        None => label_badge("—", C_DIM),
    };

    // Latency
    let latency_str = match ep {
        Some(e) => format!("{}ms", e.latency_ms),
        None => "—".into(),
    };
    let lat_color = ep
        .map(|e| if e.latency_ms < 200 { C_OK } else if e.latency_ms < 1000 { C_WARN } else { C_CRIT })
        .unwrap_or(C_DIM);

    // API column — link to api_path or check mark
    let api_cell = if svc.has_api {
        if !svc.api_path.is_empty() && !svc.domain.is_empty() {
            let api_url = format!("https://{}{}", svc.domain, svc.api_path);
            format!(r#"<td style="padding:3px 4px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);"><a href="{}" style="color:{C_OK};font-size:10px;text-decoration:none;">api</a></td>"#, api_url)
        } else {
            format!(r#"<td style="padding:3px 4px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);color:{C_OK};font-size:10px;">api</td>"#)
        }
    } else {
        format!(r#"<td style="padding:3px 4px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);color:{C_DIM};font-size:10px;">—</td>"#)
    };

    // Web UI column — link or dash
    let web_cell = if svc.has_web_ui && !svc.domain.is_empty() {
        let url = if svc.domain.starts_with("http") { svc.domain.clone() } else { format!("https://{}", svc.domain) };
        format!(r#"<td style="padding:3px 4px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);"><a href="{}" style="color:{C_OK};font-size:10px;text-decoration:none;">web</a></td>"#, url)
    } else {
        format!(r#"<td style="padding:3px 4px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);color:{C_DIM};font-size:10px;">—</td>"#)
    };

    write!(h, "<tr>{}{}{}<td style=\"padding:3px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);\">{status_html}</td>{}{}{}</tr>\n",
        td(&svc.name, C_TEXT, "11px", "left"),
        td(&svc.category, cat_color, "10px", "left"),
        url_cell,
        td(&latency_str, lat_color, "10px", "right"),
        api_cell,
        web_cell,
    ).unwrap();
}

fn render_repos(h: &mut String, data: &ReportData) {
    if data.repos.is_empty() { return; }

    let total_repo_size = data.repos.iter().map(|r| r.disk_kb).sum::<u64>();
    let total_size_str = if total_repo_size > 1048576 {
        format!("{:.1} GB", total_repo_size as f64 / 1048576.0)
    } else if total_repo_size > 1024 {
        format!("{:.0} MB", total_repo_size as f64 / 1024.0)
    } else {
        format!("{} KB", total_repo_size)
    };
    section_start(h, &format!("GitHub Repositories ({} repos — {} total)", data.repos.len(), total_size_str), 5);
    h.push_str("<tr>");
    for (label, align) in &[("Repository","left"),("Visibility","center"),("Language","left"),("Size","right"),("Updated","left")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");

    for repo in &data.repos {
        let vis_badge = match repo.visibility.as_str() {
            "PUBLIC" => label_badge("PUBLIC", C_OK),
            "PRIVATE" => label_badge("PRIVATE", C_WARN),
            _ => label_badge(&repo.visibility, C_DIM),
        };
        let size = if repo.disk_kb > 1024 {
            format!("{:.0} MB", repo.disk_kb as f64 / 1024.0)
        } else {
            format!("{} KB", repo.disk_kb)
        };
        let time = repo.updated_at.replace('T', " ").replace('Z', "");
        let time_short = if time.len() > 16 { &time[..16] } else { &time };
        write!(h, r#"<tr>
{}
<td style="padding:3px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);">{vis_badge}</td>
{}{}{}
</tr>
"#,
            td(&repo.name, C_TEXT, "11px", "left"),
            td(&repo.language, C_DIM, "10px", "left"),
            td(&size, C_DIM, "11px", "right"),
            td(time_short, C_DIM, "10px", "left"),
        ).unwrap();
    }
    section_end(h);
}

fn render_finops_vms(h: &mut String, data: &ReportData) {
    if data.vm_finops.is_empty() { return; }

    let total_cpu: u32 = data.vm_finops.iter().map(|v| v.cpu).sum();
    let total_ram: f64 = data.vm_finops.iter().map(|v| v.ram_gb).sum();
    let free_count = data.vm_finops.iter().filter(|v| v.tier == "Free").count();
    let paid_count = data.vm_finops.iter().filter(|v| v.tier != "Free").count();

    section_start(h, &format!("VM Fleet ({} VMs — {} free, {} paid — {}cpu / {:.0}GB RAM)",
        data.vm_finops.len(), free_count, paid_count, total_cpu, total_ram), 6);
    h.push_str("<tr>");
    for (label, align) in &[("VM","left"),("Provider","left"),("Tier","center"),("Shape","left"),("Specs","right"),("Workload","right")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");

    for vm in &data.vm_finops {
        let tier_color = if vm.tier == "Free" { C_OK } else { C_WARN };
        let tier_badge = label_badge(&vm.tier, tier_color);
        let specs = format!("{}cpu / {}GB", vm.cpu, vm.ram_gb);
        let workload = format!("{} svc / {} ctrs", vm.services, vm.containers);
        write!(h, r#"<tr>
{}{}
<td style="padding:3px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);">{tier_badge}</td>
{}{}{}
</tr>
"#,
            td(&vm.alias, C_TEXT, "11px", "left"),
            td(&vm.provider, C_DIM, "10px", "left"),
            td(&vm.shape, C_DIM, "10px", "left"),
            td(&specs, C_TEXT, "11px", "right"),
            td(&workload, C_DIM, "10px", "right"),
        ).unwrap();
    }
    section_end(h);
}

fn render_finops_providers(h: &mut String, data: &ReportData) {
    if data.vps_providers.is_empty() { return; }

    section_start(h, &format!("Cloud Providers ({} registered)", data.vps_providers.len()), 3);
    h.push_str("<tr>");
    for (label, align) in &[("Provider","left"),("Name","left"),("Tier","left")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");

    for vps in &data.vps_providers {
        write!(h, "<tr>{}{}{}</tr>\n",
            td(&vps.name, C_TEXT, "11px", "left"),
            td(&vps.provider, C_DIM, "10px", "left"),
            td(&vps.tier, C_DIM, "10px", "left"),
        ).unwrap();
    }
    section_end(h);
}

fn render_finops_assets(h: &mut String, data: &ReportData) {
    section_start(h, "Asset Summary", 2);

    let assets = [
        ("Virtual Machines", format!("{}", data.vm_finops.len())),
        ("Services (enabled)", format!("{}", data.total_services)),
        ("Containers (declared)", format!("{}", data.total_containers)),
        ("Public Domains", format!("{}", data.total_domains)),
        ("S3 Buckets", format!("{}", data.cloud_buckets.len())),
        ("Databases (declared)", format!("{}", data.databases.iter().filter(|d| d.enabled).count())),
        ("MCP Servers", format!("{}", data.mcp_servers.len())),
        ("GitHub Repos", format!("{}", data.repos.len())),
        ("GHCR Packages", format!("{}", data.ghcr_total)),
        ("Dagu DAGs", format!("{}", data.dags.len())),
        ("GHA Workflows", format!("{}", data.gha_runs.len())),
    ];

    for (label, value) in &assets {
        write!(h, "<tr>{}{}</tr>\n",
            td(label, C_DIM, "11px", "left"),
            td(value, C_TEXT, "12px", "right"),
        ).unwrap();
    }
    section_end(h);
}

fn render_report_metadata(h: &mut String, data: &ReportData) {
    section_start(h, "Report Metadata", 2);

    let ssh_ok = data.vms.iter().filter(|v| v.status != VmStatus::Unknown && v.containers_total > 0 || v.mem_pct > 0).count();
    let ssh_fail = data.vms.len() - ssh_ok;

    let meta = [
        ("Generated", format!("{} {}", data.date, data.time)),
        ("Duration", format!("{:.1}s", data.generation_duration_ms as f64 / 1000.0)),
        ("SSH collection", format!("{}/{} VMs responded", ssh_ok, data.vms.len())),
        ("Endpoints probed", format!("{}", data.endpoints.len())),
        ("Certs checked", format!("{}", data.certs.len())),
        ("Engine", "Rust (async tokio + reqwest + trust-dns)".into()),
    ];

    for (label, value) in &meta {
        write!(h, "<tr>{}{}</tr>\n",
            td(label, C_DIM, "11px", "left"),
            td(value, C_TEXT, "11px", "right"),
        ).unwrap();
    }
    section_end(h);
}

fn render_finops_costs(h: &mut String, data: &ReportData) {
    if data.cloud_costs.is_empty() {
        // No cost data — show free tier badge
        section_start(h, "Monthly Cloud Costs", 1);
        write!(h, r#"<tr><td style="padding:12px 16px;text-align:center;">
<span style="display:inline-block;padding:6px 16px;border-radius:6px;font-size:14px;font-weight:bold;background:{C_OK};color:{BG_BODY};font-family:{FONT};">All Free Tier — $0/mo</span>
</td></tr>"#).unwrap();
        section_end(h);
        return;
    }

    // Group costs by month
    let mut months: std::collections::BTreeMap<String, Vec<&CloudCost>> = std::collections::BTreeMap::new();
    for cost in &data.cloud_costs {
        months.entry(cost.month.clone()).or_default().push(cost);
    }

    section_start(h, &format!("Monthly Cloud Costs ({} months)", months.len()), 5);
    h.push_str("<tr>");
    for (label, align) in &[("Month","left"),("Provider","left"),("Service","left"),("Usage","right"),("Cost","right")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");

    for (month, items) in months.iter().rev() {
        let month_total: f64 = items.iter().map(|c| c.amount).sum();
        let month_usage: f64 = items.iter().map(|c| c.usage).sum();
        let currency = items.first().map(|c| c.currency.as_str()).unwrap_or("EUR");
        let total_color = if month_total > 10.0 { C_CRIT } else if month_total > 1.0 { C_WARN } else { C_OK };

        // Month header with totals
        write!(h, r#"<tr>
<td colspan="3" style="padding:6px 8px 2px;color:{C_TEXT};font-size:12px;font-weight:bold;border-bottom:1px solid {BG_HEAD};font-family:{FONT};">{month}</td>
<td style="padding:6px 8px 2px;text-align:right;color:{C_DIM};font-size:11px;border-bottom:1px solid {BG_HEAD};font-family:{FONT};">{month_usage:.0} units</td>
<td style="padding:6px 8px 2px;text-align:right;color:{total_color};font-size:12px;font-weight:bold;border-bottom:1px solid {BG_HEAD};font-family:{FONT};">{currency} {month_total:.2}</td>
</tr>"#).unwrap();

        // Sort by cost descending, then by usage
        let mut sorted: Vec<_> = items.iter().collect();
        sorted.sort_by(|a, b| {
            b.amount.partial_cmp(&a.amount)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(b.usage.partial_cmp(&a.usage).unwrap_or(std::cmp::Ordering::Equal))
        });

        for cost in sorted {
            let amt_color = if cost.amount > 5.0 { C_CRIT } else if cost.amount > 1.0 { C_WARN } else if cost.amount > 0.0 { C_TEXT } else { C_DIM };
            let cost_str = if cost.amount > 0.001 {
                format!("{} {:.2}", cost.currency, cost.amount)
            } else {
                "FREE".into()
            };
            let usage_str = if cost.usage > 1000.0 {
                format!("{:.0}", cost.usage)
            } else if cost.usage > 0.01 {
                format!("{:.2}", cost.usage)
            } else {
                "—".into()
            };
            write!(h, "<tr>{}{}{}{}{}</tr>\n",
                td("", C_DIM, "10px", "left"),
                td(&cost.provider, C_DIM, "10px", "left"),
                td(&cost.service, C_TEXT, "10px", "left"),
                td(&usage_str, C_DIM, "10px", "right"),
                td(&cost_str, amt_color, "11px", "right"),
            ).unwrap();
        }
    }
    section_end(h);
}

fn render_wg_traffic(h: &mut String, data: &ReportData) {
    let has_transfer = data.vms.iter().any(|v| !v.wg_transfer.is_empty());
    if !has_transfer { return; }

    section_start(h, "WireGuard Transfer Stats", 4);
    h.push_str("<tr>");
    for (label, align) in &[("VM","left"),("Peer","left"),("RX","right"),("TX","right")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");

    for vm in &data.vms {
        if vm.wg_transfer.is_empty() { continue; }
        for wt in &vm.wg_transfer {
            let short_peer = if wt.peer.len() > 12 {
                format!("{}...", &wt.peer[..12])
            } else {
                wt.peer.clone()
            };
            write!(h, "<tr>{}{}{}{}</tr>\n",
                td(&vm.name, C_TEXT, "11px", "left"),
                td(&short_peer, C_DIM, "10px", "left"),
                td(&human_size(wt.rx_bytes), C_OK, "11px", "right"),
                td(&human_size(wt.tx_bytes), C_OK, "11px", "right"),
            ).unwrap();
        }
    }
    section_end(h);
}

fn render_system_info(h: &mut String, data: &ReportData) {
    if data.vms.is_empty() { return; }

    section_start(h, "System Info (Kernel)", 2);
    h.push_str("<tr>");
    h.push_str(&th("VM", "left"));
    h.push_str(&th("Kernel", "left"));
    h.push_str("</tr>\n");

    // Collect all kernel versions to detect differences
    let kernels: Vec<&str> = data.vms.iter()
        .filter(|v| v.kernel != "?" && !v.kernel.is_empty())
        .map(|v| v.kernel.as_str())
        .collect();
    let all_same = kernels.windows(2).all(|w| w[0] == w[1]);

    for vm in &data.vms {
        let kern_color = if vm.kernel == "?" || vm.kernel.is_empty() {
            C_DIM
        } else if !all_same {
            C_WARN
        } else {
            C_OK
        };
        let display = if vm.kernel.is_empty() { "?" } else { &vm.kernel };
        write!(h, "<tr>{}{}</tr>\n",
            td(&vm.name, C_TEXT, "11px", "left"),
            td(display, kern_color, "11px", "left"),
        ).unwrap();
    }

    if !all_same && kernels.len() > 1 {
        write!(h, r#"<tr><td colspan="2" style="padding:4px 8px;">
<div style="border-left:4px solid {C_WARN};background:{BG_CARD};padding:4px 10px;border-radius:0 4px 4px 0;">
<span style="font-size:10px;color:{C_WARN};font-family:{FONT};">Kernel versions differ across VMs</span>
</div></td></tr>"#).unwrap();
    }

    section_end(h);
}

fn human_size(bytes: u64) -> String {
    if bytes > 1_073_741_824 {
        format!("{:.1}G", bytes as f64 / 1_073_741_824.0)
    } else if bytes > 1_048_576 {
        format!("{:.1}M", bytes as f64 / 1_048_576.0)
    } else if bytes > 1024 {
        format!("{}K", bytes / 1024)
    } else {
        format!("{}B", bytes)
    }
}

fn human_tokens(tokens: u64) -> String {
    if tokens >= 1_000_000_000 {
        format!("{:.1}B", tokens as f64 / 1_000_000_000.0)
    } else if tokens >= 1_000_000 {
        format!("{:.1}M", tokens as f64 / 1_000_000.0)
    } else if tokens >= 1_000 {
        format!("{:.1}K", tokens as f64 / 1_000.0)
    } else {
        format!("{}", tokens)
    }
}

fn model_color(model: &str) -> &'static str {
    if model.contains("opus") { "#FF9900" }     // orange for $$$ opus
    else if model.contains("sonnet") { "#57A6D6" } // blue for sonnet
    else if model.contains("haiku") { C_OK }     // green for cheap haiku
    else { C_DIM }
}

// ── G) AI Section ───────────────────────────────────────────────────

fn render_ai_section(h: &mut String, data: &ReportData) {
    let Some(ai) = &data.ai else {
        section_start(h, "AI Usage (Claude Code)", 1);
        write!(h, r#"<tr><td style="padding:12px 16px;text-align:center;color:{C_DIM};font-size:12px;font-family:{FONT};">No AI stats available (~/.claude/stats-cache.json not found)</td></tr>"#).unwrap();
        section_end(h);
        return;
    };

    // ── 1. Model Usage table ────────────────────────────────────────
    section_start(h, &format!("AI Model Usage (Est. ${:.0} total)", ai.total_cost_usd), 6);
    h.push_str("<tr>");
    for (label, align) in &[("Model","left"),("Input","right"),("Output","right"),("Cache Read","right"),("Cache Create","right"),("Est. Cost","right")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");

    for m in &ai.models {
        let mc = model_color(&m.model);
        write!(h, "<tr>{}{}{}{}{}{}</tr>\n",
            td(&m.model, mc, "12px", "left"),
            td(&human_tokens(m.input_tokens), C_TEXT, "11px", "right"),
            td(&human_tokens(m.output_tokens), C_TEXT, "11px", "right"),
            td(&human_tokens(m.cache_read_tokens), C_DIM, "11px", "right"),
            td(&human_tokens(m.cache_create_tokens), C_DIM, "11px", "right"),
            td(&format!("${:.2}", m.estimated_cost_usd), mc, "12px", "right"),
        ).unwrap();
    }
    section_end(h);

    // ── 2. Cost Breakdown with progress bars ────────────────────────
    if ai.total_cost_usd > 0.0 {
        section_start(h, "Cost Breakdown by Model", 3);
        h.push_str("<tr>");
        for (label, align) in &[("Model","left"),("Proportion","left"),("Cost","right")] {
            h.push_str(&th(label, align));
        }
        h.push_str("</tr>\n");

        for m in &ai.models {
            let pct = (m.estimated_cost_usd / ai.total_cost_usd * 100.0) as u32;
            let mc = model_color(&m.model);
            let bar = format!(
                r#"<div style="display:inline-block;background:{BG_BAR};border-radius:4px;height:14px;width:200px;vertical-align:middle;"><div style="background:{mc};border-radius:4px;height:14px;width:{pct}%;"></div></div> <span style="color:{mc};font-size:11px;font-family:{FONT};">{pct}%</span>"#
            );
            write!(h, r#"<tr>
{model_td}
<td style="padding:3px 8px;border-bottom:1px solid rgba(15,52,96,0.3);">{bar}</td>
{cost_td}
</tr>
"#,
                model_td = td(&m.model, mc, "11px", "left"),
                cost_td = td(&format!("${:.2}", m.estimated_cost_usd), mc, "11px", "right"),
            ).unwrap();
        }
        section_end(h);
    }

    // ── 3. Activity Summary ─────────────────────────────────────────
    section_start(h, "Activity Summary", 2);

    let first_date = if ai.first_session.len() >= 10 { &ai.first_session[..10] } else { &ai.first_session };
    let summary_items = [
        ("Total Sessions", format!("{}", ai.total_sessions)),
        ("Total Messages", format!("{}", ai.total_messages)),
        ("First Session", first_date.to_string()),
        ("Models Used", format!("{}", ai.models.len())),
    ];

    for (label, value) in &summary_items {
        write!(h, "<tr>{}{}</tr>\n",
            td(label, C_DIM, "11px", "left"),
            td(value, C_TEXT, "12px", "right"),
        ).unwrap();
    }
    section_end(h);

    // ── Last 7 days activity table ──────────────────────────────────
    if !ai.daily.is_empty() {
        section_start(h, "Last 7 Days Activity", 4);
        h.push_str("<tr>");
        for (label, align) in &[("Date","left"),("Messages","right"),("Sessions","right"),("Tokens","right")] {
            h.push_str(&th(label, align));
        }
        h.push_str("</tr>\n");

        for day in &ai.daily {
            let msg_color = if day.messages > 10000 { C_WARN } else { C_TEXT };
            write!(h, "<tr>{}{}{}{}</tr>\n",
                td(&day.date, C_DIM, "11px", "left"),
                td(&format!("{}", day.messages), msg_color, "11px", "right"),
                td(&format!("{}", day.sessions), C_TEXT, "11px", "right"),
                td(&human_tokens(day.tokens), C_DIM, "11px", "right"),
            ).unwrap();
        }
        section_end(h);
    }
}

// ── Section Topology Diagrams ────────────────────────────────────────

/// Helper: render a topology node box (consistent template for ALL topology boxes)
fn topo_box(color: &str, title: &str, subtitle: &str) -> String {
    format!(r#"<td style="border:2px solid {};background:{};padding:8px 12px;border-radius:6px;text-align:center;vertical-align:middle;">
<div style="color:{};font-size:11px;font-weight:bold;font-family:{};">{}</div>
<div style="color:{};font-size:9px;font-family:{};">{}</div></td>"#,
        color, BG_CARD, C_TEXT, FONT, title, C_DIM, FONT, subtitle)
}

/// Helper: render a horizontal arrow cell between boxes
fn topo_arrow(direction: &str) -> String {
    let (arrow, style) = match direction {
        "right" => ("\u{2192}", ""),
        "left" => ("\u{2190}", ""),
        "down" => ("\u{2193}", "display:block;"),
        "up" => ("\u{2191}", "display:block;"),
        "both" => ("\u{2194}", ""),
        _ => ("\u{2192}", ""),
    };
    format!(r#"<td style="color:{};font-size:18px;text-align:center;vertical-align:middle;padding:2px 6px;font-family:{};{}">{}</td>"#,
        C_OK, FONT, style, arrow)
}

/// Helper: render a vertical arrow row between rows of boxes
fn topo_arrow_row(cols: u8) -> String {
    format!(r#"<tr><td colspan="{}" style="text-align:center;color:{};font-size:18px;padding:2px 0;font-family:{};">{}</td></tr>"#,
        cols, C_OK, FONT, "\u{2193}")
}

/// Helper: render a subsection header within a topology table
fn topo_sub_header(h: &mut String, cols: u8, title: &str) {
    write!(h, r#"<tr><td colspan="{cols}" style="padding:12px 8px 4px;color:{C_DIM};font-size:11px;font-weight:bold;font-family:{FONT};">{title}</td></tr>"#).unwrap();
}

/// Helper: resolve VM status to a border color
fn vm_status_color(status: &VmStatus) -> &'static str {
    match status {
        VmStatus::Healthy => C_OK,
        VmStatus::Warning => C_WARN,
        VmStatus::Critical => C_CRIT,
        VmStatus::Unknown => C_DIM,
    }
}

// Legacy alias kept for potential external callers
#[allow(dead_code)]
fn topo_arrow_cell(arrow: &str) -> String {
    format!(r#"<td style="color:{C_OK};font-size:18px;text-align:center;vertical-align:middle;padding:2px 6px;font-family:{FONT};">{arrow}</td>"#)
}

// ── A) Container Distribution — 2x2 VM grid ────────────────────────

fn render_topo_containers(h: &mut String, data: &ReportData) {
    if data.vms.is_empty() { return; }

    section_start(h, "Container Distribution", 1);

    // Collect VMs with containers
    let active_vms: Vec<&VmData> = data.vms.iter().filter(|v| v.containers_total > 0).collect();
    if active_vms.is_empty() { section_end(h); return; }

    // 2x2 grid with arrows
    write!(h, r#"<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0">"#).unwrap();

    // Row 1: first two VMs
    h.push_str("<tr>");
    if let Some(vm) = active_vms.first() {
        let color = vm_status_color(&vm.status);
        h.push_str(&topo_box(color, &vm.name, &format!("{}/{} ctrs", vm.containers_running, vm.containers_total)));
    }
    h.push_str(&topo_arrow("both"));
    if let Some(vm) = active_vms.get(1) {
        let color = vm_status_color(&vm.status);
        h.push_str(&topo_box(color, &vm.name, &format!("{}/{} ctrs", vm.containers_running, vm.containers_total)));
    } else {
        h.push_str("<td></td>");
    }
    h.push_str("</tr>\n");

    // Vertical arrows
    if active_vms.len() > 2 {
        h.push_str(&topo_arrow_row(3));

        // Row 2: next two VMs
        h.push_str("<tr>");
        if let Some(vm) = active_vms.get(2) {
            let color = vm_status_color(&vm.status);
            h.push_str(&topo_box(color, &vm.name, &format!("{}/{} ctrs", vm.containers_running, vm.containers_total)));
        }
        if active_vms.len() > 3 {
            h.push_str(&topo_arrow("both"));
            if let Some(vm) = active_vms.get(3) {
                let color = vm_status_color(&vm.status);
                h.push_str(&topo_box(color, &vm.name, &format!("{}/{} ctrs", vm.containers_running, vm.containers_total)));
            }
        } else {
            h.push_str("<td></td><td></td>");
        }
        h.push_str("</tr>\n");
    }

    // Any remaining VMs beyond 4
    for chunk in active_vms.get(4..).unwrap_or(&[]).chunks(2) {
        h.push_str(&topo_arrow_row(3));
        h.push_str("<tr>");
        for vm in chunk {
            let color = vm_status_color(&vm.status);
            h.push_str(&topo_box(color, &vm.name, &format!("{}/{} ctrs", vm.containers_running, vm.containers_total)));
        }
        if chunk.len() < 2 { h.push_str("<td></td><td></td>"); }
        h.push_str("</tr>\n");
    }

    h.push_str("</table></td></tr>\n");
    section_end(h);
}

// ── B) Data Storage — flow diagram ──────────────────────────────────

fn render_topo_data(h: &mut String, data: &ReportData) {
    section_start(h, "Data Storage", 1);

    let bucket_count = data.cloud_buckets.len();
    let bucket_bytes: u64 = data.cloud_buckets.iter().map(|b| b.size_bytes).sum();
    let bucket_size = if bucket_bytes > 0 { human_size(bucket_bytes) } else { "?".into() };
    let total_vols: usize = data.vms.iter().map(|v| v.runtime_volumes.len()).sum();
    let db_count = data.databases.iter().filter(|d| d.enabled).count();
    let vm_count = data.vms.len();

    // Row 1: [OCI Buckets] -> [Backups] <- [VMs]
    write!(h, r#"<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0">"#).unwrap();

    h.push_str("<tr>");
    h.push_str(&topo_box("#FF9900", "OCI Buckets", &format!("{} buckets, {}", bucket_count, bucket_size)));
    h.push_str(&topo_arrow("right"));
    h.push_str(&topo_box(C_OK, "Backups", "restic + S3"));
    h.push_str(&topo_arrow("left"));
    h.push_str(&topo_box("#57A6D6", "VMs", &format!("{} nodes", vm_count)));
    h.push_str("</tr>\n");

    // Arrow down from VMs
    h.push_str(&topo_arrow_row(5));

    // Row 2: centered Docker Volumes
    h.push_str("<tr><td></td><td></td>");
    h.push_str(&topo_box("#4169E1", "Docker Volumes", &format!("{} volumes", total_vols)));
    h.push_str("<td></td><td></td></tr>\n");

    // Arrow down
    h.push_str(&topo_arrow_row(5));

    // Row 3: centered Databases
    h.push_str("<tr><td></td><td></td>");
    h.push_str(&topo_box("#DC382D", "Databases", &format!("{} declared", db_count)));
    h.push_str("<td></td><td></td></tr>\n");

    h.push_str("</table></td></tr>\n");
    section_end(h);
}

// ── C) Security Topology — 3 parts ──────────────────────────────────

fn render_topo_security(h: &mut String, data: &ReportData) {
    let certs_ok = data.certs.iter().filter(|c| c.days_left >= 7).count();
    let certs_total = data.certs.len();
    let endpoints_ok = data.endpoints.iter()
        .filter(|e| (200..=399).contains(&e.status_code) && !e.edge_fallback)
        .count();

    section_start(h, "Security Topology", 1);

    // ── Part 1: Defense in Depth (vertical chain) ───────────────────
    topo_sub_header(h, 1, "Defense in Depth");

    let layers: Vec<(&str, &str, String)> = vec![
        ("Cloudflare", "#F46800", "DDoS + CDN".into()),
        ("Caddy", C_OK, format!("TLS + {}/{} certs", certs_ok, certs_total)),
        ("Authelia", C_WARN, format!("2FA/OIDC, {}/{} OK", endpoints_ok, data.endpoints.len())),
        ("introspect", "#9B59B6", "Bearer tokens".into()),
        ("Container", "#57A6D6", format!("{} isolated", data.fleet_running)),
    ];

    write!(h, r#"<tr><td style="padding:4px 8px;">
<table width="100%" cellpadding="0" cellspacing="0">"#).unwrap();

    for (i, (name, color, desc)) in layers.iter().enumerate() {
        h.push_str("<tr>");
        h.push_str(&topo_box(color, name, desc));
        h.push_str("</tr>\n");
        if i < layers.len() - 1 {
            h.push_str(&topo_arrow_row(1));
        }
    }

    h.push_str("</table></td></tr>\n");

    // ── Part 2: Network Zones (horizontal) ──────────────────────────
    topo_sub_header(h, 1, "Network Zones");

    write!(h, r#"<tr><td style="padding:4px 8px;">
<table width="100%" cellpadding="0" cellspacing="0"><tr>"#).unwrap();
    h.push_str(&topo_box("#F46800", "Internet", "public"));
    h.push_str(&topo_arrow("right"));
    h.push_str(&topo_box(C_WARN, "DMZ: gcp-proxy", "edge"));
    h.push_str(&topo_arrow("right"));
    h.push_str(&topo_box("#9B59B6", "WG Mesh", "encrypted"));
    h.push_str(&topo_arrow("right"));
    h.push_str(&topo_box(C_OK, "Private VMs", "internal"));
    h.push_str("</tr></table></td></tr>\n");

    // ── Part 3: Auth Flows (2 horizontal rows) ──────────────────────
    topo_sub_header(h, 1, "Auth Flows");

    // Browser flow
    write!(h, r#"<tr><td style="padding:4px 8px;">
<table width="100%" cellpadding="0" cellspacing="0"><tr>"#).unwrap();
    h.push_str(&topo_box(C_TEXT, "Browser", "user"));
    h.push_str(&topo_arrow("right"));
    h.push_str(&topo_box(C_WARN, "Authelia 2FA", "TOTP"));
    h.push_str(&topo_arrow("right"));
    h.push_str(&topo_box(C_OK, "Cookie", "forward_auth"));
    h.push_str(&topo_arrow("right"));
    h.push_str(&topo_box("#57A6D6", "App", "authenticated"));
    h.push_str("</tr></table></td></tr>\n");

    // CLI flow
    write!(h, r#"<tr><td style="padding:4px 8px;">
<table width="100%" cellpadding="0" cellspacing="0"><tr>"#).unwrap();
    h.push_str(&topo_box(C_TEXT, "CLI/API", "bearer"));
    h.push_str(&topo_arrow("right"));
    h.push_str(&topo_box("#9B59B6", "OIDC Token", "JWT"));
    h.push_str(&topo_arrow("right"));
    h.push_str(&topo_box(C_OK, "introspect", "validated"));
    h.push_str(&topo_arrow("right"));
    h.push_str(&topo_box("#57A6D6", "App", "authenticated"));
    h.push_str("</tr></table></td></tr>\n");

    section_end(h);
}

// ── D) CI/CD Pipeline — box-and-arrow ───────────────────────────────

fn render_topo_cicd(h: &mut String, data: &ReportData) {
    let gha_count = data.gha_runs.len();
    let gha_ok = data.gha_runs.iter().filter(|r| r.conclusion == "success").count();
    let dag_count = data.dags.len();

    section_start(h, "CI/CD Pipeline", 1);

    // Main pipeline: [Developer] -> [GitHub] -> [GHA] -> [GHCR] -> [VMs]
    topo_sub_header(h, 1, "Deployment Pipeline");

    write!(h, r#"<tr><td style="padding:4px 8px;">
<table width="100%" cellpadding="0" cellspacing="0"><tr>"#).unwrap();
    h.push_str(&topo_box(C_TEXT, "Developer", "git push"));
    h.push_str(&topo_arrow("right"));
    h.push_str(&topo_box(C_TEXT, "GitHub", &format!("{} repos", data.repos.len())));
    h.push_str(&topo_arrow("right"));
    let gha_color = if gha_ok == gha_count && gha_count > 0 { C_OK } else if gha_ok > 0 { C_WARN } else { C_CRIT };
    h.push_str(&topo_box(gha_color, "GHA", &format!("{}/{} OK", gha_ok, gha_count)));
    h.push_str(&topo_arrow("right"));
    h.push_str(&topo_box("#9B59B6", "GHCR", &format!("{} images", data.ghcr_total)));
    h.push_str(&topo_arrow("right"));
    h.push_str(&topo_box("#57A6D6", "VMs", "docker pull"));
    h.push_str("</tr></table></td></tr>\n");

    // Orchestration sub-flow: [cloud-data-config] -> [Dagu] -> [VMs]
    topo_sub_header(h, 1, "Orchestration");

    write!(h, r#"<tr><td style="padding:4px 8px;">
<table width="100%" cellpadding="0" cellspacing="0"><tr>"#).unwrap();
    h.push_str(&topo_box(C_TEXT, "cloud-data-config", "GHA"));
    h.push_str(&topo_arrow("right"));
    h.push_str(&topo_box("#FF9900", "cloud-data", "JSON hub"));
    h.push_str(&topo_arrow("right"));
    let dag_ok = data.dags.iter().filter(|d| d.status == "success" || d.status == "done" || d.status == "finished").count();
    let dag_color = if dag_ok == dag_count && dag_count > 0 { C_OK } else if dag_ok > 0 { C_WARN } else if dag_count == 0 { C_DIM } else { C_CRIT };
    h.push_str(&topo_box(dag_color, "Dagu", &format!("{} DAGs, {}/{} OK", dag_count, dag_ok, dag_count)));
    h.push_str(&topo_arrow("right"));
    h.push_str(&topo_box("#57A6D6", "VM sync", "deploy"));
    h.push_str("</tr></table></td></tr>\n");

    section_end(h);
}

// ── E) Service Routing — full chain ─────────────────────────────────

fn render_topo_routing(h: &mut String, data: &ReportData) {
    section_start(h, "Service Routing", 1);

    // [*.diegonmarcos.com] -> [Cloudflare] -> [Caddy] -> [WireGuard] -> [Container]
    write!(h, r#"<tr><td style="padding:4px 8px;">
<table width="100%" cellpadding="0" cellspacing="0"><tr>"#).unwrap();
    h.push_str(&topo_box("#F46800", "*.diegonmarcos.com", &format!("{} domains", data.total_domains)));
    h.push_str(&topo_arrow("right"));
    h.push_str(&topo_box("#F46800", "Cloudflare", "DNS"));
    h.push_str(&topo_arrow("right"));
    h.push_str(&topo_box(C_OK, "Caddy", &format!("{} routes", data.endpoints.len())));
    h.push_str(&topo_arrow("right"));
    h.push_str(&topo_box("#9B59B6", "WireGuard", &format!("{} VMs", data.vms.len())));
    h.push_str(&topo_arrow("right"));
    h.push_str(&topo_box("#57A6D6", "Container", &format!("{} services", data.total_services)));
    h.push_str("</tr></table></td></tr>\n");

    section_end(h);
}

// ── F) Resource Map — VM boxes with specs ───────────────────────────

fn render_topo_resources(h: &mut String, data: &ReportData) {
    if data.vm_finops.is_empty() { return; }

    section_start(h, "VM Resource Map", 1);

    write!(h, r#"<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0">"#).unwrap();

    // Sort: biggest first (by CPU * RAM)
    let mut sorted: Vec<&VmFinops> = data.vm_finops.iter().collect();
    sorted.sort_by(|a, b| {
        let score_a = a.cpu as f64 * a.ram_gb;
        let score_b = b.cpu as f64 * b.ram_gb;
        score_b.partial_cmp(&score_a).unwrap_or(std::cmp::Ordering::Equal)
    });

    // Render in rows of 3
    for chunk in sorted.chunks(3) {
        h.push_str("<tr>");
        for vm in chunk {
            let tier_color = if vm.tier == "Free" { C_OK } else { C_WARN };
            let tier_label = if vm.tier == "Free" { "FREE" } else { "PAID" };
            h.push_str(&topo_box(tier_color, &vm.alias,
                &format!("{}cpu/{}GB {}", vm.cpu, vm.ram_gb, tier_label)));
        }
        for _ in chunk.len()..3 {
            h.push_str("<td></td>");
        }
        h.push_str("</tr>\n");
        // Arrow between rows if more coming
    }

    h.push_str("</table></td></tr>\n");
    section_end(h);
}

// ── G) AI Token Flow — input -> models -> costs ─────────────────────

fn render_topo_ai(h: &mut String, data: &ReportData) {
    let Some(ai) = &data.ai else { return; };
    if ai.models.is_empty() || ai.total_cost_usd <= 0.0 { return; }

    section_start(h, "AI Token Flow", 1);

    write!(h, r#"<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0">"#).unwrap();

    // Each row: [Claude Code] -> [model] -> [$cost]
    for (i, m) in ai.models.iter().enumerate() {
        let mc = model_color(&m.model);
        h.push_str("<tr>");
        // Only show source box on first row, span it vertically
        if i == 0 {
            write!(h, r#"<td rowspan="{}" style="border:2px solid {};background:{};padding:8px 12px;border-radius:6px;text-align:center;vertical-align:middle;">
<div style="color:{};font-size:11px;font-weight:bold;font-family:{};">Claude Code</div>
<div style="color:{};font-size:9px;font-family:{};">${:.2} total</div></td>"#,
                ai.models.len(), C_OK, BG_CARD, C_TEXT, FONT, C_DIM, FONT, ai.total_cost_usd).unwrap();
        }
        h.push_str(&topo_arrow("right"));
        h.push_str(&topo_box(mc, &m.model, "model"));
        h.push_str(&topo_arrow("right"));
        h.push_str(&topo_box(mc, &format!("${:.2}", m.estimated_cost_usd), "cost"));
        h.push_str("</tr>\n");
    }

    h.push_str("</table></td></tr>\n");
    section_end(h);
}

// ── I) ANALYTICS Section ─────────────────────────────────────────────

fn render_analytics_web(h: &mut String, data: &ReportData) {
    if data.umami_sites.is_empty() {
        section_start(h, "Web Analytics (Umami)", 1);
        write!(h, r#"<tr><td style="padding:12px 16px;">
<span style="display:inline-block;padding:4px 12px;border-radius:4px;font-size:11px;color:{C_DIM};background:{BG_BAR};font-family:{FONT};">Umami analytics unavailable &mdash; check connection</span>
</td></tr>"#).unwrap();
        section_end(h);
        return;
    }

    for site in &data.umami_sites {
        // Site header
        section_start(h, &format!("{} &mdash; {}", site.name, site.domain), 5);

        // MTD stats row
        let avg_time = if site.current_month.visits > 0 {
            site.current_month.total_time / site.current_month.visits
        } else {
            0
        };
        write!(h, r#"<tr>
{}{}{}{}{}
</tr>"#,
            th("Pageviews", "center"),
            th("Visitors", "center"),
            th("Visits", "center"),
            th("Bounces", "center"),
            th("Avg Time", "center"),
        ).unwrap();
        write!(h, r#"<tr>
{}{}{}{}{}
</tr>"#,
            td(&format!("{}", site.current_month.pageviews), C_TEXT, "13px", "center"),
            td(&format!("{}", site.current_month.visitors), C_OK, "13px", "center"),
            td(&format!("{}", site.current_month.visits), C_TEXT, "13px", "center"),
            td(&format!("{}", site.current_month.bounces), if site.current_month.bounces > 0 { C_WARN } else { C_TEXT }, "13px", "center"),
            td(&format!("{}s", avg_time), C_DIM, "13px", "center"),
        ).unwrap();

        // Last 6 months table
        if !site.last_6_months.is_empty() {
            write!(h, r#"<tr><td colspan="5" style="padding:8px 16px 2px;color:{C_DIM};font-size:10px;font-family:{FONT};letter-spacing:1px;">LAST 6 MONTHS</td></tr>"#).unwrap();
            write!(h, r#"<tr><td colspan="5" style="padding:0 8px;"><table width="100%" cellpadding="0" cellspacing="0">"#).unwrap();
            write!(h, "<tr>{}{}{}{}</tr>",
                th("Month", "left"),
                th("Pageviews", "right"),
                th("Visitors", "right"),
                th("Visits", "right"),
            ).unwrap();
            for (month, stats) in &site.last_6_months {
                write!(h, "<tr>{}{}{}{}</tr>",
                    td(month, C_DIM, "11px", "left"),
                    td(&format!("{}", stats.pageviews), C_TEXT, "11px", "right"),
                    td(&format!("{}", stats.visitors), C_OK, "11px", "right"),
                    td(&format!("{}", stats.visits), C_TEXT, "11px", "right"),
                ).unwrap();
            }
            h.push_str("</table></td></tr>");
        }

        // Top 10 pages
        if !site.top_pages.is_empty() {
            write!(h, r#"<tr><td colspan="5" style="padding:8px 16px 2px;color:{C_DIM};font-size:10px;font-family:{FONT};letter-spacing:1px;">TOP PAGES (MTD)</td></tr>"#).unwrap();
            write!(h, r#"<tr><td colspan="5" style="padding:0 8px;"><table width="100%" cellpadding="0" cellspacing="0">"#).unwrap();
            write!(h, "<tr>{}{}</tr>",
                th("URL", "left"),
                th("Views", "right"),
            ).unwrap();
            for (url, views) in &site.top_pages {
                write!(h, "<tr>{}{}</tr>",
                    td(url, C_TEXT, "11px", "left"),
                    td(&format!("{}", views), C_OK, "11px", "right"),
                ).unwrap();
            }
            h.push_str("</table></td></tr>");
        }

        section_end(h);
    }
}

fn render_matomo_comparison(h: &mut String, data: &ReportData) {
    if data.matomo_sites.is_empty() {
        section_start(h, "Matomo Analytics (comparison source)", 1);
        write!(h, r#"<tr><td style="padding:12px 16px;">
<span style="color:{C_WARN};font-size:12px;font-family:{FONT};">Matomo data unavailable — check SSH to oci-apps / matomo-hybrid container</span>
</td></tr>"#).unwrap();
        section_end(h);
        return;
    }

    for site in &data.matomo_sites {
        section_start(h, &format!("Matomo — {} ({} visits, {} pageviews total)", site.name, site.total_visits, site.total_pageviews), 1);

        // Monthly breakdown
        if !site.monthly.is_empty() {
            h.push_str("<tr><td style=\"padding:8px;\"><table width=\"100%\" cellpadding=\"0\" cellspacing=\"0\">");
            h.push_str("<tr>");
            for (label, align) in &[("Month","left"),("Visits","right"),("Pageviews","right")] {
                h.push_str(&th(label, align));
            }

            // If Umami data exists, add comparison columns
            let umami = data.umami_sites.first();
            if umami.is_some() {
                h.push_str(&th("Umami PV", "right"));
                h.push_str(&th("Match %", "right"));
            }
            h.push_str("</tr>\n");

            for m in &site.monthly {
                let umami_pv = umami.and_then(|u| {
                    u.last_6_months.iter().find(|(label, _)| label == &m.month).map(|(_, s)| s.pageviews)
                }).or_else(|| {
                    // Check current month
                    umami.and_then(|u| {
                        let now = chrono::Utc::now();
                        let current = format!("{:04}-{:02}", now.year(), now.month());
                        if m.month == current { Some(u.current_month.pageviews) } else { None }
                    })
                });

                write!(h, "<tr>{}{}{}",
                    td(&m.month, C_TEXT, "11px", "left"),
                    td(&m.visits.to_string(), C_TEXT, "11px", "right"),
                    td(&m.pageviews.to_string(), C_TEXT, "11px", "right"),
                ).unwrap();

                if umami.is_some() {
                    match umami_pv {
                        Some(upv) => {
                            let pct = if m.pageviews > 0 { (upv as f64 / m.pageviews as f64 * 100.0) as u64 } else { 0 };
                            let color = if pct >= 90 { C_OK } else if pct >= 50 { C_WARN } else { C_CRIT };
                            write!(h, "{}{}",
                                td(&upv.to_string(), C_DIM, "11px", "right"),
                                td(&format!("{}%", pct), color, "11px", "right"),
                            ).unwrap();
                        }
                        None => {
                            write!(h, "{}{}", td("—", C_DIM, "11px", "right"), td("—", C_DIM, "11px", "right")).unwrap();
                        }
                    }
                }
                h.push_str("</tr>\n");
            }

            // Totals row
            let total_v: u64 = site.monthly.iter().map(|m| m.visits).sum();
            let total_pv: u64 = site.monthly.iter().map(|m| m.pageviews).sum();
            write!(h, r#"<tr><td style="padding:3px 8px;font-weight:bold;color:{C_TEXT};font-size:11px;border-top:2px solid {BG_HEAD};font-family:{FONT};">TOTAL</td>"#).unwrap();
            write!(h, r#"<td style="padding:3px 8px;font-weight:bold;color:{C_TEXT};font-size:11px;text-align:right;border-top:2px solid {BG_HEAD};font-family:{FONT};">{}</td>"#, total_v).unwrap();
            write!(h, r#"<td style="padding:3px 8px;font-weight:bold;color:{C_TEXT};font-size:11px;text-align:right;border-top:2px solid {BG_HEAD};font-family:{FONT};">{}</td>"#, total_pv).unwrap();
            if umami.is_some() {
                let umami_total: u64 = data.umami_sites.first().map(|u| {
                    u.last_6_months.iter().map(|(_, s)| s.pageviews).sum::<u64>() + u.current_month.pageviews
                }).unwrap_or(0);
                let pct = if total_pv > 0 { (umami_total as f64 / total_pv as f64 * 100.0) as u64 } else { 0 };
                let color = if pct >= 90 { C_OK } else if pct >= 50 { C_WARN } else { C_CRIT };
                write!(h, r#"<td style="padding:3px 8px;font-weight:bold;color:{C_DIM};font-size:11px;text-align:right;border-top:2px solid {BG_HEAD};font-family:{FONT};">{}</td>"#, umami_total).unwrap();
                write!(h, r#"<td style="padding:3px 8px;font-weight:bold;color:{color};font-size:11px;text-align:right;border-top:2px solid {BG_HEAD};font-family:{FONT};">{}%</td>"#, pct).unwrap();
            }
            h.push_str("</tr>");

            h.push_str("</table></td></tr>");
        }
        section_end(h);
    }
}

fn render_analytics_containers(h: &mut String, data: &ReportData) {
    if data.container_cpu_ranking.is_empty() {
        return;
    }

    section_start(h, &format!("Container Resource Usage ({} containers by CPU*h)", data.container_cpu_ranking.len()), 9);
    write!(h, r#"<tr><td colspan="9" style="padding:4px 8px;color:{C_DIM};font-size:10px;font-family:{FONT};border-bottom:1px solid {BG_HEAD};">CPU*h = (CPU% / 100) &times; uptime since container start &mdash; snapshot metric, not a fixed 24h window</td></tr>"#).unwrap();

    write!(h, "<tr>{}{}{}{}{}{}{}{}{}</tr>",
        th("#", "center"),
        th("CPU*h", "right"),
        th("MEM*GB*h", "right"),
        th("Container", "left"),
        th("VM", "left"),
        th("CPU %", "right"),
        th("Mem Usage", "right"),
        th("Mem %", "right"),
        th("Uptime", "right"),
    ).unwrap();

    for entry in &data.container_cpu_ranking {
        let cpu_num: f64 = entry.cpu_pct.trim_end_matches('%').trim().parse().unwrap_or(0.0);
        let cpu_color = if cpu_num > 5.0 { C_CRIT } else if cpu_num > 1.0 { C_WARN } else { C_OK };
        let cpuh_color = if entry.cpu_hours > 100.0 { C_CRIT } else if entry.cpu_hours > 10.0 { C_WARN } else { C_OK };
        let memh_color = if entry.mem_gb_hours > 50.0 { C_WARN } else { C_TEXT };

        let uptime_str = if entry.uptime_hours >= 24.0 {
            format!("{:.0}d", entry.uptime_hours / 24.0)
        } else {
            format!("{:.1}h", entry.uptime_hours)
        };

        write!(h, "<tr>{}{}{}{}{}{}{}{}{}</tr>",
            td(&format!("{}", entry.rank), C_DIM, "11px", "center"),
            td(&format!("{:.1}", entry.cpu_hours), cpuh_color, "11px", "right"),
            td(&format!("{:.1}", entry.mem_gb_hours), memh_color, "11px", "right"),
            td(&entry.container, C_TEXT, "11px", "left"),
            td(&entry.vm, C_DIM, "11px", "left"),
            td(&entry.cpu_pct, cpu_color, "11px", "right"),
            td(&entry.mem_usage, C_TEXT, "11px", "right"),
            td(&entry.mem_pct, C_DIM, "11px", "right"),
            td(&uptime_str, C_DIM, "11px", "right"),
        ).unwrap();
    }

    section_end(h);
}

// ── Firewall 3-Layer Tables (B0 Security) ────────────────────────────

fn render_firewall_summary(h: &mut String, data: &ReportData) {
    if data.firewalls.is_empty() { return; }

    // ── Global Firewall Policy ──
    let gfw = &data.global_firewall;
    section_start(h, "Global Firewall Policy", 2);
    for (label, val) in &[
        ("Forward Policy", gfw.forward_policy.as_str()),
        ("Docker iptables", if gfw.docker_iptables { "ENABLED" } else { "DISABLED" }),
        ("Docker Subnet", gfw.docker_subnet.as_str()),
        ("WireGuard Subnet", gfw.wg_subnet.as_str()),
    ] {
        let color = if *label == "Forward Policy" && *val == "DROP" { C_OK }
            else if *label == "Docker iptables" && *val == "ENABLED" { C_WARN }
            else { C_TEXT };
        write!(h, "<tr>{}{}</tr>\n", td(label, C_DIM, "12px", "left"), td(val, color, "12px", "left")).unwrap();
    }
    section_end(h);

    // ── Layer 1: VPS/Terraform (cloud provider firewall) ──
    section_start(h, "Layer 1 — VPS / Terraform (Cloud Provider Firewall)", 3);
    h.push_str("<tr>");
    for (label, align) in &[("VM","left"),("Public Ports (Terraform)","left"),("Exposure","center")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");
    for fw in &data.firewalls {
        let pub_ports = if fw.public_ports.is_empty() { "none (WG-only)".to_string() }
        else {
            fw.public_ports.iter().map(|p| format!("{}/{}", p.port, p.proto)).collect::<Vec<_>>().join(", ")
        };
        let (badge_label, badge_color) = if fw.public_ports.is_empty() { ("WG-ONLY", C_OK) }
            else if fw.public_ports.len() < 5 { ("LOW", C_OK) }
            else if fw.public_ports.len() < 10 { ("MEDIUM", C_WARN) }
            else { ("HIGH", C_CRIT) };
        write!(h, "<tr>{}{}<td style=\"padding:3px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);\">{}</td></tr>\n",
            td(&fw.vm_name, C_TEXT, "12px", "left"),
            td(&pub_ports, C_DIM, "10px", "left"),
            label_badge(badge_label, badge_color),
        ).unwrap();
    }
    section_end(h);

    // ── Layer 2: OS / Home-Manager (nftables/iptables) ──
    section_start(h, "Layer 2 — OS / Home-Manager (nftables/iptables)", 3);
    h.push_str("<tr>");
    for (label, align) in &[("VM","left"),("OS Rules (nftables)","left"),("Count","right")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");
    for fw in &data.firewalls {
        let os_ports = if fw.os_rules.is_empty() { "none".to_string() }
        else {
            fw.os_rules.iter().map(|r| format!("{}/{}", r.port, r.proto)).collect::<Vec<_>>().join(", ")
        };
        write!(h, "<tr>{}{}{}</tr>\n",
            td(&fw.vm_name, C_TEXT, "12px", "left"),
            td(&os_ports, C_DIM, "10px", "left"),
            td(&fw.os_rules.len().to_string(), C_TEXT, "11px", "right"),
        ).unwrap();
    }
    section_end(h);

    // ── Layer 3: Container Port Bindings ──
    section_start(h, "Layer 3 — Container Port Bindings (docker-compose)", 3);
    h.push_str("<tr>");
    for (label, align) in &[("VM","left"),("Service : Port","left"),("Count","right")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");
    // Group services by VM
    let mut vm_svc_ports: std::collections::HashMap<String, Vec<String>> = std::collections::HashMap::new();
    for svc in &data.services {
        if svc.enabled && svc.port > 0 {
            vm_svc_ports.entry(svc.vm.clone()).or_default().push(format!("{}:{}", svc.name, svc.port));
        }
    }
    let mut vm_keys: Vec<&String> = vm_svc_ports.keys().collect();
    vm_keys.sort();
    for vm in vm_keys {
        let ports = &vm_svc_ports[vm];
        write!(h, "<tr>{}{}{}</tr>\n",
            td(vm, C_TEXT, "12px", "left"),
            td(&ports.join(", "), C_DIM, "10px", "left"),
            td(&ports.len().to_string(), C_TEXT, "11px", "right"),
        ).unwrap();
    }
    section_end(h);

    // ── Final: Real Port Exposure per VM (3-layer comparison) ──
    section_start(h, "Port Exposure Summary (3-Layer Comparison)", 5);
    h.push_str("<tr>");
    for (label, align) in &[("VM","left"),("L1 Terraform","right"),("L2 OS","right"),("L3 Container","right"),("Drift","center")] {
        h.push_str(&th(label, align));
    }
    h.push_str("</tr>\n");
    for fw in &data.firewalls {
        let l1 = fw.public_ports.len();
        let l2 = fw.os_rules.len();
        let l3 = vm_svc_ports.get(&fw.vm_name).map(|v| v.len()).unwrap_or(0);
        // Drift: L1 should match L2, L3 is internal — flag if L1 != L2
        let (drift_label, drift_color) = if l1 == 0 && l2 == 0 {
            ("WG-ONLY", C_OK)
        } else if l1 == l2 {
            ("MATCH", C_OK)
        } else {
            ("DRIFT", C_CRIT)
        };
        write!(h, "<tr>{}{}{}{}<td style=\"padding:3px 8px;text-align:center;border-bottom:1px solid rgba(15,52,96,0.3);\">{}</td></tr>\n",
            td(&fw.vm_name, C_TEXT, "12px", "left"),
            td(&l1.to_string(), C_TEXT, "11px", "right"),
            td(&l2.to_string(), C_TEXT, "11px", "right"),
            td(&l3.to_string(), C_DIM, "11px", "right"),
            label_badge(drift_label, drift_color),
        ).unwrap();
    }
    section_end(h);
}

// ── Port Layers Diagram (Topology section) ──────────────────────────

fn render_topo_port_layers(h: &mut String, data: &ReportData) {
    if data.firewalls.is_empty() { return; }

    topo_sub_header(h, 1, "PORT LAYERS");

    // Build per-VM summary strings
    let vm_summaries: Vec<String> = data.firewalls.iter().map(|fw| {
        if fw.wg_only {
            format!("{}: WG-ONLY", fw.vm_name)
        } else {
            format!("{}: {} public", fw.vm_name, fw.public_ports.len())
        }
    }).collect();
    let vm_line = vm_summaries.join(" | ");

    let layer_box = |color: &str, title: &str, subtitle: &str| -> String {
        format!(r#"<div style="border:2px solid {};background:{};padding:10px 16px;border-radius:6px;text-align:center;margin:2px 8px;">
<div style="color:{};font-size:12px;font-weight:bold;font-family:{};">{}</div>
<div style="color:{};font-size:10px;font-family:{};">{}</div></div>"#,
            color, BG_CARD, C_TEXT, FONT, title, C_DIM, FONT, subtitle)
    };

    let arrow_down = format!(
        r#"<div style="text-align:center;color:{};font-size:20px;padding:2px 0;font-family:{};">{}</div>"#,
        C_OK, FONT, "\u{2193}"
    );

    write!(h, r#"<tr><td style="padding:8px;">"#).unwrap();
    h.push_str(&layer_box("#F46800", "Layer 1: Cloudflare", "DNS + CDN + DDoS protection"));
    h.push_str(&arrow_down);
    h.push_str(&layer_box(C_WARN, "Layer 2: Cloud Firewalls", &vm_line));
    h.push_str(&arrow_down);
    h.push_str(&layer_box(C_OK, "Layer 3: WireGuard", &format!("{} encrypted mesh", data.global_firewall.wg_subnet)));
    h.push_str(&arrow_down);
    h.push_str(&layer_box("#57A6D6", "Layer 4: Docker", &format!("{}, forward={}", data.global_firewall.docker_subnet, data.global_firewall.forward_policy)));
    h.push_str("</td></tr>\n");
}

// ── J) TOPOLOGY Section (5 infrastructure maps) ─────────────────────

fn render_topology(h: &mut String, data: &ReportData, mode: OutputMode) {
    section_start(h, "Infrastructure Topology", 1);

    match mode {
        OutputMode::Web => {
            // 1. NETWORK
            topo_topic_header(h, "1. NETWORK");
            embed_diagram(h, "WireGuard Mesh", "graphviz", &crate::diagrams::wireguard_mesh_dot(data));
            embed_diagram(h, "Traffic Flow", "mermaid", &mermaid_to_div(&crate::mermaid::traffic_flow(data)));
            embed_diagram(h, "DNS Resolution", "pikchr", &crate::diagrams::dns_chain_pikchr(data));

            // 2. SECURITY
            topo_topic_header(h, "2. SECURITY");
            embed_diagram(h, "Full Security Stack", "d2", &crate::diagrams::security_layers_d2(data));
            embed_diagram(h, "Auth Flow (OIDC)", "plantuml", &crate::diagrams::auth_flow_plantuml(data));
            embed_diagram(h, "Network Zones", "mermaid", &mermaid_to_div(&crate::mermaid::network_zones(data)));
            render_topo_port_layers(h, data);

            // 3. COMPUTE
            topo_topic_header(h, "3. COMPUTE");
            embed_diagram(h, "Container Distribution", "graphviz", &crate::diagrams::container_distribution_dot(data));
            embed_diagram(h, "VM Resources", "d2", &crate::diagrams::vm_resource_d2(data));
            embed_diagram(h, "Provider Map", "graphviz", &crate::diagrams::provider_map_dot(data));

            // 4. DATA
            topo_topic_header(h, "4. DATA");
            embed_diagram(h, "Data Flow", "plantuml", &crate::diagrams::data_flow_plantuml(data));
            embed_diagram(h, "Storage Map", "d2", &crate::diagrams::storage_map_d2(data));
            embed_diagram(h, "Backup Pipeline", "plantuml", &crate::diagrams::backup_flow_plantuml(data));

            // 5. SERVICES
            topo_topic_header(h, "5. SERVICES");
            embed_diagram(h, "Service Mesh", "graphviz", &crate::diagrams::service_mesh_dot(data));
            embed_diagram(h, "Service Categories", "mermaid", &mermaid_to_div(&crate::mermaid::service_categories(data)));

            // 6. WORKFLOWS
            topo_topic_header(h, "6. WORKFLOWS");
            embed_diagram(h, "CI/CD Pipeline", "d2", &crate::diagrams::cicd_pipeline_d2(data));

            // 7. AI
            topo_topic_header(h, "7. AI");
            embed_diagram(h, "Model Usage", "mermaid", &mermaid_to_div(&crate::mermaid::ai_models(data)));
        }
        OutputMode::Email => {
            // CSS fallback diagrams for email clients
            render_topo_i_wireguard(h, data);
            render_topo_i_traffic_flow(h, data);
            render_topo_port_layers(h, data);
            render_topo_i_service_categories(h, data);
            render_topo_i_storage_overview(h, data);
            render_topo_i_provider_map(h, data);
        }
    }

    section_end(h);
}

// ── I.1 WireGuard Mesh — 3x3 grid ──────────────────────────────────

fn render_topo_i_wireguard(h: &mut String, data: &ReportData) {
    if data.vms.is_empty() { return; }

    topo_sub_header(h, 1, "1. WIREGUARD MESH");

    let find_vm = |name: &str| -> Option<&VmData> {
        data.vms.iter().find(|v| v.name == name)
    };

    let vm_box = |name: &str, ip: &str| -> String {
        if let Some(vm) = data.vms.iter().find(|v| v.name.to_lowercase() == name.to_lowercase()) {
            let color = vm_status_color(&vm.status);
            topo_box(color, &vm.name, &format!("{} | {} ctrs", vm.ip, vm.containers_running))
        } else {
            topo_box(C_DIM, name, &format!("{} | offline", ip))
        }
    };

    write!(h, r#"<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0">"#).unwrap();

    // Row 1: [empty] [oci-mail] [oci-analytics]
    h.push_str("<tr><td></td>");
    h.push_str(&vm_box("oci-mail", "10.0.0.3"));
    h.push_str(&vm_box("oci-analytics", "10.0.0.4"));
    h.push_str("</tr>\n");

    // Arrow row
    write!(h, r#"<tr><td></td><td style="text-align:center;color:{};font-size:18px;padding:2px 0;font-family:{};">{}</td><td style="text-align:center;color:{};font-size:18px;padding:2px 0;font-family:{};">{}</td></tr>"#,
        C_OK, FONT, "\u{2195}", C_OK, FONT, "\u{2195}").unwrap();

    // Row 2: [Surface] <-> [GCP-PROXY hub] <-> [oci-apps]
    h.push_str("<tr>");
    h.push_str(&vm_box("Surface", "10.0.0.2"));
    // Hub box (special styling)
    if let Some(hub) = find_vm("gcp-proxy") {
        let hub_color = vm_status_color(&hub.status);
        write!(h, r#"<td style="border:3px solid {};background:{};padding:8px 12px;border-radius:6px;text-align:center;vertical-align:middle;">
<div style="color:{};font-size:12px;font-weight:bold;font-family:{};">GCP-PROXY</div>
<div style="color:{};font-size:9px;font-family:{};">{} | {} ctrs | HUB</div></td>"#,
            hub_color, BG_HEAD, C_TEXT, FONT, C_DIM, FONT, hub.ip, hub.containers_running).unwrap();
    } else {
        write!(h, r#"<td style="border:3px solid {};background:{};padding:8px 12px;border-radius:6px;text-align:center;vertical-align:middle;">
<div style="color:{};font-size:12px;font-weight:bold;font-family:{};">GCP-PROXY</div>
<div style="color:{};font-size:9px;font-family:{};">10.0.0.1 | HUB</div></td>"#,
            C_DIM, BG_HEAD, C_TEXT, FONT, C_DIM, FONT).unwrap();
    }
    h.push_str(&vm_box("oci-apps", "10.0.0.6"));
    h.push_str("</tr>\n");

    // Arrow row
    write!(h, r#"<tr><td></td><td style="text-align:center;color:{};font-size:18px;padding:2px 0;font-family:{};">{}</td><td style="text-align:center;color:{};font-size:18px;padding:2px 0;font-family:{};">{}</td></tr>"#,
        C_OK, FONT, "\u{2195}", C_OK, FONT, "\u{2195}").unwrap();

    // Row 3: [Termux] [gcp-t4] [empty]
    h.push_str("<tr>");
    h.push_str(&vm_box("Termux", "10.0.0.9"));
    h.push_str(&vm_box("gcp-t4", "10.0.0.8"));
    h.push_str("<td></td></tr>\n");

    h.push_str("</table></td></tr>\n");
}

// ── I.2 Full Traffic Flow — 6 boxes in a row ────────────────────────

fn render_topo_i_traffic_flow(h: &mut String, data: &ReportData) {
    topo_sub_header(h, 1, "2. FULL TRAFFIC FLOW");

    let caddy_ip = data.vms.iter()
        .find(|v| v.name == "gcp-proxy")
        .map(|v| v.ip.as_str())
        .unwrap_or("10.0.0.1");

    write!(h, r#"<tr><td style="padding:8px;">
<table width="100%" cellpadding="0" cellspacing="0"><tr>"#).unwrap();

    let boxes: &[(&str, &str, &str)] = &[
        ("User", "browser/CLI", C_TEXT),
        ("Cloudflare", "DNS + WAF", "#F46800"),
        ("Caddy", &format!(":443 | {}", caddy_ip), C_OK),
        ("WireGuard", "10.0.0.0/24", "#9B59B6"),
        ("VM", &format!("{} nodes", data.vms.len()), "#57A6D6"),
        ("Container", &format!("{}/{}", data.fleet_running, data.fleet_total), C_OK),
    ];

    for (i, (title, sub, color)) in boxes.iter().enumerate() {
        if i > 0 {
            h.push_str(&topo_arrow("right"));
        }
        h.push_str(&topo_box(color, title, sub));
    }

    h.push_str("</tr></table></td></tr>\n");
}

// ── I.3 Service Category Map — colored boxes ────────────────────────

fn render_topo_i_service_categories(h: &mut String, data: &ReportData) {
    topo_sub_header(h, 1, "3. SERVICE CATEGORY MAP");

    let cat_counts: Vec<(String, usize)> = {
        let mut map: std::collections::BTreeMap<String, usize> = std::collections::BTreeMap::new();
        for svc in data.services.iter().filter(|s| s.enabled) {
            *map.entry(svc.category.clone()).or_default() += 1;
        }
        let mut v: Vec<_> = map.into_iter().collect();
        v.sort_by(|a, b| b.1.cmp(&a.1));
        v
    };

    if cat_counts.is_empty() { return; }

    // Render as boxes in a row (wrapping in chunks of 4)
    for chunk in cat_counts.chunks(4) {
        write!(h, r#"<tr><td style="padding:4px 8px;">
<table width="100%" cellpadding="0" cellspacing="4"><tr>"#).unwrap();

        for (cat, count) in chunk {
            let color = category_color(cat);
            // Scale padding proportional to count for visual sizing
            let pad = 6 + count * 2;
            let pad = if pad > 20 { 20 } else { pad };
            write!(h, r#"<td style="border:2px solid {};background:{};padding:{}px 12px;border-radius:6px;text-align:center;vertical-align:middle;">
<div style="color:{};font-size:11px;font-weight:bold;font-family:{};">{}: {}</div></td>"#,
                color, BG_CARD, pad, C_TEXT, FONT, cat, count).unwrap();
        }

        h.push_str("</tr></table></td></tr>\n");
    }
}

// ── I.4 Storage Overview — 4 boxes with arrows ──────────────────────

fn render_topo_i_storage_overview(h: &mut String, data: &ReportData) {
    topo_sub_header(h, 1, "4. STORAGE OVERVIEW");

    let total_vols: usize = data.vms.iter().map(|v| v.runtime_volumes.len()).sum();
    let db_count = data.databases.iter().filter(|d| d.enabled).count();

    let ghcr_disk = if data.github_disk_kb > 1048576 {
        format!("{:.1}GB", data.github_disk_kb as f64 / 1048576.0)
    } else if data.github_disk_kb > 1024 {
        format!("{:.0}MB", data.github_disk_kb as f64 / 1024.0)
    } else if data.github_disk_kb > 0 {
        format!("{}KB", data.github_disk_kb)
    } else {
        "?".into()
    };

    write!(h, r#"<tr><td style="padding:4px 8px;">
<table width="100%" cellpadding="0" cellspacing="0"><tr>"#).unwrap();

    h.push_str(&topo_box("#FF9900", "OCI S3", &format!("{} buckets", data.cloud_buckets.len())));
    h.push_str(&topo_arrow("right"));
    h.push_str(&topo_box("#9B59B6", "GHCR", &format!("{} imgs, {}", data.ghcr_total, ghcr_disk)));
    h.push_str(&topo_arrow("right"));
    h.push_str(&topo_box("#4169E1", "Volumes", &format!("{} vols", total_vols)));
    h.push_str(&topo_arrow("right"));
    h.push_str(&topo_box("#DC382D", "DBs", &format!("{} declared", db_count)));

    h.push_str("</tr></table></td></tr>\n");
}

// ── I.5 Provider Map — grouped VM boxes ─────────────────────────────

fn render_topo_i_provider_map(h: &mut String, data: &ReportData) {
    if data.vm_finops.is_empty() { return; }

    topo_sub_header(h, 1, "5. PROVIDER MAP");

    // Group VMs by provider+tier
    let mut groups: std::collections::BTreeMap<String, Vec<&VmFinops>> = std::collections::BTreeMap::new();
    for vm in &data.vm_finops {
        let key = format!("{} {}", vm.provider, vm.tier);
        groups.entry(key).or_default().push(vm);
    }

    write!(h, r#"<tr><td style="padding:4px 8px;">
<table width="100%" cellpadding="0" cellspacing="0">"#).unwrap();

    let group_vec: Vec<_> = groups.iter().collect();
    for (i, (key, vms)) in group_vec.iter().enumerate() {
        if i > 0 && i % 2 == 0 {
            // New row every 2 groups
            h.push_str("</tr>\n<tr>");
        } else if i == 0 {
            h.push_str("<tr>");
        }

        let tier_color = if key.contains("Free") { C_OK } else { C_WARN };
        let vm_names: Vec<String> = vms.iter().map(|v| v.alias.clone()).collect();
        let subtitle = vm_names.join(", ");
        h.push_str(&topo_box(tier_color, &format!("{}: {} VMs", key, vms.len()), &subtitle));

        if i < group_vec.len() - 1 && (i + 1) % 2 != 0 {
            h.push_str(&topo_arrow("both"));
        }
    }
    h.push_str("</tr>\n");

    h.push_str("</table></td></tr>\n");
}

// ── Appendix — consolidated Z.N subsections ─────────────────────────
//
// NO SIMPLIFICATION, NO SHRINKING. Every section from cloud_health_full.md +
// cloud_mail_full.md is rendered as its own Z.N block with the FULL body
// preserved verbatim inside a <pre>. Nothing is collapsed.

fn escape_html(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

fn z_anchor(number: &str) -> String {
    number.replace('.', "-").to_ascii_lowercase()
}

#[derive(Debug, Clone)]
struct AppendixSectionParsed {
    number: String,
    title: String,
    source: String,
    body: String,
}

/// Reverse of `appendix::to_markdown()`. Splits on `## Z.` markers.
/// Produced format:
///     \n## Z.N — Title\n\n_Source: `origin`_\n\n<body>\n---\n
fn parse_appendix_back(md: &str) -> Vec<AppendixSectionParsed> {
    let mut out: Vec<AppendixSectionParsed> = Vec::new();
    let marker = "## Z.";
    let mut rest = md;
    if let Some(pos) = rest.find(marker) {
        rest = &rest[pos..];
    } else {
        return out;
    }
    while !rest.is_empty() {
        let after_current = rest.get(marker.len()..).unwrap_or("");
        let next_rel = after_current.find(&format!("\n{}", marker));
        let (chunk, remaining) = match next_rel {
            Some(off) => {
                let end = marker.len() + off;
                (&rest[..end], &rest[end + 1..])
            }
            None => (rest, ""),
        };
        if let Some(parsed) = parse_one_section(chunk) {
            out.push(parsed);
        }
        rest = remaining;
    }
    out
}

fn parse_one_section(chunk: &str) -> Option<AppendixSectionParsed> {
    let mut lines = chunk.lines();
    let header = lines.next()?;
    let header = header.trim_start_matches("## ");
    let (number, title) = match header.find(" — ") {
        Some(i) => (header[..i].to_string(), header[i + 5..].to_string()),
        None => (header.to_string(), String::new()),
    };

    let mut source = String::new();
    let mut body_lines: Vec<&str> = Vec::new();
    let mut saw_source = false;
    for line in lines {
        if !saw_source {
            if line.trim().is_empty() {
                continue;
            }
            if let Some(rest) = line.strip_prefix("_Source: `") {
                if let Some(src) = rest.strip_suffix("`_") {
                    source = src.to_string();
                    saw_source = true;
                    continue;
                }
            }
            body_lines.push(line);
            saw_source = true;
            continue;
        }
        body_lines.push(line);
    }

    while let Some(last) = body_lines.last() {
        if last.trim() == "---" || last.trim().is_empty() {
            body_lines.pop();
        } else {
            break;
        }
    }
    while let Some(first) = body_lines.first() {
        if first.trim().is_empty() {
            body_lines.remove(0);
        } else {
            break;
        }
    }

    let body = body_lines.join("\n");
    Some(AppendixSectionParsed {
        number,
        title,
        source,
        body,
    })
}

fn render_appendix(h: &mut String, data: &ReportData) {
    if data.appendix_md.trim().is_empty() {
        return;
    }
    let sections = parse_appendix_back(&data.appendix_md);

    section_title(h, "Z", "Appendix — Consolidated Sub-Reports");

    // Index row listing every Z.N subsection as anchored links.
    write!(
        h,
        r#"<tr><td style="padding:8px 12px;">
<div style="background:{BG_CARD};border:1px solid {BG_HEAD};border-radius:8px;padding:10px 14px;">
<p style="color:{C_TEXT};font-family:{FONT};font-size:12px;margin:0 0 6px 0;">
<strong style="color:{C_OK};">{n} consolidated subsections</strong> — parsed from
<code style="color:{C_WARN};">cloud_health_full.md</code> + <code style="color:{C_WARN};">cloud_mail_full.md</code>. Every section preserved verbatim.
</p>
<ul style="color:{C_DIM};font-family:{FONT};font-size:11px;margin:0;padding-left:20px;columns:2;">"#,
        n = sections.len(),
    )
    .unwrap();
    for s in &sections {
        write!(
            h,
            r##"<li><a href="#{anchor}" style="color:{C_OK};">{num} — {title}</a></li>"##,
            anchor = z_anchor(&s.number),
            num = escape_html(&s.number),
            title = escape_html(&s.title),
        )
        .unwrap();
    }
    write!(h, "</ul></div></td></tr>\n").unwrap();

    // Render each Z.N as its own block — NOT collapsed.
    for s in &sections {
        write!(
            h,
            r#"<tr><td id="{anchor}" style="padding:14px 12px 4px 12px;">
<h3 style="color:{C_OK};font-family:{FONT};font-size:14px;margin:12px 0 4px 0;border-left:3px solid {C_OK};padding-left:8px;">{num} — {title}</h3>
<p style="color:{C_DIM};font-family:{FONT};font-size:10px;margin:0 0 6px 8px;">source: <code>{source}</code></p>
<pre style="color:{C_TEXT};font-family:{FONT};font-size:10.5px;line-height:1.35;white-space:pre;margin:0 0 4px 0;padding:10px;background:{BG_CARD};border:1px solid {BG_HEAD};border-radius:6px;overflow-x:auto;">{body}</pre>
</td></tr>
"#,
            anchor = z_anchor(&s.number),
            num = escape_html(&s.number),
            title = escape_html(&s.title),
            source = escape_html(&s.source),
            body = escape_html(&s.body),
        )
        .unwrap();
    }
}
