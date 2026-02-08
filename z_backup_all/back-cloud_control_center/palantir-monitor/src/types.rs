use serde::{Deserialize, Serialize};
use std::fmt;

/// Check status enumeration
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Status {
    Ok,
    Warn,
    Fail,
}

impl Status {
    pub fn emoji(&self) -> &'static str {
        match self {
            Status::Ok => "✅",
            Status::Warn => "⚠️",
            Status::Fail => "❌",
        }
    }
}

impl fmt::Display for Status {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.emoji())
    }
}

/// Individual check item result
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckItem {
    pub description: String,
    pub status: Status,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<String>,
}

impl CheckItem {
    pub fn ok(description: impl Into<String>) -> Self {
        Self {
            description: description.into(),
            status: Status::Ok,
            details: None,
        }
    }

    pub fn warn(description: impl Into<String>, details: Option<String>) -> Self {
        Self {
            description: description.into(),
            status: Status::Warn,
            details,
        }
    }

    pub fn fail(description: impl Into<String>, details: Option<String>) -> Self {
        Self {
            description: description.into(),
            status: Status::Fail,
            details,
        }
    }

    pub fn with_details(mut self, details: impl Into<String>) -> Self {
        self.details = Some(details.into());
        self
    }
}

/// Result from running a check
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckResult {
    pub name: String,
    pub emoji: String,
    pub passed: Vec<CheckItem>,
    pub failed: Vec<CheckItem>,
    pub warnings: Vec<CheckItem>,
    pub summary: String,
}

impl CheckResult {
    pub fn new(name: impl Into<String>, emoji: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            emoji: emoji.into(),
            passed: Vec::new(),
            failed: Vec::new(),
            warnings: Vec::new(),
            summary: String::new(),
        }
    }

    pub fn add_item(&mut self, item: CheckItem) {
        match item.status {
            Status::Ok => self.passed.push(item),
            Status::Warn => self.warnings.push(item),
            Status::Fail => self.failed.push(item),
        }
    }

    pub fn add_items(&mut self, items: Vec<CheckItem>) {
        for item in items {
            self.add_item(item);
        }
    }

    pub fn total_count(&self) -> usize {
        self.passed.len() + self.warnings.len() + self.failed.len()
    }

    pub fn ok_count(&self) -> usize {
        self.passed.len()
    }

    pub fn warn_count(&self) -> usize {
        self.warnings.len()
    }

    pub fn fail_count(&self) -> usize {
        self.failed.len()
    }

    pub fn with_summary(mut self, summary: impl Into<String>) -> Self {
        self.summary = summary.into();
        self
    }
}

/// VM information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VmInfo {
    pub id: String,
    pub provider: String,
    pub ip: String,
    pub ram: String,
    pub role: String,
    pub services: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mode: Option<String>,
}

impl VmInfo {
    pub fn new(
        id: impl Into<String>,
        provider: impl Into<String>,
        ip: impl Into<String>,
        ram: impl Into<String>,
        role: impl Into<String>,
        services: Vec<String>,
    ) -> Self {
        Self {
            id: id.into(),
            provider: provider.into(),
            ip: ip.into(),
            ram: ram.into(),
            role: role.into(),
            services,
            mode: None,
        }
    }

    pub fn with_mode(mut self, mode: impl Into<String>) -> Self {
        self.mode = Some(mode.into());
        self
    }
}

/// Docker network information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetworkInfo {
    pub name: String,
    pub subnet: String,
    pub vm: String,
}

/// Domain information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DomainInfo {
    pub domain: String,
    pub purpose: String,
}

/// Overall report summary
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Summary {
    pub ok_count: usize,
    pub fail_count: usize,
    pub warn_count: usize,
    pub total_checks: usize,
    pub health_score: usize,
    pub status: String,
}

impl Summary {
    pub fn from_results(results: &[CheckResult]) -> Self {
        let ok_count: usize = results.iter().map(|r| r.ok_count()).sum();
        let warn_count: usize = results.iter().map(|r| r.warn_count()).sum();
        let fail_count: usize = results.iter().map(|r| r.fail_count()).sum();
        let total_checks = ok_count + warn_count + fail_count;

        let health_score = if total_checks > 0 {
            (ok_count * 100) / total_checks
        } else {
            100
        };

        let status = if fail_count > 0 {
            "ALERT".to_string()
        } else if warn_count > 0 {
            "WARN".to_string()
        } else {
            "OK".to_string()
        };

        Self {
            ok_count,
            fail_count,
            warn_count,
            total_checks,
            health_score,
            status,
        }
    }

    pub fn subject_line(&self, date: &str) -> String {
        // NO EMOJI in subject line
        if self.fail_count > 0 {
            format!("[ALERT] Cloud Health - {} failures - {}", self.fail_count, date)
        } else if self.warn_count > 0 {
            format!("[WARN] Cloud Health - {} warnings - {}", self.warn_count, date)
        } else {
            format!("[OK] Cloud Health Report - {}", date)
        }
    }
}

/// Metadata for report
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Metadata {
    pub generated: String,
    pub host: String,
    pub report_id: String,
    pub timestamp: String,
    pub version: String,
}

impl Metadata {
    pub fn new() -> Self {
        use chrono::Utc;
        let now = Utc::now();

        Self {
            generated: now.to_rfc3339(),
            host: hostname::get()
                .ok()
                .and_then(|h| h.into_string().ok())
                .unwrap_or_else(|| "unknown".to_string()),
            report_id: now.timestamp().to_string(),
            timestamp: now.format("%Y%m%d-%H%M%S").to_string(),
            version: "2.0".to_string(),
        }
    }
}

impl Default for Metadata {
    fn default() -> Self {
        Self::new()
    }
}
