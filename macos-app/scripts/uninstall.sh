#!/usr/bin/env bash
# Remove HA-LockBridge from /Applications/.
#
# Contributor convenience — end users can just drag the app to the Trash.
# If you added HA-LockBridge to Login Items, remove it manually under
# System Settings → General → Login Items (Mac Catalyst apps can't register
# OR unregister themselves as login items, so there's nothing for this script
# to clean up there).
#
# Usage:
#   ./scripts/uninstall.sh
#   ./scripts/uninstall.sh --purge   # also delete the paired-clients config
#
# The .xcconfig with your developer team ID is left untouched.

set -euo pipefail

DEST_APP="/Applications/HA-LockBridge.app"

# Non-sandboxed (self-built) copies write here; a sandboxed App Store build
# instead writes inside its container (see CONTAINER_CONFIG_DIR below). Purge
# checks both so it works regardless of which build produced the config.
CONFIG_DIR="$HOME/Library/Application Support/HALockBridge"
CONTAINER_CONFIG_DIR="$HOME/Library/Containers/io.github.mikenemat.HALockBridgeApp/Data/Library/Application Support/HALockBridge"

PURGE=0
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        -h|--help)
            sed -n '2,14p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
    esac
done

# --- Stop the running app -----------------------------------------------------
if pgrep -f "$DEST_APP/Contents/MacOS/HA-LockBridge" > /dev/null; then
    echo "→ Stopping the running app …"
    pkill -f "$DEST_APP/Contents/MacOS/HA-LockBridge" || true
    sleep 1
fi

# --- Remove the .app ----------------------------------------------------------
if [ -d "$DEST_APP" ]; then
    echo "→ Deleting $DEST_APP …"
    rm -rf "$DEST_APP"
fi

# --- Config (paired tokens) — opt-in ------------------------------------------
FOUND_CONFIG=0
for dir in "$CONFIG_DIR" "$CONTAINER_CONFIG_DIR"; do
    [ -d "$dir" ] || continue
    FOUND_CONFIG=1
    if [ "$PURGE" -eq 1 ]; then
        echo "→ Purging $dir (paired tokens + instance ID will be lost) …"
        rm -rf "$dir"
    else
        echo
        echo "Note: paired-clients config preserved at:"
        echo "    $dir"
    fi
done

if [ "$PURGE" -ne 1 ] && [ "$FOUND_CONFIG" -eq 1 ]; then
    echo "Delete it manually, or re-run with --purge, to fully reset."
fi

echo
echo "Uninstalled."
