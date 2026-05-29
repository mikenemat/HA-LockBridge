# Changelog

All notable changes to HA-LockBridge are documented here.
This project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html) and
follows the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.

## [0.5.0] — 2026-05-28

### Changed
- **Distribution pivot: Mac App Store, not Developer ID.** A spike with the
  paid Apple Developer Program confirmed that Apple silently strips the
  `com.apple.developer.homekit` entitlement from any Developer ID
  provisioning profile, regardless of what's checked on the App ID. HomeKit
  on macOS is App-Store-only by policy. The whole Developer ID + notarized
  GitHub Release pipeline (`.github/workflows/release.yml`,
  `macos-app/scripts/release.sh`, the v0.4.1–v0.4.5 release attempts) is
  removed. End-user installs from source for now; App Store listing is in
  preparation.
- **App is now sandboxed.** Added `com.apple.security.app-sandbox`,
  `com.apple.security.network.server`, and `com.apple.security.network.client`
  entitlements (required for App Store). A spike confirmed `HMHomeManager`,
  Bonjour publish, and the HTTP/WS server all work cleanly under sandbox
  with no additional restricted entitlements (notably no
  `com.apple.developer.networking.multicast`, which would have needed
  separate Apple approval). One-time effect for existing users: the config
  path moves from `~/Library/Application Support/HALockBridge/` to the
  per-app sandbox container at
  `~/Library/Containers/<bundle-id>/Data/Library/Application Support/HALockBridge/`,
  orphaning paired-client tokens. Re-pair with HA on upgrade.
- **Auto-start at login moved into the app.** The previous shell-script
  LaunchAgent workflow (`install-launchagent.sh`, `uninstall-launchagent.sh`,
  `launchagent.plist.template`, `launch-wrapper.sh`) is replaced by an
  in-app **Start at Login** toggle in the menu bar, backed by
  `SMAppService.mainApp`. macOS surfaces the registration under System
  Settings → General → Login Items; auto-cleanup happens when the app is
  removed.
- **Stable accessory IDs.** The wire ID HA tracks is now a SHA-256 hash of
  `manufacturer + model + serial_number`, not `HMAccessory.uniqueIdentifier`.
  The latter is per-app on macOS — every time the app's signing identity
  changes (cert rotates, paid-vs-free swap, reinstall), the old UUIDs got
  re-issued and HA's entities orphaned. The hashed ID survives all of
  this. One-time migration: existing entities become orphans on upgrade;
  Reload the integration once and reconfigure to clean them up.
- **Versions aligned across both halves.** macOS app + HA integration both
  ship at `0.4.1`. The Bonjour TXT-record `version` field also bumped
  (was stuck at `0.1`).

### Added
- **Notarized release distribution.** New `scripts/release.sh` builds with
  the Developer ID Application cert, submits to Apple's notary service,
  staples the ticket, and bundles `HA-LockBridge.app` + the HACS-installable
  HA integration + a brief install README into a single GitHub Releases zip.
- **Live HA-connected indicator** in the Stats & Debug page (green/red dot
  + remote IP). Updates in real time via a `BridgeServer.onConnectionsChanged`
  callback wired into the view model.
- **Serial number read** added to the per-accessory info read set
  (`HMCharacteristicTypeSerialNumber`). Surfaced in `/accessories` as
  `serial_number` and used as the stable-ID hash input.

### Security
- **Removed the PIN-fallback pair path.** `/pair/approve?id=X&pin=Y` and
  `/pair/deny?id=X&pin=Y` are gone, along with the PIN generation, the PIN
  display in the status window, and the stderr log line that emitted the
  PIN in plaintext. The PIN was token-equivalent (a successful PIN-auth
  call issued a real bearer), so any process with read access to
  `/tmp/ha-lockbridge.err` could have paired as a fake HA. The SwiftUI
  status window's Approve/Deny buttons are now the only auth path.
- **HA integration redacts the WS URL** in log output. Previously
  `_LOGGER.warning("Attempting WS connect to %s", self._ws_url)` emitted
  `ws://host:port/events?token=…` with the live bearer token in the query
  string — a leaky default at WARNING level. The integration now logs a
  token-stripped URL.

### Fixed
- **The post-pair "entities unavailable" bug** turned out to be two compounding
  problems:
  1. HA's WebSocket request reused the TCP connection from the prior
     `/accessories` HTTP GET (via aiohttp's shared session pool). NIO's
     `HTTPServerUpgradeHandler` removes itself from the pipeline after the
     first request on a connection (per HTTP-upgrade-is-per-connection
     semantics), so a WS upgrade on a reused connection has no upgrader to
     intercept it — request falls through to the regular HTTP handler and 404s
     `/events`.
  2. The naive fix (give the WebSocket its own `aiohttp.ClientSession`) broke
     `.local` hostname resolution: a plain `ClientSession` uses Python's stdlib
     DNS resolver, which can't resolve mDNS names in HA's container.
  Both fixed by giving the WS its own `aiohttp.TCPConnector(force_close=True,
  resolver=aiohttp.ThreadedResolver())`:
  - `force_close=True` → every connect is a brand-new TCP socket, never pooled
    alongside HTTP requests, so the bridge's per-connection upgrade handler is
    always installed
  - `ThreadedResolver` → uses `getaddrinfo` (via nsswitch + nss-mdns) so
    `.local` hostnames resolve. The default `AsyncResolver` (when `aiodns` is
    installed, as on HA) uses c-ares, which doesn't speak mDNS.

  Note: `async_create_clientsession(hass)` does NOT solve this — it reuses
  HA's global connector, so the connection pool (and the no-force-close
  behavior) is shared.
- **Thread-safety in TokenStore.** Added an `NSLock` around `paired_clients`
  access. This wasn't the actual cause of the 404 (above), but the race was
  real and worth closing.
- **HA WS connection flapping** caused by aiohttp's `receive_timeout` firing
  during idle (control frames don't reset it). HA client now uses
  `heartbeat=15` so it pings the bridge actively, plus a more generous
  `receive_timeout=60`.
- **`via_device` deprecation warning** at entity creation. HA was warning
  this would stop working in 2025.12.0; that deadline has passed but HA kept
  the back-compat. Either way, the integration now registers itself as a
  hub device before forwarding platform setup, so the warning is gone.

### Added
- **Runtime accessory discovery.** The bridge implements `HMHomeDelegate` so
  new locks paired into Apple Home while the bridge is running are picked up
  automatically. Options Flow on the HA side surfaces them in the
  device-selection list — no re-pairing required.
- **`scripts/install.sh` + `scripts/uninstall.sh`** helpers that copy the
  built .app to `/Applications`, optionally install the LaunchAgent for
  auto-start at login (default NO), and clean up on uninstall.

## [0.2.0] — 2026-05

First public-ready cut.

### Added
- **Bonjour discovery + click-to-pair UX.** Bridge advertises itself via mDNS;
  HomeAssistant auto-discovers and prompts to pair. No host/port typing.
- **In-app SwiftUI pairing window** with Approve/Deny buttons, auto-countdown
  hide after pairing, and a stable status footer.
- **Multi-client support.** Bridge maintains a `paired_clients` dict so multiple
  HomeAssistant instances can connect independently, each with its own token.
- **Hostname/IP change resilience.** Bridge identity is a UUID in Bonjour TXT
  records, not the hostname. HA's stored entry auto-updates host/port on
  re-discovery (Mac rename, IP change, etc.).
- **5-state lifecycle.** Bridge derives `locked` / `unlocking` / `unlocked` /
  `locking` / `jammed` from current+target+timing, mapped directly to HA's
  `LockEntity` state properties so animations render natively.
- **ThorBolt model auto-prefix.** Sleekpoint Innovations devices reporting bare
  model strings (e.g. `X1`) are rewritten to `ThorBolt X1`.
- **Battery + low-battery + jammed sensors** as diagnostic entities per lock.
- **Ghost-accessory filtering.** Locks never reachable enough to read
  manufacturer info are hidden from the API entirely.
- **App icon + HA integration icon.**
- **LaunchAgent install/uninstall scripts** for auto-start at login.

### Changed
- Bundle ID is now `io.github.mikenemat.HALockBridge` (was an internal
  dev ID).
- Bearer-token-paste UX retired in favor of click-to-pair.
- Macros notification path removed (it was unreliable for `.accessory` apps).

### Security
- All tokens are 32-byte randomly generated and persisted only to
  `~/Library/Application Support/HALockBridge/config.json` with mode 0600.
- Pair requests expire 5 minutes after creation; PIN fallback verifies caller.

## [0.1.0] — initial sketch (internal)

- HomeKit framework integration via Mac Catalyst
- HTTP + WebSocket server with bearer-token auth
- HomeAssistant custom integration consuming the API
