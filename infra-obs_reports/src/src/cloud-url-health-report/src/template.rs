use std::collections::HashMap;
use std::path::{Path, PathBuf};

const TEMPLATE_FILE: &str = "cloud_url_health.md.tpl";

fn resolve_template_path() -> PathBuf {
    if let Ok(dir) = std::env::var("TEMPLATE_DIR") {
        let p = Path::new(&dir).join(TEMPLATE_FILE);
        if p.exists() {
            return p;
        }
    }
    PathBuf::from(TEMPLATE_FILE)
}

pub fn render_string(vars: &HashMap<String, String>) -> anyhow::Result<String> {
    let tpl = resolve_template_path();
    let mut template = std::fs::read_to_string(&tpl)?;
    eprintln!(
        "[url-health] template loaded ({} chars, {} vars) from {}",
        template.len(),
        vars.len(),
        tpl.display()
    );

    let mut sorted_keys: Vec<&String> = vars.keys().collect();
    sorted_keys.sort_by(|a, b| b.len().cmp(&a.len()));

    for key in sorted_keys {
        let placeholder = format!("${}", key);
        if template.contains(&placeholder) {
            template = template.replace(&placeholder, &vars[key]);
        }
    }
    Ok(template)
}
