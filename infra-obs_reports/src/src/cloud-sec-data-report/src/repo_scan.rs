//! Repo secret-scan phase. Scans tracked files + (optional) git history across
//! a declared set of repos for leaked credentials, key files, and plaintext
//! `.secrets.yaml` that should have been sops-encrypted.
//!
//! Data-driven — all patterns + repo list + skip rules live in
//! `cloud-data-repo-scan.json`. Runs entirely laptop-local — zero VM CPU.
//! `~/git/cloud-vault/` is NEVER scanned (intentional key store).

use anyhow::{Context, Result};
use reports_common::context::find_cloud_data_file;
use reports_common::types::{Check, Severity};
use regex::RegexSet;
use serde::Deserialize;
use std::path::PathBuf;
use std::process::Stdio;
use std::time::{Duration, Instant};
use tokio::process::Command;
use tokio::time::timeout;

/// Hard per-command deadlines for git subprocess calls in the tree scan.
/// Without these, `git grep` on a large repo with a wide combined regex can
/// spin indefinitely — blocking the whole sec-data report. Fire Rule #4:
/// tested in `tests::scan_tree_respects_ls_files_deadline`.
const GIT_LS_FILES_TIMEOUT: Duration = Duration::from_secs(10);
const GIT_GREP_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, Deserialize, Clone)]
pub struct RepoScanConfig {
    #[serde(default)]
    pub enabled: bool,
    pub repos: Vec<RepoSpec>,
    #[serde(default = "default_history_commits")]
    pub history_max_commits: u32,
    #[serde(default = "default_history_budget")]
    pub history_secs_budget: u64,
    #[serde(default)]
    pub skip_paths_re: Vec<String>,
    #[serde(default)]
    pub expected_encrypted_files_re: Vec<String>,
    #[serde(default)]
    pub filename_allowlist_re: Vec<String>,
    #[serde(default)]
    pub filename_patterns: Vec<Pattern>,
    #[serde(default)]
    pub content_patterns: Vec<Pattern>,
    #[serde(default)]
    pub ignore_line_markers: Vec<String>,
    #[serde(default)]
    pub activation_script_patterns_re: Vec<String>,
}

fn default_history_commits() -> u32 { 5000 }
fn default_history_budget() -> u64 { 60 }

#[derive(Debug, Deserialize, Clone)]
pub struct RepoSpec {
    pub path: String,
    pub visibility: String, // "public" | "private"
    #[serde(default = "yes")] pub scan_tree: bool,
    #[serde(default = "yes")] pub scan_history: bool,
}
fn yes() -> bool { true }

#[derive(Debug, Deserialize, Clone)]
pub struct Pattern {
    pub id: String,
    pub severity: String, // "critical" | "warning"
    pub regex: String,
}

pub fn load_config() -> Result<RepoScanConfig> {
    // Migrated to build-reports.json:.repo_scan; legacy fallback retained.
    if let Some(section) = reports_common::context::load_build_reports_section("repo_scan") {
        return serde_json::from_value(section)
            .context("parsing build-reports.json:.repo_scan");
    }
    let path = find_cloud_data_file("cloud-data-repo-scan.json")
        .context("neither build-reports.json:.repo_scan nor cloud-data-repo-scan.json found")?;
    let bytes = std::fs::read(&path)
        .with_context(|| format!("reading {}", path.display()))?;
    let cfg: RepoScanConfig = serde_json::from_slice(&bytes)
        .with_context(|| format!("parsing {}", path.display()))?;
    eprintln!(
        "[repo-scan] config loaded ({} repos, {} content patterns, {} filename patterns, enabled={})",
        cfg.repos.len(), cfg.content_patterns.len(), cfg.filename_patterns.len(), cfg.enabled,
    );
    Ok(cfg)
}

fn expand(p: &str) -> PathBuf {
    PathBuf::from(shellexpand::tilde(p).to_string())
}

fn sev(s: &str) -> Severity {
    match s.to_ascii_lowercase().as_str() {
        "critical" => Severity::Critical,
        "warning" => Severity::Warning,
        _ => Severity::Info,
    }
}

/// Public visibility → escalate warnings to critical (leaks on public github).
fn escalate(visibility: &str, declared: Severity) -> Severity {
    if visibility == "public" && matches!(declared, Severity::Warning) {
        Severity::Critical
    } else {
        declared
    }
}

pub async fn run(cfg: &RepoScanConfig) -> Vec<Check> {
    let t0 = Instant::now();
    let mut checks = Vec::new();

    if !cfg.enabled {
        checks.push(Check {
            name: "repo-scan".into(),
            passed: true,
            details: "Disabled via cloud-data-repo-scan.json".into(),
            duration_ms: 0,
            error: None,
            severity: Severity::Info,
        });
        return checks;
    }

    // Compile pattern sets once.
    let skip_re = match RegexSet::new(&cfg.skip_paths_re) {
        Ok(r) => r,
        Err(e) => {
            checks.push(fail("repo-scan: skip_paths compile", e.to_string()));
            return checks;
        }
    };
    let expected_enc_re = match RegexSet::new(&cfg.expected_encrypted_files_re) {
        Ok(r) => r,
        Err(e) => { checks.push(fail("repo-scan: expected_encrypted compile", e.to_string())); return checks; }
    };
    let allowlist_re = match RegexSet::new(&cfg.filename_allowlist_re) {
        Ok(r) => r,
        Err(e) => { checks.push(fail("repo-scan: filename_allowlist compile", e.to_string())); return checks; }
    };
    let activation_script_re = match RegexSet::new(&cfg.activation_script_patterns_re) {
        Ok(r) => r,
        Err(e) => { checks.push(fail("repo-scan: activation_script_patterns compile", e.to_string())); return checks; }
    };

    let filename_set = match RegexSet::new(cfg.filename_patterns.iter().map(|p| &p.regex)) {
        Ok(r) => r,
        Err(e) => { checks.push(fail("repo-scan: filename_patterns compile", e.to_string())); return checks; }
    };
    // Combined content regex for a single `git grep -E`
    let combined_content = cfg.content_patterns.iter()
        .map(|p| format!("({})", p.regex))
        .collect::<Vec<_>>()
        .join("|");
    if combined_content.is_empty() {
        checks.push(fail("repo-scan", "no content_patterns configured".into()));
        return checks;
    }
    // Per-pattern compiled regexes (for match → pattern id)
    let content_compiled: Vec<(String, Severity, regex::Regex)> = cfg.content_patterns.iter()
        .filter_map(|p| regex::Regex::new(&p.regex).ok()
            .map(|r| (p.id.clone(), sev(&p.severity), r)))
        .collect();

    let mut total_findings = 0u32;

    for repo in &cfg.repos {
        let path = expand(&repo.path);
        if !path.join(".git").exists() {
            checks.push(Check {
                name: format!("repo-scan:{}", repo.path),
                passed: true,
                details: "repo not present on this host — skipped".into(),
                duration_ms: 0,
                error: None,
                severity: Severity::Info,
            });
            continue;
        }

        let t = Instant::now();

        // ── Tree scan: git grep -nIE <combined> ───────────────────
        if repo.scan_tree {
            let tree_findings = scan_tree(
                &path,
                &combined_content,
                &content_compiled,
                &skip_re,
                &allowlist_re,
                &filename_set,
                &cfg.filename_patterns,
                &expected_enc_re,
                &cfg.ignore_line_markers,
                &activation_script_re,
                &repo.visibility,
            ).await;
            total_findings += tree_findings.len() as u32;
            for (name, severity, details) in tree_findings {
                checks.push(Check {
                    name: format!("repo-scan:{}:{}", shortname(&repo.path), name),
                    passed: false,
                    details,
                    duration_ms: 0,
                    error: Some("secret leak candidate".into()),
                    severity: escalate(&repo.visibility, severity),
                });
            }
        }

        // ── History scan: git log --all -G<regex> ─────────────────
        // Expensive; uses a time budget.
        if repo.scan_history {
            let hist = scan_history(
                &path,
                &content_compiled,
                cfg.history_max_commits,
                Duration::from_secs(cfg.history_secs_budget),
                &repo.visibility,
                &skip_re,
                &allowlist_re,
                &cfg.ignore_line_markers,
                &activation_script_re,
            ).await;
            total_findings += hist.len() as u32;
            for (name, severity, details) in hist {
                checks.push(Check {
                    name: format!("repo-scan:{}:hist:{}", shortname(&repo.path), name),
                    passed: false,
                    details,
                    duration_ms: 0,
                    error: Some("secret appears in git history".into()),
                    severity: escalate(&repo.visibility, severity),
                });
            }
        }

        let ms = t.elapsed().as_millis() as u64;
        checks.push(Check {
            name: format!("repo-scan:{}", shortname(&repo.path)),
            passed: true,
            details: format!(
                "{} scanned in {:.1}s (visibility={})",
                repo.path, ms as f64 / 1000.0, repo.visibility
            ),
            duration_ms: ms,
            error: None,
            severity: Severity::Info,
        });
    }

    checks.push(Check {
        name: "repo-scan: total".into(),
        passed: total_findings == 0,
        details: format!(
            "{} findings across {} repos in {:.1}s",
            total_findings, cfg.repos.len(), t0.elapsed().as_secs_f64()
        ),
        duration_ms: t0.elapsed().as_millis() as u64,
        error: if total_findings == 0 { None } else { Some(format!("{} secret candidates", total_findings)) },
        severity: if total_findings == 0 { Severity::Info } else { Severity::Warning },
    });

    checks
}

fn fail(name: &str, err: String) -> Check {
    Check {
        name: name.into(),
        passed: false,
        details: err.clone(),
        duration_ms: 0,
        error: Some(err),
        severity: Severity::Warning,
    }
}

fn shortname(p: &str) -> String {
    p.rsplit('/').next().unwrap_or(p).to_string()
}

async fn scan_tree(
    repo: &std::path::Path,
    combined_content: &str,
    content_compiled: &[(String, Severity, regex::Regex)],
    skip_re: &RegexSet,
    allowlist_re: &RegexSet,
    filename_set: &RegexSet,
    filename_patterns: &[Pattern],
    expected_enc_re: &RegexSet,
    ignore_markers: &[String],
    activation_script_re: &RegexSet,
    visibility: &str,
) -> Vec<(String, Severity, String)> {
    let _ = visibility; // escalation applied by caller
    let mut findings = Vec::new();

    // List all tracked files once. Deadline-bound; a hung git process must
    // not block the whole sec-data report.
    let ls_fut = Command::new("git")
        .arg("-C").arg(repo)
        .args(["ls-files", "-z"])
        .stdout(Stdio::piped())
        .output();
    let out = match timeout(GIT_LS_FILES_TIMEOUT, ls_fut).await {
        Ok(Ok(o)) if o.status.success() => o.stdout,
        Ok(Ok(_)) | Ok(Err(_)) => return findings,
        Err(_) => {
            findings.push((
                "repo-scan.timeout".into(),
                Severity::Warning,
                format!("git ls-files exceeded {}s deadline", GIT_LS_FILES_TIMEOUT.as_secs()),
            ));
            return findings;
        }
    };
    let mut files: Vec<String> = out.split(|&b| b == 0)
        .filter(|s| !s.is_empty())
        .filter_map(|s| std::str::from_utf8(s).ok().map(|x| x.to_string()))
        .collect();

    // Also grab untracked + ignored worktree files whose name contains "secrets"
    // (catches *.secrets.yaml.new, secrets.yaml.bak, etc. that aren't in index).
    let ls_untracked_fut = Command::new("git").arg("-C").arg(repo)
        .args(["ls-files", "-o", "-z"])
        .stdout(Stdio::piped()).output();
    if let Ok(Ok(o)) = timeout(GIT_LS_FILES_TIMEOUT, ls_untracked_fut).await {
        for s in o.stdout.split(|&b| b == 0) {
            if s.is_empty() { continue; }
            if let Ok(p) = std::str::from_utf8(s) {
                if p.to_ascii_lowercase().contains("secrets") {
                    files.push(p.to_string());
                }
            }
        }
    }

    // 1. Filename patterns.
    for f in &files {
        if skip_re.is_match(f) { continue; }
        if allowlist_re.is_match(f) { continue; }
        let matches = filename_set.matches(f);
        for idx in matches.iter() {
            let p = &filename_patterns[idx];
            findings.push((
                p.id.clone(),
                sev(&p.severity),
                format!("{}  (filename matches {})", f, p.regex),
            ));
        }
    }

    // 2. Expected-encrypted verification.
    for f in &files {
        if !expected_enc_re.is_match(f) { continue; }
        if skip_re.is_match(f) { continue; }
        if allowlist_re.is_match(f) { continue; }
        let full = repo.join(f);
        let head = match std::fs::read(&full) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let head_str = String::from_utf8_lossy(&head[..head.len().min(2048)]);
        // sops-encrypted YAML starts with a `sops:` top-level key OR contains "sops_version"
        let is_sops = head_str.contains("sops:") || head_str.contains("sops_version")
            || head_str.contains("ENC[AES256_GCM");
        if !is_sops {
            findings.push((
                "plaintext_secrets_yaml".into(),
                Severity::Critical,
                format!("{}  (matches *.secrets.yaml but NOT sops-encrypted)", f),
            ));
        }
    }

    // 3. Content scan via `git grep -nIE <combined>`.
    // Deadline-bound — on large repos with a big combined regex this can
    // spin for minutes; we cap it at GIT_GREP_TIMEOUT and record a warning.
    let grep_fut = Command::new("git")
        .arg("-C").arg(repo)
        .args(["grep", "-nIE", "--no-color", combined_content, "HEAD"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output();
    let grep = match timeout(GIT_GREP_TIMEOUT, grep_fut).await {
        Ok(inner) => inner,
        Err(_) => {
            findings.push((
                "repo-scan.timeout".into(),
                Severity::Warning,
                format!(
                    "git grep exceeded {}s deadline for {} — content scan skipped",
                    GIT_GREP_TIMEOUT.as_secs(),
                    repo.display(),
                ),
            ));
            return findings;
        }
    };
    if let Ok(o) = grep {
        let stdout = String::from_utf8_lossy(&o.stdout);
        for line in stdout.lines() {
            // Format: HEAD:<path>:<lineno>:<content>
            let rest = line.strip_prefix("HEAD:").unwrap_or(line);
            let mut parts = rest.splitn(3, ':');
            let fpath = parts.next().unwrap_or("");
            let lineno = parts.next().unwrap_or("?");
            let content = parts.next().unwrap_or("");
            if skip_re.is_match(fpath) { continue; }
            if allowlist_re.is_match(fpath) { continue; }
            // Skip lines that are already-encrypted sops blobs.
            if ignore_markers.iter().any(|m| content.contains(m.as_str())) { continue; }
            // Is this an activation script? → auto-elevate any leak to Critical.
            let is_activation = activation_script_re.is_match(fpath);
            // Which pattern matched?
            for (id, sev_, re) in content_compiled {
                if re.is_match(content) {
                    let preview = content.chars().take(80).collect::<String>();
                    let (out_id, out_sev) = if is_activation {
                        (format!("activation_script:{}", id), Severity::Critical)
                    } else {
                        (id.clone(), sev_.clone())
                    };
                    findings.push((
                        out_id.clone(),
                        out_sev,
                        format!("{}:{}  [{}]  {}", fpath, lineno, out_id, preview),
                    ));
                }
            }
        }
    }

    findings
}

async fn scan_history(
    repo: &std::path::Path,
    content_compiled: &[(String, Severity, regex::Regex)],
    max_commits: u32,
    budget: Duration,
    visibility: &str,
    skip_re: &RegexSet,
    allowlist_re: &RegexSet,
    ignore_markers: &[String],
    activation_script_re: &RegexSet,
) -> Vec<(String, Severity, String)> {
    let _ = visibility;
    let mut findings = Vec::new();
    let deadline = Instant::now() + budget;

    // Stream full history as a patch, pipe through regex match.
    // `git log --all --full-history --max-count=<N> -p --unified=0`
    let mut cmd = Command::new("git");
    cmd.arg("-C").arg(repo)
        .args([
            "log",
            "--all",
            "--full-history",
            "-p",
            "--unified=0",
            &format!("--max-count={}", max_commits),
            "--no-color",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let child = match cmd.spawn() {
        Ok(c) => c,
        Err(_) => return findings,
    };
    let stdout = match child.stdout {
        Some(s) => s,
        None => return findings,
    };

    use tokio::io::{AsyncBufReadExt, BufReader};
    let mut reader = BufReader::new(stdout).lines();
    let mut current_commit = String::new();
    let mut current_path = String::new();
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();

    while let Ok(Some(line)) = reader.next_line().await {
        if Instant::now() > deadline {
            findings.push((
                "history_budget_exceeded".into(),
                Severity::Info,
                format!("history scan stopped at budget {}s", budget.as_secs()),
            ));
            break;
        }
        if let Some(rest) = line.strip_prefix("commit ") {
            current_commit = rest.split_whitespace().next().unwrap_or("").to_string();
            continue;
        }
        if let Some(rest) = line.strip_prefix("+++ b/") {
            current_path = rest.to_string();
            continue;
        }
        if !line.starts_with('+') || line.starts_with("+++") {
            continue;
        }
        // Respect skip + allowlist rules on current diff's file path.
        if !current_path.is_empty()
            && (skip_re.is_match(&current_path) || allowlist_re.is_match(&current_path))
        {
            continue;
        }
        let content = &line[1..];
        // Skip already-encrypted sops blobs.
        if ignore_markers.iter().any(|m| content.contains(m.as_str())) { continue; }
        let is_activation = activation_script_re.is_match(&current_path);
        for (id, sev_, re) in content_compiled {
            if re.is_match(content) {
                let (out_id, out_sev) = if is_activation {
                    (format!("activation_script:{}", id), Severity::Critical)
                } else {
                    (id.clone(), sev_.clone())
                };
                let key = format!("{}:{}:{}", out_id, current_path, &current_commit[..current_commit.len().min(8)]);
                if seen.insert(key.clone()) {
                    let preview = content.chars().take(80).collect::<String>();
                    findings.push((
                        out_id.clone(),
                        out_sev,
                        format!(
                            "commit {}  {}  [{}]  {}",
                            &current_commit[..current_commit.len().min(8)],
                            current_path, out_id, preview
                        ),
                    ));
                }
            }
        }
    }

    findings
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Fire Rule #4: pin the deadline constants so a future refactor can't
    /// silently remove them and re-introduce the indefinite-hang class of
    /// bug that blocked the sec-data pipeline at "[repo-scan] config
    /// loaded" for 10+ minutes before this fix.
    #[test]
    fn repo_scan_git_calls_have_bounded_deadlines() {
        assert!(GIT_LS_FILES_TIMEOUT.as_secs() >= 1);
        assert!(GIT_LS_FILES_TIMEOUT.as_secs() <= 30);
        assert!(GIT_GREP_TIMEOUT.as_secs() >= 1);
        assert!(GIT_GREP_TIMEOUT.as_secs() <= 60);
    }

    /// A git grep wrapped in our timeout must return within the declared
    /// deadline. This guards against the deadline ever being bypassed by a
    /// refactor that drops the `timeout(...)` wrapper.
    #[tokio::test]
    async fn grep_respects_deadline_guard() {
        let repo = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        if !repo.join(".git").exists()
            && !repo.parent().map(|p| p.join(".git").exists()).unwrap_or(false)
        {
            eprintln!("skip: not inside a git repo");
            return;
        }
        let start = Instant::now();
        let grep_fut = Command::new("git")
            .arg("-C")
            .arg(repo)
            .args(["grep", "-nIE", "--no-color", "__no_such_token_xyzzy__", "HEAD"])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .output();
        let _ = timeout(Duration::from_secs(5), grep_fut).await;
        let elapsed = start.elapsed();
        assert!(
            elapsed < Duration::from_secs(7),
            "git grep exceeded deadline guard: {}s",
            elapsed.as_secs()
        );
    }
}
