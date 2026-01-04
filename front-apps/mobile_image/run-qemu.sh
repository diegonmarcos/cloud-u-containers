#!/bin/bash
# Direct QEMU launch for BlissOS - debug/compatibility mode

cd "$(dirname "$0")"

qemu-system-x86_64 \
    -enable-kvm \
    -m 4G \
    -smp 4 \
    -cpu host \
    -machine q35 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file=OVMF_VARS.fd \
    -drive file=blissos-samsung.qcow2,format=qcow2,if=virtio \
    -cdrom BlissOS-16.9.7-gapps.iso \
    -boot menu=on \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    -device qemu-xhci \
    -device usb-tablet \
    -display gtk,gl=off \
    -vga std \
    -full-screen
