#!/usr/bin/env bash
#
# Cloud Connect - Container Entrypoint
#
# Sets up:
# - Encrypted DNS (cloudflared)
# - ProtonVPN (optional auto-connect)
# - Shell configuration
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ═══════════════════════════════════════════════════════════════════════════
# ENCRYPTED DNS
# ═══════════════════════════════════════════════════════════════════════════

setup_dns() {
    log_info "Setting up encrypted DNS (DoH)..."

    # Start cloudflared as DNS proxy
    if command -v cloudflared &>/dev/null; then
        # Run cloudflared in background
        sudo cloudflared proxy-dns --port 5053 --upstream https://1.1.1.1/dns-query --upstream https://1.0.0.1/dns-query &>/dev/null &

        # Update resolv.conf to use local DNS proxy
        echo "nameserver 127.0.0.1" | sudo tee /etc/resolv.conf > /dev/null

        log_success "Encrypted DNS active (Cloudflare DoH)"
    else
        log_warn "cloudflared not found, using default DNS"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# PROTONVPN
# ═══════════════════════════════════════════════════════════════════════════

setup_vpn() {
    if [[ "${CLOUD_SKIP_VPN:-0}" == "1" ]]; then
        log_warn "Skipping VPN setup (CLOUD_SKIP_VPN=1)"
        return
    fi

    log_info "ProtonVPN is available"
    echo ""
    echo "  To connect: protonvpn-cli connect"
    echo "  Status:     protonvpn-cli status"
    echo "  Disconnect: protonvpn-cli disconnect"
    echo ""

    # Auto-connect if credentials are available
    if [[ -f /vault/protonvpn/credentials ]]; then
        log_info "Found ProtonVPN credentials in vault, connecting..."
        # TODO: Implement auto-login
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# VNC DESKTOP
# ═══════════════════════════════════════════════════════════════════════════

setup_vnc() {
    # VNC is disabled by default - enable with CLOUD_START_VNC=1
    if [[ "${CLOUD_START_VNC:-0}" != "1" ]]; then
        log_info "VNC disabled (set CLOUD_START_VNC=1 to enable)"
        return
    fi

    log_info "Starting VNC server..."

    # Start VNC server on display :1
    if command -v Xvnc &>/dev/null; then
        Xvnc :1 -geometry 1920x1080 -depth 24 \
            -rfbauth ~/.vnc/passwd \
            -SecurityTypes VncAuth \
            -localhost no &>/dev/null &
        sleep 2

        # Start Openbox window manager
        export DISPLAY=:1
        openbox &>/dev/null &
        sleep 1

        # Start a terminal
        konsole &>/dev/null &

        log_success "VNC server started on port 5901"
    else
        log_warn "VNC server not found"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# SHELL SETUP
# ═══════════════════════════════════════════════════════════════════════════

setup_shell() {
    log_info "Setting up shell..."

    # Setup starship prompt
    if command -v starship &>/dev/null; then
        # Bash
        if ! grep -q 'starship init bash' ~/.bashrc 2>/dev/null; then
            echo 'eval "$(starship init bash)"' >> ~/.bashrc
        fi

        # Fish
        mkdir -p ~/.config/fish
        if ! grep -q 'starship init fish' ~/.config/fish/config.fish 2>/dev/null; then
            echo 'starship init fish | source' >> ~/.config/fish/config.fish
        fi

        # Zsh
        if ! grep -q 'starship init zsh' ~/.zshrc 2>/dev/null; then
            echo 'eval "$(starship init zsh)"' >> ~/.zshrc
        fi
    fi

    # Setup zoxide (smart cd)
    if command -v zoxide &>/dev/null; then
        if ! grep -q 'zoxide init' ~/.bashrc 2>/dev/null; then
            echo 'eval "$(zoxide init bash)"' >> ~/.bashrc
        fi
    fi

    # Create cloud alias
    if ! grep -q 'alias cloud=' ~/.bashrc 2>/dev/null; then
        cat >> ~/.bashrc << 'EOF'

# Cloud Connect aliases
alias cloud='/opt/cloud-connect/modules/00-base/cloud-cmd.sh'
alias ll='eza -la --icons'
alias ls='eza --icons'
alias cat='bat --paging=never'
alias grep='rg'
alias find='fd'

# Quick navigation
alias ..='cd ..'
alias ...='cd ../..'
EOF
    fi

    log_success "Shell configured"
}

# ═══════════════════════════════════════════════════════════════════════════
# WELCOME MESSAGE
# ═══════════════════════════════════════════════════════════════════════════

show_welcome() {
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}           Cloud Connect - Anonymous Environment                ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  Features:"
    echo "    ${GREEN}✓${NC} Encrypted DNS (Cloudflare DoH)"
    echo "    ${GREEN}✓${NC} ProtonVPN ready"
    echo "    ${GREEN}✓${NC} Brave browser"
    echo "    ${GREEN}✓${NC} Modern CLI tools"
    echo "    ${GREEN}✓${NC} VNC Desktop available (CLOUD_START_VNC=1)"
    echo ""
    echo "  AI CLIs:"
    echo "    ${BLUE}claude${NC}               - Claude Code CLI"
    echo "    ${BLUE}gemini${NC}               - Google Gemini CLI"
    echo ""
    echo "  GUI Apps (use host X11 or enable VNC):"
    echo "    ${BLUE}brave${NC}                - Brave browser"
    echo "    ${BLUE}dolphin${NC}              - File manager"
    echo "    ${BLUE}konsole${NC}              - Terminal"
    echo ""
    echo "  Commands:"
    echo "    ${BLUE}cloud tools install${NC}  - Add dev tools"
    echo "    ${BLUE}cloud vault load${NC}     - Load personal vault"
    echo "    ${BLUE}cloud status${NC}         - Show status"
    echo "    ${BLUE}brave${NC}                - Launch browser"
    echo ""
    echo "  VPN:"
    echo "    ${BLUE}protonvpn-cli connect${NC}    - Connect to VPN"
    echo "    ${BLUE}protonvpn-cli status${NC}     - Check status"
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════

main() {
    # Setup components
    setup_dns
    setup_vpn
    setup_vnc
    setup_shell

    # Show welcome on interactive shell
    if [[ -t 0 ]]; then
        show_welcome
    fi

    # Execute command or start shell
    if [[ $# -gt 0 ]]; then
        exec "$@"
    else
        exec /bin/bash
    fi
}

main "$@"
