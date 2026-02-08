//! Path constants and utilities

use std::path::PathBuf;

/// Get the LOCAL_KEYS directory
pub fn local_keys_dir() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("~"))
        .join("Documents/Git/LOCAL_KEYS")
}

/// Get SSH keys directory
pub fn ssh_keys_dir() -> PathBuf {
    local_keys_dir().join("00_terminal/ssh")
}

/// Get WireGuard keys directory
pub fn wireguard_keys_dir() -> PathBuf {
    local_keys_dir().join("00_terminal/wireguard")
}

/// Get configs directory
pub fn configs_dir() -> PathBuf {
    local_keys_dir().join("configs")
}

/// Expand ~ in path
pub fn expand_tilde(path: &std::path::Path) -> PathBuf {
    if let Ok(stripped) = path.strip_prefix("~") {
        dirs::home_dir()
            .unwrap_or_else(|| PathBuf::from("~"))
            .join(stripped)
    } else {
        path.to_path_buf()
    }
}

/// Ensure directory exists
pub fn ensure_dir(path: &std::path::Path) -> std::io::Result<()> {
    if !path.exists() {
        std::fs::create_dir_all(path)?;
    }
    Ok(())
}
