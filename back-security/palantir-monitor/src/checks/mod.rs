use crate::config::CloudConfig;
use crate::types::CheckResult;
use anyhow::Result;
use async_trait::async_trait;
use reqwest::Client;
use std::sync::Arc;
use std::time::Duration;
use trust_dns_resolver::TokioAsyncResolver;

// Check module declarations
pub mod external;
pub mod cloud;
pub mod docker;
pub mod ports;
pub mod ips;
pub mod security;
pub mod sauron;

/// Shared context for all checks
#[derive(Clone)]
pub struct CheckContext {
    pub config: Arc<CloudConfig>,
    pub http_client: Client,
    pub dns_resolver: Arc<TokioAsyncResolver>,
}

impl CheckContext {
    pub async fn new(config: CloudConfig) -> Result<Self> {
        // Create HTTP client with timeout
        let http_client = Client::builder()
            .timeout(Duration::from_secs(10))
            .danger_accept_invalid_certs(false)
            .build()?;

        // Create DNS resolver
        let dns_resolver = Arc::new(
            TokioAsyncResolver::tokio_from_system_conf()?
        );

        Ok(Self {
            config: Arc::new(config),
            http_client,
            dns_resolver,
        })
    }
}

/// Trait that all health checks must implement
#[async_trait]
pub trait Check: Send + Sync {
    /// Name of the check (e.g., "External Connectivity")
    fn name(&self) -> &str;

    /// Emoji for the check section (e.g., "1️⃣")
    fn emoji(&self) -> &str;

    /// Run the health check
    async fn run(&self, ctx: &CheckContext) -> Result<CheckResult>;
}

/// Registry for all checks
pub struct CheckRegistry {
    checks: Vec<Box<dyn Check>>,
}

impl CheckRegistry {
    pub fn new() -> Self {
        Self {
            checks: Vec::new(),
        }
    }

    pub fn register(&mut self, check: Box<dyn Check>) {
        self.checks.push(check);
    }

    pub async fn run_all(&self, ctx: &CheckContext) -> Vec<Result<CheckResult>> {
        // Run checks sequentially (trait objects can't be cloned for concurrent execution)
        let mut results = Vec::new();
        for check in &self.checks {
            tracing::info!("Running check: {}", check.name());
            let result = check.run(ctx).await;
            results.push(result);
        }
        results
    }

    pub fn checks(&self) -> &[Box<dyn Check>] {
        &self.checks
    }
}

impl Default for CheckRegistry {
    fn default() -> Self {
        Self::new()
    }
}

/// Helper function to check if a port is open
pub async fn check_port(host: &str, port: u16, timeout_secs: u64) -> bool {
    use tokio::net::TcpStream;
    use tokio::time::timeout;

    let addr = format!("{}:{}", host, port);
    let duration = Duration::from_secs(timeout_secs);

    match timeout(duration, TcpStream::connect(&addr)).await {
        Ok(Ok(_)) => true,
        _ => false,
    }
}

/// Helper function to check HTTP endpoint
pub async fn check_http(
    client: &Client,
    url: &str,
    expected_codes: &[u16],
) -> Result<(u16, bool)> {
    let response = client
        .get(url)
        .send()
        .await?;

    let status = response.status().as_u16();
    let success = expected_codes.contains(&status);

    Ok((status, success))
}
