use crate::checks::{check_port, Check, CheckContext};
use crate::types::{CheckItem, CheckResult, Status};
use anyhow::Result;
use async_trait::async_trait;

pub struct PortCheck;

impl PortCheck {
    pub fn new() -> Self {
        Self
    }
}

#[async_trait]
impl Check for PortCheck {
    fn name(&self) -> &str {
        "Port Analysis"
    }

    fn emoji(&self) -> &str {
        "4️⃣"
    }

    async fn run(&self, ctx: &CheckContext) -> Result<CheckResult> {
        let mut result = CheckResult::new(self.name(), self.emoji());

        // Check expected ports on each VM
        let mail_ip = ctx.config.get_vm_ip("oci-micro-1").unwrap_or("130.110.251.193");

        let mail_ports = vec![
            (22, "SSH"), (25, "SMTP"), (80, "HTTP"), (443, "HTTPS"),
            (465, "SMTPS"), (587, "Submission"), (993, "IMAPS"), (8080, "Proxy"),
        ];

        for (port, name) in mail_ports {
            let open = check_port(mail_ip, port, 3).await;
            result.add_item(CheckItem {
                description: format!("OCI Micro 1: {} ({})", port, name),
                status: if open { Status::Ok } else { Status::Fail },
                details: None,
            });
        }

        // Check for unexpected open ports (databases)
        let risky_ports = vec![
            (3306, "MySQL"),
            (5432, "PostgreSQL"),
            (6379, "Redis"),
            (27017, "MongoDB"),
        ];

        for (port, name) in risky_ports {
            let open = check_port(mail_ip, port, 2).await;
            result.add_item(CheckItem {
                description: format!("{} ({}) - Not exposed", port, name),
                status: if !open { Status::Ok } else { Status::Fail },
                details: if open { Some("Risky port exposed!".to_string()) } else { None },
            });
        }

        let summary = format!(
            "**Total Port Checks: {}** | ✅ OK: {} | ⚠️ WARN: {} | ❌ FAIL: {}",
            result.total_count(),
            result.ok_count(),
            result.warn_count(),
            result.fail_count()
        );

        Ok(result.with_summary(summary))
    }
}
