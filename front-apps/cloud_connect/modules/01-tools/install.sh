#!/usr/bin/env bash
#
# Cloud Connect - Tools Module
#
# Install development tools on demand
#
# Usage:
#   cloud tools install python node rust go
#   cloud tools install all
#   cloud tools list
#   cloud tools check
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD_ROOT="${CLOUD_ROOT:-/opt/cloud-connect}"

source "$CLOUD_ROOT/lib/colors.sh"
source "$CLOUD_ROOT/lib/logging.sh"

# ═══════════════════════════════════════════════════════════════════════════
# AVAILABLE TOOLS
# ═══════════════════════════════════════════════════════════════════════════

declare -A TOOLS=(
    [python]="Python 3 + pip + poetry"
    [node]="Node.js LTS + npm + pnpm"
    [rust]="Rust + cargo + rust-analyzer"
    [go]="Go"
    [git]="Git + lazygit + gh + delta"
    [cli]="ripgrep + fd + bat + eza + fzf + zoxide"
    [docker]="Docker + docker-compose + podman"
    [editors]="neovim + helix"
)

# ═══════════════════════════════════════════════════════════════════════════
# HELP
# ═══════════════════════════════════════════════════════════════════════════

show_help() {
    cat << EOF
${BOLD}Cloud Connect - Tools Module${NC}

${BOLD}USAGE:${NC}
    cloud tools <command> [options]

${BOLD}COMMANDS:${NC}
    install <tool...>   Install specified tools
    install all         Install all tools
    list                List available tools
    check               Check installed tools

${BOLD}AVAILABLE TOOLS:${NC}
EOF
    for tool in "${!TOOLS[@]}"; do
        printf "    ${CYAN}%-12s${NC} %s\n" "$tool" "${TOOLS[$tool]}"
    done | sort

    cat << EOF

${BOLD}EXAMPLES:${NC}
    cloud tools install python node rust
    cloud tools install all
    cloud tools check

EOF
}

# ═══════════════════════════════════════════════════════════════════════════
# INSTALLERS
# ═══════════════════════════════════════════════════════════════════════════

install_python() {
    log_subheader "Installing Python"

    sudo pacman -S --noconfirm --needed \
        python \
        python-pip \
        python-virtualenv \
        python-poetry \
        python-black \
        python-pylint \
        python-pytest \
        ipython

    log_success "Python installed"
    python --version
}

install_node() {
    log_subheader "Installing Node.js"

    sudo pacman -S --noconfirm --needed \
        nodejs-lts-iron \
        npm

    # Install pnpm
    npm install -g pnpm

    # Install useful global packages
    npm install -g \
        typescript \
        tsx \
        eslint \
        prettier

    log_success "Node.js installed"
    node --version
    pnpm --version
}

install_rust() {
    log_subheader "Installing Rust"

    # Install rustup if not present
    if ! command -v rustup &>/dev/null; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
    fi

    # Install stable toolchain
    rustup default stable
    rustup component add rust-analyzer clippy rustfmt

    # Install useful cargo tools
    cargo install \
        cargo-watch \
        cargo-edit \
        cargo-audit

    log_success "Rust installed"
    rustc --version
    cargo --version
}

install_go() {
    log_subheader "Installing Go"

    sudo pacman -S --noconfirm --needed go gopls

    # Setup GOPATH
    mkdir -p "$HOME/go/{bin,src,pkg}"
    if ! grep -q 'GOPATH' ~/.bashrc; then
        cat >> ~/.bashrc << 'EOF'

# Go
export GOPATH=$HOME/go
export PATH=$PATH:$GOPATH/bin
EOF
    fi

    log_success "Go installed"
    go version
}

install_git() {
    log_subheader "Installing Git Tools"

    sudo pacman -S --noconfirm --needed \
        git \
        git-lfs \
        lazygit \
        github-cli \
        git-delta \
        tig

    # Install git-absorb from AUR
    yay -S --noconfirm --needed git-absorb

    log_success "Git tools installed"
    git --version
    lazygit --version
}

install_cli() {
    log_subheader "Installing CLI Tools"

    sudo pacman -S --noconfirm --needed \
        ripgrep \
        fd \
        bat \
        eza \
        fzf \
        zoxide \
        btop \
        procs \
        dust \
        tokei \
        hyperfine \
        tealdeer

    # Update tldr cache
    tldr --update 2>/dev/null || true

    log_success "CLI tools installed"
}

install_docker() {
    log_subheader "Installing Docker"

    sudo pacman -S --noconfirm --needed \
        docker \
        docker-compose \
        podman \
        buildah

    log_success "Docker tools installed"
    docker --version
    podman --version
}

install_editors() {
    log_subheader "Installing Editors"

    sudo pacman -S --noconfirm --needed \
        neovim \
        helix

    log_success "Editors installed"
    nvim --version | head -1
    hx --version
}

install_all() {
    log_header "Installing All Tools"

    local total=${#TOOLS[@]}
    local current=0

    for tool in python node rust go git cli docker editors; do
        current=$((current + 1))
        log_step $current $total "Installing $tool"
        "install_$tool"
        echo ""
    done

    log_success "All tools installed!"
}

# ═══════════════════════════════════════════════════════════════════════════
# CHECK
# ═══════════════════════════════════════════════════════════════════════════

check_tools() {
    log_header "Installed Tools"

    echo ""

    # Python
    if command -v python &>/dev/null; then
        status_ok "python: $(python --version 2>&1)"
    else
        status_skip "python: not installed"
    fi

    # Node
    if command -v node &>/dev/null; then
        status_ok "node: $(node --version)"
    else
        status_skip "node: not installed"
    fi

    # Rust
    if command -v rustc &>/dev/null; then
        status_ok "rust: $(rustc --version)"
    else
        status_skip "rust: not installed"
    fi

    # Go
    if command -v go &>/dev/null; then
        status_ok "go: $(go version | cut -d' ' -f3)"
    else
        status_skip "go: not installed"
    fi

    # Git
    if command -v git &>/dev/null; then
        status_ok "git: $(git --version | cut -d' ' -f3)"
    else
        status_skip "git: not installed"
    fi

    # Docker
    if command -v docker &>/dev/null; then
        status_ok "docker: $(docker --version | cut -d' ' -f3 | tr -d ',')"
    else
        status_skip "docker: not installed"
    fi

    # Neovim
    if command -v nvim &>/dev/null; then
        status_ok "neovim: $(nvim --version | head -1 | cut -d' ' -f2)"
    else
        status_skip "neovim: not installed"
    fi

    echo ""
}

list_tools() {
    log_header "Available Tools"

    echo ""
    for tool in "${!TOOLS[@]}"; do
        printf "  ${CYAN}%-12s${NC} %s\n" "$tool" "${TOOLS[$tool]}"
    done | sort
    echo ""

    echo "Install with: ${CYAN}cloud tools install <tool>${NC}"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════

main() {
    case "${1:-}" in
        -h|--help|"")
            show_help
            exit 0
            ;;
        install)
            shift
            if [[ $# -eq 0 ]]; then
                log_error "Specify tools to install"
                echo "Example: cloud tools install python node rust"
                exit 1
            fi

            if [[ "$1" == "all" ]]; then
                install_all
            else
                for tool in "$@"; do
                    if [[ -n "${TOOLS[$tool]:-}" ]]; then
                        "install_$tool"
                    else
                        log_error "Unknown tool: $tool"
                        echo "Run 'cloud tools list' to see available tools"
                    fi
                done
            fi
            ;;
        list)
            list_tools
            ;;
        check)
            check_tools
            ;;
        *)
            log_error "Unknown command: $1"
            echo "Run 'cloud tools --help' for usage"
            exit 1
            ;;
    esac
}

main "$@"
