#!/usr/bin/env bash
# Regenerate the Xcode project from project.yml, build the Mac Catalyst app,
# print embedded entitlements, then exec the bundled binary.

set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate

# xcodegen pins LastUpgradeCheck to its own baseline (currently 1430,
# i.e. Xcode 14.3), which surfaces the "Update to recommended settings"
# banner in modern Xcode. The recommended-settings build flags themselves
# are already encoded in project.yml under settings.base (e.g.
# ENABLE_USER_SCRIPT_SANDBOXING). All that's left is the sentinel itself —
# bumping it dismisses the banner. Mirror the value in project.yml
# attributes.LastUpgradeCheck if Xcode advances and the banner returns.
sed -i '' 's/LastUpgradeCheck = [0-9]*;/LastUpgradeCheck = 2650;/' HALockBridge.xcodeproj/project.pbxproj

DEST='platform=macOS,variant=Mac Catalyst'
DERIVED=build

xcodebuild \
  -project HALockBridge.xcodeproj \
  -scheme HALockBridge \
  -configuration Release \
  -destination "$DEST" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  build | tail -25

APP="$DERIVED/Build/Products/Release-maccatalyst/HA-LockBridge.app"
BIN="$APP/Contents/MacOS/HA-LockBridge"

echo
echo "App:  $APP"
echo "Exec: $BIN"
echo "---- embedded entitlements ----"
codesign -d --entitlements - "$BIN" 2>&1 | grep -v "^Executable=" || true
echo "-------------------------------"
echo

# Filter UIKit's benign "Unable to find global key UIWindow" warning out of
# stderr. Any args (e.g. --toggle, --lock, --unlock <name>) are forwarded.
exec "$BIN" "$@" 2> >(grep --line-buffered -v 'Unable to find global key UIWindow' >&2)
