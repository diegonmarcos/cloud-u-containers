#!/bin/bash
# Extract APKs from connected Samsung device via ADB

set -e
cd "$(dirname "$0")"

SHARED_DIR="shared/apks"
APP_LIST="shared/samsung_apps.txt"

mkdir -p "$SHARED_DIR"

# Check ADB connection
if ! adb devices | grep -q "device$"; then
    echo "No device connected. Enable USB debugging on Samsung and reconnect."
    exit 1
fi

echo "Connected to: $(adb devices | grep device$ | cut -f1)"

# Get list of user-installed apps (excluding system)
echo "Fetching app list..."
adb shell pm list packages -3 | cut -d: -f2 | sort > "$APP_LIST"

TOTAL=$(wc -l < "$APP_LIST")
echo "Found $TOTAL user apps"

# Extract each APK
COUNT=0
while read -r pkg; do
    COUNT=$((COUNT + 1))
    echo "[$COUNT/$TOTAL] Extracting: $pkg"

    # Get APK path(s) - some apps have split APKs
    paths=$(adb shell pm path "$pkg" | cut -d: -f2 | tr -d '\r')

    # Create app directory for split APKs
    app_dir="$SHARED_DIR/$pkg"
    mkdir -p "$app_dir"

    i=0
    while read -r path; do
        if [[ -n "$path" ]]; then
            if [[ $i -eq 0 ]]; then
                adb pull "$path" "$app_dir/base.apk" 2>/dev/null || true
            else
                adb pull "$path" "$app_dir/split_$i.apk" 2>/dev/null || true
            fi
            i=$((i + 1))
        fi
    done <<< "$paths"
done < "$APP_LIST"

echo ""
echo "Extraction complete!"
echo "APKs saved to: $SHARED_DIR"
echo "App list saved to: $APP_LIST"
echo ""
echo "Transfer 'shared/' folder to BlissOS VM to install apps."
