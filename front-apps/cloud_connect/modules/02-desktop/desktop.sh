#!/usr/bin/env bash
#
# Cloud Connect - Desktop Module
#
# Install and manage KDE Plasma desktop
#
# Usage:
#   cloud desktop install
#   cloud desktop start
#   cloud desktop stop
#

set -euo pipefail

CLOUD_ROOT="${CLOUD_ROOT:-/opt/cloud-connect}"
source "$CLOUD_ROOT/lib/colors.sh"
source "$CLOUD_ROOT/lib/logging.sh"

show_help() {
    cat << EOF
${BOLD}Cloud Connect - Desktop Module${NC}

${BOLD}USAGE:${NC}
    cloud desktop <command>

${BOLD}COMMANDS:${NC}
    install     Install KDE Plasma desktop
    start       Start desktop session
    stop        Stop desktop session
    status      Show desktop status

${BOLD}NOTES:${NC}
    Desktop requires X11 forwarding to work.
    Make sure DISPLAY is set on the host.

EOF
}

install_desktop() {
    log_header "Installing KDE Plasma Desktop"

    log_step 1 4 "Installing Xorg"
    sudo pacman -S --noconfirm --needed \
        xorg-server \
        xorg-xinit \
        xorg-xauth

    log_step 2 4 "Installing KDE Plasma"
    sudo pacman -S --noconfirm --needed \
        plasma-desktop \
        plasma-pa \
        plasma-nm \
        kde-gtk-config \
        breeze-gtk

    log_step 3 4 "Installing KDE Applications"
    sudo pacman -S --noconfirm --needed \
        dolphin \
        konsole \
        kate \
        yakuake \
        ark \
        gwenview \
        okular \
        spectacle

    log_step 4 4 "Configuring desktop"

    # Create .xinitrc
    cat > ~/.xinitrc << 'EOF'
#!/bin/sh
export DESKTOP_SESSION=plasma
exec startplasma-x11
EOF
    chmod +x ~/.xinitrc

    log_success "KDE Plasma installed!"
    echo ""
    echo "Start desktop with: ${CYAN}cloud desktop start${NC}"
    echo ""
}

start_desktop() {
    if [[ -z "${DISPLAY:-}" ]]; then
        die "DISPLAY not set. Make sure X11 forwarding is enabled."
    fi

    log_info "Starting KDE Plasma..."

    if command -v startplasma-x11 &>/dev/null; then
        startplasma-x11 &
        log_success "Desktop started"
    else
        die "KDE Plasma not installed. Run: cloud desktop install"
    fi
}

stop_desktop() {
    log_info "Stopping desktop..."
    pkill -f plasma || true
    pkill -f kwin || true
    log_success "Desktop stopped"
}

show_status() {
    log_header "Desktop Status"

    if pgrep -f plasma &>/dev/null; then
        status_ok "KDE Plasma: Running"
    else
        status_skip "KDE Plasma: Not running"
    fi

    if command -v startplasma-x11 &>/dev/null; then
        status_ok "Desktop: Installed"
    else
        status_skip "Desktop: Not installed"
    fi

    echo ""
    echo "DISPLAY: ${DISPLAY:-not set}"
    echo ""
}

main() {
    case "${1:-}" in
        -h|--help|"")
            show_help
            ;;
        install)
            install_desktop
            ;;
        start)
            start_desktop
            ;;
        stop)
            stop_desktop
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
