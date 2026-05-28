#!/usr/bin/env bash
# Build a notarized, stapled HA-LockBridge.app for distribution via
# GitHub Releases. Maintainer-only.
#
# Requirements (one-time setup):
#   1. Apple Developer Program membership ($99/yr) — gives you a
#      "Developer ID Application" cert (separate from the local-development
#      "Apple Development" cert used by build.sh).
#   2. An App-Store-Connect API key stored in your keychain via
#      `xcrun notarytool store-credentials "HALOCKBRIDGE_NOTARY" \
#         --apple-id "you@example.com" \
#         --team-id "$DEVELOPMENT_TEAM" \
#         --password "<app-specific password>"`
#      Use any name; this script reads it from $NOTARY_PROFILE below.
#
# What it does:
#   1. xcodebuild Release with the Developer ID Application cert (export
#      DEVELOPER_ID_CERT_NAME or let `security find-identity` pick the first
#      match).
#   2. `xcrun notarytool submit … --wait` — uploads to Apple, waits for the
#      cloud notarization to finish (usually 1–5 min).
#   3. `xcrun stapler staple` — embeds the notarization ticket in the .app
#      so Gatekeeper trusts it offline.
#   4. Stages the stapled .app + the HACS-installable HA integration
#      (custom_components/ha_lockbridge/) + hacs.json + a brief README
#      into a single HA-LockBridge-vX.Y.Z.zip ready to upload to a GitHub
#      Release. End users get both halves of the project from one download.
#
# Usage:
#   ./scripts/release.sh                       # build + notarize + staple + zip
#   ./scripts/release.sh --build-only          # just produce the signed .app
#   ./scripts/release.sh --version 0.3.0       # override the version tag in zip name
#
# The MARKETING_VERSION in project.yml is the source of truth for version
# unless --version is passed.

set -euo pipefail

REPO_BRIDGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NOTARY_PROFILE="${NOTARY_PROFILE:-HALOCKBRIDGE_NOTARY}"

BUILD_ONLY=0
VERSION_OVERRIDE=""
for arg in "$@"; do
    case "$arg" in
        --build-only) BUILD_ONLY=1 ;;
        --version) VERSION_OVERRIDE="next" ;;  # placeholder; next-arg pattern below
        -h|--help)
            sed -n '2,33p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            if [ "$VERSION_OVERRIDE" = "next" ]; then
                VERSION_OVERRIDE="$arg"
            else
                echo "Unknown argument: $arg"; exit 1
            fi
            ;;
    esac
done

cd "$REPO_BRIDGE_DIR"

# --- Version ------------------------------------------------------------------
if [ -n "$VERSION_OVERRIDE" ] && [ "$VERSION_OVERRIDE" != "next" ]; then
    VERSION="$VERSION_OVERRIDE"
else
    VERSION="$(grep -E '^[[:space:]]+MARKETING_VERSION:' project.yml | head -1 | awk -F'"' '{print $2}')"
fi
[ -n "$VERSION" ] || { echo "Could not determine version."; exit 1; }
echo "→ Building HA-LockBridge v$VERSION"

# --- Build with Developer ID signing -----------------------------------------
xcodegen generate > /dev/null

# Developer ID Application cert. If multiple are installed, use the first.
DEV_ID_CERT="${DEVELOPER_ID_CERT_NAME:-$(security find-identity -p codesigning -v | awk -F\" '/Developer ID Application:/{print $2; exit}')}"
[ -n "$DEV_ID_CERT" ] || {
    echo "No 'Developer ID Application' cert found in keychain."
    echo "Install via Xcode → Settings → Accounts → Manage Certificates → +."
    exit 1
}
echo "→ Signing with: $DEV_ID_CERT"

# Use the Distribution config (defined in project.yml). It's a Release-based
# config that additionally pins Manual signing + the Developer ID cert + the
# pre-installed "HA-LockBridge Developer ID" provisioning profile — settings
# that are scoped to the HALockBridge target only, so SwiftPM dependencies
# (swift-nio etc.) keep their default of no provisioning profile and the
# build doesn't fail with "X does not support provisioning profiles."
# Pipe the full xcodebuild output through to the caller — previously this
# was `| tail -10`, which routinely swallowed the actual error context on
# failure. With `set -o pipefail` already on, the pipeline's exit code
# is xcodebuild's exit code regardless of the tee.
xcodebuild \
    -project HALockBridge.xcodeproj \
    -scheme HALockBridge \
    -configuration Distribution \
    -destination 'platform=macOS,variant=Mac Catalyst' \
    -derivedDataPath build \
    build 2>&1 | tee build/xcodebuild.log

APP="build/Build/Products/Distribution-maccatalyst/HA-LockBridge.app"
[ -d "$APP" ] || { echo "Build produced no .app at $APP"; exit 1; }
echo "→ Built: $APP"

if [ "$BUILD_ONLY" -eq 1 ]; then
    echo "Done (--build-only)."
    exit 0
fi

# --- Notarize -----------------------------------------------------------------
ZIP_FOR_NOTARY="build/HA-LockBridge-notary.zip"
rm -f "$ZIP_FOR_NOTARY"
ditto -c -k --keepParent "$APP" "$ZIP_FOR_NOTARY"

echo "→ Submitting to Apple's notary service (profile: $NOTARY_PROFILE) …"
xcrun notarytool submit "$ZIP_FOR_NOTARY" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

# --- Staple -------------------------------------------------------------------
echo "→ Stapling notarization ticket to the .app …"
xcrun stapler staple "$APP"

# --- Stage release contents ---------------------------------------------------
# A single zip carries both halves of the project for end users: the macOS
# .app plus the HACS-installable HA integration. No source code, no scripts,
# no build files. ditto (not zip) is used for the outer archive so the .app's
# code-signing metadata and stapled notarization ticket survive round-trip
# through GitHub Releases + Safari/Finder extraction.
REPO_ROOT="$(cd "$REPO_BRIDGE_DIR/.." && pwd)"
STAGING="build/HA-LockBridge-v$VERSION"
rm -rf "$STAGING"
mkdir -p "$STAGING/custom_components"

echo "→ Staging release contents in $STAGING …"

cp -R "$APP" "$STAGING/HA-LockBridge.app"

# rsync (not cp -R) so we can exclude __pycache__ / .pyc / .DS_Store that
# would otherwise creep in from local dev runs.
rsync -a \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='.DS_Store' \
    "$REPO_ROOT/custom_components/ha_lockbridge" \
    "$STAGING/custom_components/"

# Include hacs.json so anyone forking or self-hosting the integration gets
# the HACS metadata without needing to grab it separately.
cp "$REPO_ROOT/hacs.json" "$STAGING/hacs.json"

cat > "$STAGING/README.txt" << EOF
HA-LockBridge v$VERSION
========================

This download includes both halves of the project:

  HA-LockBridge.app/            — the macOS bridge
  custom_components/            — the Home Assistant integration

Install on your always-on Mac
-----------------------------

  1. Drag HA-LockBridge.app into /Applications/.
  2. Double-click to launch. Click Allow on the HomeKit prompt.
  3. From the menu bar icon, enable "Start at Login" so the bridge
     auto-launches with your Mac.

Install in Home Assistant
-------------------------

  Manual:  copy custom_components/ha_lockbridge/ into your HA
           /config/custom_components/ directory, then restart HA.
  HACS:    add the GitHub repo as a custom repository in HACS,
           then install from the HACS UI.

Pair
----

  In Home Assistant, Settings → Devices & Services. A "HA-LockBridge"
  card will appear within ~10 seconds. Click Configure, then Approve
  in the bridge's window when prompted.

Full documentation: https://github.com/mikenemat/ha-lockbridge
EOF

# --- Final zip for upload -----------------------------------------------------
RELEASE_ZIP="build/HA-LockBridge-v$VERSION.zip"
rm -f "$RELEASE_ZIP"
ditto -c -k --keepParent "$STAGING" "$RELEASE_ZIP"
rm -rf "$STAGING"

echo
echo "✓ Done."
echo "  $RELEASE_ZIP"
echo
echo "Upload to GitHub Releases, e.g.:"
echo "  gh release create v$VERSION $RELEASE_ZIP --notes-from-tag"
