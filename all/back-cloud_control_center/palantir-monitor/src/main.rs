mod checks;
mod config;
mod email;
mod report;
mod topology;
mod types;

use anyhow::Result;
use checks::*;
use config::CloudConfig;
use report::Report;
use tracing_subscriber;

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize logging
    tracing_subscriber::fmt()
        .with_env_filter("palantir_monitor=info")
        .init();

    tracing::info!("==========================================");
    tracing::info!("Palantir Monitor - Cloud Health Check");
    tracing::info!("Started: {}", chrono::Utc::now().format("%Y-%m-%d %H:%M:%S UTC"));
    tracing::info!("==========================================");

    // 1. Load configuration
    tracing::info!("Loading configuration...");
    let config = CloudConfig::load()?;
    tracing::info!("Configuration loaded successfully");

    // 2. Create check context
    tracing::info!("Initializing check context...");
    let ctx = CheckContext::new(config.clone()).await?;
    tracing::info!("Check context initialized");

    // 3. Register all checks
    let mut registry = CheckRegistry::new();
    registry.register(Box::new(external::ExternalCheck::new()));
    registry.register(Box::new(cloud::CloudCheck::new()));
    registry.register(Box::new(docker::DockerCheck::new()));
    registry.register(Box::new(ports::PortCheck::new()));
    registry.register(Box::new(ips::IpCheck::new()));
    registry.register(Box::new(security::SecurityCheck::new()));
    registry.register(Box::new(sauron::SauronCheck::new()));

    tracing::info!("Registered {} health checks", registry.checks().len());

    // 4. Run all checks
    tracing::info!("Running health checks...");
    let check_results = registry.run_all(&ctx).await;

    // Collect successful results (log errors)
    let mut results = Vec::new();
    for (i, result) in check_results.into_iter().enumerate() {
        match result {
            Ok(r) => {
                tracing::info!(
                    "✅ {} completed: {} OK, {} WARN, {} FAIL",
                    r.name,
                    r.ok_count(),
                    r.warn_count(),
                    r.fail_count()
                );
                results.push(r);
            }
            Err(e) => {
                tracing::error!("❌ Check {} failed: {}", i, e);
            }
        }
    }

    // 5. Generate ASCII topology
    tracing::info!("Generating ASCII topology diagram...");
    let ascii_topology = topology::generate_ascii_topology(&config);

    // 6. Build report
    tracing::info!("Building reports...");
    let report = Report::build(&config, results, &ascii_topology)?;

    // Display summary
    tracing::info!("");
    tracing::info!("==========================================");
    tracing::info!("Report Summary:");
    tracing::info!("  ✅ Passed:   {}", report.summary.ok_count);
    tracing::info!("  ❌ Failed:   {}", report.summary.fail_count);
    tracing::info!("  ⚠️  Warnings: {}", report.summary.warn_count);
    tracing::info!("  📊 Total:    {}", report.summary.total_checks);
    tracing::info!("  💯 Health:   {}%", report.summary.health_score);
    tracing::info!("  🎯 Status:   {}", report.summary.status);
    tracing::info!("==========================================");
    tracing::info!("");

    // 7. Save reports
    tracing::info!("Saving reports to /app/reports/...");
    report.save("/app/reports")?;
    tracing::info!("Reports saved successfully");

    // 8. Send email
    tracing::info!("Sending email report...");
    email::send_report(&report, &config).await?;
    tracing::info!("Email sent successfully");

    tracing::info!("");
    tracing::info!("==========================================");
    tracing::info!("Completed: {}", chrono::Utc::now().format("%Y-%m-%d %H:%M:%S UTC"));
    tracing::info!("==========================================");

    Ok(())
}
