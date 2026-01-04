#!/bin/bash
# Install extracted APKs into BlissOS VM via ADB

set -e
cd "$(dirname "$0")"

SHARED_DIR="shared/apks"
BLISSOS_IP="${1:-}"

# Check if IP provided or try to find VM
if [[ -z "$BLISSOS_IP" ]]; then
    # Try to get VM IP from libvirt
    BLISSOS_IP=$(virsh domifaddr blissos-samsung 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)

    if [[ -z "$BLISSOS_IP" ]]; then
        echo "Usage: $0 <blissos-vm-ip>"
        echo "Or ensure VM 'blissos-samsung' is running"
        exit 1
    fi
fi

echo "Connecting to BlissOS at $BLISSOS_IP..."
adb connect "$BLISSOS_IP:5555"

sleep 2

if ! adb devices | grep -q "$BLISSOS_IP"; then
    echo "Failed to connect. Ensure:"
    echo "  1. BlissOS VM is running"
    echo "  2. ADB over network is enabled in Developer Options"
    exit 1
fi

echo "Connected!"
echo ""

# Count apps
TOTAL=$(find "$SHARED_DIR" -maxdepth 1 -type d | wc -l)
TOTAL=$((TOTAL - 1))  # Exclude parent dir

echo "Found $TOTAL apps to install"
echo ""

# Install each app
COUNT=0
FAILED=0
for app_dir in "$SHARED_DIR"/*/; do
    pkg=$(basename "$app_dir")
    COUNT=$((COUNT + 1))

    echo "[$COUNT/$TOTAL] Installing: $pkg"

    # Check for split APKs
    if [[ $(ls "$app_dir"/*.apk 2>/dev/null | wc -l) -gt 1 ]]; then
        # Split APK - use install-multiple
        if adb install-multiple "$app_dir"/*.apk 2>/dev/null; then
            echo "  ✓ Installed (split APK)"
        else
            echo "  ✗ Failed"
            FAILED=$((FAILED + 1))
        fi
    else
        # Single APK
        if adb install "$app_dir/base.apk" 2>/dev/null; then
            echo "  ✓ Installed"
        else
            echo "  ✗ Failed"
            FAILED=$((FAILED + 1))
        fi
    fi
done

echo ""
echo "Installation complete!"
echo "  Installed: $((COUNT - FAILED))/$COUNT"
echo "  Failed: $FAILED"
echo ""

if [[ $FAILED -gt 0 ]]; then
    echo "Some apps failed. Common reasons:"
    echo "  - App requires higher Android version"
    echo "  - App is ARM-only (no x86 support)"
    echo "  - App requires specific hardware (Samsung Knox, etc.)"
fi
