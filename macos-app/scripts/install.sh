#!/usr/bin/env bash
# Build HA-LockBridge from source and copy to /Applications/.
#
# Contributor convenience — end users should install HA-LockBridge from the
# Mac App Store instead (that's the only supported distribution channel; see
# the repo README). This script exists for developers iterating locally.
#
# Re-runnable. Won't touch the paired-clients config.
#
# Usage:
#   ./scripts/install.sh            # build if needed, then copy
#   ./scripts/install.sh --rebuild  # force a fresh build first
#
# Auto-start at login is a manual one-time step (Mac Catalyst apps can't
# register themselves): launch the .app once, click "Start at Login" to open
# System Settings → General → Login Items, and add HA-LockBridge there.

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
    # Use --build-only: plain ./build.sh ends in `exec` of the app and never
    # returns, which would hang this script forever. Build output is shown
    # (not discarded) so a failure is diagnosable inline.
    (cd "$REPO_BRIDGE_DIR" && ./build.sh --build-only) || {
        echo "Build failed (see output above)."
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
echo "To enable auto-start at login, click \"Start at Login\" in the app window,"
echo "then add HA-LockBridge under System Settings → General → Login Items."
