#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/os_arch_minimum"
PODMAN_DIR="${SCRIPT_DIR}/podamn_minimum"
CONFIG_FILE="${CONFIG_DIR}/config.json"
OUTPUT_DIR="/home/diego/src_var/images/arch"
RAW_DIR="${OUTPUT_DIR}/qcow2_raw"
CUSTOM_DIR="${OUTPUT_DIR}/qcow2_custom"
ISO_DIR="${OUTPUT_DIR}/iso"
CLOUD_IMAGE_URL="https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2"
SSH_KEY=~/.ssh/id_ed25519

# Load config from JSON
if [[ -f "$CONFIG_FILE" ]]; then
    VM_NAME=$(jq -r '.vm.name' "$CONFIG_FILE")
    VM_MEMORY=$(jq -r '.vm.memory' "$CONFIG_FILE")
    VM_CPUS=$(jq -r '.vm.cpus' "$CONFIG_FILE")
    HOSTNAME=$(jq -r '.vm.hostname' "$CONFIG_FILE")
    USERNAME=$(jq -r '.user.username' "$CONFIG_FILE")
    PASSWORD=$(jq -r '.user.password' "$CONFIG_FILE")
    ROOT_PASSWORD=$(jq -r '.user.root_password' "$CONFIG_FILE")
else
    error "Config file not found: $CONFIG_FILE"
fi

BASE_IMAGE="${RAW_DIR}/arch-cloudimg.qcow2"
VM_DISK="${CUSTOM_DIR}/${VM_NAME}.qcow2"

log() { echo "[$(date +%H:%M:%S)] $1"; }
error() { echo "[ERROR] $1" >&2; exit 1; }
vm_exists() { virsh list --all --name 2>/dev/null | grep -q "^${VM_NAME}$"; }
vm_running() { virsh list --name 2>/dev/null | grep -q "^${VM_NAME}$"; }
get_vm_ip() { virsh domifaddr "$VM_NAME" 2>/dev/null | grep -oE '192\.168\.[0-9]+\.[0-9]+' | head -1; }

run_ssh() {
    SSH_ASKPASS="" DISPLAY="" ssh -o StrictHostKeyChecking=no -o BatchMode=yes -i "$SSH_KEY" "$@"
}

cmd_build() {
    log "=== Building Arch Linux VM (Minimum + Podman) ==="
    log "Config: $CONFIG_FILE"
    log "VM: $VM_NAME | User: $USERNAME | RAM: ${VM_MEMORY}MB | CPUs: $VM_CPUS"

    # Create directory structure
    mkdir -p "$RAW_DIR" "$CUSTOM_DIR" "$ISO_DIR"

    # Download base image to raw folder (master copy)
    if [[ ! -f "$BASE_IMAGE" ]]; then
        log "Downloading cloud image to raw folder..."
        curl -L -o "$BASE_IMAGE" "$CLOUD_IMAGE_URL"
        log "Master image saved: $BASE_IMAGE"
    else
        log "Using existing master image: $BASE_IMAGE"
    fi

    # Delete existing VM
    vm_exists && { virsh destroy "$VM_NAME" 2>/dev/null || true; virsh undefine "$VM_NAME" --nvram 2>/dev/null || true; }
    [[ -f "$VM_DISK" ]] && rm -f "$VM_DISK"

    # Copy and mount disk
    log "Creating VM disk..."
    cp "$BASE_IMAGE" "$VM_DISK"
    sudo modprobe nbd max_part=8
    sudo qemu-nbd --connect=/dev/nbd0 "$VM_DISK"
    sleep 2
    ROOT_PART=$(lsblk -ln -o NAME,SIZE /dev/nbd0 | tail -1 | awk '{print $1}')
    sudo mkdir -p /mnt/archvm
    sudo mount "/dev/${ROOT_PART}" /mnt/archvm

    log "Injecting configuration..."

    # Set root password
    ROOT_HASH=$(openssl passwd -6 "$ROOT_PASSWORD")
    sudo sed -i "s|^root:[^:]*:|root:${ROOT_HASH}:|" /mnt/archvm/etc/shadow

    # Remove base image's default user and create our user
    PASS_HASH=$(openssl passwd -6 "$PASSWORD")
    sudo sed -i "/^arch:/d" /mnt/archvm/etc/passwd
    sudo sed -i "/^arch:/d" /mnt/archvm/etc/shadow
    sudo sed -i "/^arch:/d" /mnt/archvm/etc/group
    sudo sed -i "/^${USERNAME}:/d" /mnt/archvm/etc/passwd
    sudo sed -i "/^${USERNAME}:/d" /mnt/archvm/etc/shadow
    sudo sed -i "/^${USERNAME}:/d" /mnt/archvm/etc/group
    echo "${USERNAME}:x:1000:1000:${USERNAME}:/home/${USERNAME}:/bin/bash" | sudo tee -a /mnt/archvm/etc/passwd > /dev/null
    echo "${USERNAME}:${PASS_HASH}:19000:0:99999:7:::" | sudo tee -a /mnt/archvm/etc/shadow > /dev/null
    echo "${USERNAME}:x:1000:" | sudo tee -a /mnt/archvm/etc/group > /dev/null
    sudo sed -i "s/^wheel:x:\([0-9]*\):$/wheel:x:\1:${USERNAME}/" /mnt/archvm/etc/group
    sudo rm -rf /mnt/archvm/home/arch
    sudo mkdir -p "/mnt/archvm/home/${USERNAME}/.ssh"
    sudo chown -R 1000:1000 "/mnt/archvm/home/${USERNAME}"

    # SSH key
    [[ -f "${SSH_KEY}.pub" ]] || ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q
    cat "${SSH_KEY}.pub" | sudo tee "/mnt/archvm/home/${USERNAME}/.ssh/authorized_keys" > /dev/null
    sudo chmod 700 "/mnt/archvm/home/${USERNAME}/.ssh"
    sudo chmod 600 "/mnt/archvm/home/${USERNAME}/.ssh/authorized_keys"
    sudo chown -R 1000:1000 "/mnt/archvm/home/${USERNAME}/.ssh"

    # Copy config files
    [[ -f "${CONFIG_DIR}/sshd_override.conf" ]] && sudo cp "${CONFIG_DIR}/sshd_override.conf" /mnt/archvm/etc/ssh/sshd_config.d/50-cloud-vm.conf
    [[ -f "${CONFIG_DIR}/sudoers_wheel" ]] && { sudo cp "${CONFIG_DIR}/sudoers_wheel" /mnt/archvm/etc/sudoers.d/wheel; sudo chmod 440 /mnt/archvm/etc/sudoers.d/wheel; }

    # Copy podman container files
    if [[ -d "$PODMAN_DIR" ]]; then
        sudo mkdir -p "/mnt/archvm/home/${USERNAME}/podman"
        sudo cp "$PODMAN_DIR"/* "/mnt/archvm/home/${USERNAME}/podman/"
        sudo chown -R 1000:1000 "/mnt/archvm/home/${USERNAME}/podman"
        log "Injected podman files to /home/${USERNAME}/podman/"
    fi

    # Copy install script and config from os_arch_minimum
    log "Injecting install script..."
    sudo cp "${CONFIG_DIR}/build.sh" "/mnt/archvm/home/${USERNAME}/install.sh"
    sudo cp "${CONFIG_DIR}/config.json" "/mnt/archvm/home/${USERNAME}/config.json"
    sudo chmod +x "/mnt/archvm/home/${USERNAME}/install.sh"
    sudo chown 1000:1000 "/mnt/archvm/home/${USERNAME}/install.sh"
    sudo chown 1000:1000 "/mnt/archvm/home/${USERNAME}/config.json"
    log "Injected install.sh and config.json to /home/${USERNAME}/"

    # Create systemd service to run install.sh on first boot
    sudo tee "/mnt/archvm/etc/systemd/system/first-boot.service" > /dev/null << 'FIRSTBOOT'
[Unit]
Description=First Boot Setup
After=network-online.target
Wants=network-online.target
ConditionPathExists=/home/diego/install.sh

[Service]
Type=oneshot
ExecStart=/home/diego/install.sh
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes

[Install]
WantedBy=multi-user.target
FIRSTBOOT

    # Fix the service file with actual username
    sudo sed -i "s|/home/diego/|/home/${USERNAME}/|g" "/mnt/archvm/etc/systemd/system/first-boot.service"

    # Enable the first-boot service
    sudo ln -sf /etc/systemd/system/first-boot.service "/mnt/archvm/etc/systemd/system/multi-user.target.wants/first-boot.service"

    # Unmount
    log "Unmounting..."
    sudo umount /mnt/archvm
    sudo qemu-nbd --disconnect /dev/nbd0

    # Create VM
    log "Creating VM..."
    virt-install --name "$VM_NAME" --memory "$VM_MEMORY" --vcpus "$VM_CPUS" \
        --disk "path=${VM_DISK},format=qcow2" --os-variant archlinux \
        --network network=default --graphics spice --import --noautoconsole

    log "VM created! First boot will run install.sh automatically."
    log "Watch progress: virt-viewer $VM_NAME"
    log "Or SSH after boot: ./build.sh ssh"
    log ""
    log "After login, build container with: ~/podman/build.sh"
}

cmd_start() { vm_exists || error "VM not found"; vm_running && log "Already running" || virsh start "$VM_NAME"; sleep 5; log "IP: $(get_vm_ip)"; }
cmd_stop() { vm_running && virsh shutdown "$VM_NAME" || log "Not running"; }
cmd_delete() { vm_running && virsh destroy "$VM_NAME" 2>/dev/null || true; vm_exists && virsh undefine "$VM_NAME" --nvram 2>/dev/null || true; [[ -f "$VM_DISK" ]] && rm -f "$VM_DISK"; log "Deleted"; }
cmd_ssh() { vm_running || { virsh start "$VM_NAME"; sleep 15; }; IP=$(get_vm_ip); [[ -n "$IP" ]] || error "No IP"; run_ssh "${USERNAME:-diego}@${IP}"; }
cmd_status() { echo "Base: $(ls -lh "$BASE_IMAGE" 2>/dev/null | awk '{print $5}' || echo 'N/A')"; echo "Disk: $(ls -lh "$VM_DISK" 2>/dev/null | awk '{print $5}' || echo 'N/A')"; vm_running && echo "VM: RUNNING ($(get_vm_ip))" || echo "VM: $(vm_exists && echo STOPPED || echo 'NOT CREATED')"; }

case "${1:-}" in
    build) cmd_build ;; start) cmd_start ;; stop) cmd_stop ;; delete) cmd_delete ;; ssh) cmd_ssh ;; status) cmd_status ;;
    *) echo "Usage: $0 {build|start|stop|delete|ssh|status}" ;;
esac
