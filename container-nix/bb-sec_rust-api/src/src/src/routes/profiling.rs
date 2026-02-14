use axum::extract::{Path, State};
use axum::{Json, Router};
use axum::routing::get;
use serde_json::json;
use std::sync::Arc;
use std::time::Instant;

use crate::config::{AppConfig, SshConfig};
use crate::error::AppError;
use crate::models::profiling::{DiagnosticCheckResult, ProfilingResponse, ProfilingSummary};
use crate::services::diagnostics::{self, CheckResult};
use crate::AppState;

pub fn routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/rust/profiling/{container}", get(profile_container))
}

/// Resolved container location info.
struct ContainerResolution {
    vm_id: String,
    vm_label: String,
    service_name: String,
    domain: Option<String>,
}

fn resolve_container(config: &AppConfig, container: &str) -> Result<ContainerResolution, AppError> {
    for (vm_id, vm_map) in &config.all_vm_services {
        for (service_name, containers) in &vm_map.services {
            if containers.iter().any(|c| c == container) {
                let domain = config.container_domain_map.get(container).cloned();
                return Ok(ContainerResolution {
                    vm_id: vm_id.clone(),
                    vm_label: vm_map.label.clone(),
                    service_name: service_name.clone(),
                    domain,
                });
            }
        }
    }
    Err(AppError::not_found(format!("Container '{container}' not found in any VM")))
}

fn check_to_result(c: CheckResult) -> DiagnosticCheckResult {
    DiagnosticCheckResult {
        name: c.name,
        success: c.success,
        time_ms: c.time_ms,
        data: c.data,
    }
}

#[utoipa::path(
    get,
    path = "/rust/profiling/{container}",
    tag = "Get-Profiling",
    params(("container" = String, Path, description = "Container name to profile")),
    responses(
        (status = 200, description = "Container profiling report", body = ProfilingResponse),
        (status = 404, description = "Container not found"),
    )
)]
pub async fn profile_container(
    State(state): State<Arc<AppState>>,
    Path(container): Path<String>,
) -> Result<Json<ProfilingResponse>, AppError> {
    if !crate::models::vm::validate_container_name(&container) {
        return Err(AppError::bad_request("Invalid container name"));
    }

    let resolution = resolve_container(&state.config, &container)?;
    let ssh_config = state.config.vm_ssh.get(&resolution.vm_id)
        .ok_or_else(|| AppError::internal(format!(
            "No SSH config for VM {}", resolution.vm_id
        )))?;

    let total_start = Instant::now();
    let mut checks: Vec<DiagnosticCheckResult> = Vec::new();

    // --- Check 1: WireGuard ping ---
    let ping_result = diagnostics::ping_with_latency(&ssh_config.host).await;
    checks.push(check_to_result(ping_result));

    // --- Check 2: SSH connectivity ---
    let ssh_result = diagnostics::timed_ssh_check(ssh_config).await;
    let ssh_ok = ssh_result.success;
    checks.push(check_to_result(ssh_result));

    // If SSH failed, skip SSH-dependent checks (3-7) but still run check 8
    let mut published_ports: Vec<(u16, u16)> = Vec::new(); // (host_port, container_port)

    if ssh_ok {
        // --- Checks 3+4: Container status + Docker network (combined SSH call) ---
        let (status_check, network_check, ports) =
            check_container_and_network(ssh_config, &container).await;
        published_ports = ports;
        checks.push(check_to_result(status_check));
        checks.push(check_to_result(network_check));

        // --- Checks 5+7: Port reachability on host + iptables DNAT (combined SSH call) ---
        if !published_ports.is_empty() {
            let (port_check, iptables_check) =
                check_ports_and_iptables(ssh_config, &container, &published_ports).await;
            checks.push(check_to_result(port_check));

            // --- Check 6: Port reachability via WireGuard (local TCP connect) ---
            let wg_check =
                check_ports_wireguard(&ssh_config.host, &published_ports).await;
            checks.push(check_to_result(wg_check));

            checks.push(check_to_result(iptables_check));
        } else {
            // No published ports — report as informational
            let start = Instant::now();
            checks.push(check_to_result(CheckResult::ok(
                "port_reachability_host",
                start.elapsed().as_millis() as u64,
                json!({ "ports_checked": [], "note": "no published ports" }),
            )));
            checks.push(check_to_result(CheckResult::ok(
                "port_reachability_wireguard",
                0,
                json!({ "ports_checked": [], "note": "no published ports" }),
            )));
            checks.push(check_to_result(CheckResult::ok(
                "iptables_dnat",
                0,
                json!({ "rules": [], "note": "no published ports" }),
            )));
        }
    } else {
        // SSH down — mark checks 3-7 as failed
        for name in &[
            "container_status",
            "docker_network",
            "port_reachability_host",
            "port_reachability_wireguard",
            "iptables_dnat",
        ] {
            checks.push(check_to_result(CheckResult::fail(name, 0, "skipped: SSH unavailable")));
        }
    }

    // --- Check 8: Authelia bearer auth (HTTP, no SSH needed) ---
    if let Some(domain) = &resolution.domain {
        let auth_check = check_authelia_bearer(
            &state.http,
            domain,
            state.config.authelia_bearer_token.as_deref(),
        )
        .await;
        checks.push(check_to_result(auth_check));
    } else {
        checks.push(check_to_result(CheckResult::ok(
            "authelia_bearer_auth",
            0,
            json!({ "note": "no domain mapped, skipped" }),
        )));
    }

    let total_time = total_start.elapsed().as_millis() as u64;
    let passed = checks.iter().filter(|c| c.success).count();
    let failed = checks.iter().filter(|c| !c.success).count();
    let total = checks.len();

    let overall_status = if failed == 0 {
        "healthy"
    } else if passed == 0 {
        "down"
    } else {
        "degraded"
    };

    Ok(Json(ProfilingResponse {
        container,
        vm_id: resolution.vm_id,
        vm_label: resolution.vm_label,
        service: resolution.service_name,
        domain: resolution.domain,
        total_time_ms: total_time,
        checks,
        summary: ProfilingSummary {
            checks_passed: passed,
            checks_failed: failed,
            checks_total: total,
            overall_status: overall_status.to_string(),
        },
    }))
}

// ---------------------------------------------------------------------------
// Check implementations
// ---------------------------------------------------------------------------

/// Checks 3+4: Container status and docker network in a combined SSH call.
async fn check_container_and_network(
    ssh: &SshConfig,
    container: &str,
) -> (CheckResult, CheckResult, Vec<(u16, u16)>) {
    let cmd = format!(
        concat!(
            "echo '---STATUS---' && ",
            "docker inspect --format '{{{{.State.Status}}}}|{{{{.State.Health.Status}}}}|{{{{.Config.Image}}}}|{{{{.State.StartedAt}}}}|{{{{.RestartCount}}}}' {c} 2>&1 && ",
            "echo '---UPTIME---' && ",
            "docker ps -a --filter 'name=^{c}$' --format '{{{{.Status}}}}' 2>&1 && ",
            "echo '---NETWORK---' && ",
            "docker inspect --format '{{{{json .NetworkSettings}}}}' {c} 2>&1"
        ),
        c = container
    );

    let start = Instant::now();
    let result = crate::services::ssh::ssh_command(ssh, &cmd).await;
    let elapsed = start.elapsed().as_millis() as u64;

    if !result.success {
        return (
            CheckResult::fail("container_status", elapsed, &result.output),
            CheckResult::fail("docker_network", 0, "skipped: container inspect failed"),
            Vec::new(),
        );
    }

    let output = &result.output;

    // Parse status section
    let status_section = extract_section(output, "---STATUS---", "---UPTIME---");
    let uptime_section = extract_section(output, "---UPTIME---", "---NETWORK---");
    let network_section = extract_after(output, "---NETWORK---");

    let status_check = parse_container_status(&status_section, &uptime_section, elapsed);
    let (network_check, ports) = parse_docker_network(&network_section);

    (status_check, network_check, ports)
}

fn extract_section(output: &str, start_marker: &str, end_marker: &str) -> String {
    if let Some(start) = output.find(start_marker) {
        let after = &output[start + start_marker.len()..];
        if let Some(end) = after.find(end_marker) {
            return after[..end].trim().to_string();
        }
        return after.trim().to_string();
    }
    String::new()
}

fn extract_after(output: &str, marker: &str) -> String {
    if let Some(start) = output.find(marker) {
        return output[start + marker.len()..].trim().to_string();
    }
    String::new()
}

fn parse_container_status(status_line: &str, uptime_line: &str, elapsed: u64) -> CheckResult {
    let parts: Vec<&str> = status_line.split('|').collect();
    if parts.len() >= 5 {
        let state = parts[0];
        let health = if parts[1] == "<no value>" || parts[1].is_empty() {
            "none"
        } else {
            parts[1]
        };
        let is_running = state == "running";
        let data = json!({
            "state": state,
            "health": health,
            "image": parts[2],
            "started_at": parts[3],
            "restart_count": parts[4],
            "uptime": uptime_line,
        });
        if is_running {
            CheckResult::ok("container_status", elapsed, data)
        } else {
            CheckResult::fail_with_data("container_status", elapsed, data)
        }
    } else {
        CheckResult::fail("container_status", elapsed, &format!("unexpected format: {status_line}"))
    }
}

fn parse_docker_network(network_json: &str) -> (CheckResult, Vec<(u16, u16)>) {
    let start = Instant::now();
    let mut published_ports: Vec<(u16, u16)> = Vec::new();

    let parsed: Result<Value, _> = serde_json::from_str(network_json);
    match parsed {
        Ok(ns) => {
            // Extract networks
            let mut networks = Vec::new();
            if let Some(nets) = ns.get("Networks").and_then(|n| n.as_object()) {
                for (name, info) in nets {
                    networks.push(json!({
                        "name": name,
                        "ip": info.get("IPAddress").and_then(|v| v.as_str()).unwrap_or(""),
                        "gateway": info.get("Gateway").and_then(|v| v.as_str()).unwrap_or(""),
                        "subnet": info.get("IPPrefixLen").and_then(|v| v.as_u64()).unwrap_or(0),
                    }));
                }
            }

            // Extract published ports
            let mut ports_info = Vec::new();
            if let Some(ports) = ns.get("Ports").and_then(|p| p.as_object()) {
                for (container_port_proto, bindings) in ports {
                    let container_port: u16 = container_port_proto
                        .split('/')
                        .next()
                        .and_then(|p| p.parse().ok())
                        .unwrap_or(0);
                    if let Some(bindings) = bindings.as_array() {
                        for binding in bindings {
                            if let Some(hp) = binding.get("HostPort").and_then(|v| v.as_str()) {
                                if let Ok(host_port) = hp.parse::<u16>() {
                                    published_ports.push((host_port, container_port));
                                    ports_info.push(json!({
                                        "host_port": host_port,
                                        "container_port": container_port_proto,
                                    }));
                                }
                            }
                        }
                    }
                }
            }

            let elapsed = start.elapsed().as_millis() as u64;
            (
                CheckResult::ok("docker_network", elapsed, json!({
                    "networks": networks,
                    "published_ports": ports_info,
                })),
                published_ports,
            )
        }
        Err(e) => {
            let elapsed = start.elapsed().as_millis() as u64;
            (
                CheckResult::fail("docker_network", elapsed, &format!("JSON parse error: {e}")),
                Vec::new(),
            )
        }
    }
}

/// Checks 5+7: Port reachability on host + iptables DNAT in combined SSH call.
async fn check_ports_and_iptables(
    ssh: &SshConfig,
    container: &str,
    ports: &[(u16, u16)],
) -> (CheckResult, CheckResult) {
    // Build port check commands
    let port_cmds: Vec<String> = ports.iter().map(|(hp, _)| {
        format!(
            "echo -n '{hp}:' && timeout 3 bash -c 'echo >/dev/tcp/localhost/{hp}' 2>/dev/null && echo OPEN || echo CLOSED"
        )
    }).collect();

    let dport_pattern: Vec<String> = ports.iter().map(|(hp, _)| hp.to_string()).collect();
    let dport_regex = dport_pattern.join("|");

    let cmd = format!(
        "{port_checks} && echo '---IPTABLES---' && (sudo iptables-save -t nat 2>/dev/null | grep -E 'DNAT.*(dport ({dports}))' || docker port {container} 2>/dev/null || echo 'no_rules')",
        port_checks = port_cmds.join(" && "),
        dports = dport_regex,
        container = container,
    );

    let start = Instant::now();
    let result = crate::services::ssh::ssh_command(ssh, &cmd).await;
    let elapsed = start.elapsed().as_millis() as u64;

    // Parse port results even on partial failure
    let output = &result.output;
    let (port_section, iptables_section) = if let Some(idx) = output.find("---IPTABLES---") {
        (output[..idx].trim(), output[idx + 14..].trim())
    } else {
        (output.as_str(), "")
    };

    // Parse port checks
    let mut ports_checked = Vec::new();
    for line in port_section.lines() {
        let line = line.trim();
        if let Some((port_str, status)) = line.split_once(':') {
            if let Ok(hp) = port_str.parse::<u16>() {
                let cp = ports.iter().find(|(h, _)| *h == hp).map(|(_, c)| *c).unwrap_or(0);
                ports_checked.push(json!({
                    "host_port": hp,
                    "container_port": cp,
                    "reachable": status == "OPEN",
                }));
            }
        }
    }

    let all_open = ports_checked.iter().all(|p| p["reachable"] == true);
    let port_check = if all_open {
        CheckResult::ok("port_reachability_host", elapsed, json!({
            "ports_checked": ports_checked,
        }))
    } else {
        CheckResult::fail_with_data("port_reachability_host", elapsed, json!({
            "ports_checked": ports_checked,
        }))
    };

    // Parse iptables
    let mut rules = Vec::new();
    for line in iptables_section.lines() {
        let line = line.trim();
        if line.is_empty() || line == "no_rules" {
            continue;
        }
        // Parse iptables-save format: -A CHAIN ... --dport PORT ... --to-destination IP:PORT
        let chain = extract_flag(line, "-A");
        let protocol = extract_flag(line, "-p");
        let dport = extract_flag(line, "--dport");
        let to_dest = extract_flag(line, "--to-destination");

        if chain.is_some() || to_dest.is_some() {
            rules.push(json!({
                "chain": chain,
                "protocol": protocol,
                "dport": dport,
                "to_destination": to_dest,
                "raw": line,
            }));
        } else {
            // docker port output format: 8080/tcp -> 0.0.0.0:8080
            rules.push(json!({ "raw": line }));
        }
    }

    let iptables_check = CheckResult::ok("iptables_dnat", 0, json!({ "rules": rules }));

    (port_check, iptables_check)
}

fn extract_flag(line: &str, flag: &str) -> Option<String> {
    let parts: Vec<&str> = line.split_whitespace().collect();
    for (i, p) in parts.iter().enumerate() {
        if *p == flag {
            if let Some(val) = parts.get(i + 1) {
                return Some(val.to_string());
            }
        }
    }
    None
}

/// Check 6: Port reachability via WireGuard (direct TCP connect from API process).
async fn check_ports_wireguard(wg_host: &str, ports: &[(u16, u16)]) -> CheckResult {
    let start = Instant::now();
    let mut ports_checked = Vec::new();

    for (hp, cp) in ports {
        let (ok, time_ms) = diagnostics::tcp_connect_check(wg_host, *hp, 3).await;
        ports_checked.push(json!({
            "host_port": hp,
            "container_port": cp,
            "reachable": ok,
            "time_ms": time_ms,
        }));
    }

    let elapsed = start.elapsed().as_millis() as u64;
    let all_open = ports_checked.iter().all(|p| p["reachable"] == true);

    if all_open {
        CheckResult::ok("port_reachability_wireguard", elapsed, json!({
            "from": "10.0.0.1",
            "to": wg_host,
            "ports_checked": ports_checked,
        }))
    } else {
        CheckResult::fail_with_data("port_reachability_wireguard", elapsed, json!({
            "from": "10.0.0.1",
            "to": wg_host,
            "ports_checked": ports_checked,
        }))
    }
}

/// Check 8: Authelia bearer auth flow test.
async fn check_authelia_bearer(
    http: &reqwest::Client,
    domain: &str,
    token: Option<&str>,
) -> CheckResult {
    let start = Instant::now();
    let url = format!("https://{domain}");

    // Step 1: Unauthenticated request (no-redirect)
    let no_redirect_client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .danger_accept_invalid_certs(true)
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .unwrap_or_else(|_| http.clone());

    let unauth_status;
    let auth_redirect;

    match no_redirect_client.get(&url).send().await {
        Ok(resp) => {
            unauth_status = Some(resp.status().as_u16());
            let location = resp.headers().get("location")
                .and_then(|v| v.to_str().ok())
                .unwrap_or("")
                .to_string();
            auth_redirect = location.contains("auth.") || resp.status().as_u16() == 302 || resp.status().as_u16() == 401;
        }
        Err(e) => {
            let elapsed = start.elapsed().as_millis() as u64;
            return CheckResult::fail("authelia_bearer_auth", elapsed, &format!(
                "unauthenticated request failed: {e}"
            ));
        }
    }

    // Step 2: Authenticated request with bearer token
    let (auth_status, token_valid, token_available) = if let Some(tok) = token {
        match http.get(&url)
            .header("Authorization", format!("Bearer {tok}"))
            .timeout(std::time::Duration::from_secs(10))
            .send()
            .await
        {
            Ok(resp) => {
                let status = resp.status().as_u16();
                (Some(status), status >= 200 && status < 400, true)
            }
            Err(_) => (None, false, true),
        }
    } else {
        (None, false, false)
    };

    let elapsed = start.elapsed().as_millis() as u64;

    let data = json!({
        "domain": domain,
        "unauthenticated_status": unauth_status,
        "auth_redirect_detected": auth_redirect,
        "authenticated_status": auth_status,
        "token_valid": token_valid,
        "token_available": token_available,
    });

    // Fail if we had a token but it was rejected
    if token_available && !token_valid {
        CheckResult::fail_with_data("authelia_bearer_auth", elapsed, data)
    } else {
        CheckResult::ok("authelia_bearer_auth", elapsed, data)
    }
}
