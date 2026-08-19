use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// Resolve a template path. If it's absolute, use as-is. Otherwise, prefer
/// `$TEMPLATE_DIR/<path>` (set by the crate engine to the crate source dir),
/// falling back to cwd-relative for standalone invocations.
fn resolve_template_path(template_path: &str) -> PathBuf {
    let p = Path::new(template_path);
    if p.is_absolute() {
        return p.to_path_buf();
    }
    if let Ok(dir) = std::env::var("TEMPLATE_DIR") {
        let joined = Path::new(&dir).join(p);
        if joined.exists() {
            return joined;
        }
    }
    p.to_path_buf()
}

/// Read template, replace $VARS (longest key first), write output
pub fn render(
    template_path: &str,
    output_path: &str,
    vars: &HashMap<String, String>,
) -> anyhow::Result<()> {
    let resolved = resolve_template_path(template_path);
    let mut template = std::fs::read_to_string(&resolved)?;
    println!(
        "Template loaded ({} chars, {} vars) from {}",
        template.len(),
        vars.len(),
        resolved.display()
    );

    // Sort keys longest first to prevent partial matches
    let mut sorted_keys: Vec<&String> = vars.keys().collect();
    sorted_keys.sort_by(|a, b| b.len().cmp(&a.len()));

    for key in sorted_keys {
        let placeholder = format!("${}", key);
        if template.contains(&placeholder) {
            template = template.replace(&placeholder, &vars[key]);
        } else {
            eprintln!("  WARN: ${} not found in template", key);
        }
    }

    // Check for unreplaced vars
    let unreplaced: Vec<&str> = template
        .match_indices('$')
        .filter_map(|(i, _)| {
            let rest = &template[i..];
            if rest.starts_with("${") {
                return None;
            }
            let end = rest
                .find(|c: char| !c.is_ascii_uppercase() && c != '_')
                .unwrap_or(rest.len());
            if end > 1 {
                Some(&rest[..end])
            } else {
                None
            }
        })
        .collect();
    if !unreplaced.is_empty() {
        eprintln!("  WARN: unreplaced vars: {:?}", unreplaced);
    }

    std::fs::write(output_path, template)?;
    println!("Wrote {}", output_path);
    Ok(())
}
