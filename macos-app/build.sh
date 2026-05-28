#!/usr/bin/env bash
# Regenerate the Xcode project from project.yml, build the Mac Catalyst app,
# print embedded entitlements, then exec the bundled binary.

set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate

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
