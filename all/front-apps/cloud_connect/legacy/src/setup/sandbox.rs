//! Sandbox module - Docker KDE Desktop for isolated environments

use crate::config::Config;
use anyhow::{Context, Result};
use owo_colors::OwoColorize;
use std::process::Command;
use std::io::Write;
use std::path::PathBuf;

// Embedded desktop files (shared with USB module)
const DOCKER_COMPOSE: &str = include_str!("../../assets/desktop/docker-compose.yml");
const DOCKERFILE: &str = include_str!("../../assets/desktop/Dockerfile");
const ENTRYPOINT_SH: &str = include_str!("../../assets/desktop/entrypoint.sh");
const FIRST_LOGIN_SH: &str = include_str!("../../assets/desktop/first-login.sh");

/// Create a new sandbox with KDE desktop
pub async fn create_sandbox(cfg: &Config, name: &str) -> Result<()> {
    let sandbox_cfg = &cfg.sandbox;
    let container_name = format!("{}-{}", sandbox_cfg.container_prefix, name);
    let desktop_dir = sandbox_cfg.data_dir.join(name);

    // Calculate resource limits (90% of system resources)
    let (mem_limit, memswap_limit, cpus) = calculate_resource_limits()?;

    println!("{}", "Creating Cloud Desktop Sandbox".cyan().bold());
    println!();
    println!("  Name:      {}", container_name);
    println!("  Desktop:   KDE Plasma");
    println!("  Apps:      Dolphin, Konsole, Kate, Brave, Obsidian");
    println!("  User:      diegonmarcos");
    println!("  Password:  changeme (must change on first login)");
    println!();
    println!("  Resource Limits (90% of system):");
    println!("    Memory:  {}", mem_limit);
    println!("    Swap:    {} (equal to RAM)", mem_limit);
    println!("    CPUs:    {}", cpus);
    println!();

    // Check if container already exists
    if container_exists(&container_name)? {
        println!("{} Container '{}' already exists", "Warning:".yellow(), container_name);
        println!();
        println!("Options:");
        println!("  Enter:   cloud setup sandbox enter {}", name);
        println!("  Destroy: cloud setup sandbox destroy {}", name);
        return Ok(());
    }

    // Create desktop directory
    std::fs::create_dir_all(&desktop_dir).context("Failed to create desktop directory")?;

    // Write Docker files
    println!("{}", "Setting up Docker KDE Desktop...".dimmed());
    write_desktop_files(&desktop_dir)?;

    // Build the Docker image
    println!("{}", "Building Docker image (this may take 10-15 minutes)...".cyan());
    let compose_file = desktop_dir.join("docker-compose.yml").to_str().unwrap().to_string();

    let status = Command::new("docker")
        .args(["compose", "-f", &compose_file, "build"])
        .envs([
            ("CLOUD_MEM_LIMIT", mem_limit.as_str()),
            ("CLOUD_MEMSWAP_LIMIT", memswap_limit.as_str()),
            ("CLOUD_CPUS", cpus.as_str()),
        ])
        .status()
        .context("Failed to build Docker image")?;

    if !status.success() {
        anyhow::bail!("Failed to build Docker image");
    }

    // Start the container with resource limits
    println!("{}", "Starting container with resource limits...".dimmed());
    let status = Command::new("docker")
        .args(["compose", "-f", &compose_file, "up", "-d"])
        .envs([
            ("CLOUD_MEM_LIMIT", mem_limit.as_str()),
            ("CLOUD_MEMSWAP_LIMIT", memswap_limit.as_str()),
            ("CLOUD_CPUS", cpus.as_str()),
        ])
        .status()
        .context("Failed to start container")?;

    if !status.success() {
        anyhow::bail!("Failed to start container");
    }

    // Rename container to match our naming convention
    let _ = Command::new("docker")
        .args(["rename", "cloud-desktop", &container_name])
        .status();

    println!();
    println!("{}", "═".repeat(60).green());
    println!("{} Sandbox '{}' created!", "Success:".green(), name);
    println!("{}", "═".repeat(60).green());
    println!();
    println!("Desktop access:");
    println!("  Enter shell: cloud setup sandbox enter {}", name);
    println!("  Full desktop: The KDE desktop is running with X11 forwarding");
    println!();
    println!("First login:");
    println!("  User:     diegonmarcos");
    println!("  Password: changeme (you MUST change this)");
    println!();

    Ok(())
}

/// Write Docker desktop files to directory
fn write_desktop_files(dir: &PathBuf) -> Result<()> {
    // docker-compose.yml
    std::fs::write(dir.join("docker-compose.yml"), DOCKER_COMPOSE)
        .context("Failed to write docker-compose.yml")?;

    // Dockerfile
    std::fs::write(dir.join("Dockerfile"), DOCKERFILE)
        .context("Failed to write Dockerfile")?;

    // entrypoint.sh
    let entrypoint_path = dir.join("entrypoint.sh");
    std::fs::write(&entrypoint_path, ENTRYPOINT_SH)
        .context("Failed to write entrypoint.sh")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&entrypoint_path, std::fs::Permissions::from_mode(0o755))?;
    }

    // first-login.sh
    let first_login_path = dir.join("first-login.sh");
    std::fs::write(&first_login_path, FIRST_LOGIN_SH)
        .context("Failed to write first-login.sh")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&first_login_path, std::fs::Permissions::from_mode(0o755))?;
    }

    Ok(())
}

/// Enter an existing sandbox container
pub async fn enter_sandbox(cfg: &Config, name: &str) -> Result<()> {
    let container_name = format!("{}-{}", cfg.sandbox.container_prefix, name);

    // Check if container exists
    if !container_exists(&container_name)? {
        // Try the default cloud-desktop name
        if container_exists("cloud-desktop")? {
            return enter_container("cloud-desktop").await;
        }
        anyhow::bail!("Sandbox '{}' does not exist. Create it first with: cloud setup sandbox create {}", name, name);
    }

    enter_container(&container_name).await
}

/// Enter a container by name
async fn enter_container(container_name: &str) -> Result<()> {
    // Start container if not running
    if !container_running(container_name)? {
        println!("{} Starting container...", "Info:".cyan());
        let status = Command::new("docker")
            .args(["start", container_name])
            .status()
            .context("Failed to start container")?;

        if !status.success() {
            anyhow::bail!("Failed to start container");
        }
    }

    println!("{}", "═".repeat(60).cyan());
    println!("  Entering Cloud Desktop: {}", container_name.bold());
    println!("{}", "═".repeat(60).cyan());
    println!();
    println!("You are now inside the KDE Desktop container.");
    println!("Type 'exit' to leave the sandbox.");
    println!();

    // Exec into container with interactive shell
    let status = Command::new("docker")
        .args([
            "exec",
            "-it",
            "-u", "diegonmarcos",
            container_name,
            "/bin/bash",
            "-l"
        ])
        .status()
        .context("Failed to exec into container")?;

    println!();
    if status.success() {
        println!("{} Exited sandbox", "Info:".cyan());
    }

    Ok(())
}

/// Stop a sandbox container
pub async fn stop_sandbox(cfg: &Config, name: &str) -> Result<()> {
    let container_name = format!("{}-{}", cfg.sandbox.container_prefix, name);

    if !container_exists(&container_name)? {
        println!("{} Sandbox '{}' does not exist", "Warning:".yellow(), name);
        return Ok(());
    }

    println!("{} Stopping sandbox '{}'...", "Info:".cyan(), name);

    let status = Command::new("docker")
        .args(["stop", &container_name])
        .status()
        .context("Failed to stop container")?;

    if status.success() {
        println!("{} Sandbox '{}' stopped", "Success:".green(), name);
    }

    Ok(())
}

/// Destroy a sandbox container and its data
pub async fn destroy_sandbox(cfg: &Config, name: &str, force: bool) -> Result<()> {
    let container_name = format!("{}-{}", cfg.sandbox.container_prefix, name);
    let desktop_dir = cfg.sandbox.data_dir.join(name);

    // Check for cloud-desktop as well
    let actual_container = if container_exists(&container_name)? {
        container_name.clone()
    } else if container_exists("cloud-desktop")? {
        "cloud-desktop".to_string()
    } else {
        println!("{} Sandbox '{}' does not exist", "Warning:".yellow(), name);
        return Ok(());
    };

    if !force {
        println!("{}", "WARNING: This will destroy the sandbox and all its data!".red());
        print!("Type 'yes' to confirm: ");
        std::io::stdout().flush()?;

        let mut input = String::new();
        std::io::stdin().read_line(&mut input)?;
        if input.trim() != "yes" {
            println!("Aborted.");
            return Ok(());
        }
    }

    println!("{} Destroying sandbox '{}'...", "Info:".cyan(), name);

    // Stop and remove container
    let _ = Command::new("docker").args(["stop", &actual_container]).status();
    let status = Command::new("docker")
        .args(["rm", "-f", &actual_container])
        .status()
        .context("Failed to remove container")?;

    if !status.success() {
        println!("{} Failed to remove container", "Warning:".yellow());
    }

    // Remove Docker volume
    let _ = Command::new("docker")
        .args(["volume", "rm", "-f", "desktop_user-data"])
        .status();

    // Remove desktop files
    if desktop_dir.exists() {
        std::fs::remove_dir_all(&desktop_dir)?;
        println!("  Removed: {}", desktop_dir.display());
    }

    println!("{} Sandbox '{}' destroyed", "Success:".green(), name);

    Ok(())
}

/// List all sandbox containers
pub async fn list_sandboxes(cfg: &Config) -> Result<()> {
    let prefix = &cfg.sandbox.container_prefix;

    // Get containers matching our prefix or cloud-desktop
    let output = Command::new("docker")
        .args([
            "ps", "-a",
            "--format", "{{.Names}}\t{{.Status}}\t{{.Image}}"
        ])
        .output()
        .context("Failed to list containers")?;

    if !output.status.success() {
        anyhow::bail!("Failed to list containers");
    }

    let stdout = String::from_utf8_lossy(&output.stdout);

    println!("{}", "Cloud Desktop Sandboxes".bold().underline());
    println!();

    let mut found = false;

    println!("{:<30} {:<25} {}", "NAME".bold(), "STATUS".bold(), "IMAGE".bold());
    println!("{}", "-".repeat(75));

    for line in stdout.lines() {
        let parts: Vec<&str> = line.split('\t').collect();
        if parts.len() >= 3 {
            let name = parts[0];
            // Match our prefix or cloud-desktop
            if name.starts_with(prefix) || name == "cloud-desktop" {
                found = true;
                let display_name = name.replace(&format!("{}-", prefix), "");
                let status = parts[1];
                let image = parts[2];

                let status_colored = if status.contains("Up") {
                    status.green().to_string()
                } else {
                    status.red().to_string()
                };

                println!("{:<30} {:<25} {}", display_name, status_colored, image);
            }
        }
    }

    if !found {
        println!("{}", "No sandboxes found".dimmed());
        println!();
        println!("Create one with: {}", "cloud setup sandbox create <name>".cyan());
    }

    println!();
    println!("Desktop features:");
    println!("  • KDE Plasma Desktop with X11 forwarding");
    println!("  • Apps: Dolphin, Konsole, Kate, Brave, Obsidian");
    println!("  • VPN ready (WireGuard, OpenVPN)");
    println!("  • Persistent home directory");

    Ok(())
}

// Helper functions

fn container_exists(name: &str) -> Result<bool> {
    let output = Command::new("docker")
        .args(["ps", "-a", "--filter", &format!("name=^{}$", name), "-q"])
        .output()
        .context("Failed to check container")?;

    Ok(!output.stdout.is_empty())
}

fn container_running(name: &str) -> Result<bool> {
    let output = Command::new("docker")
        .args(["ps", "--filter", &format!("name=^{}$", name), "-q"])
        .output()
        .context("Failed to check container status")?;

    Ok(!output.stdout.is_empty())
}

/// Calculate resource limits (90% of system resources)
/// Returns (mem_limit, memswap_limit, cpus) as strings for docker-compose
fn calculate_resource_limits() -> Result<(String, String, String)> {
    // Get total memory in bytes
    let meminfo = std::fs::read_to_string("/proc/meminfo")
        .unwrap_or_default();

    let total_mem_kb: u64 = meminfo
        .lines()
        .find(|l| l.starts_with("MemTotal:"))
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|s| s.parse().ok())
        .unwrap_or(8 * 1024 * 1024); // Default 8GB

    // Calculate 90% of RAM in GB
    let mem_gb = (total_mem_kb as f64 / 1024.0 / 1024.0 * 0.90).floor() as u64;
    let mem_limit = format!("{}g", mem_gb.max(2)); // Minimum 2GB

    // Swap = RAM (so memswap = 2x mem)
    let memswap_gb = mem_gb * 2;
    let memswap_limit = format!("{}g", memswap_gb.max(4));

    // Get CPU count
    let cpu_count: f64 = std::thread::available_parallelism()
        .map(|p| p.get() as f64)
        .unwrap_or(4.0);

    // 90% of CPUs
    let cpus = format!("{:.1}", cpu_count * 0.90);

    Ok((mem_limit, memswap_limit, cpus))
}

/// Get resource limits for display or export
pub fn get_system_resources() -> (u64, u64, usize) {
    let meminfo = std::fs::read_to_string("/proc/meminfo").unwrap_or_default();

    let total_mem_kb: u64 = meminfo
        .lines()
        .find(|l| l.starts_with("MemTotal:"))
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|s| s.parse().ok())
        .unwrap_or(8 * 1024 * 1024);

    let total_mem_gb = total_mem_kb / 1024 / 1024;
    let available_mem_gb = (total_mem_gb as f64 * 0.90) as u64;

    let cpu_count = std::thread::available_parallelism()
        .map(|p| p.get())
        .unwrap_or(4);

    (total_mem_gb, available_mem_gb, cpu_count)
}
