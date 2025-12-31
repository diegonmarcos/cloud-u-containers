#!/bin/bash
# Cloud Desktop Entrypoint Script

set -e

USERNAME="diegonmarcos"

# Create runtime directory if not exists
mkdir -p /tmp/runtime-$USERNAME
chown $USERNAME:$USERNAME /tmp/runtime-$USERNAME
chmod 700 /tmp/runtime-$USERNAME

# Start D-Bus
if [ ! -d /run/dbus ]; then
    mkdir -p /run/dbus
fi
if [ ! -f /run/dbus/pid ]; then
    dbus-daemon --system --fork
fi

# Start PipeWire for audio (as user)
su - $USERNAME -c "pipewire &" 2>/dev/null || true
su - $USERNAME -c "pipewire-pulse &" 2>/dev/null || true
su - $USERNAME -c "wireplumber &" 2>/dev/null || true

# Fix permissions for X11
if [ -e /tmp/.X11-unix ]; then
    chmod 1777 /tmp/.X11-unix
fi

# Allow X connections
xhost +local: 2>/dev/null || true

# Check if password needs to be changed
if chage -l $USERNAME 2>/dev/null | grep -q "Password expires.*: password must be changed"; then
    echo ""
    echo "=========================================="
    echo "  FIRST LOGIN - PASSWORD CHANGE REQUIRED"
    echo "=========================================="
    echo ""
    echo "Your temporary password is: changeme"
    echo "You will be prompted to change it now."
    echo ""
    passwd $USERNAME
fi

# Start the desktop
if [ "$1" = "startplasma-x11" ]; then
    echo "Starting KDE Plasma Desktop..."

    # Start SDDM display manager
    if command -v sddm &> /dev/null; then
        exec sddm
    else
        # Fallback: start X directly
        exec su - $USERNAME -c "startx"
    fi
else
    exec "$@"
fi
