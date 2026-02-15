use axum::extract::{Path, Query, State};
use axum::routing::get;
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::RwLock;

use crate::error::AppError;
use crate::AppState;

#[derive(Deserialize)]
pub struct RefreshQuery {
    #[serde(default)]
    refresh: bool,
}

const CACHE_TTL: Duration = Duration::from_secs(300);
const PROBE_TIMEOUT: Duration = Duration::from_secs(5);

const WELL_KNOWN_PATHS: &[&str] = &[
    "/openapi.json",
    "/swagger.json",
    "/api/docs/openapi.json",
    "/api/swagger.json",
    "/api/v1/swagger.json",
    "/apispec.json",
    "/.well-known/openid-configuration",
];

#[derive(Clone)]
pub struct CachedSpec {
    pub spec_url: String,
    pub spec_format: String,
    pub content: Value,
    pub fetched_at: Instant,
}

pub type SpecCache = Arc<RwLock<HashMap<String, Option<CachedSpec>>>>;

pub fn new_spec_cache() -> SpecCache {
    Arc::new(RwLock::new(HashMap::new()))
}

pub fn routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/api/services", get(list_services))
        .route("/api/services/all/specs", get(get_all_specs))
        .route("/api/services/{service}", get(get_service))
        .route("/api/services/{service}/spec", get(get_service_spec))
}

fn find_vm_for_container(state: &AppState, container: &str) -> Option<(String, String)> {
    for (vm_id, vm_map) in &state.config.all_vm_services {
        for containers in vm_map.services.values() {
            if containers.iter().any(|c| c == container) {
                return Some((vm_id.clone(), vm_map.label.clone()));
            }
        }
    }
    None
}

fn build_service_info(
    state: &AppState,
    name: &str,
    domain: &str,
    cached: Option<&Option<CachedSpec>>,
) -> Value {
    let (vm_id, vm_label) = find_vm_for_container(state, name)
        .unwrap_or_default();

    let (has_spec, spec_url, spec_format) = match cached {
        Some(Some(c)) if c.fetched_at.elapsed() < CACHE_TTL => {
            (true, Some(c.spec_url.clone()), Some(c.spec_format.clone()))
        }
        _ => (false, None, None),
    };

    json!({
        "name": name,
        "domain": domain,
        "vm_id": vm_id,
        "vm_label": vm_label,
        "spec_url": spec_url,
        "spec_format": spec_format,
        "has_spec": has_spec,
    })
}

fn detect_spec_format(path: &str, _content: &Value) -> String {
    if path.contains("openid-configuration") {
        "oidc".to_string()
    } else if path.contains("swagger") {
        "swagger".to_string()
    } else {
        "openapi".to_string()
    }
}

async fn probe_spec(
    http: &reqwest::Client,
    domain: &str,
    bearer_token: Option<&str>,
    cache: &SpecCache,
    service_name: &str,
    force_refresh: bool,
) -> Option<CachedSpec> {
    // Check cache (read lock) — 5-min TTL, bypass with force_refresh
    if !force_refresh {
        let cache_r = cache.read().await;
        if let Some(entry) = cache_r.get(service_name) {
            match entry {
                Some(cached) if cached.fetched_at.elapsed() < CACHE_TTL => {
                    return Some(cached.clone());
                }
                None => return None,
                _ => {} // expired — fall through to re-probe
            }
        }
    }

    // Probe well-known paths
    let base = if domain.contains('/') {
        // Subpath service (e.g. app.diegonmarcos.com/gitea)
        format!("https://{domain}")
    } else {
        format!("https://{domain}")
    };

    for path in WELL_KNOWN_PATHS {
        let url = format!("{base}{path}");
        let mut req = http.get(&url).timeout(PROBE_TIMEOUT);
        if let Some(token) = bearer_token {
            req = req.header("Authorization", format!("Bearer {token}"));
        }

        let resp = match req.send().await {
            Ok(r) if r.status().is_success() => r,
            _ => continue,
        };

        let body = match resp.json::<Value>().await {
            Ok(v) if v.is_object() => v,
            _ => continue,
        };

        let format = detect_spec_format(path, &body);
        let cached = CachedSpec {
            spec_url: url,
            spec_format: format,
            content: body,
            fetched_at: Instant::now(),
        };

        // Write to cache
        {
            let mut cache_w = cache.write().await;
            cache_w.insert(service_name.to_string(), Some(cached.clone()));
        }

        return Some(cached);
    }

    // Negative cache — store None
    {
        let mut cache_w = cache.write().await;
        cache_w.insert(service_name.to_string(), None);
    }

    None
}

#[utoipa::path(
    get,
    path = "/api/services",
    tag = "Services",
    responses(
        (status = 200, description = "List all services with domains and discovered spec info")
    )
)]
pub async fn list_services(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, AppError> {
    let cache = state.spec_cache.read().await;
    let mut services: Vec<Value> = state
        .config
        .container_domain_map
        .iter()
        .map(|(name, domain)| build_service_info(&state, name, domain, cache.get(name)))
        .collect();
    services.sort_by(|a, b| {
        a["name"].as_str().unwrap_or("").cmp(b["name"].as_str().unwrap_or(""))
    });

    let total = services.len();
    let with_spec = services.iter().filter(|s| s["has_spec"].as_bool() == Some(true)).count();

    Ok(Json(json!({
        "services": services,
        "totals": {
            "total": total,
            "with_spec": with_spec,
            "without_spec": total - with_spec,
        }
    })))
}

#[utoipa::path(
    get,
    path = "/api/services/{service}",
    tag = "Services",
    params(
        ("service" = String, Path, description = "Service name"),
    ),
    responses(
        (status = 200, description = "Single service metadata"),
        (status = 404, description = "Service not found")
    )
)]
pub async fn get_service(
    State(state): State<Arc<AppState>>,
    Path(service): Path<String>,
) -> Result<Json<Value>, AppError> {
    let domain = state
        .config
        .container_domain_map
        .get(&service)
        .ok_or_else(|| AppError::not_found(format!("Unknown service: {service}")))?;

    let cache = state.spec_cache.read().await;
    let info = build_service_info(&state, &service, domain, cache.get(&service));
    Ok(Json(info))
}

#[utoipa::path(
    get,
    path = "/api/services/{service}/spec",
    tag = "Services",
    params(
        ("service" = String, Path, description = "Service name"),
    ),
    responses(
        (status = 200, description = "API spec content"),
        (status = 404, description = "Service not found"),
        (status = 422, description = "No spec discovered for this service")
    )
)]
pub async fn get_service_spec(
    State(state): State<Arc<AppState>>,
    Path(service): Path<String>,
    Query(query): Query<RefreshQuery>,
) -> Result<Json<Value>, AppError> {
    let domain = state
        .config
        .container_domain_map
        .get(&service)
        .ok_or_else(|| AppError::not_found(format!("Unknown service: {service}")))?
        .clone();

    let token = state.config.authelia_bearer_token.as_deref();
    let start = Instant::now();
    let result = probe_spec(&state.http, &domain, token, &state.spec_cache, &service, query.refresh).await;
    let elapsed = start.elapsed().as_millis() as u64;

    match result {
        Some(cached) => {
            let was_cached = cached.fetched_at.elapsed() > Duration::from_millis(100);
            Ok(Json(json!({
                "name": service,
                "domain": domain,
                "spec_url": cached.spec_url,
                "spec_format": cached.spec_format,
                "content": cached.content,
                "fetch_time_ms": elapsed,
                "cached": was_cached,
            })))
        }
        None => Err(AppError {
            status: axum::http::StatusCode::UNPROCESSABLE_ENTITY,
            message: format!("No API spec discovered for service: {service}"),
        }),
    }
}

#[utoipa::path(
    get,
    path = "/api/services/all/specs",
    tag = "Services",
    responses(
        (status = 200, description = "All discovered API specs")
    )
)]
pub async fn get_all_specs(
    State(state): State<Arc<AppState>>,
    Query(query): Query<RefreshQuery>,
) -> Result<Json<Value>, AppError> {
    let total_start = Instant::now();
    let services: Vec<(String, String)> = state
        .config
        .container_domain_map
        .iter()
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();

    let token = state.config.authelia_bearer_token.clone();
    let mut set = tokio::task::JoinSet::new();

    let refresh = query.refresh;
    for (name, domain) in services {
        let http = state.http.clone();
        let cache = Arc::clone(&state.spec_cache);
        let token = token.clone();
        set.spawn(async move {
            let start = Instant::now();
            let result = probe_spec(
                &http,
                &domain,
                token.as_deref(),
                &cache,
                &name,
                refresh,
            )
            .await;
            let elapsed = start.elapsed().as_millis() as u64;
            (name, domain, result, elapsed)
        });
    }

    let mut results = Vec::new();
    let mut fetched = 0usize;
    let mut failed = 0usize;
    let mut skipped = 0usize;

    while let Some(join_result) = set.join_next().await {
        let (name, _domain, probe_result, elapsed) = match join_result {
            Ok(r) => r,
            Err(_) => continue,
        };

        match probe_result {
            Some(cached) => {
                fetched += 1;
                results.push(json!({
                    "name": name,
                    "spec_url": cached.spec_url,
                    "spec_format": cached.spec_format,
                    "content": cached.content,
                    "fetch_time_ms": elapsed,
                }));
            }
            None => {
                skipped += 1;
                results.push(json!({
                    "name": name,
                    "has_spec": false,
                    "fetch_time_ms": elapsed,
                }));
            }
        }
    }

    results.sort_by(|a, b| {
        a["name"].as_str().unwrap_or("").cmp(b["name"].as_str().unwrap_or(""))
    });

    let total_time = total_start.elapsed().as_millis() as u64;

    Ok(Json(json!({
        "services": results,
        "totals": {
            "fetched": fetched,
            "failed": failed,
            "skipped": skipped,
        },
        "total_time_ms": total_time,
    })))
}
