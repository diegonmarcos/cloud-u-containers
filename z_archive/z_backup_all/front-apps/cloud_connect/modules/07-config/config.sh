#!/usr/bin/env bash
#
# Cloud Connect - Config Module
#
# Apply personal configurations from vault
#
# Usage:
#   cloud config apply
#   cloud config shell
#   cloud config git
#   cloud config apps
#

set -euo pipefail

CLOUD_ROOT="${CLOUD_ROOT:-/opt/cloud-connect}"
source "$CLOUD_ROOT/lib/colors.sh"
source "$CLOUD_ROOT/lib/logging.sh"

VAULT_MOUNT="/vault"

show_help() {
    cat << EOF
${BOLD}Cloud Connect - Config Module${NC}

${BOLD}USAGE:${NC}
    cloud config <command>

${BOLD}COMMANDS:${NC}
    apply       Apply all configurations
    shell       Apply shell configs (fish, zsh, starship)
    git         Apply git config
    apps        Apply app configs
    status      Show config status

${BOLD}VAULT STRUCTURE:${NC}
    vault/
    ├── shell/
    │   ├── fish/config.fish
    │   ├── zsh/.zshrc
    │   └── starship.toml
    ├── git/
    │   ├── .gitconfig
    │   └── .gitignore_global
    └── apps/
        └── ...

${BOLD}EXAMPLES:${NC}
    cloud config apply
    cloud config shell
    cloud config git

EOF
}

check_vault() {
    if [[ ! -d "$VAULT_MOUNT" ]] || [[ ! -f "$VAULT_MOUNT/.vault" ]]; then
        die "Vault not loaded. Run: cloud vault load /path/to/vault"
    fi
}

apply_shell_config() {
    log_subheader "Shell Configuration"

    local config_dir="$VAULT_MOUNT/shell"

    if [[ ! -d "$config_dir" ]]; then
        status_skip "No shell configs in vault"
        return
    fi

    # Fish config
    if [[ -d "$config_dir/fish" ]]; then
        mkdir -p ~/.config/fish
        cp -r "$config_dir/fish/"* ~/.config/fish/
        status_ok "Applied: fish config"
    fi

    # Zsh config
    if [[ -f "$config_dir/.zshrc" ]]; then
        cp "$config_dir/.zshrc" ~/
        status_ok "Applied: .zshrc"
    fi

    # Starship config
    if [[ -f "$config_dir/starship.toml" ]]; then
        mkdir -p ~/.config
        cp "$config_dir/starship.toml" ~/.config/
        status_ok "Applied: starship.toml"
    fi

    # Bash aliases
    if [[ -f "$config_dir/aliases.sh" ]]; then
        cp "$config_dir/aliases.sh" ~/.bash_aliases
        status_ok "Applied: aliases"
    fi
}

apply_git_config() {
    log_subheader "Git Configuration"

    local config_dir="$VAULT_MOUNT/git"

    if [[ ! -d "$config_dir" ]]; then
        status_skip "No git configs in vault"
        return
    fi

    # Git config
    if [[ -f "$config_dir/.gitconfig" ]]; then
        cp "$config_dir/.gitconfig" ~/
        status_ok "Applied: .gitconfig"
    fi

    # Global gitignore
    if [[ -f "$config_dir/.gitignore_global" ]]; then
        cp "$config_dir/.gitignore_global" ~/
        git config --global core.excludesfile ~/.gitignore_global
        status_ok "Applied: .gitignore_global"
    fi
}

apply_app_config() {
    log_subheader "App Configuration"

    local config_dir="$VAULT_MOUNT/apps"

    if [[ ! -d "$config_dir" ]]; then
        status_skip "No app configs in vault"
        return
    fi

    # VS Code settings
    if [[ -d "$config_dir/vscode" ]]; then
        mkdir -p ~/.config/Code/User
        cp -r "$config_dir/vscode/"* ~/.config/Code/User/
        status_ok "Applied: VS Code settings"
    fi

    # Neovim config
    if [[ -d "$config_dir/nvim" ]]; then
        mkdir -p ~/.config/nvim
        cp -r "$config_dir/nvim/"* ~/.config/nvim/
        status_ok "Applied: Neovim config"
    fi

    # Yazi config
    if [[ -d "$config_dir/yazi" ]]; then
        mkdir -p ~/.config/yazi
        cp -r "$config_dir/yazi/"* ~/.config/yazi/
        status_ok "Applied: Yazi config"
    fi

    # Konsole profiles
    if [[ -d "$config_dir/konsole" ]]; then
        mkdir -p ~/.local/share/konsole
        cp -r "$config_dir/konsole/"* ~/.local/share/konsole/
        status_ok "Applied: Konsole profiles"
    fi
}

apply_all() {
    check_vault

    log_header "Applying Configuration"

    apply_shell_config
    echo ""
    apply_git_config
    echo ""
    apply_app_config
    echo ""

    log_success "Configuration applied!"
    echo ""
    echo "Reload shell to apply changes: ${CYAN}exec \$SHELL${NC}"
    echo ""
}

show_status() {
    log_header "Config Status"

    check_vault

    echo "Vault configs:"
    for dir in shell git apps; do
        if [[ -d "$VAULT_MOUNT/$dir" ]]; then
            local count
            count=$(find "$VAULT_MOUNT/$dir" -type f | wc -l)
            status_ok "$dir/: $count files"
        else
            status_skip "$dir/: Not in vault"
        fi
    done

    echo ""
    echo "Applied configs:"

    # Check starship
    if [[ -f ~/.config/starship.toml ]]; then
        status_ok "Starship prompt"
    else
        status_skip "Starship prompt"
    fi

    # Check git
    if [[ -f ~/.gitconfig ]]; then
        local git_user
        git_user=$(git config --global user.name 2>/dev/null || echo "not set")
        status_ok "Git config (user: $git_user)"
    else
        status_skip "Git config"
    fi

    echo ""
}

main() {
    case "${1:-}" in
        -h|--help|"")
            show_help
            ;;
        apply|all)
            apply_all
            ;;
        shell)
            check_vault
            apply_shell_config
            ;;
        git)
            check_vault
            apply_git_config
            ;;
        apps)
            check_vault
            apply_app_config
            ;;
        status)
            show_status
            ;;
        *)
            log_error "Unknown command: $1"
            exit 1
            ;;
    esac
}

main "$@"
