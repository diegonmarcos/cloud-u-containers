use axum::{
    extract::{Path, State},
    routing::post,
    Json, Router,
};
use serde_json::{json, Value};
use std::sync::Arc;

use crate::config::VmProvider;
use crate::error::AppError;
use crate::models::vm::{validate_container_name, validate_vm_id};
use crate::services::{gcp, oci, ssh};
use crate::AppState;

pub fn routes() -> Router<Arc<AppState>> {
    Router::new()
        // VM actions — oci-apps
        .route("/api/vm/oci-apps/start", post(vm_oci_apps_start))
        .route("/api/vm/oci-apps/stop", post(vm_oci_apps_stop))
        .route("/api/vm/oci-apps/reset", post(vm_oci_apps_reset))
        // VM actions — oci-apps-1
        .route("/api/vm/oci-apps-1/start", post(vm_oci_apps_1_start))
        .route("/api/vm/oci-apps-1/stop", post(vm_oci_apps_1_stop))
        .route("/api/vm/oci-apps-1/reset", post(vm_oci_apps_1_reset))
        // VM actions — gcp-proxy
        .route("/api/vm/gcp-proxy/start", post(vm_gcp_proxy_start))
        .route("/api/vm/gcp-proxy/stop", post(vm_gcp_proxy_stop))
        .route("/api/vm/gcp-proxy/reset", post(vm_gcp_proxy_reset))
        // VM actions — oci-mail
        .route("/api/vm/oci-mail/start", post(vm_oci_mail_start))
        .route("/api/vm/oci-mail/stop", post(vm_oci_mail_stop))
        .route("/api/vm/oci-mail/reset", post(vm_oci_mail_reset))
        // VM actions — oci-analytics
        .route("/api/vm/oci-analytics/start", post(vm_oci_analytics_start))
        .route("/api/vm/oci-analytics/stop", post(vm_oci_analytics_stop))
        .route("/api/vm/oci-analytics/reset", post(vm_oci_analytics_reset))
        // Bulk on-demand container ops (oci-apps-1)
        .route("/api/containers/on-demand/start-all", post(ondemand_containers_start_all))
        .route("/api/containers/on-demand/stop-all", post(ondemand_containers_stop_all))
        .route("/api/containers/on-demand/restart-all", post(ondemand_containers_restart_all))
        // Matomo / Windmill toggle (oci-analytics)
        .route("/api/containers/windmill/start", post(windmill_start))
        .route("/api/containers/windmill/stop", post(windmill_stop))
        .route("/api/containers/matomo/wake", post(matomo_wake))
        .route("/api/containers/matomo/sleep", post(matomo_sleep))
        // Legacy flex-shortcut container/service routes
        .route("/api/containers/{name}/start", post(ondemand_container_start))
        .route("/api/containers/{name}/stop", post(ondemand_container_stop))
        .route("/api/containers/{name}/restart", post(ondemand_container_restart))
        .route("/api/services/{service}/start", post(ondemand_service_start))
        .route("/api/services/{service}/stop", post(ondemand_service_stop))
        // Engine: generalized per-VM POST routes
        .route("/api/vms/{vm_id}/start", post(vm_start))
        .route("/api/vms/{vm_id}/stop", post(vm_stop))
        .route("/api/vms/{vm_id}/reset", post(vm_reset))
        // Unified: single {action} dispatch
        .route("/api/vms/{vm_id}/{action}", post(vm_action))
        .route("/api/vms/{vm_id}/containers/{name}/start", post(vm_container_start))
        .route("/api/vms/{vm_id}/containers/{name}/stop", post(vm_container_stop))
        .route("/api/vms/{vm_id}/containers/{name}/restart", post(vm_container_restart))
        .route("/api/vms/{vm_id}/services/{service}/start", post(vm_service_start))
        .route("/api/vms/{vm_id}/services/{service}/stop", post(vm_service_stop))
}

// ---------------------------------------------------------------------------
// Helpers — generalized to accept vm_id
// ---------------------------------------------------------------------------

pub(crate) fn validate_service_for_vm(service: &str, vm_id: &str, state: &AppState) -> Result<Vec<String>, AppError> {
    let vm_map = state.config.all_vm_services.get(vm_id)
        .ok_or_else(|| AppError::not_found(format!("Unknown VM: {vm_id}")))?;
    let containers = vm_map.services.get(service)
        .ok_or_else(|| {
            let valid: Vec<&String> = vm_map.services.keys().collect();
            AppError::not_found(format!(
                "Unknown service '{service}' on {vm_id}. Valid: {}",
                valid.iter().map(|s| s.as_str()).collect::<Vec<_>>().join(", ")
            ))
        })?;
    Ok(containers.clone())
}

/// Load GCP service account config (best-effort, cached at process level would be ideal but
/// re-reading from disk is fine for the call frequency here).
pub(crate) fn load_gcp_sa(state: &AppState) -> Result<gcp::ServiceAccountConfig, String> {
    gcp::parse_service_account(&state.config.gcp_service_account_file)
}

/// Get the provider state for any VM.
pub(crate) async fn get_vm_state_by_id(state: &AppState, vm_id: &str) -> Result<String, AppError> {
    let vm = state.config.vm_instances.get(vm_id)
        .ok_or_else(|| AppError::service_unavailable(format!("VM {vm_id} not configured")))?;
    match vm.provider {
        VmProvider::Oci => oci::get_instance_state(&state.http, &state.config, &vm.instance_id)
            .await
            .map_err(|e| AppError::internal(e)),
        VmProvider::Gcp => {
            let gcp_vm = state.config.gcp_vms.get(vm_id)
                .ok_or_else(|| AppError::internal(format!("GCP VM config not found for {vm_id}")))?;
            let sa = load_gcp_sa(state).map_err(AppError::internal)?;
            gcp::get_instance_state(
                &state.http, &sa, &state.gcp_token_cache,
                &gcp_vm.project_id, &gcp_vm.zone, &gcp_vm.name,
            ).await.map_err(|e| AppError::internal(e))
        }
    }
}

/// Ensure a VM is running. Starts it and polls if stopped.
/// Returns (current_state, was_awakened) — was_awakened=true means VM was offline and had to be started.
pub(crate) async fn ensure_vm_running_by_id(state: &AppState, vm_id: &str) -> Result<(String, bool), AppError> {
    let vm = state.config.vm_instances.get(vm_id)
        .ok_or_else(|| AppError::service_unavailable(format!("VM {vm_id} not configured")))?;

    match vm.provider {
        VmProvider::Oci => {
            let current = oci::get_instance_state(&state.http, &state.config, &vm.instance_id)
                .await
                .map_err(|e| AppError::internal(e))?;

            if current == "RUNNING" {
                return Ok((current, false));
            }

            if current == "STOPPED" {
                oci::instance_action(&state.http, &state.config, &vm.instance_id, "START")
                    .await
                    .map_err(|e| AppError::internal(e))?;

                for _ in 0..60 {
                    tokio::time::sleep(tokio::time::Duration::from_secs(5)).await;
                    let state_now = oci::get_instance_state(&state.http, &state.config, &vm.instance_id)
                        .await
                        .unwrap_or_else(|_| "UNKNOWN".into());
                    if state_now == "RUNNING" {
                        tokio::time::sleep(tokio::time::Duration::from_secs(10)).await;
                        return Ok(("RUNNING".into(), true));
                    }
                }
                return Err(AppError::internal("Timeout waiting for VM to start"));
            }

            Ok((current, false))
        }
        VmProvider::Gcp => {
            let gcp_vm = state.config.gcp_vms.get(vm_id)
                .ok_or_else(|| AppError::internal(format!("GCP VM config not found for {vm_id}")))?;
            let sa = load_gcp_sa(state).map_err(AppError::internal)?;

            let current = gcp::get_instance_state(
                &state.http, &sa, &state.gcp_token_cache,
                &gcp_vm.project_id, &gcp_vm.zone, &gcp_vm.name,
            ).await.map_err(|e| AppError::internal(e))?;

            if current == "RUNNING" {
                return Ok((current, false));
            }

            if current == "TERMINATED" || current == "STOPPED" {
                gcp::instance_action(
                    &state.http, &sa, &state.gcp_token_cache,
                    &gcp_vm.project_id, &gcp_vm.zone, &gcp_vm.name, "start",
                ).await.map_err(|e| AppError::internal(e))?;

                for _ in 0..60 {
                    tokio::time::sleep(tokio::time::Duration::from_secs(5)).await;
                    let state_now = gcp::get_instance_state(
                        &state.http, &sa, &state.gcp_token_cache,
                        &gcp_vm.project_id, &gcp_vm.zone, &gcp_vm.name,
                    ).await.unwrap_or_else(|_| "UNKNOWN".into());
                    if state_now == "RUNNING" {
                        tokio::time::sleep(tokio::time::Duration::from_secs(10)).await;
                        return Ok(("RUNNING".into(), true));
                    }
                }
                return Err(AppError::internal("Timeout waiting for GCP VM to start"));
            }

            Ok((current, false))
        }
    }
}

/// Get container statuses on a specific VM.
pub(crate) async fn get_container_statuses(state: &AppState, vm_id: &str, containers: &[String]) -> Vec<Value> {
    let ssh_cfg = match state.config.vm_ssh.get(vm_id) {
        Some(cfg) => cfg,
        None => return vec![],
    };

    let mut statuses = vec![];
    for name in containers {
        let result = ssh::ssh_command(
            ssh_cfg,
            &format!("docker inspect --format '{{{{.State.Status}}}}' {name} 2>/dev/null || echo 'not_found'"),
        )
        .await;

        statuses.push(json!({
            "name": name,
            "status": if result.success { result.output } else { "unknown".into() }
        }));
    }
    statuses
}

/// Batch-fetch all container states via a single SSH call.
pub(crate) async fn batch_container_statuses(state: &AppState, vm_id: &str) -> Vec<(String, String, String)> {
    let ssh_cfg = match state.config.vm_ssh.get(vm_id) {
        Some(cfg) => cfg,
        None => return vec![],
    };

    let result = ssh::ssh_command(
        ssh_cfg,
        "docker ps -a --format '{{.Names}}|{{.State}}|{{.Ports}}'"
    ).await;

    if !result.success {
        return vec![];
    }

    result.output.lines().filter_map(|line| {
        let parts: Vec<&str> = line.splitn(3, '|').collect();
        if parts.len() >= 2 {
            Some((
                parts[0].to_string(),
                parts[1].to_string(),
                parts.get(2).unwrap_or(&"").to_string(),
            ))
        } else {
            None
        }
    }).collect()
}

/// Compute service status from container states.
pub(crate) fn compute_service_status(containers: &[String], all_statuses: &[(String, String, String)]) -> Value {
    let mut container_details = vec![];
    let mut running = 0;

    for name in containers {
        let (state, ports) = all_statuses.iter()
            .find(|(n, _, _)| n == name)
            .map(|(_, s, p)| (s.clone(), p.clone()))
            .unwrap_or_else(|| ("not_found".into(), String::new()));

        if state == "running" {
            running += 1;
        }
        container_details.push(json!({
            "name": name,
            "state": state,
            "ports": ports,
        }));
    }

    let status = if running == containers.len() {
        "up"
    } else if running == 0 {
        "down"
    } else {
        "partial"
    };

    json!({
        "status": status,
        "containers": container_details,
    })
}

/// Determine health string from provider state and SSH connectivity.
pub(crate) fn compute_health(provider_state: &str, ssh_ok: bool) -> &'static str {
    if (provider_state == "RUNNING" || provider_state == "N/A") && ssh_ok {
        "online"
    } else if provider_state == "RUNNING" || provider_state == "N/A" {
        "degraded"
    } else if provider_state == "STOPPED" || provider_state == "TERMINATED" {
        "offline"
    } else {
        "unknown"
    }
}

/// Check if we should attempt SSH/ping probes for this provider state.
pub(crate) fn should_probe(provider_state: &str) -> bool {
    matches!(provider_state, "RUNNING" | "N/A")
}

/// Result of probing a VM's connectivity.
pub(crate) struct VmProbe {
    pub provider_state: String,
    pub ping: bool,
    pub ssh: bool,
    pub health: &'static str,
    pub container_data: Vec<(String, String, String)>,
}

/// Probe a VM: get provider state, ping, SSH, batch container statuses.
pub(crate) async fn probe_vm(state: &AppState, vm_id: &str) -> VmProbe {
    let provider_state = get_vm_state_by_id(state, vm_id)
        .await
        .unwrap_or_else(|_| "unknown".into());

    let ssh_cfg = state.config.vm_ssh.get(vm_id);
    let host = ssh_cfg.map(|c| c.host.as_str()).unwrap_or("");

    let (ping, ssh_ok, container_data) = if should_probe(&provider_state) {
        let p = ssh::check_ping(host).await;
        let s = match ssh_cfg {
            Some(cfg) => ssh::check_ssh(cfg).await,
            None => false,
        };
        let data = if s {
            batch_container_statuses(state, vm_id).await
        } else {
            vec![]
        };
        (p, s, data)
    } else {
        (false, false, vec![])
    };

    let health = compute_health(&provider_state, ssh_ok);
    VmProbe { provider_state, ping, ssh: ssh_ok, health, container_data }
}

pub(crate) async fn probe_domain_chain(
    http: &reqwest::Client,
    domain: &str,
    service: &str,
    bearer_token: Option<&str>,
) -> Value {
    let url = format!("https://{domain}");
    let total_start = std::time::Instant::now();
    let mut hops = vec![];

    let no_redirect_client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(10))
        .danger_accept_invalid_certs(true)
        .build()
        .unwrap_or_else(|_| http.clone());

    // Hop 1: initial no-redirect probe
    let hop1_start = std::time::Instant::now();
    let probe = no_redirect_client.get(&url).send().await;
    let hop1_ms = hop1_start.elapsed().as_millis() as u64;

    let (status_code, redirect_to, auth_required) = match &probe {
        Ok(resp) => {
            let code = resp.status().as_u16();
            let location = resp.headers().get("location")
                .and_then(|v| v.to_str().ok())
                .map(|s| s.to_string());
            let is_redirect = (300..400).contains(&code);
            let to_auth = location.as_deref()
                .map(|loc| loc.contains("auth"))
                .unwrap_or(false);
            (code, location.filter(|_| is_redirect), is_redirect && to_auth)
        }
        Err(_) => (0, None, false),
    };

    let mut hop1 = json!({
        "url": &url,
        "status": status_code,
        "time_ms": hop1_ms,
    });
    if let Some(ref loc) = redirect_to {
        hop1["redirect_to"] = json!(loc);
    }
    if auth_required {
        hop1["note"] = json!("authelia redirect detected");
    }
    hops.push(hop1);

    let mut final_status = status_code;
    let mut authenticated = false;

    // If auth required and we have a bearer token, do an authenticated probe
    if auth_required {
        if let Some(token) = bearer_token {
            let hop_start = std::time::Instant::now();
            let auth_resp = no_redirect_client.get(&url)
                .header("Authorization", format!("Bearer {token}"))
                .send()
                .await;
            let hop_ms = hop_start.elapsed().as_millis() as u64;
            let auth_status = auth_resp.as_ref().map(|r| r.status().as_u16()).unwrap_or(0);

            let mut hop = json!({
                "url": &url,
                "status": auth_status,
                "time_ms": hop_ms,
                "note": "authenticated via bearer",
            });

            if let Ok(ref resp) = auth_resp {
                if (300..400).contains(&resp.status().as_u16()) {
                    if let Some(loc) = resp.headers().get("location").and_then(|v| v.to_str().ok()) {
                        hop["redirect_to"] = json!(loc);
                        let final_start = std::time::Instant::now();
                        let final_resp = no_redirect_client.get(loc).send().await;
                        let final_ms = final_start.elapsed().as_millis() as u64;
                        let fs = final_resp.as_ref().map(|r| r.status().as_u16()).unwrap_or(0);
                        hops.push(hop);
                        hops.push(json!({
                            "url": loc,
                            "status": fs,
                            "time_ms": final_ms,
                            "note": "final redirect",
                        }));
                        final_status = fs;
                        authenticated = true;
                    } else {
                        final_status = auth_status;
                        authenticated = true;
                        hops.push(hop);
                    }
                } else {
                    final_status = auth_status;
                    authenticated = true;
                    hops.push(hop);
                }
            } else {
                final_status = auth_status;
                hops.push(hop);
            }
        }
    }

    let total_ms = total_start.elapsed().as_millis() as u64;

    json!({
        "domain": domain,
        "service": service,
        "hops": hops,
        "auth_required": auth_required,
        "authenticated": authenticated,
        "final_status": final_status,
        "healthy": final_status > 0 && final_status < 500,
        "total_time_ms": total_ms,
    })
}

pub(crate) fn round1(v: f64) -> f64 {
    (v * 10.0).round() / 10.0
}

/// Gather system resources, specs, and info from a VM via SSH.
pub(crate) async fn gather_vm_resources(state: &AppState, vm_id: &str) -> Value {
    let ssh_cfg = match state.config.vm_ssh.get(vm_id) {
        Some(cfg) => cfg,
        None => return json!({"error": "no SSH config"}),
    };

    let cmd = concat!(
        "echo CPUMODEL:$(lscpu 2>/dev/null | grep -m1 'Model name' | sed 's/.*:[[:space:]]*//' || echo unknown);",
        "echo CORES:$(nproc 2>/dev/null || echo 0);",
        "echo LOAD:$(cat /proc/loadavg 2>/dev/null || echo '0 0 0 0/0 0');",
        "echo MEMLINE:$(free -m 2>/dev/null | grep '^Mem:' || echo 'Mem: 0 0 0 0 0 0');",
        "echo SWAPLINE:$(free -m 2>/dev/null | grep '^Swap:' || echo 'Swap: 0 0 0');",
        "echo DISKLINE:$(df / 2>/dev/null | tail -1 || echo '/ 0 0 0 0% /');",
        "echo ARCH:$(uname -m 2>/dev/null || echo unknown);",
        "echo KERNEL:$(uname -r 2>/dev/null || echo unknown);",
        "echo OS:$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"' || echo unknown);",
        "echo HOSTNAME:$(hostname 2>/dev/null || echo unknown);",
        "echo UPTIME:$(uptime -p 2>/dev/null || uptime 2>/dev/null || echo unknown);",
        "echo GPU:$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo N/A);",
        "echo DOCKERINFO:$(docker info --format '{{.ContainersRunning}}/{{.Containers}}' 2>/dev/null || echo unknown)",
    );

    let result = ssh::ssh_command(ssh_cfg, cmd).await;
    if !result.success {
        return json!({"error": "SSH failed"});
    }

    let output = &result.output;
    let field = |prefix: &str| -> String {
        output.lines()
            .find(|l| l.starts_with(prefix))
            .map(|l| l[prefix.len()..].trim().to_string())
            .unwrap_or_default()
    };

    // CPU
    let cores: u32 = field("CORES:").parse().unwrap_or(0);
    let load_parts: Vec<f64> = field("LOAD:")
        .split_whitespace().take(3)
        .filter_map(|s| s.parse().ok()).collect();
    let load_1m = load_parts.first().copied().unwrap_or(0.0);
    let load_5m = load_parts.get(1).copied().unwrap_or(0.0);
    let load_15m = load_parts.get(2).copied().unwrap_or(0.0);
    let cpu_pct = if cores > 0 { (load_1m / cores as f64 * 100.0).min(100.0) } else { 0.0 };

    // Memory (free -m: total used free shared buff/cache available)
    let mem_vals: Vec<u64> = field("MEMLINE:")
        .split_whitespace().skip(1)
        .filter_map(|s| s.parse().ok()).collect();
    let mem_total = mem_vals.first().copied().unwrap_or(0);
    let mem_used = mem_vals.get(1).copied().unwrap_or(0);
    let mem_available = mem_vals.get(5).copied().unwrap_or(0);
    let mem_pct = if mem_total > 0 { mem_used as f64 / mem_total as f64 * 100.0 } else { 0.0 };

    // Swap
    let swap_vals: Vec<u64> = field("SWAPLINE:")
        .split_whitespace().skip(1)
        .filter_map(|s| s.parse().ok()).collect();
    let swap_total = swap_vals.first().copied().unwrap_or(0);
    let swap_used = swap_vals.get(1).copied().unwrap_or(0);
    let swap_free = swap_vals.get(2).copied().unwrap_or(0);
    let swap_pct = if swap_total > 0 { swap_used as f64 / swap_total as f64 * 100.0 } else { 0.0 };

    // Disk (df: filesystem 1K-blocks used available use% mounted)
    let disk_line = field("DISKLINE:");
    let disk_parts: Vec<&str> = disk_line.split_whitespace().collect();
    let disk_total_kb: u64 = disk_parts.get(1).and_then(|s| s.parse().ok()).unwrap_or(0);
    let disk_used_kb: u64 = disk_parts.get(2).and_then(|s| s.parse().ok()).unwrap_or(0);
    let disk_avail_kb: u64 = disk_parts.get(3).and_then(|s| s.parse().ok()).unwrap_or(0);
    let disk_pct: f64 = disk_parts.get(4)
        .and_then(|s| s.trim_end_matches('%').parse().ok()).unwrap_or(0.0);
    let to_gb = |kb: u64| (kb as f64 / 1048576.0 * 10.0).round() / 10.0;

    // Provider from config
    let provider = state.config.vm_instances.get(vm_id)
        .map(|vm| match vm.provider { VmProvider::Oci => "oci", VmProvider::Gcp => "gcp" })
        .unwrap_or("unknown");

    json!({
        "resources": {
            "cpu": { "load_1m": round1(load_1m), "load_5m": round1(load_5m), "load_15m": round1(load_15m), "cores": cores, "usage_pct": round1(cpu_pct) },
            "memory": { "total_mb": mem_total, "used_mb": mem_used, "available_mb": mem_available, "usage_pct": round1(mem_pct) },
            "swap": { "total_mb": swap_total, "used_mb": swap_used, "free_mb": swap_free, "usage_pct": round1(swap_pct) },
            "disk": { "total_gb": to_gb(disk_total_kb), "used_gb": to_gb(disk_used_kb), "available_gb": to_gb(disk_avail_kb), "usage_pct": disk_pct },
            "gpu": field("GPU:"),
        },
        "specs": {
            "cpu_model": field("CPUMODEL:"),
            "cpu_cores": cores,
            "ram_total_mb": mem_total,
            "disk_total_gb": to_gb(disk_total_kb),
            "arch": field("ARCH:"),
            "kernel": field("KERNEL:"),
            "os": field("OS:"),
        },
        "info": {
            "hostname": field("HOSTNAME:"),
            "uptime": field("UPTIME:"),
            "provider": provider,
            "wireguard_ip": &ssh_cfg.host,
            "docker_containers": field("DOCKERINFO:"),
        }
    })
}

#[utoipa::path(
    post,
    path = "/api/vms/{vm_id}/start",
    tag = "Post-Engines",
    params(("vm_id" = String, Path, description = "VM identifier")),
    responses(
        (status = 200, description = "VM started", body = Value),
        (status = 404, description = "Unknown VM"),
        (status = 500, description = "Failed to start VM")
    )
)]
pub async fn vm_start(
    State(state): State<Arc<AppState>>,
    Path(vm_id): Path<String>,
) -> Result<Json<Value>, AppError> {
    if !validate_vm_id(&vm_id) {
        return Err(AppError::bad_request("Invalid VM ID"));
    }
    let (vm_state, vm_awakened) = ensure_vm_running_by_id(&state, &vm_id).await?;
    Ok(Json(json!({
        "status": "ok",
        "vm_id": vm_id,
        "vm_state": vm_state,
        "vm_awakened": vm_awakened,
    })))
}

#[utoipa::path(
    post,
    path = "/api/vms/{vm_id}/stop",
    tag = "Post-Engines",
    params(("vm_id" = String, Path, description = "VM identifier")),
    responses(
        (status = 200, description = "VM stopped", body = Value),
        (status = 404, description = "Unknown VM"),
        (status = 500, description = "Failed to stop VM")
    )
)]
pub async fn vm_stop(
    State(state): State<Arc<AppState>>,
    Path(vm_id): Path<String>,
) -> Result<Json<Value>, AppError> {
    if !validate_vm_id(&vm_id) {
        return Err(AppError::bad_request("Invalid VM ID"));
    }

    // Best-effort: stop containers via SSH first
    if let Some(vm_map) = state.config.all_vm_services.get(&vm_id) {
        if let Some(ssh_cfg) = state.config.vm_ssh.get(&vm_id) {
            let all_containers: Vec<String> = vm_map.services
                .values()
                .flat_map(|c| c.clone())
                .collect();
            if !all_containers.is_empty() {
                let containers_str = all_containers.join(" ");
                let _ = ssh::ssh_command(ssh_cfg, &format!("docker stop {containers_str}")).await;
            }
        }
    }

    let vm = state.config.vm_instances.get(&vm_id)
        .ok_or_else(|| AppError::service_unavailable(format!("VM {vm_id} not configured")))?;

    match vm.provider {
        VmProvider::Oci => {
            oci::instance_action(&state.http, &state.config, &vm.instance_id, "STOP")
                .await
                .map_err(|e| AppError::internal(e))?;
        }
        VmProvider::Gcp => {
            let gcp_vm = state.config.gcp_vms.get(&vm_id)
                .ok_or_else(|| AppError::internal(format!("GCP VM config not found for {vm_id}")))?;
            let sa = load_gcp_sa(&state).map_err(AppError::internal)?;
            gcp::instance_action(
                &state.http, &sa, &state.gcp_token_cache,
                &gcp_vm.project_id, &gcp_vm.zone, &gcp_vm.name, "stop",
            ).await.map_err(|e| AppError::internal(e))?;
        }
    }

    Ok(Json(json!({
        "status": "ok",
        "action": "stop",
        "vm_id": vm_id,
    })))
}

#[utoipa::path(
    post,
    path = "/api/vms/{vm_id}/reset",
    tag = "Post-Engines",
    params(("vm_id" = String, Path, description = "VM identifier")),
    responses(
        (status = 200, description = "VM reset/started", body = Value),
        (status = 404, description = "Unknown VM"),
        (status = 500, description = "Failed to reset VM")
    )
)]
pub async fn vm_reset(
    State(state): State<Arc<AppState>>,
    Path(vm_id): Path<String>,
) -> Result<Json<Value>, AppError> {
    if !validate_vm_id(&vm_id) {
        return Err(AppError::bad_request("Invalid VM ID"));
    }
    let vm = state.config.vm_instances.get(&vm_id)
        .ok_or_else(|| AppError::service_unavailable(format!("VM {vm_id} not configured")))?;

    match vm.provider {
        VmProvider::Oci => {
            let current = oci::get_instance_state(&state.http, &state.config, &vm.instance_id)
                .await
                .map_err(|e| AppError::internal(e))?;
            let action = if current == "RUNNING" { "RESET" } else { "START" };
            oci::instance_action(&state.http, &state.config, &vm.instance_id, action)
                .await
                .map_err(|e| AppError::internal(e))?;
            Ok(Json(json!({
                "status": "ok",
                "previous_state": current,
                "action": action,
                "vm_id": vm_id,
            })))
        }
        VmProvider::Gcp => {
            let gcp_vm = state.config.gcp_vms.get(&vm_id)
                .ok_or_else(|| AppError::internal(format!("GCP VM config not found for {vm_id}")))?;
            let sa = load_gcp_sa(&state).map_err(AppError::internal)?;
            let current = gcp::get_instance_state(
                &state.http, &sa, &state.gcp_token_cache,
                &gcp_vm.project_id, &gcp_vm.zone, &gcp_vm.name,
            ).await.map_err(|e| AppError::internal(e))?;

            let action = if current == "RUNNING" { "reset" } else { "start" };
            gcp::instance_action(
                &state.http, &sa, &state.gcp_token_cache,
                &gcp_vm.project_id, &gcp_vm.zone, &gcp_vm.name, action,
            ).await.map_err(|e| AppError::internal(e))?;

            Ok(Json(json!({
                "status": "ok",
                "previous_state": current,
                "action": action,
                "vm_id": vm_id,
            })))
        }
    }
}

// ---------------------------------------------------------------------------
// Unified: single /api/vms/{vm_id}/{action} dispatcher
// ---------------------------------------------------------------------------

#[utoipa::path(
    post,
    path = "/api/vms/{vm_id}/{action}",
    tag = "Post-Engines",
    params(
        ("vm_id" = String, Path, description = "VM identifier (e.g. oci-A1-f_0, gcp-E2-f_0)"),
        ("action" = String, Path, description = "Action: start, stop, reset, status"),
    ),
    responses(
        (status = 200, description = "Action executed", body = Value),
        (status = 400, description = "Unknown action"),
        (status = 404, description = "Unknown VM"),
        (status = 500, description = "Action failed")
    )
)]
pub async fn vm_action(
    State(state): State<Arc<AppState>>,
    Path((vm_id, action)): Path<(String, String)>,
) -> Result<Json<Value>, AppError> {
    if !validate_vm_id(&vm_id) {
        return Err(AppError::bad_request("Invalid VM ID"));
    }
    match action.as_str() {
        "start" => vm_start(State(state), Path(vm_id)).await,
        "stop" => vm_stop(State(state), Path(vm_id)).await,
        "reset" => vm_reset(State(state), Path(vm_id)).await,
        "status" => {
            let vm_state = get_vm_state_by_id(&state, &vm_id).await
                .unwrap_or_else(|_| "unknown".into());
            Ok(Json(json!({
                "status": "ok",
                "vm_id": vm_id,
                "vm_state": vm_state,
            })))
        }
        _ => Err(AppError::bad_request(format!(
            "Unknown action '{action}'. Valid: start, stop, reset, status"
        ))),
    }
}

// ---------------------------------------------------------------------------
// Engine: generalized per-VM container/service actions (Post-Engines)
// ---------------------------------------------------------------------------

#[utoipa::path(
    post,
    path = "/api/vms/{vm_id}/containers/{name}/start",
    tag = "Post-Engines",
    params(
        ("vm_id" = String, Path, description = "VM identifier"),
        ("name" = String, Path, description = "Container name"),
    ),
    responses(
        (status = 200, description = "Container started", body = Value),
        (status = 400, description = "Invalid input"),
        (status = 500, description = "Failed to start container")
    )
)]
pub async fn vm_container_start(
    State(state): State<Arc<AppState>>,
    Path((vm_id, name)): Path<(String, String)>,
) -> Result<Json<Value>, AppError> {
    if !validate_vm_id(&vm_id) {
        return Err(AppError::bad_request("Invalid VM ID"));
    }
    if !validate_container_name(&name) {
        return Err(AppError::bad_request("Invalid container name"));
    }
    let (vm_state, vm_awakened) = ensure_vm_running_by_id(&state, &vm_id).await?;
    let ssh_cfg = state.config.vm_ssh.get(&vm_id)
        .ok_or_else(|| AppError::internal(format!("SSH config not found for {vm_id}")))?;
    let result = ssh::ssh_command(ssh_cfg, &format!("docker start {name}")).await;
    if !result.success {
        return Err(AppError::internal(format!("Failed to start container: {}", result.output)));
    }
    let statuses = get_container_statuses(&state, &vm_id, &[name.clone()]).await;
    Ok(Json(json!({
        "status": "ok", "vm_id": vm_id, "vm_state": vm_state,
        "vm_awakened": vm_awakened,
        "container": statuses.into_iter().next(),
    })))
}

#[utoipa::path(
    post,
    path = "/api/vms/{vm_id}/containers/{name}/stop",
    tag = "Post-Engines",
    params(
        ("vm_id" = String, Path, description = "VM identifier"),
        ("name" = String, Path, description = "Container name"),
    ),
    responses(
        (status = 200, description = "Container stopped", body = Value),
        (status = 400, description = "Invalid input"),
        (status = 500, description = "Failed to stop container")
    )
)]
pub async fn vm_container_stop(
    State(state): State<Arc<AppState>>,
    Path((vm_id, name)): Path<(String, String)>,
) -> Result<Json<Value>, AppError> {
    if !validate_vm_id(&vm_id) {
        return Err(AppError::bad_request("Invalid VM ID"));
    }
    if !validate_container_name(&name) {
        return Err(AppError::bad_request("Invalid container name"));
    }
    let vm_state = get_vm_state_by_id(&state, &vm_id).await.unwrap_or_else(|_| "unknown".into());
    if vm_state == "STOPPED" || vm_state == "TERMINATED" {
        return Ok(Json(json!({
            "status": "ok", "vm_id": vm_id, "vm_state": vm_state,
            "container": name, "action": "already_offline",
            "message": "VM is offline — containers are implicitly stopped",
        })));
    }
    let ssh_cfg = state.config.vm_ssh.get(&vm_id)
        .ok_or_else(|| AppError::internal(format!("SSH config not found for {vm_id}")))?;
    let result = ssh::ssh_command(ssh_cfg, &format!("docker stop {name}")).await;
    if !result.success {
        return Err(AppError::internal(format!("Failed to stop container: {}", result.output)));
    }
    Ok(Json(json!({
        "status": "ok", "vm_id": vm_id, "vm_state": vm_state,
        "container": name, "action": "stopped",
    })))
}

#[utoipa::path(
    post,
    path = "/api/vms/{vm_id}/containers/{name}/restart",
    tag = "Post-Engines",
    params(
        ("vm_id" = String, Path, description = "VM identifier"),
        ("name" = String, Path, description = "Container name"),
    ),
    responses(
        (status = 200, description = "Container restarted", body = Value),
        (status = 400, description = "Invalid input"),
        (status = 500, description = "Failed to restart container")
    )
)]
pub async fn vm_container_restart(
    State(state): State<Arc<AppState>>,
    Path((vm_id, name)): Path<(String, String)>,
) -> Result<Json<Value>, AppError> {
    if !validate_vm_id(&vm_id) {
        return Err(AppError::bad_request("Invalid VM ID"));
    }
    if !validate_container_name(&name) {
        return Err(AppError::bad_request("Invalid container name"));
    }
    let (vm_state, vm_awakened) = ensure_vm_running_by_id(&state, &vm_id).await?;
    let ssh_cfg = state.config.vm_ssh.get(&vm_id)
        .ok_or_else(|| AppError::internal(format!("SSH config not found for {vm_id}")))?;
    let result = ssh::ssh_command(ssh_cfg, &format!("docker restart {name}")).await;
    if !result.success {
        return Err(AppError::internal(format!("Failed to restart container: {}", result.output)));
    }
    let statuses = get_container_statuses(&state, &vm_id, &[name.clone()]).await;
    Ok(Json(json!({
        "status": "ok", "vm_id": vm_id, "vm_state": vm_state,
        "vm_awakened": vm_awakened,
        "container": statuses.into_iter().next(),
    })))
}

#[utoipa::path(
    post,
    path = "/api/vms/{vm_id}/services/{service}/start",
    tag = "Post-Engines",
    params(
        ("vm_id" = String, Path, description = "VM identifier"),
        ("service" = String, Path, description = "Service name"),
    ),
    responses(
        (status = 200, description = "Service started", body = Value),
        (status = 404, description = "Unknown service or VM"),
        (status = 500, description = "Failed to start service")
    )
)]
pub async fn vm_service_start(
    State(state): State<Arc<AppState>>,
    Path((vm_id, service)): Path<(String, String)>,
) -> Result<Json<Value>, AppError> {
    if !validate_vm_id(&vm_id) {
        return Err(AppError::bad_request("Invalid VM ID"));
    }
    let containers = validate_service_for_vm(&service, &vm_id, &state)?;
    let (vm_state, vm_awakened) = ensure_vm_running_by_id(&state, &vm_id).await?;
    let ssh_cfg = state.config.vm_ssh.get(&vm_id)
        .ok_or_else(|| AppError::internal(format!("SSH config not found for {vm_id}")))?;
    let containers_str = containers.join(" ");
    let result = ssh::ssh_command(ssh_cfg, &format!("docker start {containers_str}")).await;
    let statuses = get_container_statuses(&state, &vm_id, &containers).await;
    Ok(Json(json!({
        "status": if result.success { "ok" } else { "partial" },
        "vm_id": vm_id, "service": service, "vm_state": vm_state,
        "vm_awakened": vm_awakened,
        "containers": statuses,
    })))
}

#[utoipa::path(
    post,
    path = "/api/vms/{vm_id}/services/{service}/stop",
    tag = "Post-Engines",
    params(
        ("vm_id" = String, Path, description = "VM identifier"),
        ("service" = String, Path, description = "Service name"),
    ),
    responses(
        (status = 200, description = "Service stopped", body = Value),
        (status = 404, description = "Unknown service or VM"),
        (status = 500, description = "Failed to stop service")
    )
)]
pub async fn vm_service_stop(
    State(state): State<Arc<AppState>>,
    Path((vm_id, service)): Path<(String, String)>,
) -> Result<Json<Value>, AppError> {
    if !validate_vm_id(&vm_id) {
        return Err(AppError::bad_request("Invalid VM ID"));
    }
    let containers = validate_service_for_vm(&service, &vm_id, &state)?;
    let vm_state = get_vm_state_by_id(&state, &vm_id).await.unwrap_or_else(|_| "unknown".into());
    if vm_state == "STOPPED" || vm_state == "TERMINATED" {
        return Ok(Json(json!({
            "status": "ok", "vm_id": vm_id, "vm_state": vm_state,
            "service": service, "action": "already_offline",
            "message": "VM is offline — containers are implicitly stopped",
        })));
    }
    let ssh_cfg = state.config.vm_ssh.get(&vm_id)
        .ok_or_else(|| AppError::internal(format!("SSH config not found for {vm_id}")))?;
    let containers_str = containers.join(" ");
    let result = ssh::ssh_command(ssh_cfg, &format!("docker stop {containers_str}")).await;
    if !result.success {
        return Err(AppError::internal(format!("Failed to stop containers: {}", result.output)));
    }
    Ok(Json(json!({
        "status": "ok", "vm_id": vm_id, "vm_state": vm_state,
        "service": service, "action": "stopped", "containers": containers,
    })))
}

// ---------------------------------------------------------------------------
// Explicit per-VM actions (12 routes)
// ---------------------------------------------------------------------------

macro_rules! vm_action_handler {
    ($fn_name:ident, $path:literal, $vm_id:literal, $action:ident, $desc:literal) => {
        #[utoipa::path(post, path = $path, tag = "Post-VMs",
            responses((status = 200, description = $desc, body = Value),
                      (status = 500, description = "Failed")))]
        pub async fn $fn_name(
            State(state): State<Arc<AppState>>,
        ) -> Result<Json<Value>, AppError> {
            $action(State(state), Path($vm_id.to_string())).await
        }
    };
}

vm_action_handler!(vm_oci_apps_start, "/api/vm/oci-apps/start", "oci-A1-f_0", vm_start, "Start oci-apps");
vm_action_handler!(vm_oci_apps_stop, "/api/vm/oci-apps/stop", "oci-A1-f_0", vm_stop, "Stop oci-apps");
vm_action_handler!(vm_oci_apps_reset, "/api/vm/oci-apps/reset", "oci-A1-f_0", vm_reset, "Reset oci-apps");

vm_action_handler!(vm_oci_apps_1_start, "/api/vm/oci-apps-1/start", "oci-A1-f_1", vm_start, "Start oci-apps-1");
vm_action_handler!(vm_oci_apps_1_stop, "/api/vm/oci-apps-1/stop", "oci-A1-f_1", vm_stop, "Stop oci-apps-1");
vm_action_handler!(vm_oci_apps_1_reset, "/api/vm/oci-apps-1/reset", "oci-A1-f_1", vm_reset, "Reset oci-apps-1");

vm_action_handler!(vm_gcp_proxy_start, "/api/vm/gcp-proxy/start", "gcp-E2-f_0", vm_start, "Start gcp-proxy");
vm_action_handler!(vm_gcp_proxy_stop, "/api/vm/gcp-proxy/stop", "gcp-E2-f_0", vm_stop, "Stop gcp-proxy");
vm_action_handler!(vm_gcp_proxy_reset, "/api/vm/gcp-proxy/reset", "gcp-E2-f_0", vm_reset, "Reset gcp-proxy");

vm_action_handler!(vm_oci_mail_start, "/api/vm/oci-mail/start", "oci-E2-f_0", vm_start, "Start oci-mail");
vm_action_handler!(vm_oci_mail_stop, "/api/vm/oci-mail/stop", "oci-E2-f_0", vm_stop, "Stop oci-mail");
vm_action_handler!(vm_oci_mail_reset, "/api/vm/oci-mail/reset", "oci-E2-f_0", vm_reset, "Reset oci-mail");

vm_action_handler!(vm_oci_analytics_start, "/api/vm/oci-analytics/start", "oci-E2-f_1", vm_start, "Start oci-analytics");
vm_action_handler!(vm_oci_analytics_stop, "/api/vm/oci-analytics/stop", "oci-E2-f_1", vm_stop, "Stop oci-analytics");
vm_action_handler!(vm_oci_analytics_reset, "/api/vm/oci-analytics/reset", "oci-E2-f_1", vm_reset, "Reset oci-analytics");

// ---------------------------------------------------------------------------
// Bulk on-demand container ops (oci-apps-1)
// ---------------------------------------------------------------------------

#[utoipa::path(
    post,
    path = "/api/containers/on-demand/start-all",
    tag = "Post-Containers",
    responses(
        (status = 200, description = "All on-demand containers started", body = Value),
        (status = 500, description = "Failed to start containers")
    )
)]
pub async fn ondemand_containers_start_all(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let flex_vm_id = &state.config.flex_vm_id;
    let (vm_state, vm_awakened) = ensure_vm_running_by_id(&state, flex_vm_id).await?;

    let ssh_cfg = state.config.vm_ssh.get(flex_vm_id)
        .ok_or_else(|| AppError::internal("SSH config not found for flex VM"))?;

    let all_containers: Vec<String> = state.config.all_vm_services
        .get(flex_vm_id)
        .map(|vm_map| vm_map.services.values().flat_map(|c| c.clone()).collect())
        .unwrap_or_default();

    let containers_str = all_containers.join(" ");
    let result = ssh::ssh_command(ssh_cfg, &format!("docker start {containers_str}")).await;

    let statuses = batch_container_statuses(&state, flex_vm_id).await;
    let running = statuses.iter().filter(|(_, s, _)| s == "running").count();

    Ok(Json(json!({
        "status": if result.success { "ok" } else { "partial" },
        "vm_id": flex_vm_id,
        "vm_state": vm_state,
        "vm_awakened": vm_awakened,
        "action": "start-all",
        "containers_running": running,
        "containers_total": all_containers.len(),
    })))
}

#[utoipa::path(
    post,
    path = "/api/containers/on-demand/stop-all",
    tag = "Post-Containers",
    responses(
        (status = 200, description = "All on-demand containers stopped", body = Value),
        (status = 500, description = "Failed to stop containers")
    )
)]
pub async fn ondemand_containers_stop_all(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let flex_vm_id = &state.config.flex_vm_id;
    let vm_state = get_vm_state_by_id(&state, flex_vm_id).await.unwrap_or_else(|_| "unknown".into());

    if vm_state == "STOPPED" || vm_state == "TERMINATED" {
        return Ok(Json(json!({
            "status": "ok", "vm_id": flex_vm_id, "vm_state": vm_state,
            "action": "already_offline",
            "message": "VM is offline — containers are implicitly stopped",
        })));
    }

    let ssh_cfg = state.config.vm_ssh.get(flex_vm_id)
        .ok_or_else(|| AppError::internal("SSH config not found for flex VM"))?;

    let all_containers: Vec<String> = state.config.all_vm_services
        .get(flex_vm_id)
        .map(|vm_map| vm_map.services.values().flat_map(|c| c.clone()).collect())
        .unwrap_or_default();

    let containers_str = all_containers.join(" ");
    let result = ssh::ssh_command(ssh_cfg, &format!("docker stop {containers_str}")).await;

    Ok(Json(json!({
        "status": if result.success { "ok" } else { "partial" },
        "vm_id": flex_vm_id,
        "vm_state": vm_state,
        "action": "stop-all",
        "containers_total": all_containers.len(),
    })))
}

#[utoipa::path(
    post,
    path = "/api/containers/on-demand/restart-all",
    tag = "Post-Containers",
    responses(
        (status = 200, description = "All on-demand containers restarted", body = Value),
        (status = 500, description = "Failed to restart containers")
    )
)]
pub async fn ondemand_containers_restart_all(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let flex_vm_id = &state.config.flex_vm_id;
    let (vm_state, vm_awakened) = ensure_vm_running_by_id(&state, flex_vm_id).await?;

    let ssh_cfg = state.config.vm_ssh.get(flex_vm_id)
        .ok_or_else(|| AppError::internal("SSH config not found for flex VM"))?;

    let all_containers: Vec<String> = state.config.all_vm_services
        .get(flex_vm_id)
        .map(|vm_map| vm_map.services.values().flat_map(|c| c.clone()).collect())
        .unwrap_or_default();

    let containers_str = all_containers.join(" ");
    let result = ssh::ssh_command(ssh_cfg, &format!("docker restart {containers_str}")).await;

    let statuses = batch_container_statuses(&state, flex_vm_id).await;
    let running = statuses.iter().filter(|(_, s, _)| s == "running").count();

    Ok(Json(json!({
        "status": if result.success { "ok" } else { "partial" },
        "vm_id": flex_vm_id,
        "vm_state": vm_state,
        "vm_awakened": vm_awakened,
        "action": "restart-all",
        "containers_running": running,
        "containers_total": all_containers.len(),
    })))
}

// ---------------------------------------------------------------------------
// Matomo / Windmill toggle (oci-analytics — shared 956MB RAM)
// ---------------------------------------------------------------------------

const ANALYTICS_VM_ID: &str = "oci-E2-f_1";
const WINDMILL_COMPOSE: &str = "/home/ubuntu/windmill/docker-compose.yml";
const MATOMO_CONTAINER: &str = "matomo-hybrid";

#[utoipa::path(
    post,
    path = "/api/containers/windmill/start",
    tag = "Post-Containers",
    responses(
        (status = 200, description = "Windmill started (matomo sleeping)", body = Value),
        (status = 500, description = "Failed")
    )
)]
pub async fn windmill_start(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let (vm_state, vm_awakened) = ensure_vm_running_by_id(&state, ANALYTICS_VM_ID).await?;
    let ssh_cfg = state.config.vm_ssh.get(ANALYTICS_VM_ID)
        .ok_or_else(|| AppError::internal("SSH config not found for oci-analytics"))?;

    // Sleep matomo first, then start windmill
    let sleep = ssh::ssh_command(ssh_cfg,
        &format!("docker exec {MATOMO_CONTAINER} /scripts/matomo-sleep.sh")).await;
    let start = ssh::ssh_command(ssh_cfg,
        &format!("docker-compose -f {WINDMILL_COMPOSE} start")).await;

    Ok(Json(json!({
        "status": if start.success { "ok" } else { "partial" },
        "vm_id": ANALYTICS_VM_ID,
        "vm_state": vm_state,
        "vm_awakened": vm_awakened,
        "action": "windmill-start",
        "matomo_sleep": sleep.success,
        "windmill_start": start.success,
    })))
}

#[utoipa::path(
    post,
    path = "/api/containers/windmill/stop",
    tag = "Post-Containers",
    responses(
        (status = 200, description = "Windmill stopped (matomo waking)", body = Value),
        (status = 500, description = "Failed")
    )
)]
pub async fn windmill_stop(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let (vm_state, vm_awakened) = ensure_vm_running_by_id(&state, ANALYTICS_VM_ID).await?;
    let ssh_cfg = state.config.vm_ssh.get(ANALYTICS_VM_ID)
        .ok_or_else(|| AppError::internal("SSH config not found for oci-analytics"))?;

    // Stop windmill first, then wake matomo
    let stop = ssh::ssh_command(ssh_cfg,
        &format!("docker-compose -f {WINDMILL_COMPOSE} stop")).await;
    let wake = ssh::ssh_command(ssh_cfg,
        &format!("docker exec {MATOMO_CONTAINER} /scripts/matomo-wake.sh")).await;

    Ok(Json(json!({
        "status": if stop.success { "ok" } else { "partial" },
        "vm_id": ANALYTICS_VM_ID,
        "vm_state": vm_state,
        "vm_awakened": vm_awakened,
        "action": "windmill-stop",
        "windmill_stop": stop.success,
        "matomo_wake": wake.success,
    })))
}

#[utoipa::path(
    post,
    path = "/api/containers/matomo/wake",
    tag = "Post-Containers",
    responses(
        (status = 200, description = "Matomo waking (windmill stopped)", body = Value),
        (status = 500, description = "Failed")
    )
)]
pub async fn matomo_wake(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let (vm_state, vm_awakened) = ensure_vm_running_by_id(&state, ANALYTICS_VM_ID).await?;
    let ssh_cfg = state.config.vm_ssh.get(ANALYTICS_VM_ID)
        .ok_or_else(|| AppError::internal("SSH config not found for oci-analytics"))?;

    // Stop windmill first, then wake matomo
    let stop = ssh::ssh_command(ssh_cfg,
        &format!("docker-compose -f {WINDMILL_COMPOSE} stop")).await;
    let wake = ssh::ssh_command(ssh_cfg,
        &format!("docker exec {MATOMO_CONTAINER} /scripts/matomo-wake.sh")).await;

    Ok(Json(json!({
        "status": if wake.success { "ok" } else { "partial" },
        "vm_id": ANALYTICS_VM_ID,
        "vm_state": vm_state,
        "vm_awakened": vm_awakened,
        "action": "matomo-wake",
        "windmill_stop": stop.success,
        "matomo_wake": wake.success,
    })))
}

#[utoipa::path(
    post,
    path = "/api/containers/matomo/sleep",
    tag = "Post-Containers",
    responses(
        (status = 200, description = "Matomo sleeping (windmill started)", body = Value),
        (status = 500, description = "Failed")
    )
)]
pub async fn matomo_sleep(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let (vm_state, vm_awakened) = ensure_vm_running_by_id(&state, ANALYTICS_VM_ID).await?;
    let ssh_cfg = state.config.vm_ssh.get(ANALYTICS_VM_ID)
        .ok_or_else(|| AppError::internal("SSH config not found for oci-analytics"))?;

    // Sleep matomo first, then start windmill
    let sleep = ssh::ssh_command(ssh_cfg,
        &format!("docker exec {MATOMO_CONTAINER} /scripts/matomo-sleep.sh")).await;
    let start = ssh::ssh_command(ssh_cfg,
        &format!("docker-compose -f {WINDMILL_COMPOSE} start")).await;

    Ok(Json(json!({
        "status": if sleep.success { "ok" } else { "partial" },
        "vm_id": ANALYTICS_VM_ID,
        "vm_state": vm_state,
        "vm_awakened": vm_awakened,
        "action": "matomo-sleep",
        "matomo_sleep": sleep.success,
        "windmill_start": start.success,
    })))
}

#[utoipa::path(
    post,
    path = "/api/containers/{name}/start",
    tag = "Post-Engines",
    params(("name" = String, Path, description = "Container name")),
    responses(
        (status = 200, description = "Container started", body = Value),
        (status = 400, description = "Invalid container name"),
        (status = 500, description = "Failed to start container")
    )
)]
pub async fn ondemand_container_start(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
) -> Result<Json<Value>, AppError> {
    let flex_vm_id = state.config.flex_vm_id.clone();
    vm_container_start(State(state), Path((flex_vm_id, name))).await
}

#[utoipa::path(
    post,
    path = "/api/containers/{name}/stop",
    tag = "Post-Engines",
    params(("name" = String, Path, description = "Container name")),
    responses(
        (status = 200, description = "Container stopped", body = Value),
        (status = 400, description = "Invalid container name"),
        (status = 500, description = "Failed to stop container")
    )
)]
pub async fn ondemand_container_stop(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
) -> Result<Json<Value>, AppError> {
    let flex_vm_id = state.config.flex_vm_id.clone();
    vm_container_stop(State(state), Path((flex_vm_id, name))).await
}

#[utoipa::path(
    post,
    path = "/api/containers/{name}/restart",
    tag = "Post-Engines",
    params(("name" = String, Path, description = "Container name")),
    responses(
        (status = 200, description = "Container restarted", body = Value),
        (status = 400, description = "Invalid container name"),
        (status = 500, description = "Failed to restart container")
    )
)]
pub async fn ondemand_container_restart(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
) -> Result<Json<Value>, AppError> {
    let flex_vm_id = state.config.flex_vm_id.clone();
    vm_container_restart(State(state), Path((flex_vm_id, name))).await
}

#[utoipa::path(
    post,
    path = "/api/services/{service}/start",
    tag = "Post-Engines",
    params(("service" = String, Path, description = "Service name")),
    responses(
        (status = 200, description = "Service started", body = Value),
        (status = 404, description = "Unknown service"),
        (status = 500, description = "Failed to start service")
    )
)]
pub async fn ondemand_service_start(
    State(state): State<Arc<AppState>>,
    Path(service): Path<String>,
) -> Result<Json<Value>, AppError> {
    let flex_vm_id = state.config.flex_vm_id.clone();
    vm_service_start(State(state), Path((flex_vm_id, service))).await
}

#[utoipa::path(
    post,
    path = "/api/services/{service}/stop",
    tag = "Post-Engines",
    params(("service" = String, Path, description = "Service name")),
    responses(
        (status = 200, description = "Service stopped", body = Value),
        (status = 404, description = "Unknown service"),
        (status = 500, description = "Failed to stop service")
    )
)]
pub async fn ondemand_service_stop(
    State(state): State<Arc<AppState>>,
    Path(service): Path<String>,
) -> Result<Json<Value>, AppError> {
    let flex_vm_id = state.config.flex_vm_id.clone();
    vm_service_stop(State(state), Path((flex_vm_id, service))).await
}
