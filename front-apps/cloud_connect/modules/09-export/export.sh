#!/usr/bin/env bash
#
# Cloud Connect - Export Module
#
# Export data from container to host
#
# Usage:
#   cloud export dotfiles
#   cloud export projects
#   cloud export all
#

set -euo pipefail

CLOUD_ROOT="${CLOUD_ROOT:-/opt/cloud-connect}"
source "$CLOUD_ROOT/lib/colors.sh"
source "$CLOUD_ROOT/lib/logging.sh"

EXPORT_DIR="${EXPORT_DIR:-$HOME/exports}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

show_help() {
    cat << EOF
${BOLD}Cloud Connect - Export Module${NC}

${BOLD}USAGE:${NC}
    cloud export <command> [options]

${BOLD}COMMANDS:${NC}
    dotfiles    Export shell configs (.bashrc, .zshrc, fish, starship)
    git         Export git config
    ssh         Export SSH config (not keys!)
    projects    Export ~/projects directory
    all         Export everything
    list        List available exports
    clean       Clean old exports

${BOLD}OPTIONS:${NC}
    --to <path>     Export destination (default: ~/exports)
    --compress      Create compressed archive

${BOLD}EXAMPLES:${NC}
    cloud export dotfiles
    cloud export all --compress
    cloud export projects --to /mnt/backup

EOF
}

ensure_export_dir() {
    mkdir -p "$EXPORT_DIR"
}

export_dotfiles() {
    log_subheader "Exporting Dotfiles"

    local dest="$EXPORT_DIR/dotfiles_$TIMESTAMP"
    mkdir -p "$dest"

    # Shell configs
    local files=(
        ".bashrc"
        ".bash_profile"
        ".bash_aliases"
        ".zshrc"
        ".profile"
    )

    for file in "${files[@]}"; do
        if [[ -f "$HOME/$file" ]]; then
            cp "$HOME/$file" "$dest/"
            status_ok "Exported: $file"
        fi
    done

    # Fish config
    if [[ -d "$HOME/.config/fish" ]]; then
        mkdir -p "$dest/fish"
        cp -r "$HOME/.config/fish/"* "$dest/fish/"
        status_ok "Exported: fish/"
    fi

    # Starship
    if [[ -f "$HOME/.config/starship.toml" ]]; then
        cp "$HOME/.config/starship.toml" "$dest/"
        status_ok "Exported: starship.toml"
    fi

    echo ""
    log_success "Dotfiles exported to: $dest"
}

export_git_config() {
    log_subheader "Exporting Git Config"

    local dest="$EXPORT_DIR/git_$TIMESTAMP"
    mkdir -p "$dest"

    if [[ -f "$HOME/.gitconfig" ]]; then
        cp "$HOME/.gitconfig" "$dest/"
        status_ok "Exported: .gitconfig"
    fi

    if [[ -f "$HOME/.gitignore_global" ]]; then
        cp "$HOME/.gitignore_global" "$dest/"
        status_ok "Exported: .gitignore_global"
    fi

    # Git credentials (if safe storage is used)
    if [[ -f "$HOME/.git-credentials" ]]; then
        log_warn "Skipping .git-credentials (contains secrets)"
    fi

    echo ""
    log_success "Git config exported to: $dest"
}

export_ssh_config() {
    log_subheader "Exporting SSH Config"

    local dest="$EXPORT_DIR/ssh_$TIMESTAMP"
    mkdir -p "$dest"

    # Only export config, NOT keys
    if [[ -f "$HOME/.ssh/config" ]]; then
        cp "$HOME/.ssh/config" "$dest/"
        status_ok "Exported: ssh/config"
    fi

    if [[ -f "$HOME/.ssh/known_hosts" ]]; then
        cp "$HOME/.ssh/known_hosts" "$dest/"
        status_ok "Exported: known_hosts"
    fi

    # Warn about keys
    log_warn "SSH keys NOT exported (security)"
    echo "  Keys should be in your vault, not exported from container"

    echo ""
    log_success "SSH config exported to: $dest"
}

export_projects() {
    log_subheader "Exporting Projects"

    local projects_dir="$HOME/projects"
    local dest="$EXPORT_DIR/projects_$TIMESTAMP"

    if [[ ! -d "$projects_dir" ]]; then
        log_warn "No projects directory found at $projects_dir"
        return
    fi

    mkdir -p "$dest"

    # Count projects
    local count=0
    for project in "$projects_dir"/*/; do
        if [[ -d "$project" ]]; then
            local name
            name=$(basename "$project")

            # Skip node_modules, .git, etc for size
            rsync -a \
                --exclude 'node_modules' \
                --exclude '.git' \
                --exclude 'target' \
                --exclude '__pycache__' \
                --exclude '.venv' \
                --exclude 'dist' \
                --exclude 'build' \
                "$project" "$dest/"

            status_ok "Exported: $name"
            count=$((count + 1))
        fi
    done

    echo ""
    log_success "$count projects exported to: $dest"
}

export_app_configs() {
    log_subheader "Exporting App Configs"

    local dest="$EXPORT_DIR/apps_$TIMESTAMP"
    mkdir -p "$dest"

    # VS Code
    if [[ -d "$HOME/.config/Code/User" ]]; then
        mkdir -p "$dest/vscode"
        cp "$HOME/.config/Code/User/settings.json" "$dest/vscode/" 2>/dev/null || true
        cp "$HOME/.config/Code/User/keybindings.json" "$dest/vscode/" 2>/dev/null || true
        if [[ -d "$HOME/.config/Code/User/snippets" ]]; then
            cp -r "$HOME/.config/Code/User/snippets" "$dest/vscode/"
        fi
        status_ok "Exported: VS Code settings"
    fi

    # Neovim
    if [[ -d "$HOME/.config/nvim" ]]; then
        mkdir -p "$dest/nvim"
        cp -r "$HOME/.config/nvim/"* "$dest/nvim/"
        status_ok "Exported: Neovim config"
    fi

    # Yazi
    if [[ -d "$HOME/.config/yazi" ]]; then
        mkdir -p "$dest/yazi"
        cp -r "$HOME/.config/yazi/"* "$dest/yazi/"
        status_ok "Exported: Yazi config"
    fi

    echo ""
    log_success "App configs exported to: $dest"
}

export_all() {
    log_header "Exporting All Data"

    ensure_export_dir

    export_dotfiles
    echo ""
    export_git_config
    echo ""
    export_ssh_config
    echo ""
    export_app_configs
    echo ""
    export_projects

    echo ""
    log_header "Export Complete"
    echo ""
    echo "All exports saved to: ${CYAN}$EXPORT_DIR${NC}"
    echo ""

    # Show size
    local total_size
    total_size=$(du -sh "$EXPORT_DIR" 2>/dev/null | cut -f1)
    echo "Total export size: $total_size"
    echo ""
}

compress_exports() {
    log_info "Compressing exports..."

    local archive="$EXPORT_DIR/cloud-export_$TIMESTAMP.tar.gz"

    # Find all exports from this session
    tar -czf "$archive" -C "$EXPORT_DIR" \
        $(ls -1 "$EXPORT_DIR" | grep "_$TIMESTAMP" | tr '\n' ' ') 2>/dev/null || true

    if [[ -f "$archive" ]]; then
        local size
        size=$(du -h "$archive" | cut -f1)
        log_success "Created archive: $archive ($size)"

        # Remove uncompressed directories
        for dir in "$EXPORT_DIR"/*_$TIMESTAMP/; do
            if [[ -d "$dir" ]]; then
                rm -rf "$dir"
            fi
        done
    fi
}

list_exports() {
    log_header "Available Exports"

    if [[ ! -d "$EXPORT_DIR" ]]; then
        echo "No exports found"
        return
    fi

    echo ""
    echo "Location: $EXPORT_DIR"
    echo ""

    # List directories
    for item in "$EXPORT_DIR"/*/; do
        if [[ -d "$item" ]]; then
            local name size date
            name=$(basename "$item")
            size=$(du -sh "$item" 2>/dev/null | cut -f1)
            date=$(stat -c %y "$item" 2>/dev/null | cut -d' ' -f1)
            printf "  ${CYAN}%-30s${NC} %8s  %s\n" "$name" "$size" "$date"
        fi
    done

    # List archives
    for item in "$EXPORT_DIR"/*.tar.gz; do
        if [[ -f "$item" ]]; then
            local name size date
            name=$(basename "$item")
            size=$(du -h "$item" 2>/dev/null | cut -f1)
            date=$(stat -c %y "$item" 2>/dev/null | cut -d' ' -f1)
            printf "  ${YELLOW}%-30s${NC} %8s  %s\n" "$name" "$size" "$date"
        fi
    done

    echo ""
}

clean_exports() {
    log_header "Cleaning Old Exports"

    if [[ ! -d "$EXPORT_DIR" ]]; then
        log_warn "No exports directory found"
        return
    fi

    # Keep last 5 exports, remove rest
    local keep=5
    local count=0

    # Count and sort by date
    for item in $(ls -1t "$EXPORT_DIR" 2>/dev/null); do
        count=$((count + 1))
        if [[ $count -gt $keep ]]; then
            rm -rf "$EXPORT_DIR/$item"
            status_ok "Removed: $item"
        fi
    done

    if [[ $count -le $keep ]]; then
        log_info "Nothing to clean (keeping last $keep exports)"
    else
        log_success "Cleaned $((count - keep)) old exports"
    fi

    echo ""
}

main() {
    local compress=false
    local dest=""
    local cmd="${1:-}"

    # Parse options
    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --compress)
                compress=true
                ;;
            --to)
                dest="$2"
                shift
                ;;
            *)
                ;;
        esac
        shift || true
    done

    # Set export dir if specified
    if [[ -n "$dest" ]]; then
        EXPORT_DIR="$dest"
    fi

    case "$cmd" in
        -h|--help|"")
            show_help
            ;;
        dotfiles)
            ensure_export_dir
            export_dotfiles
            $compress && compress_exports
            ;;
        git)
            ensure_export_dir
            export_git_config
            $compress && compress_exports
            ;;
        ssh)
            ensure_export_dir
            export_ssh_config
            $compress && compress_exports
            ;;
        projects)
            ensure_export_dir
            export_projects
            $compress && compress_exports
            ;;
        apps)
            ensure_export_dir
            export_app_configs
            $compress && compress_exports
            ;;
        all)
            export_all
            $compress && compress_exports
            ;;
        list)
            list_exports
            ;;
        clean)
            clean_exports
            ;;
        *)
            log_error "Unknown command: $cmd"
            exit 1
            ;;
    esac
}

main "$@"
