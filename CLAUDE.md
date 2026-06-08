# Claude / AI-agent context

This file is the project-specific guidance loaded by [Claude Code](https://claude.com/claude-code)
and respected by other AI coding assistants that look for `CLAUDE.md` at the repo
root. It captures the load-bearing decisions and quirks that aren't obvious
from reading the code.

If you're a human contributor, [README.md](README.md) is what you want.

## Repo layout

```
.
├── macos-app/                                 Mac Catalyst Swift app
└── custom_components/ha_lockbridge/   HA integration
```

The two directories are coupled through an HTTP + WebSocket protocol; treat
them as one product with two halves.

## What this project IS and what it ISN'T

**Is:** A side-channel bridge that lets HomeAssistant read/write HomeKit lock
accessories *while they remain paired with Apple Home*. The Mac running this
app is a *second* HomeKit controller in the home (alongside iPhone, Apple Home
app, etc.) — it never disrupts the primary pairing.

**Is NOT:**
- A HomeKit accessory protocol (HAP) re-implementation. We use Apple's
  `HMHomeManager` directly. No HAP packet crafting.
- A HomeKey emulator. HomeKey continues to work because the lock stays in
  Apple Home with its existing reader/endpoint keys; we don't touch that path.
- A general HomeKit-to-HA bridge — it's scoped to *locks* specifically (the
  one category where breaking the Apple Home pairing has serious costs).

## Architectural decisions that aren't reversible cheaply

1. **Mac Catalyst, not pure macOS.** Apple removed `HomeKit.framework` from the
   plain macOS SDK in macOS 15+; it's only in `iOSSupport` now. The Catalyst
   target triple (`arm64-apple-ios18.0-macabi`) is mandatory.

2. **App must be sandbox-free + use the `com.apple.developer.homekit`
   entitlement.** That entitlement is "restricted," meaning ad-hoc signing is
   rejected by AMFI. The app must be signed with a real provisioning profile.
   Release builds use the paid Developer ID Application cert (12-month
   profiles, notarized via `scripts/release.sh`). Contributors building
   locally with a free Personal Team will see 7-day profile rotation —
   that's expected, just rebuild.

3. **Appliance mode: the app is a normal foreground app, NOT a hidden
   menu-bar utility** (changed in 0.6.0). It runs `.regular` with
   `LSUIElement: false`, shows a Dock icon and a single always-visible
   window, keeps the display awake (`beginActivity` with
   `.idleDisplaySleepDisabled`), and **grabs focus when HA issues a lock
   write** (`HomeKitMonitor.onWriteRequested` → `activateApp()`). This is
   load-bearing, not cosmetic: HomeKit only services accessory *writes*
   promptly for the **frontmost/active app** — a backgrounded controller has
   its writes deferred tens of seconds or stalled (confirmed empirically;
   it's a documented HomeKit limitation, see git history / the README
   appliance section). The window's close + minimize buttons are hidden
   (`disableWindowDismissal`) because either would background the app and
   break writes; quit via the in-window button or ⌘Q.
   **Do not** try to make this headless again (hidden window, `.accessory`
   policy, menu-bar-only) — the entire prior four-layer window-hider +
   `StatusBarController` apparatus was removed precisely because a hidden
   bridge can't control locks. Run it on a dedicated Mac.

4. **The bridge identifies itself via a UUID in Bonjour TXT records, not via
   hostname.** This is what makes Mac renames / IP changes survivable. The HA
   integration uses that UUID as its config entry `unique_id` and relies on
   HA's `_abort_if_unique_id_configured(updates=…)` to auto-update host/port
   on re-discovery. **Don't tie identity to a hostname** — always use the UUID
   from `/info` or the Bonjour TXT.

5. **In-app pairing UI is the only Approve/Deny path.** Earlier versions also
   shipped a PIN-in-stderr / `/pair/approve?id=X&pin=Y` fallback and a
   `UNUserNotificationCenter` flow. Both removed: notifications are denied
   for `.accessory` apps too often, and the PIN log line leaked a
   token-equivalent secret to `/tmp/ha-lockbridge.err`. The SwiftUI status
   window's Approve/Deny buttons are now the sole mechanism — pair requests
   that arrive while the bridge is headless will simply sit pending until
   the user is at the Mac.

6. **Bridge filters out "ghost" HomeKit accessories** (ones that never reported
   manufacturer info because they were unreachable throughout discovery)
   *before* exposing them via the API. Filtering is on the bridge side, not in
   the HA integration — keeps the API surface clean for any future consumer.

7. **Lifecycle state derivation is on the bridge.** The bridge synthesizes
   `lifecycle_state` (one of `locked`/`unlocked`/`locking`/`unlocking`/
   `jammed`/`unknown`) using a 15s transition window after `target_state`
   changes. HA maps this directly to `LockEntity.is_locked` /
   `is_locking` / `is_unlocking` / `is_jammed`. Keep the timing logic on the
   bridge — duplicating it in HA invites drift.

8. **HA's `start_ws_loop()` is called AFTER `async_forward_entry_setups`.**
   The opposite order races: the first WS connect's `SIGNAL_CONNECTED`
   dispatch can fire before any entity has subscribed, leaving them stuck
   reporting `available=False`. See `homeassistant/.../__init__.py`.

## Build / test commands

Both `xcodegen` (Homebrew) and `Pillow` (for icon regeneration) are required.

```bash
# Bridge
cd macos-app
brew install xcodegen
cp DevelopmentTeam.xcconfig.example DevelopmentTeam.xcconfig
# edit DevelopmentTeam.xcconfig with your Apple Developer Team ID
./build.sh                                  # builds and runs
./build.sh --toggle "Front Door"            # CLI test mode (no HTTP server)
python3 Resources/generate_icon.py          # regenerate the app icon

# HA integration validation (syntax + JSON only — actual entity behavior
# requires a running HA)
cd custom_components/ha_lockbridge
for f in *.py; do python3 -m py_compile "$f"; done
python3 -c "import json; json.load(open('manifest.json'))"
```

## Things to NOT do

- **Don't pair the lock directly with HA.** That's the whole problem this
  project exists to avoid. HA's built-in `homekit_controller` integration
  does this and breaks HomeKey.
- **Don't add macOS-only API calls.** The app is Catalyst — you only have
  the iOSSupport-overlay frameworks. AppKit access is via the dynamic
  Objective-C runtime bridge in `AppDelegate.swift` (see
  `setAppKitActivationPolicy`, `centerNSWindow`).
- **Don't store secrets in source.** The Apple Developer Team ID belongs in
  `macos-app/DevelopmentTeam.xcconfig` (gitignored). Bearer tokens live in
  `~/Library/Application Support/HALockBridge/config.json`, never in the
  repo.
- **Don't reach for `UNUserNotificationCenter`.** Already tried, doesn't
  reliably work for `.accessory` apps. See item 5 above.
- **Don't change the bundle ID lightly.** Each new bundle ID requires a
  fresh provisioning profile + Xcode GUI step to add HomeKit capability,
  plus a new HomeKit TCC consent prompt on launch.
- **Don't filter ghost accessories in the HA integration.** That belongs on
  the bridge side. The integration should be a "dumb pipe" for what the
  bridge tells it.

## When you change the wire protocol

Update *both* sides:
1. `macos-app/Sources/HALockBridge/BridgeServer.swift` (server side)
2. `macos-app/Sources/HALockBridge/AccessoryState.swift` (shared schema)
3. `custom_components/ha_lockbridge/client.py` (parses
   what the bridge sends)
4. Update both READMEs' protocol tables if endpoints change.

## When you change the HA integration's `manifest.json`

Bump the `version` field. HA only reloads the integration if the version
changes. Forgetting this means your code changes don't take effect even after
a HA restart in some cases.

## Useful diagnostics

- `dns-sd -B _ha-lockbridge._tcp local.` — confirm the bridge is advertising
  via Bonjour.
- `curl http://<bridge-host>:8765/health` — no auth, confirms the server is
  alive.
- `curl http://<bridge-host>:8765/info` — no auth, returns `instance_id` so
  you can verify HA is talking to the right bridge.
- `log stream --predicate 'process == "HA-LockBridge"'` — live bridge logs
  via the unified macOS log system (if the bridge uses `os_log`, which it
  currently does NOT — bridge logs go to stderr).

## Reading the bridge's own logs

The bridge prefixes log lines so you can grep by component:

- `[ha-lockbridge] …` — HomeKit monitor (accessory discovery, state)
- `[lockbridge-server] …` — HTTP/WS server + pairing manager + Bonjour

Both go to stderr. `build.sh` strips one specific UIKit noise line
(`Unable to find global key UIWindow`) which is benign — don't try to
silence it inside the app, the Catalyst window-creation timing makes that
fragile.
