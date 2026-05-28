#!/usr/bin/env bash
# Remove HA-LockBridge from /Applications/.
#
# Contributor convenience — end users can just drag the app to the Trash.
# The "Start at Login" entry is auto-cleaned by macOS when the .app is
# removed; SMAppService handles registration lifecycle, no shell cleanup
# is needed.
#
# Usage:
#   ./scripts/uninstall.sh
#   ./scripts/uninstall.sh --purge   # also delete ~/Library/Application Support/HALockBridge/
#
# The .xcconfig with your developer team ID is left untouched.

set -euo pipefail

DEST_APP="/Applications/HA-LockBridge.app"
CONFIG_DIR="$HOME/Library/Application Support/HALockBridge"

PURGE=0
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        -h|--help)
            sed -n '2,13p' "$0" | sed 's/^# \?//'
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
if [ "$PURGE" -eq 1 ]; then
    if [ -d "$CONFIG_DIR" ]; then
        echo "→ Purging $CONFIG_DIR (paired tokens + instance ID will be lost) …"
        rm -rf "$CONFIG_DIR"
    fi
else
    if [ -d "$CONFIG_DIR" ]; then
        echo
        echo "Note: paired-clients config preserved at:"
        echo "    $CONFIG_DIR"
        echo "Delete it manually, or re-run with --purge, to fully reset."
    fi
fi

echo
echo "Uninstalled."
