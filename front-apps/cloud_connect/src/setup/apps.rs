//! Apps module - Install applications inside sandbox or host

use crate::config::Config;
use anyhow::{Context, Result};
use owo_colors::OwoColorize;
use std::process::Command;

/// Install all configured apps
pub async fn install_all(cfg: &Config, in_container: Option<&str>) -> Result<()> {
    println!("{}", "Installing all apps...".cyan());
    println!();

    let apps = &cfg.apps.apps;
    let mut all_packages: Vec<String> = Vec::new();

    // Collect all packages
    all_packages.extend(apps.terminal.clone());
    all_packages.extend(apps.browser.clone());
    all_packages.extend(apps.notes.clone());
    all_packages.extend(apps.ide.clone());
    all_packages.extend(apps.utils.clone());

    if all_packages.is_empty() {
        println!("{}", "No apps configured".yellow());
        return Ok(());
    }

    println!("Packages to install:");
    for pkg in &all_packages {
        println!("  - {}", pkg);
    }
    println!();

    // Install based on context
    if let Some(container) = in_container {
        install_in_container(container, &all_packages, &cfg.apps.aur_helper).await
    } else {
        install_on_host(&all_packages, &cfg.apps.package_manager, &cfg.apps.aur_helper).await
    }
}

/// Install a specific app
pub async fn install_app(cfg: &Config, app_name: &str, in_container: Option<&str>) -> Result<()> {
    println!("{} {}", "Installing:".cyan(), app_name);

    if let Some(container) = in_container {
        install_in_container(container, &[app_name.to_string()], &cfg.apps.aur_helper).await
    } else {
        install_on_host(&[app_name.to_string()], &cfg.apps.package_manager, &cfg.apps.aur_helper).await
    }
}

/// Install packages inside a Docker container
async fn install_in_container(container: &str, packages: &[String], aur_helper: &str) -> Result<()> {
    let container_name = if container.starts_with("cloud-sandbox-") {
        container.to_string()
    } else {
        format!("cloud-sandbox-{}", container)
    };

    println!("{} Installing in container '{}'", "Info:".cyan(), container_name);

    // First, update the system
    println!("{}", "Updating system...".dimmed());
    let status = Command::new("docker")
        .args([
            "exec", &container_name,
            "pacman", "-Syu", "--noconfirm"
        ])
        .status()
        .context("Failed to update system in container")?;

    if !status.success() {
        println!("{} System update failed, continuing anyway...", "Warning:".yellow());
    }

    // Install base-devel if not present (needed for AUR)
    println!("{}", "Installing base-devel...".dimmed());
    let _ = Command::new("docker")
        .args([
            "exec", &container_name,
            "pacman", "-S", "--noconfirm", "--needed",
            "base-devel", "git", "sudo"
        ])
        .status();

    // Separate official and AUR packages
    let (official, aur): (Vec<_>, Vec<_>) = packages.iter()
        .partition(|p| !is_aur_package(p));

    // Install official packages
    if !official.is_empty() {
        println!("{} Installing official packages...", "Info:".cyan());
        let mut args = vec![
            "exec".to_string(),
            container_name.clone(),
            "pacman".to_string(),
            "-S".to_string(),
            "--noconfirm".to_string(),
            "--needed".to_string(),
        ];
        args.extend(official.iter().map(|s| s.to_string()));

        let status = Command::new("docker")
            .args(&args)
            .status()
            .context("Failed to install official packages")?;

        if status.success() {
            println!("{} Official packages installed", "Success:".green());
        } else {
            println!("{} Some official packages failed", "Warning:".yellow());
        }
    }

    // Install AUR packages
    if !aur.is_empty() {
        println!("{} Installing AUR packages with {}...", "Info:".cyan(), aur_helper);

        // First ensure AUR helper is installed
        install_aur_helper_in_container(&container_name, aur_helper).await?;

        for pkg in aur {
            println!("  Installing AUR: {}", pkg);
            let status = Command::new("docker")
                .args([
                    "exec", "-u", "builder", &container_name,
                    aur_helper, "-S", "--noconfirm", "--needed", pkg
                ])
                .status();

            match status {
                Ok(s) if s.success() => println!("    {} {}", "Installed:".green(), pkg),
                _ => println!("    {} {} (may need manual install)", "Failed:".yellow(), pkg),
            }
        }
    }

    println!();
    println!("{} App installation complete", "Done:".green());
    Ok(())
}

/// Install packages on host system
async fn install_on_host(packages: &[String], pkg_manager: &str, aur_helper: &str) -> Result<()> {
    println!("{} Installing on host system", "Info:".cyan());

    // Separate official and AUR packages
    let (official, aur): (Vec<_>, Vec<_>) = packages.iter()
        .partition(|p| !is_aur_package(p));

    // Install official packages
    if !official.is_empty() {
        println!("{} Installing official packages with {}...", "Info:".cyan(), pkg_manager);

        let mut args = vec!["-S", "--noconfirm", "--needed"];
        let pkg_refs: Vec<&str> = official.iter().map(|s| s.as_str()).collect();
        args.extend(pkg_refs);

        let status = Command::new("sudo")
            .arg(pkg_manager)
            .args(&args)
            .status()
            .context("Failed to install packages")?;

        if status.success() {
            println!("{} Official packages installed", "Success:".green());
        } else {
            println!("{} Some packages failed", "Warning:".yellow());
        }
    }

    // Install AUR packages
    if !aur.is_empty() {
        println!("{} Installing AUR packages with {}...", "Info:".cyan(), aur_helper);

        for pkg in aur {
            let status = Command::new(aur_helper)
                .args(["-S", "--noconfirm", "--needed", pkg])
                .status();

            match status {
                Ok(s) if s.success() => println!("  {} {}", "Installed:".green(), pkg),
                _ => println!("  {} {}", "Failed:".yellow(), pkg),
            }
        }
    }

    println!();
    println!("{} App installation complete", "Done:".green());
    Ok(())
}

/// Install AUR helper (yay) in container
async fn install_aur_helper_in_container(container: &str, helper: &str) -> Result<()> {
    // Check if already installed
    let check = Command::new("docker")
        .args(["exec", container, "which", helper])
        .output()?;

    if check.status.success() {
        return Ok(());
    }

    println!("{} Installing {} in container...", "Info:".cyan(), helper);

    // Create a builder user for AUR
    let _ = Command::new("docker")
        .args([
            "exec", container,
            "bash", "-c",
            "id builder || (useradd -m builder && echo 'builder ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers)"
        ])
        .status();

    // Clone and build yay
    let install_script = format!(r#"
        cd /tmp && \
        rm -rf {helper} && \
        git clone https://aur.archlinux.org/{helper}.git && \
        cd {helper} && \
        chown -R builder:builder . && \
        sudo -u builder makepkg -si --noconfirm
    "#, helper = helper);

    let status = Command::new("docker")
        .args(["exec", container, "bash", "-c", &install_script])
        .status()
        .context("Failed to install AUR helper")?;

    if status.success() {
        println!("{} {} installed", "Success:".green(), helper);
        Ok(())
    } else {
        anyhow::bail!("Failed to install {}", helper)
    }
}

/// Check if a package is from AUR (heuristic)
fn is_aur_package(pkg: &str) -> bool {
    // Common AUR package patterns
    pkg.ends_with("-bin") ||
    pkg.ends_with("-git") ||
    pkg.contains("brave") ||
    pkg.contains("obsidian") ||
    pkg.contains("visual-studio") ||
    pkg.contains("google-chrome") ||
    pkg.contains("spotify")
}

/// List installed apps status
pub async fn check_apps(cfg: &Config, in_container: Option<&str>) -> Result<()> {
    println!("{}", "Checking installed apps...".cyan());
    println!();

    let apps = &cfg.apps.apps;

    let check_cmd = |pkg: &str| -> bool {
        if let Some(container) = in_container {
            let container_name = if container.starts_with("cloud-sandbox-") {
                container.to_string()
            } else {
                format!("cloud-sandbox-{}", container)
            };
            Command::new("docker")
                .args(["exec", &container_name, "pacman", "-Q", pkg])
                .output()
                .map(|o| o.status.success())
                .unwrap_or(false)
        } else {
            Command::new("pacman")
                .args(["-Q", pkg])
                .output()
                .map(|o| o.status.success())
                .unwrap_or(false)
        }
    };

    let print_status = |category: &str, packages: &[String]| {
        println!("{}:", category.bold());
        for pkg in packages {
            let installed = check_cmd(pkg);
            let status = if installed {
                "installed".green().to_string()
            } else {
                "missing".red().to_string()
            };
            println!("  {} - {}", pkg, status);
        }
        println!();
    };

    print_status("Terminal", &apps.terminal);
    print_status("Browser", &apps.browser);
    print_status("Notes", &apps.notes);
    print_status("IDE", &apps.ide);
    print_status("Utils", &apps.utils);

    Ok(())
}
