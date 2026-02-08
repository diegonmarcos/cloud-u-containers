use crate::checks::{check_port, Check, CheckContext};
use crate::types::{CheckItem, CheckResult, Status};
use anyhow::Result;
use async_trait::async_trait;

pub struct CloudCheck;

impl CloudCheck {
    pub fn new() -> Self {
        Self
    }
}

#[async_trait]
impl Check for CloudCheck {
    fn name(&self) -> &str {
        "Cloud Infrastructure Status"
    }

    fn emoji(&self) -> &str {
        "2️⃣"
    }

    async fn run(&self, ctx: &CheckContext) -> Result<CheckResult> {
        let mut result = CheckResult::new(self.name(), self.emoji());

        // Check SSH accessibility for all VMs
        for vm in &ctx.config.vms {
            let reachable = check_port(&vm.ip, 22, 5).await;
            result.add_item(CheckItem {
                description: format!("{} ({}) - SSH accessible", vm.id, vm.ip),
                status: if reachable { Status::Ok } else { Status::Fail },
                details: if !reachable {
                    Some("Unreachable".to_string())
                } else {
                    None
                },
            });
        }

        let summary = format!(
            "**Total Infrastructure Checks: {}** | ✅ OK: {} | ⚠️ WARN: {} | ❌ FAIL: {}",
            result.total_count(),
            result.ok_count(),
            result.warn_count(),
            result.fail_count()
        );

        Ok(result.with_summary(summary))
    }
}
