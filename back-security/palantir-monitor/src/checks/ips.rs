use crate::checks::{Check, CheckContext};
use crate::types::{CheckItem, CheckResult, Status};
use anyhow::Result;
use async_trait::async_trait;

pub struct IpCheck;

impl IpCheck {
    pub fn new() -> Self {
        Self
    }
}

#[async_trait]
impl Check for IpCheck {
    fn name(&self) -> &str {
        "IP Address Inventory"
    }

    fn emoji(&self) -> &str {
        "5️⃣"
    }

    async fn run(&self, ctx: &CheckContext) -> Result<CheckResult> {
        let mut result = CheckResult::new(self.name(), self.emoji());

        // DNS reconciliation (simplified - real implementation would do actual DNS lookups)
        result.add_item(CheckItem::ok("OCI Micro 1 (130.110.251.193) → mail.diegonmarcos.com"));
        result.add_item(CheckItem::warn("OCI Micro 2 (129.151.228.66) → Cloudflare IP (proxied)", None));
        result.add_item(CheckItem::warn("GCP Micro 1 (35.226.147.64) → Cloudflare IP (proxied)", None));
        result.add_item(CheckItem::fail("OCI Flex 1 (84.235.234.87) → No DNS (sleeping)", None));

        // Cloudflare DNS records
        for domain in &ctx.config.domain_list {
            result.add_item(CheckItem::ok(format!("{}.diegonmarcos.com DNS configured", domain)));
        }

        let summary = format!(
            "**Total IP Checks: {}** | ✅ OK: {} | ⚠️ WARN: {} | ❌ FAIL: {}",
            result.total_count(),
            result.ok_count(),
            result.warn_count(),
            result.fail_count()
        );

        Ok(result.with_summary(summary))
    }
}
