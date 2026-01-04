#!/bin/bash
# BlissOS VM Setup Script
# Samsung Apps Mirror Configuration

set -e
cd "$(dirname "$0")"

DISK_SIZE="32G"
DISK_FILE="blissos-samsung.qcow2"
ISO_FILE="BlissOS-16.9.7-gapps.iso"
VM_NAME="blissos-samsung"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; exit 1; }

# Check prerequisites
check_prereqs() {
    log "Checking prerequisites..."

    command -v qemu-system-x86_64 >/dev/null || error "QEMU not installed"
    command -v virsh >/dev/null || error "libvirt not installed"

    if ! systemctl is-active --quiet libvirtd; then
        warn "libvirtd not running. Starting..."
        sudo systemctl start libvirtd
        sudo systemctl enable libvirtd
    fi

    # Check default network
    if ! virsh net-info default &>/dev/null; then
        log "Creating default network..."
        virsh net-define /etc/libvirt/qemu/networks/default.xml 2>/dev/null || true
    fi

    if ! virsh net-list | grep -q "default.*active"; then
        log "Starting default network..."
        virsh net-start default || true
        virsh net-autostart default
    fi

    # Check UEFI firmware (Arch or Ubuntu)
    if [[ -f /usr/share/edk2/x64/OVMF_CODE.4m.fd ]]; then
        OVMF_CODE="/usr/share/edk2/x64/OVMF_CODE.4m.fd"
        OVMF_VARS="/usr/share/edk2/x64/OVMF_VARS.4m.fd"
    elif [[ -f /usr/share/OVMF/OVMF_CODE_4M.fd ]]; then
        OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.fd"
        OVMF_VARS="/usr/share/OVMF/OVMF_VARS_4M.fd"
    else
        error "UEFI firmware not found. Install: sudo apt install ovmf (Ubuntu) or sudo pacman -S edk2-ovmf (Arch)"
    fi

    log "Prerequisites OK"
}

# Create virtual disk
create_disk() {
    if [[ -f "$DISK_FILE" ]]; then
        warn "Disk already exists: $DISK_FILE"
        read -p "Delete and recreate? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -f "$DISK_FILE"
        else
            return 0
        fi
    fi

    log "Creating ${DISK_SIZE} virtual disk..."
    qemu-img create -f qcow2 "$DISK_FILE" "$DISK_SIZE"
}

# Copy NVRAM template
setup_nvram() {
    if [[ ! -f "OVMF_VARS.fd" ]]; then
        log "Copying UEFI NVRAM template..."
        cp "$OVMF_VARS" OVMF_VARS.fd
    fi
}

# Define VM in libvirt
define_vm() {
    if virsh dominfo "$VM_NAME" &>/dev/null; then
        warn "VM already defined: $VM_NAME"
        read -p "Redefine? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            virsh undefine "$VM_NAME" --nvram 2>/dev/null || virsh undefine "$VM_NAME"
        else
            return 0
        fi
    fi

    log "Defining VM..."
    virsh define blissos-vm.xml
}

# Start VM
start_vm() {
    log "Starting VM..."
    virsh start "$VM_NAME"

    log "Launching virt-viewer..."
    virt-viewer "$VM_NAME" &
}

# Main setup
setup() {
    log "BlissOS VM Setup"
    echo "================"

    # Check ISO
    if [[ ! -f "$ISO_FILE" ]]; then
        error "ISO not found: $ISO_FILE\nDownload from: https://sourceforge.net/projects/blissos-x86/"
    fi

    check_prereqs
    create_disk
    setup_nvram
    define_vm

    echo
    log "Setup complete!"
    echo
    echo "Next steps:"
    echo "  1. Run: ./setup.sh start"
    echo "  2. In BlissOS installer, select 'Installation'"
    echo "  3. Create partition > Format ext4 > Install GRUB"
    echo "  4. After install, remove ISO from VM settings"
    echo
}

# Parse commands
case "${1:-setup}" in
    setup)
        setup
        ;;
    start)
        if ! virsh dominfo "$VM_NAME" &>/dev/null; then
            error "VM not defined. Run: ./setup.sh setup"
        fi
        start_vm
        ;;
    stop)
        virsh shutdown "$VM_NAME"
        ;;
    destroy)
        virsh destroy "$VM_NAME" 2>/dev/null || true
        ;;
    status)
        virsh dominfo "$VM_NAME"
        ;;
    console)
        virt-viewer "$VM_NAME"
        ;;
    *)
        echo "Usage: $0 {setup|start|stop|destroy|status|console}"
        exit 1
        ;;
esac
