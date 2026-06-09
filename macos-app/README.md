# HA-LockBridge (Mac Catalyst app)

The Mac Catalyst app that runs on your always-on Mac, talks to HomeKit via
`HMHomeManager`, and serves the HTTP + WebSocket API that HomeAssistant
connects to.

## First-time setup

This is a one-time walkthrough for someone who's never built the bridge before.
Subsequent builds skip steps 1–3.

### 1. Prerequisites

```bash
brew install xcodegen
```

You also need Xcode 15+ installed (for the Mac Catalyst SDK) and an Apple ID
signed into Xcode.

### 2. Set your Apple Developer Team ID and bundle ID prefix

```bash
cd macos-app
cp DevelopmentTeam.xcconfig.example DevelopmentTeam.xcconfig
```

Edit `DevelopmentTeam.xcconfig` and replace **both** placeholders:

- **`DEVELOPMENT_TEAM`** — your 10-character Apple Developer Team ID.
  Find it in Xcode → *Settings → Accounts → (your Apple ID) → Manage
  Certificates*, or in the Apple Developer portal at
  <https://developer.apple.com/account>, or by running
  `security find-identity -p codesigning -v` (look for the 10-character
  alphanumeric in parentheses next to your name).

- **`BUNDLE_ID_PREFIX`** — a reverse-domain prefix unique to *your* Apple
  developer account. Apple registers bundle IDs per team, so you can't reuse
  the upstream `io.github.mikenemat` prefix; trying to enable the HomeKit
  capability on a build that uses someone else's prefix will fail. Pick
  something like `io.github.<your-github-handle>` or `com.<your-domain>`.
  `.HALockBridge` is appended automatically, so the final bundle ID will be
  e.g. `io.github.alice.HALockBridge`.

This file is `.gitignore`d so neither value leaves your machine.

### 3. First build (Xcode GUI, one-time)

The first time you build with a new bundle ID, Apple needs to register the
HomeKit capability for it. This requires a one-time pass through Xcode's GUI:

```bash
./build.sh
```

Expect this to fail the first time with:

```
error: Entitlement com.apple.developer.homekit not found and could not be
included in profile.
```

Now open the project in Xcode and grant the capability:

```bash
open HALockBridge.xcodeproj
```

In Xcode:

1. Left sidebar → click the **HALockBridge** project icon (top, blue).
2. Editor → **HALockBridge** target → **Signing & Capabilities** tab.
3. Verify **Team** is set to your Apple Developer team. If empty, pick it
   from the dropdown (Xcode may prompt you to sign in if you haven't yet).
4. You'll see a yellow warning about HomeKit. Click **+ Capability**
   (top-left button) → search "HomeKit" → double-click to add.
5. Wait ~10 seconds for Xcode to register the capability with Apple's portal
   and re-provision.
6. Close Xcode.

Now `./build.sh` works from the CLI for all subsequent builds.

### 4. Verify it runs

```bash
./build.sh
```

A "HA-LockBridge" window appears showing "Waiting for Home Assistant
to pair". macOS will prompt **HA-LockBridge would like to access your
home** — click Allow.

The window will stay open until you pair from HomeAssistant. To stop, hit
Ctrl-C.

## Install for daily use

```bash
./scripts/install.sh
```

Builds the .app (if needed) and copies it to `/Applications/HA-LockBridge.app`.

To enable auto-start at login, launch the .app and flip the **Start at Login**
toggle in the app window — the app uses `SMAppService` to register itself as
a Login Item. macOS surfaces this in System Settings → General → Login Items
where it can be disabled at any time.

To remove everything:

```bash
./scripts/uninstall.sh           # leaves paired-tokens config intact
./scripts/uninstall.sh --purge   # also deletes the config
```

## Iterating on the code (dev workflow)

```bash
./build.sh                              # build + run interactively
./build.sh --toggle "Guest Room Door"   # CLI test: toggle a lock
./build.sh --lock "Front Door"          # CLI test: idempotent lock
./build.sh --unlock "Front Door"        # CLI test: idempotent unlock
python3 Resources/generate_icon.py      # regenerate the app icon
```

`build.sh` will re-run `xcodegen generate` every time so changes to
`project.yml` are always picked up.

## Caveats

- **Appliance mode: the bridge runs as a visible foreground app**, not a
  hidden menu-bar utility. It shows a Dock icon and an always-visible window,
  keeps the display awake, and grabs focus when HA issues a lock command.
  This is required, not cosmetic: HomeKit only services accessory *writes*
  promptly for the frontmost/active app, so a backgrounded bridge can't
  control locks without multi-second lag. Run it on a **dedicated Mac**; the
  window can't be closed/minimized (use the in-window **Quit** or ⌘Q).
- The bridge needs an active **GUI user session**. HomeKit access requires
  a logged-in user. On a dedicated Mac, enable auto-login.
- HomeKit framework on macOS 15+ lives only in the iOSSupport SDK overlay,
  which is why this project is a Mac Catalyst app (not pure macOS).

## Cutting a release (maintainer-only)

End-user distribution is via the Mac App Store. The release flow is:

1. Bump the version in `project.yml`: `MARKETING_VERSION` (the user-facing
   version) and `CURRENT_PROJECT_VERSION` (the build number — must increase
   for every App Store upload). Also bump `version` in
   `custom_components/ha_lockbridge/manifest.json` if the HA integration
   changed. The bridge's wire-protocol version strings (the WebSocket
   `hello` envelope, `/info`, and the Bonjour TXT record) are derived
   automatically from `CFBundleShortVersionString` as of 0.5.4 — no manual
   edits needed there.
2. Open `HALockBridge.xcodeproj` in Xcode.
3. Select the **Generic Mac Catalyst Device** destination.
4. Product → **Archive**. The archive shows up in Window → Organizer.
5. Click **Distribute App** → **App Store Connect** → **Upload**.
6. Submit for review from App Store Connect.

HomeKit's restricted entitlement means Developer ID notarized distribution
isn't an option on macOS — Apple's profile generator silently strips the
HomeKit entitlement from any Developer ID provisioning profile, regardless
of what's checked on the App ID. Mac App Store is the only path.

## Layout

```
macos-app/
├── project.yml                     ← xcodegen source-of-truth project spec
├── build.sh                        ← xcodegen + xcodebuild + run
├── HALockBridge.entitlements       ← com.apple.developer.homekit
├── DevelopmentTeam.xcconfig.example← copy to .xcconfig (gitignored)
├── scripts/
│   ├── install.sh                  ← build + copy to /Applications/ (contributor convenience)
│   └── uninstall.sh                ← remove app (+ optional --purge config)
├── Resources/
│   ├── generate_icon.py            ← regenerate the app icon from scratch
│   └── Assets.xcassets/AppIcon.appiconset/
└── Sources/HALockBridge/
    ├── AppDelegate.swift           ← bootstraps everything
    ├── MainSceneDelegate.swift     ← hosts the SwiftUI status window
    ├── StatusView.swift            ← SwiftUI pairing/status UI
    ├── StatusViewModel.swift       ← observable state for the window
    ├── StatusBarController.swift   ← menu bar item (Status/Reset/Start at Login/Quit)
    ├── LoginItemManager.swift      ← SMAppService wrapper for Start at Login
    ├── HomeKitMonitor.swift        ← HMHomeManager observer + state store
    ├── AccessoryState.swift        ← Codable lock state + lifecycle derivation
    ├── BridgeServer.swift          ← NIO HTTP + WebSocket server
    ├── BonjourService.swift        ← NetService.publish for zeroconf
    ├── PairingManager.swift        ← in-app pairing request lifecycle
    └── Config.swift                ← config.json schema + thread-safe TokenStore
```

## Runtime config

Lives at `~/Library/Application Support/HALockBridge/config.json`:

```json
{
  "instance_id": "<UUID, persistent across restarts>",
  "host": "0.0.0.0",
  "port": 8765,
  "paired_clients": {
    "<token>": { "client_name": "Home Assistant", "paired_at": "..." }
  }
}
```

Generated on first launch. **Never committed to the repo.** Tokens here grant
full lock control — keep this file private and don't share it.

## HTTP API

| Method + Path | Auth | Purpose |
|---|---|---|
| `GET /health` | none | Liveness probe, returns `accessory_count` |
| `GET /info` | none | Returns `instance_id` (used by HA's mDNS verification) |
| `POST /pair/initiate` | none | Body: `{"client_name": "..."}` → starts pair request. Returns 409 if already paired. |
| `GET /pair/status/{id}` | none | Returns `{"state": "pending"\|"approved"\|"denied"\|"expired", "token": "..."}` |
| `GET /accessories` | bearer | All healthy locks |
| `GET /accessories/{uuid}` | bearer | One lock |
| `POST /accessories/{uuid}/state` | bearer | Body: `{"target": "secured"\|"unsecured"}` |
| `WS /events?token=...` | bearer (in query) | Snapshot + state push |

## WebSocket protocol

Server-pushed JSON envelopes:

```json
{"type": "hello", "server": "ha-lockbridge", "version": "0.5.0"}
{"type": "snapshot", "accessories": [...]}
{"type": "state", "accessory": {...}}
{"type": "removed", "id": "<uuid>"}
```

Server sends a `ping` frame every 15s; closes if no `pong` within 30s.

New accessories paired into Apple Home while the bridge is running are picked
up automatically (via `HMHomeDelegate`) and pushed to all connected WS clients
as `state` events.
