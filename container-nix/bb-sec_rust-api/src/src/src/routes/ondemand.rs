use axum::{
    extract::{Path, State},
    routing::{get, post},
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
        // Health
        .route("/rust/health/all", get(health_all))
        .route("/rust/health/containers-by-vm", get(health_containers_by_vm))
        .route("/rust/health/containers-by-service", get(health_containers_by_service))
        .route("/rust/health/proxied-by-services", get(health_proxied_by_services))
        // Legacy flex-shortcut routes (backward compat)
        .route("/rust/vm/start", post(ondemand_vm_start))
        .route("/rust/vm/stop", post(ondemand_vm_stop))
        .route("/rust/vm/reset", post(ondemand_vm_reset))
        .route("/rust/containers/{name}/status", get(ondemand_container_status))
        .route("/rust/containers/{name}/start", post(ondemand_container_start))
        .route("/rust/containers/{name}/stop", post(ondemand_container_stop))
        .route("/rust/containers/{name}/restart", post(ondemand_container_restart))
        .route("/rust/services/{service}/start", post(ondemand_service_start))
        .route("/rust/services/{service}/stop", post(ondemand_service_stop))
        // Generalized per-VM routes
        .route("/rust/vms/{vm_id}/health", get(vm_health))
        .route("/rust/vms/{vm_id}/start", post(vm_start))
        .route("/rust/vms/{vm_id}/stop", post(vm_stop))
        .route("/rust/vms/{vm_id}/reset", post(vm_reset))
        .route("/rust/vms/{vm_id}/containers/{name}/status", get(vm_container_status))
        .route("/rust/vms/{vm_id}/containers/{name}/start", post(vm_container_start))
        .route("/rust/vms/{vm_id}/containers/{name}/stop", post(vm_container_stop))
        .route("/rust/vms/{vm_id}/containers/{name}/restart", post(vm_container_restart))
        .route("/rust/vms/{vm_id}/services/{service}/start", post(vm_service_start))
        .route("/rust/vms/{vm_id}/services/{service}/stop", post(vm_service_stop))
}

// ---------------------------------------------------------------------------
// Helpers — generalized to accept vm_id
// ---------------------------------------------------------------------------

fn validate_service_for_vm(service: &str, vm_id: &str, state: &AppState) -> Result<Vec<String>, AppError> {
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
fn load_gcp_sa(state: &AppState) -> Result<gcp::ServiceAccountConfig, String> {
    gcp::parse_service_account(&state.config.gcp_service_account_file)
}

/// Get the provider state for any VM.
async fn get_vm_state_by_id(state: &AppState, vm_id: &str) -> Result<String, AppError> {
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

/// Ensure a VM is running. Starts it and polls if stopped. Returns current state.
async fn ensure_vm_running_by_id(state: &AppState, vm_id: &str) -> Result<String, AppError> {
    let vm = state.config.vm_instances.get(vm_id)
        .ok_or_else(|| AppError::service_unavailable(format!("VM {vm_id} not configured")))?;

    match vm.provider {
        VmProvider::Oci => {
            let current = oci::get_instance_state(&state.http, &state.config, &vm.instance_id)
                .await
                .map_err(|e| AppError::internal(e))?;

            if current == "RUNNING" {
                return Ok(current);
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
                        return Ok("RUNNING".into());
                    }
                }
                return Err(AppError::internal("Timeout waiting for VM to start"));
            }

            Ok(current)
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
                return Ok(current);
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
                        return Ok("RUNNING".into());
                    }
                }
                return Err(AppError::internal("Timeout waiting for GCP VM to start"));
            }

            Ok(current)
        }
    }
}

/// Get container statuses on a specific VM.
async fn get_container_statuses(state: &AppState, vm_id: &str, containers: &[String]) -> Vec<Value> {
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
async fn batch_container_statuses(state: &AppState, vm_id: &str) -> Vec<(String, String, String)> {
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
fn compute_service_status(containers: &[String], all_statuses: &[(String, String, String)]) -> Value {
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
fn compute_health(provider_state: &str, ssh_ok: bool) -> &'static str {
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
fn should_probe(provider_state: &str) -> bool {
    matches!(provider_state, "RUNNING" | "N/A")
}

// ---------------------------------------------------------------------------
// Status endpoints
// ---------------------------------------------------------------------------

#[utoipa::path(
    get,
    path = "/rust/health/all",
    tag = "Get-Health",
    responses(
        (status = 200, description = "Health of all VMs with services and containers", body = Value),
        (status = 500, description = "Internal error")
    )
)]
pub async fn health_all(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let mut vms = serde_json::Map::new();
    let mut global_services_up = 0u32;
    let mut global_services_down = 0u32;
    let mut global_services_partial = 0u32;
    let mut global_containers_running = 0u32;
    let mut global_containers_total = 0u32;

    for (vm_id, vm_map) in &state.config.all_vm_services {
        let provider_state = get_vm_state_by_id(&state, vm_id)
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
                batch_container_statuses(&state, vm_id).await
            } else {
                vec![]
            };
            (p, s, data)
        } else {
            (false, false, vec![])
        };

        let health = compute_health(&provider_state, ssh_ok);

        let mut services = serde_json::Map::new();
        let mut vm_services_up = 0u32;
        let mut vm_services_down = 0u32;
        let mut vm_services_partial = 0u32;
        let mut vm_containers_running = 0u32;
        let mut vm_containers_total = 0u32;

        for (svc_name, containers) in &vm_map.services {
            let svc_status = compute_service_status(containers, &container_data);
            let status_str = svc_status["status"].as_str().unwrap_or("down");
            match status_str {
                "up" => vm_services_up += 1,
                "partial" => vm_services_partial += 1,
                _ => vm_services_down += 1,
            }
            if let Some(ctrs) = svc_status["containers"].as_array() {
                for c in ctrs {
                    vm_containers_total += 1;
                    if c["state"].as_str() == Some("running") {
                        vm_containers_running += 1;
                    }
                }
            }
            services.insert(svc_name.clone(), svc_status);
        }

        global_services_up += vm_services_up;
        global_services_down += vm_services_down;
        global_services_partial += vm_services_partial;
        global_containers_running += vm_containers_running;
        global_containers_total += vm_containers_total;

        vms.insert(vm_id.clone(), json!({
            "label": vm_map.label,
            "provider_state": provider_state,
            "ssh": ssh_ok,
            "ping": ping,
            "health": health,
            "services": services,
            "summary": {
                "services_up": vm_services_up,
                "services_down": vm_services_down,
                "services_partial": vm_services_partial,
                "containers_running": vm_containers_running,
                "containers_total": vm_containers_total,
            }
        }));
    }

    Ok(Json(json!({
        "vms": vms,
        "global_summary": {
            "services_up": global_services_up,
            "services_down": global_services_down,
            "services_partial": global_services_partial,
            "containers_running": global_containers_running,
            "containers_total": global_containers_total,
        }
    })))
}

// ---------------------------------------------------------------------------
// Health check endpoints
// ---------------------------------------------------------------------------

#[utoipa::path(
    get,
    path = "/rust/health/containers-by-vm",
    tag = "Get-Health",
    responses(
        (status = 200, description = "Container health across all VMs grouped by VM", body = Value),
        (status = 500, description = "Internal error")
    )
)]
pub async fn health_containers_by_vm(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let mut set = tokio::task::JoinSet::new();

    for (vm_id, vm_map) in &state.config.all_vm_services {
        let vm_id = vm_id.clone();
        let label = vm_map.label.clone();
        let state = Arc::clone(&state);
        set.spawn(async move {
            let containers = batch_container_statuses(&state, &vm_id).await;
            (vm_id, label, containers)
        });
    }

    let mut vms = serde_json::Map::new();
    let mut global_running = 0u32;
    let mut global_total = 0u32;

    while let Some(result) = set.join_next().await {
        let (vm_id, label, containers) = match result {
            Ok(v) => v,
            Err(_) => continue,
        };

        let mut running = 0u32;
        let details: Vec<Value> = containers.iter().map(|(name, st, ports)| {
            if st == "running" { running += 1; }
            global_total += 1;
            json!({ "name": name, "state": st, "ports": ports })
        }).collect();
        global_running += running;

        vms.insert(vm_id, json!({
            "label": label,
            "containers": details,
            "running": running,
            "total": details.len(),
        }));
    }

    Ok(Json(json!({
        "vms": vms,
        "summary": {
            "containers_running": global_running,
            "containers_total": global_total,
        }
    })))
}

#[utoipa::path(
    get,
    path = "/rust/health/containers-by-service",
    tag = "Get-Health",
    responses(
        (status = 200, description = "Container health grouped by service across VMs", body = Value),
        (status = 500, description = "Internal error")
    )
)]
pub async fn health_containers_by_service(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let mut set = tokio::task::JoinSet::new();

    for (vm_id, vm_map) in &state.config.all_vm_services {
        let vm_id = vm_id.clone();
        let label = vm_map.label.clone();
        let state = Arc::clone(&state);
        set.spawn(async move {
            let containers = batch_container_statuses(&state, &vm_id).await;
            (vm_id, label, containers)
        });
    }

    let mut vm_results: Vec<(String, String, Vec<(String, String, String)>)> = vec![];
    while let Some(result) = set.join_next().await {
        if let Ok(v) = result {
            vm_results.push(v);
        }
    }

    // Pivot: group by service across VMs
    let mut services_map = serde_json::Map::new();
    let mut global_running = 0u32;
    let mut global_total = 0u32;

    for (vm_id, vm_map) in &state.config.all_vm_services {
        let vm_containers = vm_results.iter()
            .find(|(id, _, _)| id == vm_id)
            .map(|(_, _, c)| c.as_slice())
            .unwrap_or(&[]);

        for (svc_name, svc_containers) in &vm_map.services {
            let mut running = 0u32;
            let details: Vec<Value> = svc_containers.iter().map(|name| {
                let (st, ports) = vm_containers.iter()
                    .find(|(n, _, _)| n == name)
                    .map(|(_, s, p)| (s.clone(), p.clone()))
                    .unwrap_or_else(|| ("not_found".into(), String::new()));
                if st == "running" { running += 1; }
                global_total += 1;
                json!({ "name": name, "state": st, "ports": ports })
            }).collect();
            global_running += running;
            let total = details.len() as u32;

            let entry = services_map.entry(svc_name.clone())
                .or_insert_with(|| json!({ "vms": {} }));
            entry["vms"][vm_id] = json!({
                "label": vm_map.label,
                "containers": details,
                "running": running,
                "total": total,
            });
        }
    }

    // Compute per-service status
    let mut services_up = 0u32;
    let mut services_partial = 0u32;
    let mut services_down = 0u32;

    for (_svc_name, svc_val) in services_map.iter_mut() {
        let mut svc_running = 0u32;
        let mut svc_total = 0u32;
        if let Some(vms_obj) = svc_val["vms"].as_object() {
            for (_vm_id, vm_data) in vms_obj {
                svc_running += vm_data["running"].as_u64().unwrap_or(0) as u32;
                svc_total += vm_data["total"].as_u64().unwrap_or(0) as u32;
            }
        }
        let status = if svc_total == 0 {
            "down"
        } else if svc_running == svc_total {
            "up"
        } else if svc_running == 0 {
            "down"
        } else {
            "partial"
        };
        match status {
            "up" => services_up += 1,
            "partial" => services_partial += 1,
            _ => services_down += 1,
        }
        svc_val["status"] = json!(status);
    }

    Ok(Json(json!({
        "services": services_map,
        "summary": {
            "services_up": services_up,
            "services_partial": services_partial,
            "services_down": services_down,
            "containers_running": global_running,
            "containers_total": global_total,
        }
    })))
}

async fn probe_domain_chain(
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

#[utoipa::path(
    get,
    path = "/rust/health/proxied-by-services",
    tag = "Get-Health",
    responses(
        (status = 200, description = "Public route health probes with redirect chain", body = Value),
        (status = 500, description = "Internal error")
    )
)]
pub async fn health_proxied_by_services(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let mut set = tokio::task::JoinSet::new();
    let bearer = state.config.authelia_bearer_token.clone();

    for entry in &state.config.route_check_domains {
        let http = state.http.clone();
        let domain = entry.domain.clone();
        let service = entry.service.clone();
        let token = bearer.clone();
        set.spawn(async move {
            probe_domain_chain(&http, &domain, &service, token.as_deref()).await
        });
    }

    let mut routes = vec![];
    let mut healthy_count = 0u32;
    let mut total = 0u32;

    while let Some(result) = set.join_next().await {
        if let Ok(val) = result {
            total += 1;
            if val["healthy"].as_bool() == Some(true) {
                healthy_count += 1;
            }
            routes.push(val);
        }
    }

    // Sort by service for consistent output
    routes.sort_by(|a, b| {
        a["service"].as_str().unwrap_or("").cmp(b["service"].as_str().unwrap_or(""))
    });

    Ok(Json(json!({
        "routes": routes,
        "summary": {
            "healthy": healthy_count,
            "total": total,
        }
    })))
}

// ---------------------------------------------------------------------------
// Generalized per-VM endpoints
// ---------------------------------------------------------------------------

#[utoipa::path(
    get,
    path = "/rust/vms/{vm_id}/health",
    tag = "Get-Health",
    params(("vm_id" = String, Path, description = "VM identifier")),
    responses(
        (status = 200, description = "VM health check", body = Value),
        (status = 404, description = "Unknown VM"),
        (status = 500, description = "Internal error")
    )
)]
pub async fn vm_health(
    State(state): State<Arc<AppState>>,
    Path(vm_id): Path<String>,
) -> Result<Json<Value>, AppError> {
    if !validate_vm_id(&vm_id) {
        return Err(AppError::bad_request("Invalid VM ID"));
    }
    if !state.config.vm_ssh.contains_key(&vm_id) {
        return Err(AppError::not_found(format!("Unknown VM: {vm_id}")));
    }

    let provider_state = get_vm_state_by_id(&state, &vm_id).await.unwrap_or_else(|_| "unknown".into());

    let ssh_cfg = state.config.vm_ssh.get(&vm_id);
    let host = ssh_cfg.map(|c| c.host.as_str()).unwrap_or("");

    let (ping, ssh_ok) = if should_probe(&provider_state) {
        let p = ssh::check_ping(host).await;
        let s = match ssh_cfg {
            Some(cfg) => ssh::check_ssh(cfg).await,
            None => false,
        };
        (p, s)
    } else {
        (false, false)
    };

    let health = compute_health(&provider_state, ssh_ok);

    Ok(Json(json!({
        "id": vm_id,
        "provider_state": provider_state,
        "ssh": ssh_ok,
        "ping": ping,
        "health": health,
    })))
}

#[utoipa::path(
    post,
    path = "/rust/vms/{vm_id}/start",
    tag = "Post-VMs",
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
    let vm_state = ensure_vm_running_by_id(&state, &vm_id).await?;
    Ok(Json(json!({
        "status": "ok",
        "vm_id": vm_id,
        "vm_state": vm_state,
    })))
}

#[utoipa::path(
    post,
    path = "/rust/vms/{vm_id}/stop",
    tag = "Post-VMs",
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
    path = "/rust/vms/{vm_id}/reset",
    tag = "Post-VMs",
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
            let action = if current == "RUNNING" { "SOFTRESET" } else { "START" };
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

#[utoipa::path(
    get,
    path = "/rust/vms/{vm_id}/containers/{name}/status",
    tag = "Get-Health",
    params(
        ("vm_id" = String, Path, description = "VM identifier"),
        ("name" = String, Path, description = "Container name"),
    ),
    responses(
        (status = 200, description = "Container status", body = Value),
        (status = 400, description = "Invalid input"),
        (status = 500, description = "Internal error")
    )
)]
pub async fn vm_container_status(
    State(state): State<Arc<AppState>>,
    Path((vm_id, name)): Path<(String, String)>,
) -> Result<Json<Value>, AppError> {
    if !validate_vm_id(&vm_id) {
        return Err(AppError::bad_request("Invalid VM ID"));
    }
    if !validate_container_name(&name) {
        return Err(AppError::bad_request("Invalid container name"));
    }

    let statuses = get_container_statuses(&state, &vm_id, &[name.clone()]).await;
    let status = statuses.into_iter().next().unwrap_or_else(|| json!({"name": name, "status": "unknown"}));
    Ok(Json(status))
}

#[utoipa::path(
    post,
    path = "/rust/vms/{vm_id}/containers/{name}/start",
    tag = "Post-Containers",
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

    let vm_state = ensure_vm_running_by_id(&state, &vm_id).await?;

    let ssh_cfg = state.config.vm_ssh.get(&vm_id)
        .ok_or_else(|| AppError::internal(format!("SSH config not found for {vm_id}")))?;

    let result = ssh::ssh_command(ssh_cfg, &format!("docker start {name}")).await;
    if !result.success {
        return Err(AppError::internal(format!("Failed to start container: {}", result.output)));
    }

    let statuses = get_container_statuses(&state, &vm_id, &[name.clone()]).await;

    Ok(Json(json!({
        "status": "ok",
        "vm_id": vm_id,
        "vm_state": vm_state,
        "container": statuses.into_iter().next(),
    })))
}

#[utoipa::path(
    post,
    path = "/rust/vms/{vm_id}/containers/{name}/stop",
    tag = "Post-Containers",
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

    let ssh_cfg = state.config.vm_ssh.get(&vm_id)
        .ok_or_else(|| AppError::internal(format!("SSH config not found for {vm_id}")))?;

    let result = ssh::ssh_command(ssh_cfg, &format!("docker stop {name}")).await;
    if !result.success {
        return Err(AppError::internal(format!("Failed to stop container: {}", result.output)));
    }

    Ok(Json(json!({
        "status": "ok",
        "vm_id": vm_id,
        "container": name,
        "action": "stopped",
    })))
}

#[utoipa::path(
    post,
    path = "/rust/vms/{vm_id}/containers/{name}/restart",
    tag = "Post-Containers",
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

    let vm_state = ensure_vm_running_by_id(&state, &vm_id).await?;

    let ssh_cfg = state.config.vm_ssh.get(&vm_id)
        .ok_or_else(|| AppError::internal(format!("SSH config not found for {vm_id}")))?;

    let result = ssh::ssh_command(ssh_cfg, &format!("docker restart {name}")).await;
    if !result.success {
        return Err(AppError::internal(format!("Failed to restart container: {}", result.output)));
    }

    let statuses = get_container_statuses(&state, &vm_id, &[name.clone()]).await;

    Ok(Json(json!({
        "status": "ok",
        "vm_id": vm_id,
        "vm_state": vm_state,
        "container": statuses.into_iter().next(),
    })))
}

#[utoipa::path(
    post,
    path = "/rust/vms/{vm_id}/services/{service}/start",
    tag = "Post-Containers",
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

    let vm_state = ensure_vm_running_by_id(&state, &vm_id).await?;

    let ssh_cfg = state.config.vm_ssh.get(&vm_id)
        .ok_or_else(|| AppError::internal(format!("SSH config not found for {vm_id}")))?;

    let containers_str = containers.join(" ");
    let result = ssh::ssh_command(ssh_cfg, &format!("docker start {containers_str}")).await;

    let statuses = get_container_statuses(&state, &vm_id, &containers).await;

    Ok(Json(json!({
        "status": if result.success { "ok" } else { "partial" },
        "vm_id": vm_id,
        "service": service,
        "vm_state": vm_state,
        "containers": statuses,
    })))
}

#[utoipa::path(
    post,
    path = "/rust/vms/{vm_id}/services/{service}/stop",
    tag = "Post-Containers",
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

    let ssh_cfg = state.config.vm_ssh.get(&vm_id)
        .ok_or_else(|| AppError::internal(format!("SSH config not found for {vm_id}")))?;

    let containers_str = containers.join(" ");
    let result = ssh::ssh_command(ssh_cfg, &format!("docker stop {containers_str}")).await;

    if !result.success {
        return Err(AppError::internal(format!("Failed to stop containers: {}", result.output)));
    }

    Ok(Json(json!({
        "status": "ok",
        "vm_id": vm_id,
        "service": service,
        "action": "stopped",
        "containers": containers,
    })))
}

// ---------------------------------------------------------------------------
// Legacy flex-shortcut endpoints (delegate to generalized helpers)
// ---------------------------------------------------------------------------

#[utoipa::path(
    post,
    path = "/rust/vm/start",
    tag = "Post-VMs",
    responses(
        (status = 200, description = "VM started", body = Value),
        (status = 500, description = "Failed to start VM")
    )
)]
pub async fn ondemand_vm_start(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let flex_vm_id = state.config.flex_vm_id.clone();
    vm_start(State(state), Path(flex_vm_id)).await
}

#[utoipa::path(
    post,
    path = "/rust/vm/stop",
    tag = "Post-VMs",
    responses(
        (status = 200, description = "VM stopped gracefully", body = Value),
        (status = 500, description = "Failed to stop VM")
    )
)]
pub async fn ondemand_vm_stop(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let flex_vm_id = state.config.flex_vm_id.clone();
    vm_stop(State(state), Path(flex_vm_id)).await
}

#[utoipa::path(
    post,
    path = "/rust/vm/reset",
    tag = "Post-VMs",
    responses(
        (status = 200, description = "VM reset/started", body = Value),
        (status = 500, description = "Failed to reset VM")
    )
)]
pub async fn ondemand_vm_reset(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let flex_vm_id = state.config.flex_vm_id.clone();
    vm_reset(State(state), Path(flex_vm_id)).await
}

#[utoipa::path(
    get,
    path = "/rust/containers/{name}/status",
    tag = "Get-Health",
    params(("name" = String, Path, description = "Container name")),
    responses(
        (status = 200, description = "Container status", body = Value),
        (status = 400, description = "Invalid container name"),
        (status = 500, description = "Internal error")
    )
)]
pub async fn ondemand_container_status(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
) -> Result<Json<Value>, AppError> {
    let flex_vm_id = state.config.flex_vm_id.clone();
    vm_container_status(State(state), Path((flex_vm_id, name))).await
}

#[utoipa::path(
    post,
    path = "/rust/containers/{name}/start",
    tag = "Post-Containers",
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
    path = "/rust/containers/{name}/stop",
    tag = "Post-Containers",
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
    path = "/rust/containers/{name}/restart",
    tag = "Post-Containers",
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
    path = "/rust/services/{service}/start",
    tag = "Post-Containers",
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
    path = "/rust/services/{service}/stop",
    tag = "Post-Containers",
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
