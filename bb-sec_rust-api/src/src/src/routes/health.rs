use axum::{
    extract::{Path, State},
    routing::get,
    Json, Router,
};
use serde_json::{json, Value};
use std::sync::Arc;

use crate::error::AppError;
use crate::models::vm::validate_vm_id;
use crate::AppState;

use super::ondemand::{
    batch_container_statuses, compute_service_status, gather_vm_resources, probe_domain_chain,
    probe_vm, round1,
};

pub fn routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/api/health", get(health_alive))
        .route("/api/health/declared", get(health_declared))
        .route("/api/health/deployed", get(health_deployed))
        .route("/api/health/deployed/{vm_id}", get(health_deployed_vm))
        .route("/api/health/drift", get(health_drift))
        .route("/api/health/status", get(health_status))
        .route("/api/health/status/{vm_id}", get(health_status_vm))
}

// ---------------------------------------------------------------------------
// Tier 0: Alive
// ---------------------------------------------------------------------------

#[utoipa::path(
    get,
    path = "/api/health",
    tag = "Health",
    responses(
        (status = 200, description = "API alive check", body = Value),
    )
)]
pub async fn health_alive() -> Json<Value> {
    Json(json!({ "status": "ok" }))
}

// ---------------------------------------------------------------------------
// Tier 0: Declared (instant, no SSH)
// ---------------------------------------------------------------------------

#[utoipa::path(
    get,
    path = "/api/health/declared",
    tag = "Health",
    responses(
        (status = 200, description = "Declared services and containers from config (no SSH)", body = Value),
    )
)]
pub async fn health_declared(
    State(state): State<Arc<AppState>>,
) -> Json<Value> {
    let mut vms = serde_json::Map::new();
    let mut total_services = 0u32;
    let mut total_containers = 0u32;

    for (vm_id, vm_map) in &state.config.all_vm_services {
        let mut services_map = serde_json::Map::new();
        for (svc_name, containers) in &vm_map.services {
            total_services += 1;
            total_containers += containers.len() as u32;
            services_map.insert(svc_name.clone(), json!(containers));
        }
        vms.insert(vm_id.clone(), json!({
            "label": vm_map.label,
            "services": services_map,
        }));
    }

    let domains: serde_json::Map<String, Value> = state.config.container_domain_map
        .iter()
        .map(|(k, v)| (k.clone(), json!(v)))
        .collect();

    Json(json!({
        "vms": vms,
        "domains": domains,
        "totals": {
            "vms": state.config.all_vm_services.len(),
            "services": total_services,
            "containers": total_containers,
        }
    }))
}

// ---------------------------------------------------------------------------
// Tier 1: Deployed (docker ps -a via SSH)
// ---------------------------------------------------------------------------

#[utoipa::path(
    get,
    path = "/api/health/deployed",
    tag = "Health",
    responses(
        (status = 200, description = "Docker container states across all VMs (parallel SSH)", body = Value),
        (status = 500, description = "Internal error")
    )
)]
pub async fn health_deployed(
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
    let mut global_stopped = 0u32;
    let mut global_total = 0u32;

    while let Some(result) = set.join_next().await {
        let (vm_id, label, containers) = match result {
            Ok(v) => v,
            Err(_) => continue,
        };

        let mut running = 0u32;
        let mut stopped = 0u32;
        let details: Vec<Value> = containers.iter().map(|(name, st, ports)| {
            if st == "running" {
                running += 1;
            } else {
                stopped += 1;
            }
            json!({ "name": name, "state": st, "ports": ports })
        }).collect();
        let total = details.len() as u32;
        global_running += running;
        global_stopped += stopped;
        global_total += total;

        vms.insert(vm_id, json!({
            "label": label,
            "containers": details,
            "running": running,
            "stopped": stopped,
            "total": total,
        }));
    }

    Ok(Json(json!({
        "vms": vms,
        "summary": {
            "running": global_running,
            "stopped": global_stopped,
            "total": global_total,
        }
    })))
}

#[utoipa::path(
    get,
    path = "/api/health/deployed/{vm_id}",
    tag = "Health",
    params(("vm_id" = String, Path, description = "VM identifier")),
    responses(
        (status = 200, description = "Docker container states for one VM", body = Value),
        (status = 404, description = "Unknown VM"),
    )
)]
pub async fn health_deployed_vm(
    State(state): State<Arc<AppState>>,
    Path(vm_id): Path<String>,
) -> Result<Json<Value>, AppError> {
    if !validate_vm_id(&vm_id) {
        return Err(AppError::bad_request("Invalid VM ID"));
    }
    let vm_map = state.config.all_vm_services.get(&vm_id)
        .ok_or_else(|| AppError::not_found(format!("Unknown VM: {vm_id}")))?;

    let containers = batch_container_statuses(&state, &vm_id).await;
    let mut running = 0u32;
    let mut stopped = 0u32;
    let details: Vec<Value> = containers.iter().map(|(name, st, ports)| {
        if st == "running" {
            running += 1;
        } else {
            stopped += 1;
        }
        json!({ "name": name, "state": st, "ports": ports })
    }).collect();

    Ok(Json(json!({
        "vm_id": vm_id,
        "label": vm_map.label,
        "containers": details,
        "running": running,
        "stopped": stopped,
        "total": details.len(),
    })))
}

// ---------------------------------------------------------------------------
// Tier 2: Drift (declared vs deployed)
// ---------------------------------------------------------------------------

#[utoipa::path(
    get,
    path = "/api/health/drift",
    tag = "Health",
    responses(
        (status = 200, description = "Declared vs deployed container drift analysis", body = Value),
        (status = 500, description = "Internal error")
    )
)]
pub async fn health_drift(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let mut set = tokio::task::JoinSet::new();

    for (vm_id, _vm_map) in &state.config.all_vm_services {
        let vm_id = vm_id.clone();
        let state = Arc::clone(&state);
        set.spawn(async move {
            let containers = batch_container_statuses(&state, &vm_id).await;
            (vm_id, containers)
        });
    }

    let mut deployed_map: std::collections::HashMap<String, Vec<(String, String, String)>> =
        std::collections::HashMap::new();
    while let Some(result) = set.join_next().await {
        if let Ok((vm_id, containers)) = result {
            deployed_map.insert(vm_id, containers);
        }
    }

    let mut vms = serde_json::Map::new();
    let mut summary_declared = 0u32;
    let mut summary_deployed = 0u32;
    let mut summary_missing = 0u32;
    let mut summary_extra = 0u32;

    for (vm_id, vm_map) in &state.config.all_vm_services {
        let declared: Vec<String> = vm_map.services
            .values()
            .flat_map(|c| c.iter().cloned())
            .collect();

        let deployed_raw = deployed_map.get(vm_id).cloned().unwrap_or_default();
        let deployed: Vec<String> = deployed_raw.iter().map(|(n, _, _)| n.clone()).collect();

        let missing: Vec<&String> = declared.iter()
            .filter(|d| !deployed.contains(d))
            .collect();

        let extra: Vec<&String> = deployed.iter()
            .filter(|d| !declared.contains(d))
            .collect();

        summary_declared += declared.len() as u32;
        summary_deployed += deployed.len() as u32;
        summary_missing += missing.len() as u32;
        summary_extra += extra.len() as u32;

        vms.insert(vm_id.clone(), json!({
            "label": vm_map.label,
            "declared": declared,
            "deployed": deployed,
            "missing": missing,
            "extra": extra,
        }));
    }

    let drift = summary_missing > 0 || summary_extra > 0;

    Ok(Json(json!({
        "vms": vms,
        "summary": {
            "declared": summary_declared,
            "deployed": summary_deployed,
            "missing": summary_missing,
            "extra": summary_extra,
            "drift": drift,
        }
    })))
}

// ---------------------------------------------------------------------------
// Tier 3: Status (comprehensive — provider + SSH + resources + containers + routes)
// ---------------------------------------------------------------------------

#[utoipa::path(
    get,
    path = "/api/health/status",
    tag = "Health",
    responses(
        (status = 200, description = "Comprehensive health: provider state, SSH, resources, containers, route probes", body = Value),
        (status = 500, description = "Internal error")
    )
)]
pub async fn health_status(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    // Parallel: probe all VMs + gather resources + probe routes
    let mut vm_set = tokio::task::JoinSet::new();
    let mut res_set = tokio::task::JoinSet::new();

    for (vm_id, vm_map) in &state.config.all_vm_services {
        let vm_id_1 = vm_id.clone();
        let vm_id_2 = vm_id.clone();
        let label = vm_map.label.clone();
        let services = vm_map.services.clone();
        let s1 = Arc::clone(&state);
        let s2 = Arc::clone(&state);

        vm_set.spawn(async move {
            let probe = probe_vm(&s1, &vm_id_1).await;
            (vm_id_1, label, services, probe)
        });
        res_set.spawn(async move {
            let resources = gather_vm_resources(&s2, &vm_id_2).await;
            (vm_id_2, resources)
        });
    }

    // Route probes in parallel
    let mut route_set = tokio::task::JoinSet::new();
    let bearer = state.config.authelia_bearer_token.clone();
    for entry in &state.config.route_check_domains {
        let http = state.http.clone();
        let domain = entry.domain.clone();
        let service = entry.service.clone();
        let token = bearer.clone();
        route_set.spawn(async move {
            probe_domain_chain(&http, &domain, &service, token.as_deref()).await
        });
    }

    // OCI Object Storage
    let storage_state = Arc::clone(&state);
    let storage_handle = tokio::spawn(async move {
        let quota = storage_state.config.oci_storage_quota_gb;
        crate::services::oci::get_object_storage_info(&storage_state.http, &storage_state.config, quota).await
    });

    // Collect VM probes
    let mut vm_data: std::collections::HashMap<String, (String, std::collections::HashMap<String, Vec<String>>, super::ondemand::VmProbe)> =
        std::collections::HashMap::new();
    while let Some(result) = vm_set.join_next().await {
        if let Ok((vm_id, label, services, probe)) = result {
            vm_data.insert(vm_id, (label, services, probe));
        }
    }

    // Collect resources
    let mut resources_map: std::collections::HashMap<String, Value> = std::collections::HashMap::new();
    while let Some(result) = res_set.join_next().await {
        if let Ok((vm_id, resources)) = result {
            resources_map.insert(vm_id, resources);
        }
    }

    // Build VM responses
    let mut vms = serde_json::Map::new();
    let mut global_services_up = 0u32;
    let mut global_services_down = 0u32;
    let mut global_services_partial = 0u32;
    let mut global_containers_running = 0u32;
    let mut global_containers_total = 0u32;
    let mut total_cores = 0u32;
    let mut total_ram_mb = 0u64;
    let mut total_disk_gb = 0.0f64;
    let mut sum_cpu_pct = 0.0f64;
    let mut sum_mem_pct = 0.0f64;
    let mut vm_count = 0u32;

    for (vm_id, (label, services, probe)) in &vm_data {
        let mut svc_map = serde_json::Map::new();
        let mut vm_services_up = 0u32;
        let mut vm_services_down = 0u32;
        let mut vm_services_partial = 0u32;
        let mut vm_containers_running = 0u32;
        let mut vm_containers_total = 0u32;

        for (svc_name, containers) in services {
            let svc_status = compute_service_status(containers, &probe.container_data);
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
            svc_map.insert(svc_name.clone(), svc_status);
        }

        global_services_up += vm_services_up;
        global_services_down += vm_services_down;
        global_services_partial += vm_services_partial;
        global_containers_running += vm_containers_running;
        global_containers_total += vm_containers_total;

        let resources = resources_map.get(vm_id).cloned().unwrap_or(json!(null));
        if resources.get("error").is_none() && !resources.is_null() {
            total_cores += resources["resources"]["cpu"]["cores"].as_u64().unwrap_or(0) as u32;
            total_ram_mb += resources["resources"]["memory"]["total_mb"].as_u64().unwrap_or(0);
            total_disk_gb += resources["resources"]["disk"]["total_gb"].as_f64().unwrap_or(0.0);
            sum_cpu_pct += resources["resources"]["cpu"]["usage_pct"].as_f64().unwrap_or(0.0);
            sum_mem_pct += resources["resources"]["memory"]["usage_pct"].as_f64().unwrap_or(0.0);
            vm_count += 1;
        }

        vms.insert(vm_id.clone(), json!({
            "label": label,
            "provider_state": probe.provider_state,
            "ssh": probe.ssh,
            "ping": probe.ping,
            "health": probe.health,
            "services": svc_map,
            "resources": resources,
            "summary": {
                "services_up": vm_services_up,
                "services_down": vm_services_down,
                "services_partial": vm_services_partial,
                "containers_running": vm_containers_running,
                "containers_total": vm_containers_total,
            }
        }));
    }

    // Collect route probes
    let mut routes = vec![];
    let mut routes_healthy = 0u32;
    let mut routes_total = 0u32;
    while let Some(result) = route_set.join_next().await {
        if let Ok(val) = result {
            routes_total += 1;
            if val["healthy"].as_bool() == Some(true) {
                routes_healthy += 1;
            }
            routes.push(val);
        }
    }
    routes.sort_by(|a, b| {
        a["service"].as_str().unwrap_or("").cmp(b["service"].as_str().unwrap_or(""))
    });

    // Collect object storage
    let object_storage = match storage_handle.await {
        Ok(Ok(data)) => data,
        Ok(Err(e)) => json!({"error": e}),
        Err(_) => json!({"error": "task failed"}),
    };

    let avg_cpu_pct = if vm_count > 0 { sum_cpu_pct / vm_count as f64 } else { 0.0 };
    let avg_mem_pct = if vm_count > 0 { sum_mem_pct / vm_count as f64 } else { 0.0 };

    Ok(Json(json!({
        "vms": vms,
        "routes": {
            "probes": routes,
            "healthy": routes_healthy,
            "total": routes_total,
        },
        "object_storage": object_storage,
        "summary": {
            "services_up": global_services_up,
            "services_down": global_services_down,
            "services_partial": global_services_partial,
            "containers_running": global_containers_running,
            "containers_total": global_containers_total,
            "total_cpu_cores": total_cores,
            "total_ram_mb": total_ram_mb,
            "total_disk_gb": round1(total_disk_gb),
            "avg_cpu_pct": round1(avg_cpu_pct),
            "avg_mem_pct": round1(avg_mem_pct),
        }
    })))
}

#[utoipa::path(
    get,
    path = "/api/health/status/{vm_id}",
    tag = "Health",
    params(("vm_id" = String, Path, description = "VM identifier")),
    responses(
        (status = 200, description = "Comprehensive per-VM health status", body = Value),
        (status = 404, description = "Unknown VM"),
    )
)]
pub async fn health_status_vm(
    State(state): State<Arc<AppState>>,
    Path(vm_id): Path<String>,
) -> Result<Json<Value>, AppError> {
    if !validate_vm_id(&vm_id) {
        return Err(AppError::bad_request("Invalid VM ID"));
    }
    let vm_map = state.config.all_vm_services.get(&vm_id)
        .ok_or_else(|| AppError::not_found(format!("Unknown VM: {vm_id}")))?;

    let label = vm_map.label.clone();
    let services = vm_map.services.clone();

    // Parallel: probe + resources
    let s1 = Arc::clone(&state);
    let s2 = Arc::clone(&state);
    let vm_id_1 = vm_id.clone();
    let vm_id_2 = vm_id.clone();

    let (probe, resources) = tokio::join!(
        async { probe_vm(&s1, &vm_id_1).await },
        async { gather_vm_resources(&s2, &vm_id_2).await },
    );

    let mut svc_map = serde_json::Map::new();
    let mut services_up = 0u32;
    let mut services_down = 0u32;
    let mut services_partial = 0u32;
    let mut containers_running = 0u32;
    let mut containers_total = 0u32;

    for (svc_name, containers) in &services {
        let svc_status = compute_service_status(containers, &probe.container_data);
        let status_str = svc_status["status"].as_str().unwrap_or("down");
        match status_str {
            "up" => services_up += 1,
            "partial" => services_partial += 1,
            _ => services_down += 1,
        }
        if let Some(ctrs) = svc_status["containers"].as_array() {
            for c in ctrs {
                containers_total += 1;
                if c["state"].as_str() == Some("running") {
                    containers_running += 1;
                }
            }
        }
        svc_map.insert(svc_name.clone(), svc_status);
    }

    Ok(Json(json!({
        "vm_id": vm_id,
        "label": label,
        "provider_state": probe.provider_state,
        "ssh": probe.ssh,
        "ping": probe.ping,
        "health": probe.health,
        "services": svc_map,
        "resources": resources,
        "summary": {
            "services_up": services_up,
            "services_down": services_down,
            "services_partial": services_partial,
            "containers_running": containers_running,
            "containers_total": containers_total,
        }
    })))
}
