use crate::config::CloudConfig;
use crate::topology;
use crate::types::{CheckResult, Metadata, Status, Summary};
use anyhow::Result;
use chrono::Utc;
use serde::Serialize;
use serde_json::json;
use std::fs;
use std::path::Path;

#[derive(Clone)]
pub struct Report {
    pub metadata: Metadata,
    pub summary: Summary,
    pub results: Vec<CheckResult>,
    pub ascii_topology: String,
    pub config: CloudConfig,
}

impl Report {
    pub fn build(
        config: &CloudConfig,
        results: Vec<CheckResult>,
        ascii_topology: &str,
    ) -> Result<Self> {
        let metadata = Metadata::new();
        let summary = Summary::from_results(&results);

        Ok(Self {
            metadata,
            summary,
            results,
            ascii_topology: ascii_topology.to_string(),
            config: config.clone(),
        })
    }

    pub fn generate_markdown(&self) -> String {
        let mut md = String::new();

        // Header
        md.push_str("# 📊 Palantir Monitor - Cloud Infrastructure Health Report\n\n");
        md.push_str(&format!("**Generated:** {}\n", Utc::now().format("%Y-%m-%d %H:%M:%S UTC")));
        md.push_str(&format!("**Report ID:** {}\n\n", self.metadata.report_id));
        md.push_str("---\n\n");

        // Topology section
        md.push_str("## 🗺️ Infrastructure Topology\n\n");

        // Cloud Providers table
        md.push_str("### Cloud Providers\n\n");
        md.push_str("| Provider | Region | Tier |\n");
        md.push_str("|----------|--------|------|\n");
        md.push_str("| Oracle Cloud (OCI) | eu-marseille-1 | Always Free |\n");
        md.push_str("| Google Cloud (GCP) | us-central1 | Free Tier |\n\n");

        // VMs table
        md.push_str("### Virtual Machines\n\n");
        md.push_str("| VM | Provider | IP | RAM | Role | Services |\n");
        md.push_str("|----|----------|-----|-----|------|----------|\n");
        for vm in &self.config.vms {
            md.push_str(&format!(
                "| {} | {} | {} | {} | {} | {} |\n",
                vm.id,
                vm.provider,
                vm.ip,
                vm.ram,
                vm.role,
                vm.services.join(", ")
            ));
        }
        md.push_str("\n");

        // Domain Structure table
        md.push_str("### Domain Structure\n\n");
        md.push_str("| Domain | Purpose |\n");
        md.push_str("|--------|---------|");
        for domain in &self.config.domains {
            md.push_str(&format!("\n| {} | {} |", domain.domain, domain.purpose));
        }
        md.push_str("\n\n");

        // Docker Networks table
        md.push_str("### Docker Networks\n\n");
        md.push_str("| Network | Subnet | VM | Purpose |\n");
        md.push_str("|---------|--------|----|---------|\n");
        for net in &self.config.networks {
            let purpose = match net.name.as_str() {
                "mail_network" => "Mailu stack",
                "matomo_network" => "Analytics",
                "npm_default" => "Proxy services",
                "dev_network" => "Media apps",
                _ => "Services",
            };
            md.push_str(&format!("| {} | {} | {} | {} |\n", net.name, net.subnet, net.vm, purpose));
        }
        md.push_str("\n---\n\n");

        // ASCII Topology
        md.push_str(&self.ascii_topology);
        md.push_str("\n---\n\n");

        // Check results
        for result in &self.results {
            md.push_str(&format!("## {} {}\n\n", result.emoji, result.name));

            // Description based on check name
            let description = match result.emoji.as_str() {
                "1️⃣" => "Tests all services from the **outside** (as users would access them)\n\n",
                "2️⃣" => "Uses **SSH** to gather system metrics from each VM\n\n",
                "3️⃣" => "Cross-VM container health aggregation\n\n",
                "4️⃣" => "External port scanning + security validation\n\n",
                "5️⃣" => "DNS reconciliation and network topology\n\n",
                "6️⃣" => "SSL certificates, headers, and vulnerability scanning\n\n",
                "7️⃣" => "Collects YARA scanner alerts from all VMs\n\n",
                _ => "",
            };
            md.push_str(description);

            // Passed items
            if !result.passed.is_empty() {
                for item in &result.passed {
                    md.push_str(&format!("  - {} {}\n", Status::Ok.emoji(), item.description));
                }
            }

            // Warning items
            if !result.warnings.is_empty() {
                for item in &result.warnings {
                    let details = item.details.as_ref().map(|d| format!(" - {}", d)).unwrap_or_default();
                    md.push_str(&format!("  - {} {}{}\n", Status::Warn.emoji(), item.description, details));
                }
            }

            // Failed items
            if !result.failed.is_empty() {
                for item in &result.failed {
                    let details = item.details.as_ref().map(|d| format!(" - {}", d)).unwrap_or_default();
                    md.push_str(&format!("  - {} {}{}\n", Status::Fail.emoji(), item.description, details));
                }
            }

            md.push_str("\n");
            md.push_str(&result.summary);
            md.push_str("\n\n");
        }

        // Overall summary
        md.push_str("---\n\n");
        md.push_str("## 📈 Overall Summary\n\n");
        md.push_str("| Metric | Value |\n");
        md.push_str("|--------|-------|\n");
        md.push_str(&format!("| ✅ Passed | {} |\n", self.summary.ok_count));
        md.push_str(&format!("| ❌ Failed | {} |\n", self.summary.fail_count));
        md.push_str(&format!("| ⚠️ Warnings | {} |\n", self.summary.warn_count));
        md.push_str(&format!("| **Total Checks** | **{}** |\n\n", self.summary.total_checks));
        md.push_str(&format!("### Health Score: {}%\n\n", self.summary.health_score));
        md.push_str("---\n\n");
        md.push_str("*🤖 Generated by Palantir Monitor v2.0*\n");

        md
    }

    pub fn generate_json(&self) -> Result<String> {
        let json_data = json!({
            "metadata": {
                "generated": self.metadata.generated,
                "host": self.metadata.host,
                "report_id": self.metadata.report_id,
                "timestamp": self.metadata.timestamp,
                "version": self.metadata.version,
            },
            "summary": {
                "ok_count": self.summary.ok_count,
                "fail_count": self.summary.fail_count,
                "warn_count": self.summary.warn_count,
                "total_checks": self.summary.total_checks,
                "health_score": self.summary.health_score,
                "status": self.summary.status,
            },
            "topology": {
                "providers": ["Oracle Cloud (OCI)", "Google Cloud (GCP)"],
                "regions": {
                    "oci": "eu-marseille-1",
                    "gcp": "us-central1"
                },
                "vms": self.config.vms,
                "domains": {
                    "root": "diegonmarcos.com",
                    "subdomains": self.config.domain_list,
                },
                "networks": self.config.networks,
            },
            "checks": {
                "results": self.results.iter().map(|r| {
                    json!({
                        "name": r.name,
                        "emoji": r.emoji,
                        "ok_count": r.ok_count(),
                        "warn_count": r.warn_count(),
                        "fail_count": r.fail_count(),
                        "total": r.total_count(),
                    })
                }).collect::<Vec<_>>(),
            },
            "report_files": {
                "markdown": format!("health-report-{}.md", self.metadata.timestamp),
                "json": format!("health-report-{}.json", self.metadata.timestamp),
            }
        });

        Ok(serde_json::to_string_pretty(&json_data)?)
    }

    pub fn generate_html(&self) -> String {
        // Simple HTML wrapper around markdown
        let md = self.generate_markdown();
        let mut html = String::new();

        html.push_str("<!DOCTYPE html>\n<html>\n<head>\n");
        html.push_str("<meta charset=\"UTF-8\">\n");
        html.push_str("<style>\n");
        // Light mode (default)
        html.push_str("body { font-family: -apple-system, sans-serif; line-height: 1.6; color: #333; background: #fff; max-width: 900px; margin: 20px auto; padding: 20px; }\n");
        html.push_str("h1 { color: #2563eb; border-bottom: 2px solid #2563eb; padding-bottom: 8px; }\n");
        html.push_str("h2 { color: #1e40af; margin-top: 25px; }\n");
        html.push_str("h3 { color: #374151; margin-top: 15px; }\n");
        html.push_str("ul { margin: 10px 0; padding-left: 25px; list-style: none; }\n");
        html.push_str("li { margin: 5px 0; }\n");
        html.push_str("table { width: 100%; border-collapse: collapse; margin: 15px 0; }\n");
        html.push_str("th { background: #1e40af; color: white; padding: 10px; text-align: left; }\n");
        html.push_str("td { padding: 8px 10px; border-bottom: 1px solid #e5e7eb; }\n");
        html.push_str("tr:nth-child(even) { background: #f9fafb; }\n");
        html.push_str("hr { border: none; border-top: 1px solid #e5e7eb; margin: 20px 0; }\n");
        html.push_str("code, pre { background: #f3f4f6; padding: 2px 5px; border-radius: 3px; font-family: monospace; }\n");
        html.push_str("pre { padding: 15px; overflow-x: auto; }\n");
        html.push_str("strong { color: #1e293b; }\n");
        // Dark mode
        html.push_str("@media (prefers-color-scheme: dark) {\n");
        html.push_str("  body { color: #e5e7eb; background: #1a1a1a; }\n");
        html.push_str("  h1 { color: #60a5fa; border-bottom-color: #60a5fa; }\n");
        html.push_str("  h2 { color: #93c5fd; }\n");
        html.push_str("  h3 { color: #d1d5db; }\n");
        html.push_str("  th { background: #374151; color: #f3f4f6; }\n");
        html.push_str("  td { border-bottom: 1px solid #374151; }\n");
        html.push_str("  tr:nth-child(even) { background: #262626; }\n");
        html.push_str("  hr { border-top-color: #374151; }\n");
        html.push_str("  code, pre { background: #262626; color: #e5e7eb; }\n");
        html.push_str("  strong { color: #f3f4f6; }\n");
        html.push_str("}\n");
        html.push_str("</style>\n");
        html.push_str("</head>\n<body>\n");

        // Simple markdown to HTML conversion
        for line in md.lines() {
            if line.starts_with("# ") {
                html.push_str(&format!("<h1>{}</h1>\n", &line[2..]));
            } else if line.starts_with("## ") {
                html.push_str(&format!("<h2>{}</h2>\n", &line[3..]));
            } else if line.starts_with("### ") {
                html.push_str(&format!("<h3>{}</h3>\n", &line[4..]));
            } else if line.starts_with("---") {
                html.push_str("<hr>\n");
            } else if line.starts_with("  - ") {
                html.push_str(&format!("<li>{}</li>\n", &line[4..]));
            } else if line.starts_with("| ") {
                // Simple table handling (skip for now in basic version)
                html.push_str(&format!("{}<br>\n", line));
            } else if line.starts_with("```") {
                html.push_str("<pre>\n");
            } else if !line.is_empty() {
                html.push_str(&format!("{}<br>\n", line));
            }
        }

        html.push_str("</body>\n</html>");
        html
    }

    pub fn save(&self, output_dir: &str) -> Result<()> {
        let dir = Path::new(output_dir);
        fs::create_dir_all(dir)?;

        let base_name = format!("health-report-{}", self.metadata.timestamp);

        // Save markdown
        let md_path = dir.join(format!("{}.md", base_name));
        fs::write(&md_path, self.generate_markdown())?;

        // Save JSON
        let json_path = dir.join(format!("{}.json", base_name));
        fs::write(&json_path, self.generate_json()?)?;

        // Save HTML
        let html_path = dir.join(format!("{}.html", base_name));
        fs::write(&html_path, self.generate_html())?;

        tracing::info!("Reports saved to {:?}", dir);

        Ok(())
    }

    pub fn subject_line(&self) -> String {
        let date = Utc::now().format("%Y-%m-%d").to_string();
        self.summary.subject_line(&date)
    }
}
