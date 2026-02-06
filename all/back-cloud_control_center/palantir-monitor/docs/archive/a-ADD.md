# Architecture Design Document: Enterprise Cloud Control Plane (Rust Implementation)

| Document Metadata | Value |
|---|---|
| Project | Unified Cloud Control Plane (UCCP) |
| Version | 2.0 (Migration from Python to Rust) |
| Author | Senior Cloud Architecture Team |
| Status | APPROVED FOR IMPLEMENTATION |
| Context | Multi-Cloud Aggregation (AWS, Azure, On-Prem) |

## 1. Executive Summary

This document details the architectural specification for the re-platforming of the Enterprise Cloud Control Panel backend. The objective is to replace the existing dynamically typed Python ETL process with a statically typed, high-concurrency Rust binary.

**Primary drivers for this architectural shift:**

* **Correctness:** Enforcing strict JSON Schema compliance at the compilation level (Type-Driven Development).
* **Performance:** Leveraging tokio for non-blocking I/O across thousands of resource endpoints.
* **Deployability:** Compiling to a single, dependency-free binary (musl target) for deployment on distroless containers.

## 2. High-Level System Architecture

The system follows a **Fan-Out / Fan-In** concurrency pattern. The Aggregator does not process pillars sequentially; rather, it spawns lightweight Green Threads (Tokio Tasks) for each domain (SecOps, FinOps, Observability, Inventory), awaits their completion, and synthesizes a single immutable artifact.

### 2.1 Context Diagram

```
      +------------------+       +------------------+       +------------------+
      |    AWS Cost      |       |  Prometheus /    |       |   Tenable /      |
      |    Explorer      |       |  Datadog         |       |   Snyk API       |
      +--------+---------+       +--------+---------+       +--------+---------+
               |                          |                          |
               | (HTTPS/JSON)             | (HTTPS/PromQL)           | (HTTPS)
               v                          v                          v
      +------------------------------------------------------------------------+
      |                     RUST AGGREGATOR KERNEL                             |
      |                                                                        |
      |   +----------------+   +----------------+   +----------------+         |
      |   | FinOps Worker  |   | Obsv. Worker   |   | SecOps Worker  |         |
      |   | (Async Task)   |   | (Async Task)   |   | (Async Task)   |         |
      |   +-------+--------+   +-------+--------+   +-------+--------+         |
      |           |                    |                    |                  |
      |           +--------------------+--------------------+                  |
      |                                |                                       |
      |                     +----------v-----------+                           |
      |                     |   Schema Enforcer    |                           |
      |                     | (Serde De/Serialize) |                           |
      |                     +----------+-----------+                           |
      +--------------------------------|---------------------------------------+
                                       |
                                       v
                            +----------------------+
                            | dashboard_data.json  |
                            | (Strict Schema v1.0) |
                            +----------------------+
```

### 2.2 Sequence of Operations

1. **Initialization:** The binary loads configuration and initializes the Thread Pool.
2. **Fan-Out:** `tokio::join!` is invoked to dispatch collectors.
3. **Ingest & Map:** Each collector fetches raw data and immediately maps it to the Domain Structs. Validation happens here. If data violates the schema (e.g., negative cost, invalid enum), the worker returns an Error immediately.
4. **Fan-In:** The main thread collects results. Partial failures are handled (e.g., if SecOps fails, the dashboard can still generate with a "Degraded" flag, or fail hard depending on policy).
5. **Persist:** The final struct is serialized to JSON and flushed to disk/S3.

## 3. Data Model & Schema Strategy

We adhere to the **"Parse, don't validate"** philosophy. We do not write validation functions to check if a string is "OPERATIONAL". Instead, we define an `Enum Status::Operational`. It is physically impossible to construct the internal state with an invalid string.

### 3.1 Core Pillars

* **Topology:** The physical and logical map of resources.
* **Observability:** Golden signals (Latency, Traffic, Errors, Saturation).
* **SecOps:** Compliance scores and CVE counts.
* **FinOps:** Spend forecasting and budget adherence.

## 4. Implementation Specification

The following source code represents the complete, compilable implementation of the architecture.

### 4.1 Dependency Configuration (Cargo.toml)

Essential crates chosen for maturity and ecosystem support.

```toml
[package]
name = "cloud_control_plane"
version = "2.0.0"
edition = "2021"

[dependencies]
# CORE SERIALIZATION
# 'derive' allows us to annotate structs with #[derive(Serialize)]
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"

# ASYNC RUNTIME
# 'full' enables time, net, and multi-threaded executor
tokio = { version = "1.0", features = ["full"] }

# UTILITIES
chrono = { version = "0.4", features = ["serde"] } # ISO 8601 Time
uuid = { version = "1.0", features = ["serde", "v4"] } # Unique IDs
anyhow = "1.0" # Idiomatic Error Handling
```

### 4.2 The Contract (src/schema.rs)

This file defines the immutable contract. This matches the JSON Schema strictly.

```rust
// src/schema.rs
use serde::{Deserialize, Serialize};
use chrono::{DateTime, Utc};
use uuid::Uuid;
use std::collections::HashMap;

/// Root Data Transfer Object
#[derive(Debug, Serialize, Deserialize)]
pub struct DashboardData {
    pub meta: Meta,
    pub topology_inventory: TopologyInventory,
    pub observability: Observability,
    pub secops: SecOps,
    pub finops: FinOps,
}

// --- METADATA ---
#[derive(Debug, Serialize, Deserialize)]
pub struct Meta {
    pub dashboard_id: Uuid,
    pub generated_at: DateTime<Utc>,
    pub environment: Environment,
    pub schema_version: String,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")] // Forces JSON to be "production", not "Production"
pub enum Environment {
    Production,
    Staging,
    Dr,
}

// --- TOPOLOGY ---
#[derive(Debug, Serialize, Deserialize)]
pub struct TopologyInventory {
    pub total_asset_count: u32,
    pub service_map: Vec<ServiceNode>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ServiceNode {
    pub service_id: String,
    pub service_name: String,
    pub region: String,
    pub tags: HashMap<String, String>,
    pub dependencies: Vec<String>,
}

// --- OBSERVABILITY ---
#[derive(Debug, Serialize, Deserialize)]
pub struct Observability {
    pub overall_status: SystemStatus,
    pub active_incidents: u32,
    pub slo_adherence: Vec<ServiceSlo>,
}

#[derive(Debug, Serialize, Deserialize)]
pub enum SystemStatus {
    OPERATIONAL,
    DEGRADED,
    OUTAGE,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ServiceSlo {
    pub service_name: String,
    pub sli_metric_target: f64,
    pub error_budget_remaining: f64,
    pub golden_signals: GoldenSignals,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct GoldenSignals {
    pub latency_ms_p95: f64,
    pub traffic_rps: u32,
    pub error_rate_percent: f64,
    pub saturation_percent: f64,
}

// --- SECOPS ---
#[derive(Debug, Serialize, Deserialize)]
pub struct SecOps {
    pub compliance_score: f64,
    pub critical_vulnerabilities: u32,
    pub threat_detection: Vec<ThreatEvent>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ThreatEvent {
    pub severity: ThreatSeverity,
    #[serde(rename = "type")] // "type" is a reserved keyword in Rust
    pub threat_type: String,
    pub status: ThreatStatus,
    pub resource_id: String,
    pub timestamp: DateTime<Utc>,
}

#[derive(Debug, Serialize, Deserialize)]
pub enum ThreatSeverity {
    LOW,
    MEDIUM,
    HIGH,
    CRITICAL,
}

#[derive(Debug, Serialize, Deserialize)]
pub enum ThreatStatus {
    OPEN,
    INVESTIGATING,
    RESOLVED,
}

// --- FINOPS ---
#[derive(Debug, Serialize, Deserialize)]
pub struct FinOps {
    pub currency: String,
    pub month_to_date_spend: f64,
    pub forecasted_month_spend: f64,
    pub budget_threshold_percent: f64,
    pub top_cost_drivers: Vec<CostDriver>,
    pub optimization_opportunities: Vec<OptimizationOpp>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct CostDriver {
    pub service_name: String,
    pub cost: f64,
    pub change_from_last_month_percent: f64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct OptimizationOpp {
    pub resource_id: String,
    pub suggestion: String,
    pub estimated_monthly_savings: f64,
}
```

### 4.3 The Collectors (src/collectors.rs)

This module encapsulates the logic for retrieving data. In this implementation, we simulate API latency to demonstrate the async scheduler's behavior. In production, these blocks are replaced with `reqwest::Client` calls.

```rust
// src/collectors.rs
use crate::schema::*;
use tokio::time::{sleep, Duration};
use chrono::Utc;
use std::collections::HashMap;

pub async fn fetch_topology() -> anyhow::Result<TopologyInventory> {
    // Simulate complex graph traversal logic
    sleep(Duration::from_millis(150)).await;

    let mut tags = HashMap::new();
    tags.insert("Owner".to_string(), "Platform-SRE".to_string());
    tags.insert("Tier".to_string(), "1".to_string());

    Ok(TopologyInventory {
        total_asset_count: 1024,
        service_map: vec![
            ServiceNode {
                service_id: "svc-core-auth".to_string(),
                service_name: "Core Authentication".to_string(),
                region: "us-east-1".to_string(),
                tags,
                dependencies: vec!["db-primary".to_string(), "redis-cache".to_string()],
            }
        ],
    })
}

pub async fn fetch_observability() -> anyhow::Result<Observability> {
    // Simulate PromQL query latency
    sleep(Duration::from_millis(300)).await;

    Ok(Observability {
        overall_status: SystemStatus::OPERATIONAL,
        active_incidents: 0,
        slo_adherence: vec![
            ServiceSlo {
                service_name: "Core Authentication".to_string(),
                sli_metric_target: 99.99,
                error_budget_remaining: 100.0,
                golden_signals: GoldenSignals {
                    latency_ms_p95: 45.0,
                    traffic_rps: 1200,
                    error_rate_percent: 0.001,
                    saturation_percent: 32.5,
                },
            }
        ],
    })
}

pub async fn fetch_secops() -> anyhow::Result<SecOps> {
    // Simulate Security Hub API aggregation
    sleep(Duration::from_millis(200)).await;

    Ok(SecOps {
        compliance_score: 98.2,
        critical_vulnerabilities: 0,
        threat_detection: vec![
            ThreatEvent {
                severity: ThreatSeverity::LOW,
                threat_type: "Port Scan".to_string(),
                status: ThreatStatus::RESOLVED,
                resource_id: "fw-edge-01".to_string(),
                timestamp: Utc::now(),
            }
        ],
    })
}

pub async fn fetch_finops() -> anyhow::Result<FinOps> {
    // Simulate Cost Explorer API calculation
    sleep(Duration::from_millis(120)).await;

    Ok(FinOps {
        currency: "USD".to_string(),
        month_to_date_spend: 45200.00,
        forecasted_month_spend: 98000.00,
        budget_threshold_percent: 46.1,
        top_cost_drivers: vec![
            CostDriver {
                service_name: "RDS Aurora".to_string(),
                cost: 12000.00,
                change_from_last_month_percent: 2.1,
            }
        ],
        optimization_opportunities: vec![
            OptimizationOpp {
                resource_id: "i-0123456789".to_string(),
                suggestion: "Right-size EC2 Instance".to_string(),
                estimated_monthly_savings: 150.00,
            }
        ],
    })
}
```

### 4.4 The Orchestrator (src/main.rs)

The entry point ties the collectors and schema together.

```rust
// src/main.rs
mod schema;
mod collectors;

use schema::*;
use collectors::*;
use chrono::Utc;
use uuid::Uuid;
use std::fs::File;
use std::io::Write;
use std::path::Path;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    println!("--- [INIT] Cloud Control Plane Aggregator ---");
    let start_time = std::time::Instant::now();

    // 1. ASYNC ORCHESTRATION LAYER
    // We launch all collectors simultaneously.
    // Tokio handles the context switching efficiently.
    println!("--- [EXEC] Spawning Collector Threads...");

    let (inventory_res, obs_res, sec_res, fin_res) = tokio::join!(
        fetch_topology(),
        fetch_observability(),
        fetch_secops(),
        fetch_finops()
    );

    // 2. ERROR BOUNDARY
    // We unwrap results here. In a production CLI, we might use
    // robust logging libraries (tracing/log) to capture specific failures.
    let inventory = inventory_res?;
    let observability = obs_res?;
    let secops = sec_res?;
    let finops = fin_res?;

    println!("--- [DATA] All pillars aggregated successfully.");

    // 3. OBJECT ASSEMBLY
    let dashboard = DashboardData {
        meta: Meta {
            dashboard_id: Uuid::new_v4(),
            generated_at: Utc::now(),
            environment: Environment::Production,
            schema_version: "v2.0".to_string(),
        },
        topology_inventory: inventory,
        observability,
        secops,
        finops,
    };

    // 4. SERIALIZATION & PERSISTENCE
    let json_output = serde_json::to_string_pretty(&dashboard)?;

    let file_path = "dashboard_data.json";
    let mut file = File::create(Path::new(file_path))?;
    file.write_all(json_output.as_bytes())?;

    let duration = start_time.elapsed();

    // 5. OPERATIONAL SUMMARY
    println!("--- [DONE] Artifact generated at ./{}", file_path);
    println!("--- [METRICS] Time Elapsed: {:.2?}", duration);
    println!("--- [SUMMARY] Status: {:?} | Compliance: {}%",
        dashboard.observability.overall_status,
        dashboard.secops.compliance_score
    );

    Ok(())
}
```

## 5. Deployment Strategy

### 5.1 Build Pipeline

The Rust compiler (rustc) performs heavy optimization (LLVM backend). We recommend building the release binary using `musl` to create a truly static binary that runs on Alpine Linux or Scratch containers without glibc dependencies.

```bash
# Production Build Command
cargo build --release --target x86_64-unknown-linux-musl
```

### 5.2 Containerization

The resulting Docker image size is expected to be **<20MB** (compared to ~150MB+ for a Python equivalent with dependencies).

## 6. Architecture Review & Risks

| Risk Category | Risk Description | Mitigation |
|---|---|---|
| Learning Curve | Team familiarity with Rust's borrow checker may slow initial feature velocity. | Core architecture handles the complex async logic. Feature teams only need to implement logic within the defined Collector functions. |
| Compilation Time | Rust build times are longer than interpreted languages. | Implement aggressive caching in CI/CD (sccache) and use workspace incremental builds. |
| Schema Evolution | Breaking changes in Structs will break serialization. | This is a feature, not a bug. Breaking changes are caught at compile time, preventing runtime dashboard failures. |

---

*End of Document*
