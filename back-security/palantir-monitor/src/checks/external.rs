use crate::checks::{check_http, check_port, Check, CheckContext};
use crate::types::{CheckItem, CheckResult, Status};
use anyhow::Result;
use async_trait::async_trait;
use trust_dns_resolver::proto::rr::RecordType;

pub struct ExternalCheck;

impl ExternalCheck {
    pub fn new() -> Self {
        Self
    }

    async fn check_vm_ssh(&self, ctx: &CheckContext) -> Vec<CheckItem> {
        let mut items = Vec::new();

        // Check SSH accessibility for all VMs
        for vm in &ctx.config.vms {
            let reachable = check_port(&vm.ip, 22, 5).await;
            let status = if reachable { Status::Ok } else { Status::Fail };
            items.push(CheckItem {
                description: format!("{} ({}) - Port 22", vm.id, vm.role),
                status,
                details: if !reachable {
                    Some(format!("SSH port 22 not accessible on {}", vm.ip))
                } else {
                    None
                },
            });
        }

        items
    }

    async fn check_web_services(&self, ctx: &CheckContext) -> Vec<CheckItem> {
        let mut items = Vec::new();

        let services = vec![
            ("analytics.diegonmarcos.com (Matomo)", "https://analytics.diegonmarcos.com", vec![200, 302]),
            ("proxy.diegonmarcos.com (NPM Admin)", "https://proxy.diegonmarcos.com", vec![200, 302, 525]),
            ("auth.diegonmarcos.com (Authelia 2FA)", "https://auth.diegonmarcos.com", vec![200, 302]),
            ("mail.diegonmarcos.com/webmail (Roundcube)", "https://mail.diegonmarcos.com/webmail", vec![200, 302]),
            ("cloud.diegonmarcos.com (Dashboard)", "https://cloud.diegonmarcos.com", vec![200, 302]),
            ("photos.app.diegonmarcos.com (VM sleeping)", "https://photos.app.diegonmarcos.com", vec![200, 302, 525]),
            ("sync.diegonmarcos.com (VM sleeping)", "https://sync.diegonmarcos.com", vec![200, 302, 525]),
        ];

        for (name, url, ok_codes) in services {
            match check_http(&ctx.http_client, url, &ok_codes).await {
                Ok((code, success)) => {
                    let status = if success {
                        if code == 525 {
                            Status::Warn
                        } else {
                            Status::Ok
                        }
                    } else {
                        Status::Fail
                    };

                    items.push(CheckItem {
                        description: name.to_string(),
                        status,
                        details: if code != 200 && code != 302 {
                            Some(format!("HTTP {}", code))
                        } else {
                            None
                        },
                    });
                }
                Err(_) => {
                    items.push(CheckItem::fail(name, Some("Request failed".to_string())));
                }
            }
        }

        items
    }

    async fn check_mail_ports(&self, ctx: &CheckContext) -> Vec<CheckItem> {
        let mut items = Vec::new();

        // Get mail server IP (oci-micro-1)
        let mail_ip = ctx
            .config
            .get_vm_ip("oci-micro-1")
            .unwrap_or("130.110.251.193");

        let ports = vec![
            (465, "Port 465 (SMTPS) - Encrypted submission"),
            (993, "Port 993 (IMAPS) - Encrypted IMAP"),
            (8080, "Port 8080 (SMTP Proxy) - HTTP relay"),
        ];

        for (port, description) in ports {
            let reachable = check_port(mail_ip, port, 5).await;
            items.push(CheckItem {
                description: description.to_string(),
                status: if reachable { Status::Ok } else { Status::Fail },
                details: None,
            });
        }

        items
    }

    async fn check_dns_records(&self, ctx: &CheckContext) -> Vec<CheckItem> {
        let mut items = Vec::new();

        let records = vec![
            ("mail.diegonmarcos.com", "mail.diegonmarcos.com", RecordType::A),
            ("diegonmarcos.com", "diegonmarcos.com", RecordType::MX),
            ("analytics.diegonmarcos.com", "analytics.diegonmarcos.com", RecordType::A),
            ("proxy.diegonmarcos.com", "proxy.diegonmarcos.com", RecordType::A),
            ("auth.diegonmarcos.com", "auth.diegonmarcos.com", RecordType::A),
            ("photos.app.diegonmarcos.com", "photos.app.diegonmarcos.com", RecordType::A),
        ];

        for (name, domain, record_type) in records {
            match ctx.dns_resolver.lookup(domain, record_type).await {
                Ok(lookup) => {
                    let has_records = lookup.iter().count() > 0;
                    items.push(CheckItem {
                        description: format!("{} → {:?} record", name, record_type),
                        status: if has_records { Status::Ok } else { Status::Fail },
                        details: None,
                    });
                }
                Err(_) => {
                    items.push(CheckItem::fail(
                        format!("{} → Missing", name),
                        None,
                    ));
                }
            }
        }

        items
    }
}

#[async_trait]
impl Check for ExternalCheck {
    fn name(&self) -> &str {
        "External Connectivity"
    }

    fn emoji(&self) -> &str {
        "1️⃣"
    }

    async fn run(&self, ctx: &CheckContext) -> Result<CheckResult> {
        let mut result = CheckResult::new(self.name(), self.emoji());

        // Run all sub-checks
        result.add_items(self.check_vm_ssh(ctx).await);
        result.add_items(self.check_web_services(ctx).await);
        result.add_items(self.check_mail_ports(ctx).await);
        result.add_items(self.check_dns_records(ctx).await);

        // Generate summary
        let summary = format!(
            "**Total External Checks: {}** | ✅ OK: {} | ⚠️ WARN: {} | ❌ FAIL: {}",
            result.total_count(),
            result.ok_count(),
            result.warn_count(),
            result.fail_count()
        );

        Ok(result.with_summary(summary))
    }
}
