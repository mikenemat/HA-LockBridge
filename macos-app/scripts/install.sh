#!/usr/bin/env bash
# Build HA-LockBridge from source and copy to /Applications/.
#
# Contributor convenience — end users should download the notarized .app
# from GitHub Releases instead. This script exists for developers iterating
# locally.
#
# Re-runnable. Won't touch the paired-clients config at
# ~/Library/Application Support/HALockBridge/.
#
# Usage:
#   ./scripts/install.sh            # build if needed, then copy
#   ./scripts/install.sh --rebuild  # force a fresh build first
#
# Auto-start at login is configured by the app itself, not by this script —
# launch the .app once, then click "Start at Login" in the menu bar.

set -euo pipefail

REPO_BRIDGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILT_APP="$REPO_BRIDGE_DIR/build/Build/Products/Release-maccatalyst/HA-LockBridge.app"
DEST_APP="/Applications/HA-LockBridge.app"

REBUILD=0
for arg in "$@"; do
    case "$arg" in
        --rebuild) REBUILD=1 ;;
        -h|--help)
            sed -n '2,16p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg"; exit 1
            ;;
    esac
done

# --- Build if needed ----------------------------------------------------------

if [ "$REBUILD" -eq 1 ] || [ ! -d "$BUILT_APP" ]; then
    echo "→ Building HA-LockBridge.app …"
    (cd "$REPO_BRIDGE_DIR" && ./build.sh > /dev/null 2>&1) || {
        echo "Build failed. Run ./build.sh directly to see the error."
        exit 1
    }
fi

if [ ! -d "$BUILT_APP" ]; then
    echo "Error: expected built app at $BUILT_APP but it's not there."
    exit 1
fi

# --- Copy to /Applications ----------------------------------------------------

echo "→ Copying to $DEST_APP …"
if pgrep -f "$DEST_APP/Contents/MacOS/HA-LockBridge" > /dev/null; then
    echo "  (stopping the running copy first)"
    pkill -f "$DEST_APP/Contents/MacOS/HA-LockBridge" || true
    sleep 1
fi
rm -rf "$DEST_APP"
cp -R "$BUILT_APP" "$DEST_APP"

# Force LaunchServices to re-register so macOS knows about the new copy.
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
    -f -R -trusted "$DEST_APP" > /dev/null 2>&1 || true

echo "  ✓ Installed at $DEST_APP"
echo
echo "Done. Open /Applications/HA-LockBridge.app to start it."
echo "First launch will prompt for HomeKit access — click Allow."
echo "To enable auto-start at login, click \"Start at Login\" in the menu bar."
