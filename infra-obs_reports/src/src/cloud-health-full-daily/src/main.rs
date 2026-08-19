//! Cloud Health Daily Mail — HTML email report generator
//! Collects VM metrics (SSH), API data (HTTP), cloud-data (JSON), generates HTML to dist/
//!
//! Usage: cloud-health-daily-mail (from cloud-health-daily-mail/)
//!   Outputs: dist/cloud_health_daily.html

mod appendix;
mod collect;
mod context;
mod diagrams;
mod evidence;
mod html;
mod health_full2;
mod mail;
mod mail_full;
mod md;
mod mermaid;
mod render_only;
mod ssh;
mod types;

use anyhow::Result;
use chrono::Utc;
use reports_common::perf::PerfTracker;
use std::collections::HashSet;
use std::sync::Arc;
use std::time::Instant;
use types::*;

#[tokio::main]
async fn main() -> Result<()> {
    // Render-only mode is the Phase 3 re-pass after derives populate the
    // snapshot. It skips collection entirely — picks up cloud_health_daily.json
    // from cwd, patches the appendix from derive markdown, re-renders.
    if std::env::var("REPORTS_RENDER_ONLY").ok().as_deref() == Some("1") {
        return render_only::run().await;
    }

    let start = Instant::now();
    let perf = Arc::new(PerfTracker::new());
    let now = Utc::now();
    let date = now.format("%Y-%m-%d").to_string();
    let time = now.format("%H:%M %Z").to_string();

    println!("=== Cloud Health Daily Mail Report ===");

    // 1. Load context from cloud-data JSONs
    let ctx = context::load_context()?;
    println!(
        "Loaded: {} VMs, {} endpoints, {} TLS checks, {} databases, {} manifests",
        ctx.monitoring.vms.len(),
        ctx.monitoring.endpoint_checks.len(),
        ctx.monitoring.tls_checks.len(),
        ctx.databases.databases.len(),
        ctx.manifests.len(),
    );

    // 2. Parallel collection: SSH (per VM) + API calls
    // GitHub token: env var -> gh config -> empty
    let github_token = std::env::var("GITHUB_TOKEN")
        .ok()
        .filter(|t| !t.is_empty())
        .or_else(|| {
            let home = std::env::var("HOME").unwrap_or_default();
            std::fs::read_to_string(format!("{}/.config/gh/hosts.yml", home))
                .ok()
                .and_then(|s| {
                    s.lines()
                        .find(|l| l.trim().starts_with("oauth_token:"))
                        .map(|l| l.split(':').nth(1).unwrap_or("").trim().to_string())
                })
        })
        .unwrap_or_default();

    if github_token.is_empty() {
        eprintln!("  GITHUB_TOKEN not found (env or gh config), skipping GHA/GHCR");
    }

    // Fleet preflight — query gcloud + oci batch APIs in parallel + TCP probe :22.
    // Result lands in the run-state snapshot so derives can skip Terminated VMs
    // at step 0 instead of burning their own SSH timeouts. Master itself still
    // dispatches SSH to every VM (the underlying ssh wrapper has its own short
    // deadlines); the cost of one dead VM is bounded by ssh's ServerAlive
    // settings, not by re-attempts.
    let fleet_vms: Vec<reports_common::fleet::FleetVm> = ctx
        .monitoring
        .vms
        .iter()
        .map(|vm| {
            let provider = ctx
                .vm_finops
                .iter()
                .find(|f| f.alias == vm.name)
                .map(|f| f.provider.clone())
                .unwrap_or_else(|| "?".into());
            reports_common::fleet::FleetVm {
                vm_id: vm.name.clone(),
                provider,
                cloud_name: vm.name.clone(),
                wg_ip: Some(vm.ip.clone()),
            }
        })
        .collect();
    let fleet_state = perf
        .time_async("fleet_preflight", reports_common::fleet::load(&fleet_vms))
        .await;
    let reachable = fleet_state.reachable().len();
    let terminated = fleet_state.terminated();
    println!(
        "Fleet: {}/{} reachable{}",
        reachable,
        fleet_vms.len(),
        if terminated.is_empty() {
            String::new()
        } else {
            format!(" — terminated: {}", terminated.join(", "))
        }
    );

    // Launch all tasks concurrently. Skip ONLY VMs the cloud API positively
    // confirms are Terminated (powered off) — those have nothing to collect and
    // just bleed the SSH-handshake deadline. Everything else (Running,
    // Provisioning, Client, or Unknown) is probed: `Unknown` means the cloud
    // lister was empty/unauthenticated on the runner (`gcloud`/`oci` CLI absent
    // or no creds), which says NOTHING about WG SSH reachability. Treating
    // Unknown as unreachable previously zeroed the entire fleet (`vms: []`,
    // `total_containers: 0`) whenever the cloud CLI was missing — a false
    // outage. The SSH handshake has its own timeout, so a genuinely-down VM
    // just yields an empty VmData rather than poisoning the whole report.
    let vm_futures: Vec<_> = ctx
        .monitoring
        .vms
        .iter()
        .filter(|vm| {
            !matches!(
                fleet_state.vms.get(&vm.name),
                Some(reports_common::fleet::VmState::Terminated { .. })
            )
        })
        .map(|vm| ssh::collect_vm(vm, &ctx.databases.databases))
        .collect();

    // Build endpoint checks: monitoring-targets + build-caddy.json (public) +
    // service `.domain` declarations — deduplicated by URL.
    let mut all_endpoints: Vec<EndpointCheck> = ctx.monitoring.endpoint_checks.clone();
    let mut seen_urls: HashSet<String> = all_endpoints.iter().map(|e| e.url.clone()).collect();

    // Caddy-declared public URLs (source of truth).
    for t in reports_common::caddy::load_public_targets() {
        if seen_urls.insert(t.url.clone()) {
            let service = t.service.clone().unwrap_or_else(|| t.host.clone());
            all_endpoints.push(EndpointCheck { service, url: t.url });
        }
    }

    // Fallback: service.domain declarations not yet in Caddy (drift). Only probe
    // services that are actually routed at their domain (serves_http) — headless
    // services (e.g. mail-puller) declare a domain for identity but serve no HTTP,
    // and would otherwise false-CRIT as an unreachable endpoint.
    for svc in &ctx.services {
        if !svc.enabled || svc.domain.is_empty() || !svc.serves_http { continue; }
        let url = if svc.domain.starts_with("http") {
            svc.domain.clone()
        } else {
            format!("https://{}/", svc.domain)
        };
        if seen_urls.insert(url.clone()) {
            all_endpoints.push(EndpointCheck { service: svc.name.clone(), url });
        }
    }

    // Drop internal-only hostnames (e.g. `dns.internal` for Hickory): these
    // are not public HTTPS endpoints, never resolve from the runner, and were
    // surfacing as bogus CRIT "HTTP 0". The stack collector
    // (health_full2/stack/collectors.rs) already applies this same exclusion;
    // mirror it here so both report paths agree.
    all_endpoints.retain(|ep| !ep.url.contains(".internal"));

    let ep_futures: Vec<_> = all_endpoints.iter()
        .map(|ep| collect::check_endpoint(ep))
        .collect();

    // Deduplicate TLS domains
    let tls_domains: Vec<String> = ctx.monitoring.tls_checks.iter()
        .map(|t| t.domain.split('/').next().unwrap_or(&t.domain).to_string())
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();

    let cert_futures: Vec<_> = tls_domains.iter()
        .map(|d| collect::check_cert(d))
        .collect();

    // Run everything in parallel. mail_full::run + mail::collect_mail_network
    // were here before — both did SSH/HTTP/DNS work that the dedicated
    // cloud-mail-health-full derive already does in Phase 2. They were
    // dropped to cut master's wall-clock from ~220s to ~90s; the daily
    // appendix's mail Z-sections are filled by the Phase 3 render-only
    // re-pass that reads cloud_mail_full.md from disk.
    let collection_t = Instant::now();
    let (
        vms,
        endpoints,
        certs,
        dns,
        gha_runs,
        gha_workflows,
        (ghcr_packages, ghcr_total, github_disk_kb),
        dags,
        cloud_buckets,
        repos,
        cloud_costs,
        umami_sites,
        matomo_sites,
        full2_report,
    ) = tokio::join!(
        futures::future::join_all(vm_futures),
        futures::future::join_all(ep_futures),
        futures::future::join_all(cert_futures),
        collect::check_dns(),
        async {
            if github_token.is_empty() { vec![] }
            else { collect::fetch_gha(&github_token).await }
        },
        async {
            if github_token.is_empty() { vec![] }
            else { collect::fetch_gha_workflows(&github_token).await }
        },
        async {
            if github_token.is_empty() { (vec![], 0, 0) }
            else { collect::fetch_ghcr(&github_token).await }
        },
        collect::fetch_dags(),
        collect::fetch_bucket_sizes(&ctx.cloud_buckets),
        collect::fetch_repos(),
        collect::fetch_cloud_costs(),
        collect::fetch_umami_analytics(),
        collect::fetch_matomo_analytics(),
        health_full2::run(Some(&fleet_state)),
    );

    perf.record(
        "collection_total",
        collection_t.elapsed().as_millis() as u64,
        true,
        None,
    );

    // mail_health is left None in Phase 1 — html.rs already falls back to
    // VM mail_queue stats. Phase 3 re-render fills the appendix mail
    // Z-sections from the derive's on-disk markdown.
    let mail_health: Option<types::MailHealthData> = None;

    // 3. Mark services that responded as has_api (runtime-proven)
    let mut services = ctx.services.clone();
    for svc in &mut services {
        if let Some(ep) = endpoints.iter().find(|e| e.service == svc.name) {
            svc.has_api = ep.status_code > 0;
        }
    }

    // 4. Compute fleet totals
    let fleet_running: u32 = vms.iter().map(|v| v.containers_running).sum();
    let fleet_total: u32 = vms.iter().map(|v| v.containers_total).sum();
    let fleet_unhealthy: u32 = vms.iter().map(|v| v.containers_unhealthy).sum();

    let elapsed = start.elapsed();
    println!(
        "Collected: {} VMs, {} endpoints, {} certs, {} DNS, {} GHA runs, {} GHA workflows, {} GHCR, {} DAGs in {:.1}s",
        vms.len(), endpoints.len(), certs.len(), dns.len(),
        gha_runs.len(), gha_workflows.len(), ghcr_packages.len(), dags.len(),
        elapsed.as_secs_f64(),
    );

    // 4. Compute storage drift per VM
    let drift: Vec<StorageDrift> = {
        let mut drifts = Vec::new();
        for vm in &vms {
            let declared: HashSet<String> = ctx.databases.databases.iter()
                .filter(|d| d.enabled && d.wg_ip == vm.ip)
                .map(|d| d.container.clone())
                .collect();

            let runtime: HashSet<String> = vm.runtime_volumes.iter()
                .map(|v| v.container.clone())
                .collect();

            let declared_only: Vec<String> = declared.difference(&runtime).cloned().collect();
            let runtime_only: Vec<String> = runtime.difference(&declared).cloned().collect();
            let matched: Vec<String> = declared.intersection(&runtime).cloned().collect();

            if !declared_only.is_empty() || !runtime_only.is_empty() {
                drifts.push(StorageDrift { declared_only, runtime_only, matched });
            }
        }
        drifts
    };

    // 5. Compute container drift from manifests
    let container_drift: Vec<ContainerDrift> = {
        let mut drifts = Vec::new();
        for vm in &vms {
            if let Some(manifest) = ctx.manifests.get(&vm.name) {
                let runtime_names: HashSet<String> = vm.container_list.iter()
                    .map(|c| c.name.clone())
                    .collect();

                // Build expected containers from manifest services
                // A container belongs to a service if its name starts with the service name
                let mut expected_not_running = Vec::new();
                let mut image_mismatch = Vec::new();

                for svc in &manifest.services {
                    // Check if any runtime container matches this service
                    let matching: Vec<&ContainerInfo> = vm.container_list.iter()
                        .filter(|c| c.name.starts_with(&svc.name))
                        .collect();

                    if matching.is_empty() {
                        expected_not_running.push(svc.name.clone());
                    } else {
                        // Check image mismatches
                        for c in &matching {
                            // Check if the running image matches any declared image
                            let image_ok = svc.images.iter().any(|declared_img| {
                                // Normalize: strip tag for comparison if needed
                                let running = &c.image;
                                running.contains(&declared_img.split(':').next().unwrap_or(""))
                            });
                            if !image_ok && !svc.images.is_empty() {
                                let declared = svc.images.join(", ");
                                image_mismatch.push((c.name.clone(), c.image.clone(), declared));
                            }
                        }
                    }
                }

                // Find running containers not declared in any service
                let declared_prefixes: Vec<&str> = manifest.services.iter()
                    .map(|s| s.name.as_str())
                    .collect();
                let running_not_declared: Vec<String> = runtime_names.iter()
                    .filter(|name| !declared_prefixes.iter().any(|prefix| name.starts_with(prefix)))
                    .cloned()
                    .collect();

                if !expected_not_running.is_empty() || !running_not_declared.is_empty() || !image_mismatch.is_empty() {
                    drifts.push(ContainerDrift {
                        vm_name: vm.name.clone(),
                        expected_not_running,
                        running_not_declared,
                        image_mismatch,
                    });
                }
            }
        }
        drifts
    };

    // 6. Compute executive summary
    let exec_summary = {
        let mut critical: u32 = 0;
        let mut warnings: u32 = 0;
        let mut ok: u32 = 0;
        let mut issues: Vec<Issue> = Vec::new();

        // Helpers — emit paths RELATIVE to the reports-logs dist root.
        // The root itself is declared once in cloud-data-reports-logs.json
        // (output_dir field). Rust does not duplicate that knowledge.
        // Layout convention (vms/<vm>/, containers/<svc>/<ctr>/) is the
        // collector's contract — consumers (index.sh) join the root + the
        // relative path emitted here.
        let vm_evidence = |vm_name: &str| -> Vec<String> {
            vec![
                format!("vms/{}/", vm_name),
                format!("vms/{}/meta.json", vm_name),
                format!("vms/{}/docker_ps.json", vm_name),
                format!("vms/{}/network.txt", vm_name),
                format!("vms/{}/systemd_failed.txt", vm_name),
            ]
        };
        let container_evidence = |vm_name: &str, ctr: &str| -> Vec<String> {
            vec![
                format!("containers/*/{}/inspect.json", ctr),
                format!("containers/*/{}/logs.txt", ctr),
                format!("vms/{}/docker_ps.json", vm_name),
            ]
        };

        // VMs
        for vm in &vms {
            match vm.status {
                VmStatus::Critical => {
                    critical += 1;
                    issues.push(Issue {
                        severity: "CRIT".into(),
                        message: format!("{}: status CRITICAL", vm.name),
                        kind: "vm".into(),
                        entity: vm.name.clone(),
                        vm: vm.name.clone(),
                        evidence_paths: vm_evidence(&vm.name),
                    });
                }
                VmStatus::Warning => {
                    warnings += 1;
                    issues.push(Issue {
                        severity: "WARN".into(),
                        message: format!("{}: status WARNING", vm.name),
                        kind: "vm".into(),
                        entity: vm.name.clone(),
                        vm: vm.name.clone(),
                        evidence_paths: vm_evidence(&vm.name),
                    });
                }
                VmStatus::Healthy => { ok += 1; }
                VmStatus::Unknown => {
                    warnings += 1;
                    issues.push(Issue {
                        severity: "WARN".into(),
                        message: format!("{}: status UNKNOWN", vm.name),
                        kind: "vm".into(),
                        entity: vm.name.clone(),
                        vm: vm.name.clone(),
                        evidence_paths: vm_evidence(&vm.name),
                    });
                }
            }

            // Unhealthy containers
            for name in &vm.unhealthy_names {
                critical += 1;
                issues.push(Issue {
                    severity: "CRIT".into(),
                    message: format!("{}: {} unhealthy", vm.name, name),
                    kind: "container".into(),
                    entity: name.clone(),
                    vm: vm.name.clone(),
                    evidence_paths: container_evidence(&vm.name, name),
                });
            }

            // Exited containers
            for name in &vm.exited_names {
                warnings += 1;
                issues.push(Issue {
                    severity: "WARN".into(),
                    message: format!("{}: {} exited", vm.name, name),
                    kind: "container".into(),
                    entity: name.clone(),
                    vm: vm.name.clone(),
                    evidence_paths: container_evidence(&vm.name, name),
                });
            }

            // Disk > 75%
            if vm.disk_pct > 75 {
                warnings += 1;
                issues.push(Issue {
                    severity: "WARN".into(),
                    message: format!("{}: disk {}%", vm.name, vm.disk_pct),
                    kind: "disk".into(),
                    entity: vm.name.clone(),
                    vm: vm.name.clone(),
                    evidence_paths: vm_evidence(&vm.name),
                });
            }
        }

        // Endpoints.
        //
        // The edge is a single wildcard Caddy (`*.diegonmarcos.com` → Caddy).
        // ANY HTTP response — including 401/403/404 — proves the request was
        // routed and answered by Caddy/upstream, i.e. the route + service are
        // live. Many endpoints are probed at their bare base path (no trailing
        // sub-route / healthz), where an auth-gated or index-less service
        // legitimately returns 401/403/404; those are NOT outages and must not
        // be flagged. A genuine outage manifests as a transport failure (0) or
        // a gateway/upstream error (502/503/504): Caddy could not reach the
        // upstream at all. Plain 5xx from the app (500/501/...) is treated as a
        // warning, not a hard down, since the app is still answering.
        for ep in &endpoints {
            let after_scheme = ep.url.split("://").nth(1).unwrap_or(&ep.url);
            let host: String = after_scheme
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || *c == '.' || *c == '-')
                .collect();
            let evidence = || {
                let mut ev = Vec::new();
                if !host.is_empty() {
                    ev.push(format!("dns/{}.txt", host));
                    ev.push(format!("tls/{}_443.txt", host));
                }
                ev
            };
            // Wormhole false-green: a 200 whose body is Caddy's global wildcard
            // fallback page. The host/path is NOT routed to a live upstream, so
            // this is a genuine down/misroute despite the 200 status.
            if ep.edge_fallback {
                critical += 1;
                issues.push(Issue {
                    severity: "CRIT".into(),
                    message: format!("{}: edge fallback (wormhole 200, not routed)", ep.service),
                    kind: "endpoint".into(),
                    entity: ep.service.clone(),
                    vm: String::new(),
                    evidence_paths: evidence(),
                });
                continue;
            }
            match ep.status_code {
                // Transport failure or Caddy-can't-reach-upstream → genuine down.
                0 | 502 | 503 | 504 => {
                    critical += 1;
                    issues.push(Issue {
                        severity: "CRIT".into(),
                        message: format!("{}: HTTP {}", ep.service, ep.status_code),
                        kind: "endpoint".into(),
                        entity: ep.service.clone(),
                        vm: String::new(),
                        evidence_paths: evidence(),
                    });
                }
                // App answered with a server error (not a gateway error) →
                // routed + alive but misbehaving. Warn, don't hard-fail.
                500..=599 => {
                    warnings += 1;
                    issues.push(Issue {
                        severity: "WARN".into(),
                        message: format!("{}: HTTP {}", ep.service, ep.status_code),
                        kind: "endpoint".into(),
                        entity: ep.service.clone(),
                        vm: String::new(),
                        evidence_paths: evidence(),
                    });
                }
                // 2xx/3xx (incl. auth-gate redirects) and 4xx (auth challenge /
                // base-path-without-index on a routed service) → UP.
                _ => { ok += 1; }
            }
        }

        // Certs
        for cert in &certs {
            let cert_evidence = vec![
                format!("tls/{}_443.txt", cert.domain),
                format!("dns/{}.txt", cert.domain),
                "cloudflare/all_records.json".to_string(),
            ];
            if cert.days_left < 7 {
                critical += 1;
                issues.push(Issue {
                    severity: "CRIT".into(),
                    message: format!("cert {} expires in {}d", cert.domain, cert.days_left),
                    kind: "cert".into(),
                    entity: cert.domain.clone(),
                    vm: String::new(),
                    evidence_paths: cert_evidence,
                });
            } else if cert.days_left < 30 {
                warnings += 1;
                issues.push(Issue {
                    severity: "WARN".into(),
                    message: format!("cert {} expires in {}d", cert.domain, cert.days_left),
                    kind: "cert".into(),
                    entity: cert.domain.clone(),
                    vm: String::new(),
                    evidence_paths: cert_evidence,
                });
            } else {
                ok += 1;
            }
        }

        // GHA — current health only: collapse to the LATEST run per
        // (repo, workflow). `gha_runs` arrives sorted newest-first, so the first
        // time we see a (repo, name) pair is its most recent run; later (older)
        // runs are ignored. Without this, a workflow that failed once and then
        // succeeded on re-run would still be flagged CRIT from the stale failure
        // — a false red for an already-recovered pipeline. Runs still in
        // progress (empty/"?" conclusion) are skipped, not failed.
        let mut seen_workflows: HashSet<(String, String)> = HashSet::new();
        for run in &gha_runs {
            if !seen_workflows.insert((run.repo.clone(), run.name.clone())) {
                continue; // older run of an already-classified workflow
            }
            match run.conclusion.as_str() {
                "failure" => {
                    critical += 1;
                    issues.push(Issue {
                        severity: "CRIT".into(),
                        message: format!("GHA {} FAILED", run.name),
                        kind: "gha".into(),
                        entity: run.name.clone(),
                        vm: String::new(),
                        evidence_paths: vec![],
                    });
                }
                "success" => { ok += 1; }
                // Still running / queued / unknown — not a result yet.
                "" | "?" | "in_progress" | "queued" | "pending" | "waiting" | "requested" => {}
                other => {
                    warnings += 1;
                    issues.push(Issue {
                        severity: "WARN".into(),
                        message: format!("GHA {} {}", run.name, other),
                        kind: "gha".into(),
                        entity: run.name.clone(),
                        vm: String::new(),
                        evidence_paths: vec![],
                    });
                }
            }
        }

        // Dagu DAGs — same shape as GHA. Status values from the Dagu API:
        // "succeeded", "failed", "running", "not_started", "cancelled", "queued".
        // We surface "failed" as CRIT and any non-success/non-running as WARN
        // so a stuck/cancelled DAG also shows up. evidence_paths points at the
        // Dagu UI route — entity is the DAG name, ${dag_name} resolves there.
        for dag in &dags {
            match dag.status.as_str() {
                "failed" => {
                    critical += 1;
                    issues.push(Issue {
                        severity: "CRIT".into(),
                        message: format!(
                            "DAG {} FAILED (last run {}, schedule: {})",
                            dag.name,
                            dag.started_at,
                            if dag.schedule.is_empty() { "none" } else { &dag.schedule }
                        ),
                        kind: "dag".into(),
                        entity: dag.name.clone(),
                        vm: String::new(),
                        evidence_paths: vec![],
                    });
                }
                "succeeded" | "running" => { ok += 1; }
                other => {
                    warnings += 1;
                    issues.push(Issue {
                        severity: "WARN".into(),
                        message: format!(
                            "DAG {} {} (last run {}, schedule: {})",
                            dag.name,
                            other,
                            dag.started_at,
                            if dag.schedule.is_empty() { "none" } else { &dag.schedule }
                        ),
                        kind: "dag".into(),
                        entity: dag.name.clone(),
                        vm: String::new(),
                        evidence_paths: vec![],
                    });
                }
            }
        }

        // Sort issues: CRIT first, then WARN, then by kind for stable grouping
        issues.sort_by(|a, b| {
            let ord_a = if a.severity == "CRIT" { 0 } else { 1 };
            let ord_b = if b.severity == "CRIT" { 0 } else { 1 };
            ord_a.cmp(&ord_b).then_with(|| a.kind.cmp(&b.kind)).then_with(|| a.entity.cmp(&b.entity))
        });

        // Dedupe by (kind, entity, severity) — sources of duplicates:
        //   - GHA: same workflow ("Ship → Builder images") failing 8x in the
        //     window emits 8 identical Issues.
        //   - endpoint: same domain (api.diegonmarcos.com) probed via
        //     monitoring-targets + caddy-routes + service.domain emits 4
        //     identical Issues.
        // First occurrence wins (preserves the sort order: CRIT > WARN > kind).
        // Rebuild critical/warnings counts from the deduped list so the
        // user-facing numbers reflect distinct entities, not raw signal volume.
        {
            let mut seen: std::collections::HashSet<(String, String, String)> =
                std::collections::HashSet::new();
            issues.retain(|i| seen.insert((i.kind.clone(), i.entity.clone(), i.severity.clone())));
        }
        critical = issues.iter().filter(|i| i.severity == "CRIT").count() as u32;
        warnings = issues.iter().filter(|i| i.severity == "WARN").count() as u32;

        // Full list for JSON debug consumers (untruncated, deduped).
        let all_issues = issues.clone();
        // Display slice for markdown/HTML — top 10 (was 3, now richer).
        let mut top_issues = issues;
        top_issues.truncate(10);

        let mut issues_by_kind: std::collections::BTreeMap<String, u32> = std::collections::BTreeMap::new();
        for i in &all_issues {
            let k = if i.kind.is_empty() { "other".to_string() } else { i.kind.clone() };
            *issues_by_kind.entry(k).or_insert(0) += 1;
        }

        ExecSummary { critical, warnings, ok, top_issues, all_issues, issues_by_kind }
    };

    // 6b. Compute container CPU ranking (top 20 across all VMs)
    let container_cpu_ranking: Vec<ContainerCpuRank> = {
        let mut all_entries: Vec<ContainerCpuRank> = Vec::new();
        for vm in &vms {
            for stat in &vm.container_stats {
                // Find uptime from container_list by matching name
                let uptime_hours = vm.container_list.iter()
                    .find(|c| c.name == stat.name)
                    .map(|c| parse_running_for(&c.running_for))
                    .unwrap_or(0.0);

                let cpu_num: f64 = stat.cpu.trim_end_matches('%').trim().parse().unwrap_or(0.0);
                let mem_mib = parse_mem_mib(&stat.mem_usage);
                let cpu_hours = (cpu_num / 100.0) * uptime_hours;
                let mem_gb_hours = (mem_mib / 1024.0) * uptime_hours;

                all_entries.push(ContainerCpuRank {
                    rank: 0,
                    container: stat.name.clone(),
                    vm: vm.name.clone(),
                    cpu_pct: stat.cpu.clone(),
                    mem_usage: stat.mem_usage.clone(),
                    mem_pct: stat.mem_pct.clone(),
                    uptime_hours,
                    cpu_hours,
                    mem_gb_hours,
                });
            }
        }
        // Sort by CPU*hours descending (sustained load matters more than peak %)
        all_entries.sort_by(|a, b| {
            b.cpu_hours.partial_cmp(&a.cpu_hours).unwrap_or(std::cmp::Ordering::Equal)
        });
        // No truncation — list ALL containers
        // Assign ranks after sorting
        for (i, entry) in all_entries.iter_mut().enumerate() {
            entry.rank = (i + 1) as u32;
        }
        all_entries
    };

    // 6.5 Assemble Z-Appendix. Pass-1 sees only the in-process health_full2
    // sub-engine result. The mail-derive contributes its Z-sections during
    // Phase 3 render-only re-pass.
    let apx = appendix::from_reports(full2_report.as_ref().ok(), None);
    if let Err(ref e) = full2_report { eprintln!("[health_full2] failed: {}", e); }
    if !apx.is_empty() {
        println!("Appendix loaded: {}", apx.summary());
    } else {
        println!("Appendix: empty (Phase 1 — mail derive contributes in Phase 3)");
    }

    // 7. Build report data
    let report = ReportData {
        date,
        time,
        vms,
        endpoints,
        certs,
        dns,
        gha_runs,
        gha_workflows,
        ghcr_packages,
        ghcr_total,
        github_disk_kb,
        dags,
        databases: ctx.databases.databases.clone(),
        fleet_running,
        fleet_total,
        fleet_unhealthy,
        drift,
        exec_summary,
        container_drift,
        cloud_buckets,
        cloud_costs,
        total_services: services.iter().filter(|s| s.enabled).count(),
        services,
        repos,
        mcp_servers: ctx.mcp_servers.clone(),
        vps_providers: ctx.vps_providers.clone(),
        vm_finops: ctx.vm_finops.clone(),
        total_containers: fleet_total,
        total_domains: ctx.total_domains,
        generation_duration_ms: start.elapsed().as_millis() as u64,
        ai: ctx.ai,
        umami_sites,
        container_cpu_ranking,
        firewalls: ctx.firewalls.clone(),
        global_firewall: ctx.global_firewall.clone(),
        mail_health,
        matomo_sites,
        appendix_md: apx.legacy_md(),
        appendix_stack: apx.stack.clone(),
        appendix_full: apx.full.clone(),
    };

    // 7b. Write partial RunState snapshot for derives to consume.
    //     Any field a derive may need to skip its own duplicate collection
    //     gets serialized here. Failures are non-fatal — derives degrade
    //     to their pre-snapshot behaviour.
    {
        use reports_common::run_state::{RunState, RUN_STATE_FILENAME};
        let mut rs = RunState::new();
        rs.master_duration_ms = Some(start.elapsed().as_millis() as u64);
        rs.vms = serde_json::to_value(&report.vms).ok();
        rs.endpoints = serde_json::to_value(&report.endpoints).ok();
        rs.certs = serde_json::to_value(&report.certs).ok();
        rs.dns = serde_json::to_value(&report.dns).ok();
        rs.gha_runs = serde_json::to_value(&report.gha_runs).ok();
        rs.gha_workflows = serde_json::to_value(&report.gha_workflows).ok();
        rs.ghcr = serde_json::to_value(serde_json::json!({
            "packages": &report.ghcr_packages,
            "total": report.ghcr_total,
            "github_disk_kb": report.github_disk_kb,
        }))
        .ok();
        rs.dags = serde_json::to_value(&report.dags).ok();
        rs.cloud_buckets = serde_json::to_value(&report.cloud_buckets).ok();
        rs.cloud_costs = serde_json::to_value(&report.cloud_costs).ok();
        rs.repos = serde_json::to_value(&report.repos).ok();
        rs.matomo_sites = serde_json::to_value(&report.matomo_sites).ok();
        rs.umami_sites = serde_json::to_value(&report.umami_sites).ok();
        rs.container_drift = serde_json::to_value(&report.container_drift).ok();
        rs.storage_drift = serde_json::to_value(&report.drift).ok();
        rs.fleet_state = Some(fleet_state.clone());
        rs.master_perf = serde_json::to_value(perf.finish()).ok();
        let path = std::path::PathBuf::from(RUN_STATE_FILENAME);
        if let Err(e) = rs.write_atomic(&path) {
            eprintln!("[run_state] write failed: {e}");
        } else {
            let bytes = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
            println!("[run_state] wrote {} ({} bytes)", path.display(), bytes);
        }
    }

    // 8. Render HTML (email + web)
    let html_email = html::render(&report, html::OutputMode::Email);
    let html_web = html::render(&report, html::OutputMode::Web);

    // 8b. Render Markdown (template-driven; parity with other report crates).
    let md_out = match md::render(&report) {
        Ok(s) => Some(s),
        Err(e) => {
            eprintln!("[md] render failed: {}", e);
            None
        }
    };

    // 9. Write outputs — engine invokes binary with cwd=dist/
    let output_path = std::path::PathBuf::from("cloud_health_daily.html");
    std::fs::write(&output_path, &html_email)?;
    std::fs::write("cloud_health_daily_web.html", &html_web)?;
    if let Some(ref md_s) = md_out {
        std::fs::write(md::output_path(), md_s)?;
    }

    // 10. Write JSON (for debugging / programmatic access)
    let json = serde_json::to_string_pretty(&report)?;
    std::fs::write("cloud_health_daily.json", &json)?;

    println!(
        "\n=== DONE in {:.1}s === HTML: {} ({} bytes email, {} bytes web){}",
        start.elapsed().as_secs_f64(),
        output_path.display(),
        html_email.len(),
        html_web.len(),
        md_out
            .as_ref()
            .map(|s| format!(", MD: {} bytes", s.len()))
            .unwrap_or_default(),
    );

    Ok(())
}

/// Parse Docker's "running_for" string (e.g. "12 hours", "2 days", "About an hour") to hours
fn parse_running_for(s: &str) -> f64 {
    let s = s.trim().to_lowercase();
    // "about a minute" / "about an hour"
    if s.contains("about a minute") || s.contains("less than a second") {
        return 0.0;
    }
    if s.contains("about an hour") {
        return 1.0;
    }

    // Try to extract a number + unit pattern
    let mut hours = 0.0;
    let parts: Vec<&str> = s.split_whitespace().collect();
    let mut i = 0;
    while i < parts.len() {
        if let Ok(num) = parts[i].parse::<f64>() {
            let unit = parts.get(i + 1).unwrap_or(&"");
            if unit.starts_with("second") {
                hours += num / 3600.0;
            } else if unit.starts_with("minute") {
                hours += num / 60.0;
            } else if unit.starts_with("hour") {
                hours += num;
            } else if unit.starts_with("day") {
                hours += num * 24.0;
            } else if unit.starts_with("week") {
                hours += num * 24.0 * 7.0;
            } else if unit.starts_with("month") {
                hours += num * 24.0 * 30.0;
            } else if unit.starts_with("year") {
                hours += num * 24.0 * 365.0;
            }
            i += 2;
        } else {
            i += 1;
        }
    }
    hours
}

/// Parse mem_usage string like "119.7MiB / 23.41GiB" to MiB (first part only)
fn parse_mem_mib(s: &str) -> f64 {
    let used_part = s.split('/').next().unwrap_or("").trim();
    if used_part.ends_with("GiB") {
        used_part.trim_end_matches("GiB").trim().parse::<f64>().unwrap_or(0.0) * 1024.0
    } else if used_part.ends_with("MiB") {
        used_part.trim_end_matches("MiB").trim().parse::<f64>().unwrap_or(0.0)
    } else if used_part.ends_with("KiB") {
        used_part.trim_end_matches("KiB").trim().parse::<f64>().unwrap_or(0.0) / 1024.0
    } else if used_part.ends_with("B") {
        used_part.trim_end_matches("B").trim().parse::<f64>().unwrap_or(0.0) / (1024.0 * 1024.0)
    } else {
        0.0
    }
}
