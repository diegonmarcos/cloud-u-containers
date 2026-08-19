use crate::checks;
use crate::types::Status;

/// Runtime capabilities detected at startup.
///
/// When `wg_up=false` the VM is running in "GHA mode" (no WireGuard mesh access).
/// All SSH-dependent and Hickory-dependent checks MUST return `UNKNOWN` (not
/// `CRITICAL`) to avoid false-RED reports — the infra may be perfectly healthy but
/// unreachable from the prober. Use `self.gate(requires_wg)` before any probe.
pub struct RuntimeCapabilities {
    pub wg_up: bool,
    pub ssh_available: bool,
    pub bearer_token: Option<String>,
    pub hickory_up: bool,
    pub yara_available: bool,
}

impl RuntimeCapabilities {
    /// Returns true iff this check can produce a meaningful result.
    /// When false, the caller MUST skip the check and emit status="UNKNOWN (WG down)"
    /// instead of running a probe that will time-out and report CRITICAL.
    pub fn gate(&self, requires_wg: bool) -> bool {
        if requires_wg { self.wg_up } else { true }
    }

    /// R7: classify a would-be check result under the capability gate.
    /// `requires_wg` marks a check that can only be judged over the mesh (SSH,
    /// Hickory DNS). When the mesh is down, the honest verdict is UNKNOWN — the
    /// target may be perfectly healthy but unreachable from this runner. Only
    /// when the check CAN run do we let the observed `passed` decide GREEN/RED.
    /// This is the single chokepoint that prevents the false-RED cascade.
    pub fn classify(&self, requires_wg: bool, passed: bool) -> Status {
        if !self.gate(requires_wg) {
            Status::Unknown
        } else if passed {
            Status::Green
        } else {
            Status::Red
        }
    }

    /// True iff any WG-requiring check must be gated to UNKNOWN this run.
    /// Wire this into `render_report_status(.., wg_gated_unknown)`.
    pub fn wg_gated(&self) -> bool {
        !self.wg_up
    }

    /// Test/constructor helper — build an explicit capability set without
    /// touching the network. Used by callers that already know the environment
    /// (e.g. entrypoint exported WG_UP) and by unit tests.
    pub fn with(wg_up: bool, ssh_available: bool, hickory_up: bool) -> Self {
        RuntimeCapabilities {
            wg_up,
            ssh_available,
            bearer_token: None,
            hickory_up,
            yara_available: false,
        }
    }

    /// Detect what capabilities are available in the current environment.
    pub async fn detect() -> Self {
        // Check WG mesh: data-driven hickory IP from consolidated JSON.
        let hickory_ip = crate::context::load_consolidated()
            .ok()
            .and_then(|j| j["vms"]["gcp-E2-f_0"]["wg_ip"].as_str().map(|s| s.to_string()))
            .unwrap_or_else(|| "10.0.0.1".to_string());
        let wg_up = checks::tcp(&hickory_ip, 53).await;

        // Check if SSH keys are loaded
        let ssh_available = std::path::Path::new("/root/.ssh").exists()
            || std::env::var("HOME")
                .ok()
                .map(|h| std::path::Path::new(&format!("{}/.ssh", h)).exists())
                .unwrap_or(false);

        // Load bearer token
        let bearer_token = crate::context::load_bearer_token();

        // Check Hickory DNS — only meaningful when WG is up.
        // If WG is down, do NOT try to resolve via hickory — it'll time-out and
        // cascade into false "DNS down" findings across the entire report.
        let hickory_up = if wg_up {
            let resolver = checks::hickory_resolver();
            checks::dns_resolve(&resolver, "caddy.app").await.is_some()
        } else {
            false
        };

        // Check if yara binary is available
        let yara_available = std::process::Command::new("yara")
            .arg("--version")
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);

        let caps = RuntimeCapabilities {
            wg_up,
            ssh_available,
            bearer_token,
            hickory_up,
            yara_available,
        };

        // R7: distinguish GHA mode (WG down = UNKNOWN, not CRITICAL) clearly.
        if !caps.wg_up {
            println!("Runtime capabilities:");
            println!("  WG mesh:    DOWN — running in GHA/external mode");
            println!("  NOTE: all SSH/Hickory-dependent checks will return UNKNOWN,");
            println!("        not CRITICAL. Use caps.gate(requires_wg) before each probe.");
        } else {
            println!("Runtime capabilities:");
            println!("  WG mesh:    UP (hickory={})", if caps.hickory_up { "OK" } else { "DOWN" });
        }
        println!("  SSH keys:   {}", if caps.ssh_available { "OK" } else { "MISSING" });
        println!("  Bearer:     {}", if caps.bearer_token.is_some() { "OK" } else { "MISSING — set BEARER_TOKEN or mount vault" });
        println!("  YARA:       {}", if caps.yara_available { "OK" } else { "NOT INSTALLED" });

        caps
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn r7_wg_down_gates_ssh_check_to_unknown_not_red() {
        // Mesh down. A WG-requiring check that "fails" (would-be RED because the
        // probe times out) must classify UNKNOWN, never RED — the target might
        // be perfectly healthy but unreachable from this runner.
        let caps = RuntimeCapabilities::with(false, true, false);
        assert!(caps.wg_gated(), "WG down must set the report-level gate");
        assert_eq!(caps.classify(true, false), Status::Unknown);
        // Even a "passed" WG check is UNKNOWN when the mesh is down — a probe
        // can't have genuinely passed without the mesh.
        assert_eq!(caps.classify(true, true), Status::Unknown);
        // Non-WG checks (public URLs) are unaffected by mesh state.
        assert_eq!(caps.classify(false, true), Status::Green);
        assert_eq!(caps.classify(false, false), Status::Red);
    }

    #[test]
    fn r7_wg_up_lets_observed_result_decide() {
        // Mesh up: WG checks are judged normally on their observed pass/fail.
        let caps = RuntimeCapabilities::with(true, true, true);
        assert!(!caps.wg_gated());
        assert_eq!(caps.classify(true, true), Status::Green);
        assert_eq!(caps.classify(true, false), Status::Red);
    }
}
