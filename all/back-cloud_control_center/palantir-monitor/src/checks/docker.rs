use crate::checks::{Check, CheckContext};
use crate::types::{CheckItem, CheckResult, Status};
use anyhow::Result;
use async_trait::async_trait;

pub struct DockerCheck;

impl DockerCheck {
    pub fn new() -> Self {
        Self
    }
}

#[async_trait]
impl Check for DockerCheck {
    fn name(&self) -> &str {
        "Docker Summary"
    }

    fn emoji(&self) -> &str {
        "3️⃣"
    }

    async fn run(&self, _ctx: &CheckContext) -> Result<CheckResult> {
        let mut result = CheckResult::new(self.name(), self.emoji());

        // Placeholder data (would SSH into VMs and get docker ps output)
        result.add_item(CheckItem::ok("Running: 27 containers"));
        result.add_item(CheckItem::warn("Stopped: 5 containers", Some("Some containers stopped".to_string())));
        result.add_item(CheckItem::ok("Unhealthy: 0"));
        result.add_item(CheckItem::ok("Images stored across VMs"));

        let summary = format!(
            "**Total Summary Checks: {}** | ✅ OK: {} | ⚠️ WARN: {} | ❌ FAIL: {}",
            result.total_count(),
            result.ok_count(),
            result.warn_count(),
            result.fail_count()
        );

        Ok(result.with_summary(summary))
    }
}
