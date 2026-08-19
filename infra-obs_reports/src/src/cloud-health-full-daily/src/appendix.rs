//! Z-Appendix builder — structured consolidation.
//!
//! Parses the markdown output of the absorbed `health_full2` and `mail_full`
//! sub-engines into its natural sections (11-layer numbered sections,
//! stack sub-sections A0…A4/B2/B3/C/D, mail phases 0…6) and re-renders them
//! as flat Z.N subsections (Z.1, Z.2, … Z.M) in Daily's consolidated output.
//!
//! NO CONTENT IS DROPPED. Every section body is preserved verbatim — only
//! the wrapping headers are rewritten. The Z-numbering is the consolidated
//! reader-facing index.
//!
//! Section detection patterns (line-start anchored):
//!   `^\d+\.\s+[A-Z]`         → numbered section (11-layer headings, mail phases)
//!   `^──\s+[A-Z]\d*\)\s+`    → stack sub-section (── A0) Mesh ──)
//!   `^\s{2}[A-Z]\)\s+`       → stack mega-section (  A) HEALTH, B) INFRA, …)
//!   `^Tier\s+\d+`            → mail tier header
//!
//! Two entry points:
//!   - `from_reports(...)` — preferred, in-process submodule results.
//!   - `load()` — fallback: read artefacts from cwd.

use crate::health_full2::FullReport;
use crate::mail_full::MailReport;
use serde_json::Value;
use std::path::Path;

/// One Z-section in the consolidated appendix. Fine-grained — one per
/// native section in the source reports (not one per source report).
#[derive(Debug, Clone)]
pub struct ZSection {
    /// e.g. "Z.1", "Z.12".
    pub number: String,
    /// Source identifier (e.g. "health_full2/11-layer", "mail_full/phase").
    pub source: String,
    /// Original section title — preserved from the source markdown.
    pub title: String,
    /// Body — the full section content, verbatim.
    pub markdown: String,
}

pub struct Appendix {
    /// Ordered, flat list of Z-sections. Z.N index = position + 1.
    pub sections: Vec<ZSection>,
    /// Preserved raw JSON results so downstream code can still introspect.
    pub stack: Option<Value>,
    pub full: Option<Value>,
    pub mail: Option<Value>,
}

impl Appendix {
    pub fn is_empty(&self) -> bool {
        self.sections
            .iter()
            .all(|s| s.markdown.trim().is_empty() && s.title.trim().is_empty())
    }

    pub fn summary(&self) -> String {
        let total_lines: usize = self
            .sections
            .iter()
            .map(|s| s.markdown.lines().count())
            .sum();
        let total_bytes: usize = self.sections.iter().map(|s| s.markdown.len()).sum();
        format!(
            "sections={} ({} lines, {} bytes) stack={} full={} mail={}",
            self.sections.len(),
            total_lines,
            total_bytes,
            if self.stack.is_some() { "yes" } else { "no" },
            if self.full.is_some() { "yes" } else { "no" },
            if self.mail.is_some() { "yes" } else { "no" },
        )
    }

    /// Flatten all sections into one big markdown blob.
    pub fn to_markdown(&self) -> String {
        let mut out = String::with_capacity(256 * 1024);
        for s in &self.sections {
            out.push_str(&format!("\n## {} — {}\n\n", s.number, s.title));
            out.push_str(&format!("_Source: `{}`_\n\n", s.source));
            out.push_str(&s.markdown);
            if !s.markdown.ends_with('\n') {
                out.push('\n');
            }
            out.push_str("\n---\n");
        }
        out
    }

    /// Legacy single-string form for templates that still use `$APPENDIX`.
    pub fn legacy_md(&self) -> String {
        self.to_markdown()
    }
}

// ─────────────────────────────────────────────────────────────────────
// Section parser
// ─────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HeaderKind {
    Numbered,
    StackSub,
    StackMega,
    MailTier,
}

/// Detect if a line starts a section, returning (kind, normalized_title).
fn detect_header(line: &str) -> Option<(HeaderKind, String)> {
    let stripped = line.trim_end_matches(|c: char| c == '\n' || c == '\r');

    // Numbered: "N. UPPERCASE_TITLE" — digits, dot, space, uppercase letter.
    let leading_digits: String = stripped.chars().take_while(|c| c.is_ascii_digit()).collect();
    if !leading_digits.is_empty() {
        let rest = &stripped[leading_digits.len()..];
        if let Some(after_dot) = rest.strip_prefix(". ") {
            if after_dot
                .chars()
                .next()
                .map(|c| c.is_ascii_uppercase())
                .unwrap_or(false)
            {
                return Some((HeaderKind::Numbered, stripped.trim().to_string()));
            }
        }
    }

    // Stack sub-section: "── A0) Title ──" (Unicode em-dash prefix).
    if let Some(rest) = stripped.strip_prefix("── ") {
        if let Some(paren) = rest.find(") ") {
            let label = &rest[..paren];
            if !label.is_empty()
                && label.chars().next().map(|c| c.is_ascii_uppercase()).unwrap_or(false)
                && label.chars().all(|c| c.is_ascii_alphanumeric())
            {
                let body = rest[paren + 2..]
                    .trim_end_matches(|c: char| c == '─' || c.is_whitespace());
                return Some((HeaderKind::StackSub, format!("{}) {}", label, body)));
            }
        }
    }

    // Stack mega-section: "  A) HEALTH…" — 2 spaces, single uppercase letter, ") ".
    if stripped.starts_with("  ") && !stripped.starts_with("   ") {
        let after = &stripped[2..];
        let mut ch = after.chars();
        let c1 = ch.next();
        let c2 = ch.next();
        let c3 = ch.next();
        if let (Some(a), Some(')'), Some(' ')) = (c1, c2, c3) {
            if a.is_ascii_uppercase() {
                return Some((HeaderKind::StackMega, after.trim().to_string()));
            }
        }
    }

    // Mail tier: "Tier 0: Path Checker".
    if let Some(rest) = stripped.strip_prefix("Tier ") {
        if rest.chars().next().map(|c| c.is_ascii_digit()).unwrap_or(false) {
            return Some((HeaderKind::MailTier, stripped.trim().to_string()));
        }
    }

    None
}

/// Split a markdown blob into (title, body) sections. Body of each section
/// includes all lines up to (but not including) the next header.
fn split_markdown_into_sections(md: &str) -> Vec<(String, String)> {
    let mut sections: Vec<(String, String)> = Vec::new();
    let mut current_title: Option<String> = None;
    let mut current_body = String::new();
    let mut preamble = String::new();

    for line in md.lines() {
        if let Some((_, title)) = detect_header(line) {
            if let Some(t) = current_title.take() {
                sections.push((t, std::mem::take(&mut current_body)));
            } else if !preamble.trim().is_empty() {
                sections.push(("(preamble)".to_string(), std::mem::take(&mut preamble)));
            }
            current_title = Some(title);
        } else if current_title.is_some() {
            current_body.push_str(line);
            current_body.push('\n');
        } else {
            preamble.push_str(line);
            preamble.push('\n');
        }
    }
    if let Some(t) = current_title.take() {
        sections.push((t, current_body));
    } else if !preamble.trim().is_empty() {
        sections.push(("(content)".to_string(), preamble));
    }
    sections
}

// ─────────────────────────────────────────────────────────────────────
// Builders
// ─────────────────────────────────────────────────────────────────────

fn classify_full_source(title: &str) -> String {
    if title
        .chars()
        .next()
        .map(|c| c.is_ascii_digit())
        .unwrap_or(false)
    {
        return "health_full2/11-layer".to_string();
    }
    if let Some(first) = title.chars().next() {
        if ('A'..='Z').contains(&first) && title.contains(')') {
            let head: String = title.chars().take_while(|c| *c != ')').collect();
            return format!("health_full2/stack/{}", head);
        }
    }
    "health_full2".to_string()
}

fn classify_mail_source(title: &str) -> String {
    if title.starts_with("Tier ") {
        "mail_full/tier".to_string()
    } else if title
        .chars()
        .next()
        .map(|c| c.is_ascii_digit())
        .unwrap_or(false)
    {
        "mail_full/phase".to_string()
    } else {
        "mail_full".to_string()
    }
}

fn build_zsections(full_md: &str, mail_md: &str) -> Vec<ZSection> {
    let mut out: Vec<ZSection> = Vec::new();
    let mut n: usize = 1;

    for (title, body) in split_markdown_into_sections(full_md) {
        if title == "(preamble)" && body.trim().is_empty() {
            continue;
        }
        let source = classify_full_source(&title);
        out.push(ZSection {
            number: format!("Z.{}", n),
            source,
            title,
            markdown: body,
        });
        n += 1;
    }
    for (title, body) in split_markdown_into_sections(mail_md) {
        if title == "(preamble)" && body.trim().is_empty() {
            continue;
        }
        let source = classify_mail_source(&title);
        out.push(ZSection {
            number: format!("Z.{}", n),
            source,
            title,
            markdown: body,
        });
        n += 1;
    }

    out
}

/// Preferred: build from in-process submodule results.
pub fn from_reports(full: Option<&FullReport>, mail: Option<&MailReport>) -> Appendix {
    let full_md = full.map(|f| f.markdown.as_str()).unwrap_or("");
    let mail_md = mail.map(|m| m.markdown.as_str()).unwrap_or("");
    let sections = build_zsections(full_md, mail_md);

    Appendix {
        sections,
        stack: full.and_then(|f| f.stack.clone()),
        full: full.and_then(|f| serde_json::to_value(&f.results).ok()),
        mail: mail.and_then(|m| serde_json::to_value(&m.results).ok()),
    }
}

impl Appendix {
    /// Render-only entry: build from on-disk markdown produced by Phase 1
    /// (full md, when present) and Phase 2 derives (mail md). The Z-sections
    /// are re-numbered fresh; the structured `stack` / `full` / `mail`
    /// values aren't reconstituted from markdown so they stay None.
    pub fn from_markdown(full_md: &str, mail_md: &str) -> Self {
        Appendix {
            sections: build_zsections(full_md, mail_md),
            stack: None,
            full: None,
            mail: None,
        }
    }
}

/// Fallback: read from cwd.
pub fn load() -> Appendix {
    let full_md = read_text("cloud_health_full.md");
    let mail_md = read_text("cloud_mail_full.md");
    let sections = build_zsections(&full_md, &mail_md);

    Appendix {
        sections,
        stack: read_json("cloud_stack.json"),
        full: read_json("cloud_health_full.json"),
        mail: read_json("cloud_mail_full.json"),
    }
}

fn read_text<P: AsRef<Path>>(path: P) -> String {
    std::fs::read_to_string(path.as_ref()).unwrap_or_default()
}

fn read_json<P: AsRef<Path>>(path: P) -> Option<Value> {
    let raw = std::fs::read_to_string(path.as_ref()).ok()?;
    serde_json::from_str(&raw).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detect_numbered_header() {
        let h = detect_header("1. SELF-CHECK").unwrap();
        assert_eq!(h.0, HeaderKind::Numbered);
        assert_eq!(h.1, "1. SELF-CHECK");
    }

    #[test]
    fn detect_stack_sub_header() {
        let h = detect_header("── A0) Mesh ──────────────────────────────────────").unwrap();
        assert_eq!(h.0, HeaderKind::StackSub);
        assert_eq!(h.1, "A0) Mesh");
    }

    #[test]
    fn detect_stack_mega_header() {
        let h = detect_header("  A) HEALTH — Live checks").unwrap();
        assert_eq!(h.0, HeaderKind::StackMega);
        assert_eq!(h.1, "A) HEALTH — Live checks");
    }

    #[test]
    fn detect_mail_tier_header() {
        let h = detect_header("Tier 0: Path Checker").unwrap();
        assert_eq!(h.0, HeaderKind::MailTier);
        assert_eq!(h.1, "Tier 0: Path Checker");
    }

    #[test]
    fn non_header_lines_ignored() {
        assert!(detect_header("    ✅ OK some trailing text").is_none());
        assert!(detect_header("Some random prose").is_none());
        assert!(detect_header("══════════════════════").is_none());
        assert!(detect_header("").is_none());
    }

    #[test]
    fn splits_mixed_markdown() {
        let md = "preamble\n\n1. SELF-CHECK\nself body\n\n── A0) Mesh ──\na0 body\n\n  B) INFRA — Resources\nb body\n\nTier 0: Path Checker\ntier0 body\n";
        let sections = split_markdown_into_sections(md);
        let titles: Vec<_> = sections.iter().map(|(t, _)| t.as_str()).collect();
        assert!(titles.contains(&"(preamble)"));
        assert!(titles.contains(&"1. SELF-CHECK"));
        assert!(titles.contains(&"A0) Mesh"));
        assert!(titles.contains(&"B) INFRA — Resources"));
        assert!(titles.contains(&"Tier 0: Path Checker"));
    }

    #[test]
    fn consolidation_numbers_sequentially() {
        let full = "1. SELF-CHECK\nbody A\n2. WG MESH\nbody B\n";
        let mail = "0. INSTANT KPIs\nbody C\n1. PRE-FLIGHT\nbody D\n";
        let sections = build_zsections(full, mail);
        let numbers: Vec<_> = sections.iter().map(|s| s.number.as_str()).collect();
        assert_eq!(numbers, vec!["Z.1", "Z.2", "Z.3", "Z.4"]);
        assert_eq!(sections[0].title, "1. SELF-CHECK");
        assert_eq!(sections[3].title, "1. PRE-FLIGHT");
    }

    #[test]
    fn empty_inputs_produce_empty_appendix() {
        let a = Appendix {
            sections: build_zsections("", ""),
            stack: None,
            full: None,
            mail: None,
        };
        assert!(a.is_empty());
        assert_eq!(a.to_markdown(), "");
    }

    #[test]
    fn load_from_missing_cwd_files_yields_empty() {
        let tmp = std::env::temp_dir().join(format!("apx-test-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).unwrap();
        let prev = std::env::current_dir().unwrap();
        std::env::set_current_dir(&tmp).unwrap();
        let a = load();
        std::env::set_current_dir(prev).unwrap();
        let _ = std::fs::remove_dir_all(&tmp);
        assert!(a.is_empty(), "expected empty, got: {}", a.summary());
    }
}
