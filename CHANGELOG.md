# Changelog

All notable changes to HA-LockBridge are documented here.
This project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html) and
follows the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.

## [0.6.6] — 2026-06-15

### Fixed
- **Home-name prefix stays consistent across multi-home sync lag and home
  renames.** Follow-up to 0.6.5, from an adversarial QA pass: the `<Home>` prefix
  is gated on `homes.count > 1`, read per-publish. If iCloud delivered a second
  HomeKit home *after* the first home's locks were already published, those
  first-home locks kept their bare (un-prefixed) name while the new home's locks
  were prefixed — an asymmetric display until unrelated activity republished
  them. The bridge now re-publishes all tracked locks whenever the home set
  changes (home added/removed), and refreshes the prefix live on a home rename
  (new `homeDidUpdateName` delegate). Display-only: re-publishing goes through
  the normal identity-cache path keyed on the stable accessory UUID / serial
  hash, so wire ids, HA `unique_id`s, and entities are untouched — verified by
  the QA repros (no orphan, no duplicate).

### Changed
- `MARKETING_VERSION` 0.6.5 → 0.6.6, `CURRENT_PROJECT_VERSION` 19 → 20.

## [0.6.5] — 2026-06-15

### Added
- **Lock names are prefixed with the HomeKit home name in multi-home setups.**
  When the bridge sees more than one HomeKit home, it now sends the home name
  alongside each lock, and both the app's lock list and Home Assistant display
  it as `<Home> <Lock>` (e.g. "Beach House Front Door"). Single-home setups are
  unchanged. In HA the prefix cascades to the lock's battery/jammed/low-battery
  entities too, and the device-selection picker groups locks by home.

  **Non-breaking by construction:** the home name is a new additive wire field
  (`home`) that older integrations ignore and older bridges omit; it is never
  part of a lock's wire id / HA `unique_id` / device identifiers, so existing
  devices and entities are only **relabeled** — `entity_id`s, automations, and
  pairings are untouched. Identity (`stableID` + the identity cache) still keys
  on the bare accessory name.

### Changed
- `MARKETING_VERSION` 0.6.4 → 0.6.5, `CURRENT_PROJECT_VERSION` 18 → 19.
- HA integration `manifest.json` 0.6.0 → 0.6.1.

## [0.6.4] — 2026-06-15

Large hardening + features batch from the TODO.md backlog. **The Home Assistant
integration (bumped to 0.6.0) stays fully backward-compatible with older bridge
versions** — every new wire field/envelope is additive and read defensively, and
the WS still authenticates against bridges that only accept the `?token=` query.

### Bridge (macOS app)

#### Security
- **Bearer token no longer written to bridge logs** — the WS-upgrade debug line
  logged the full `?token=` URI on every connect. It now logs only the path.
- **Pairing window hardened:** a second `/pair/initiate` is refused (409) while a
  request is pending (kills the banner-swap confused-deputy); the approval banner
  shows the requester's IP and only clears for the matching request id; terminal
  pair requests are hard-deleted and their token nulled after the first approved
  poll; `client_name` is length-bounded.

#### Reliability & correctness
- **Emit `removed` when a lock's wire id changes** — the root fix for the
  duplicate-lock bug the 0.5.3 integration worked around.
- Fixed an HMError-82 retry double-fire (timer + reachability waiter racing).
- Superseded writes now revert to the genuine last-known state, not a frozen
  transition snapshot.
- Guard against in-flight completions resurrecting a forgotten accessory as a
  phantom; identity-cache no longer swaps wire ids between same-named locks.
- Non-retryable write failures are now recorded in Lock Errors/Warnings.
- `SecRandomCopyBytes` failure is checked; oversized request bodies close the
  connection; HTTP idle/read timeout added.

#### Appliance robustness
- **Cmd-W / Cmd-M / titlebar-double-click can no longer background-or-close the
  window** (cleared style-mask bits + removed the menu commands).
- The post-write focus re-grab is cancelled once the write settles, and the grab
  is verified (`isActive`) with a Lock Errors entry if it fails.
- **iCloud-session-rot warning:** authorized-but-no-homes for 120s surfaces a
  banner (and `homes_visible` in `/health`).
- Startup failure (corrupt config / port in use) now shows an error screen
  instead of a lying "advertising" screen.
- Recent-activity / Lock-Errors lists are capped in the UI for months-long uptime.

#### New wire fields (all additive)
- `write_reverted` WS envelope, `protocol: 1` in the `hello` envelope and
  `/info`, `homes_visible` in `/health`.

### Home Assistant integration — 0.6.0 (back-compat with old bridges preserved)
- **Reauth flow:** a revoked token (e.g. after Reset Pairing) now starts HA's
  re-authenticate flow instead of looping forever; raises `ConfigEntryNotReady`
  when the bridge is unreachable at startup (no more permanent zero-entity entry).
- **Bridge-health binary sensor** on the hub device (driven by WS-connected state).
- **New locks appear without a restart** (dynamic entity creation), and a lock
  whose state is `unknown` now shows **Unknown** instead of **Unlocked**.
- **`ha_lockbridge_write_reverted` bus event** fired when the bridge gives up on a
  write (consumed from the new envelope; old bridges simply never send it).
- Tolerant `protocol` handshake (warn-only, never gates); the bridge `409
  already_paired` is surfaced with a clear message; removed accessories go
  unavailable instead of freezing; `SIGNAL_CONNECTED` is held until the first
  fresh snapshot; pair-flow edge cases and error-toast wrapping fixed.
- **Token hardening:** the token is no longer logged anywhere, and is sent via
  both the `Authorization` header and the existing `?token=` query (so older
  bridges keep authenticating).

### Docs / CI
- CLAUDE.md corrected (App Store release flow, sandboxed since 0.5.0, 90s
  transition window, Catalyst login-item note, wire-protocol bump rule);
  sandbox container config-path swept across PRIVACY/SECURITY/READMEs; CI now runs
  pytest authoritatively plus hassfest + HACS validation; contributor onboarding
  and the appliance-Mac setup checklist added.

### Changed
- `MARKETING_VERSION` 0.6.3 → 0.6.4, `CURRENT_PROJECT_VERSION` 17 → 18.
- HA integration `manifest.json` 0.5.3 → 0.6.0 (versioned independently of the app).

## [0.6.3] — 2026-06-15

### Fixed
- **"Start at Login" no longer shows a toggle that can't work.** The toggle was
  driven by `SMAppService.mainApp`, which does **not** function on Mac
  Catalyst: its status returns `.notFound` and registration never takes effect,
  so the toggle was permanently greyed out even from a correctly-installed
  /Applications App Store build. (ServiceManagement's "register the main app
  bundle itself" path is a native-macOS facility that doesn't recognize a
  Catalyst bundle; Apple documents the related `SMLoginItemSetEnabled` API as
  unsupported under Catalyst.) Replaced with an **"Open Login Items…"** button
  and a short note — add HA-LockBridge once in System Settings → General →
  Login Items, which is reliable and one-time.

### Added
- **"HomeAssistant Integration" link in the status-window footer**, below the
  pairing status / lock-count line, pointing at the GitHub repo.

### Changed
- `MARKETING_VERSION` 0.6.2 → 0.6.3, `CURRENT_PROJECT_VERSION` 16 → 17.

## [0.6.2] — 2026-06-08

### Fixed
- **System text-services panels no longer pop up when the app grabs focus.**
  On a pair request / lock command, `bringWindowToFront`'s no-key-window
  fallback called `orderFrontRegardless` on *every* window in the app's list —
  including the macOS **Spelling & Grammar / Substitutions / Languages**
  NSPanels the system parks there — surfacing them as stray popups. The
  NSPanel-skipping filter that used to prevent this lived in the window-hider
  removed during the 0.6.0 appliance-mode refactor; a code path that needed it
  (`bringWindowToFront`, still called on every focus-steal) survived without
  it. The fallback now skips NSPanels and fronts only our content window.

### Added
- **Build version shown in the status-window footer** (e.g. `v0.6.2`), so the
  running build is confirmable at a glance while debugging.

### Changed
- `MARKETING_VERSION` 0.6.1 → 0.6.2, `CURRENT_PROJECT_VERSION` 15 → 16.

## [0.6.1] — 2026-06-08

### Fixed
- **Reset Pairing now transitions the view.** The reset-confirm **Cancel**
  button (meant to return to the stats panel) and the post-reset transition
  (meant to return to the waiting screen) both did nothing — an over-cautious
  `if display == .resetConfirm { return }` guard in `refreshMainView()`
  blocked the very paths that needed to leave that screen, so a reset left the
  view stuck until an app restart. Removed the guard.
- **"Start at Login" disabled state now explains itself.** When SMAppService
  can't register a login item (app run from a build folder / translocated dev
  build → status `.notFound`), the greyed-out toggle shows "Move the app to
  /Applications to enable" instead of looking broken.

### Changed
- **Appliance mode: the bridge is now a normal foreground app, not a hidden
  menu-bar utility.** This is the fix for the long-running "locks respond
  slowly unless the app is focused" problem. HomeKit only services accessory
  *writes* promptly for the **frontmost/active app** — a backgrounded or
  hidden controller has its writes deferred by tens of seconds or stalled
  until something brings it forward. This is a documented HomeKit limitation,
  confirmed empirically (foreground-active works instantly; foreground-
  inactive and hidden both lag), with no API to opt out. So the app stops
  fighting to be headless and instead embraces being a visible foreground
  app on a dedicated Mac. Concretely:
  - **No menu-bar tray icon.** `StatusBarController` and its template images
    are removed entirely. All controls — **Start at Login**, **Reset
    Pairing**, **Quit** — now live in the app window.
  - **Always-visible window, `.regular` activation policy, `LSUIElement:
    false`.** The four-layer window-hider, rogue-NSWindow neutralizing,
    accessory-policy gymnastics, and the 5-second auto-hide on startup are
    all gone. There are now only two screens: *waiting for pairing* and the
    *stats/control panel* (with the pair approve/deny prompt shown inline as
    a banner, and a reset-confirm overlay).
  - **Grabs focus when HA issues a lock command.** `HomeKitMonitor` fires a
    new `onWriteRequested` hook at the top of `setLockState`; AppDelegate
    wires it to bring the app to the foreground/active so HomeKit services
    the write promptly.
  - **Keeps the display awake.** `beginActivity` options gain
    `.idleDisplaySleepDisabled` (on top of `.userInitiated`) — the screen
    lock is what drops an unattended Mac out of the active state, and its
    timer is gated on the display sleeping, so keeping the display awake
    keeps the session unlocked and the app frontmost.
  - **The window can't be closed or minimized** (`disableWindowDismissal`
    hides those buttons) — either would background the app and break writes.
    Quit via the in-window button or ⌘Q.
  - **Full, scrollable event history.** Both the *Recent activity* and *Lock
    Errors/Warnings* sections now retain their entire history for the app
    run (the ring-buffer caps of 50 / 100 and the 3 / 20 display limits are
    removed) and are individually scrollable (`LazyVStack` so long histories
    stay smooth). Each section header shows its live count, and the window
    grew to 840pt to fit the three scroll regions.
  - **Focus is returned after a write.** Before stealing focus for a lock
    command, the bridge records which app was frontmost; once the write
    settles (lock confirmed / reverted) it hands focus back, returning
    things to how they were. Focus-steal is also moved *after* the
    accessory-validity guards (an unknown-accessory request no longer yanks
    focus) and only restores once the *last* of any overlapping writes
    settles.
  - **More robust focus acquisition.** `activateApp` now calls both the
    modern cooperative `activate()` and the legacy
    `activateIgnoringOtherApps:` (the latter isn't gated on an activation
    token, so it's more reliable for a background self-activation), plus a
    second re-assert ~0.2s later — fixing occasional cases where a single
    activation didn't take.
  - **Recent activity row drops the client IP** (redundant with the
    HA-connected line in the footer); just the timestamp remains.
- **READMEs + CLAUDE.md** document the foreground-app behavior and the
  dedicated-Mac requirement.
- `MARKETING_VERSION` 0.5.11 → 0.6.1, `CURRENT_PROJECT_VERSION` 13 → 15
  (minor bump — this is a significant UX/deployment change; 0.6.0 was an
  in-development branch version, never released, folded into 0.6.1).

### Why a minor version bump
Existing users upgrading from 0.5.x will see the app stop hiding into the
menu bar and start showing a Dock icon + window. Intended for a dedicated
Mac; running it on a Mac you use interactively will lag lock commands
whenever another app is frontmost.

## [0.5.11] — 2026-06-05

### Fixed
- **App Nap was never actually disabled (0.5.9 regression fix).** 0.5.9
  held a `beginActivity` assertion with options
  `[.idleSystemSleepDisabled, .automaticTerminationDisabled,
  .suddenTerminationDisabled]` — which keeps the Mac awake and the process
  un-terminable but, per Apple's Energy Efficiency Guide, does **not**
  suppress App Nap. App Nap is keyed off the `.userInitiated` priority
  signal specifically. So the process was still being throttled whenever
  its window was hidden, which silently defeated *all three* recent
  reliability fixes: the retry backoff timers stayed coalesced, the WS
  keepalive ping (NIO scheduled task) still drifted past HA's 30s timeout,
  and even the 0.5.10 resubscribe `DispatchSourceTimer` was throttled.
  The options are now `[.userInitiated]`, which carries the App-Nap-
  suppressing priority bits and is a strict superset of the previous
  options (it already implies idle-system-sleep-disabled plus both
  termination flags). Confirm via Activity Monitor → CPU → "App Nap"
  column: with the window hidden it should now read **No**.

### Changed
- `MARKETING_VERSION` 0.5.10 → 0.5.11, `CURRENT_PROJECT_VERSION` 12 → 13.

## [0.5.10] — 2026-06-05

### Fixed
- **HomeKit subscriptions now self-heal over long uptime.** Previously the
  only thing that re-established characteristic notifications was a
  reachability transition to `true`. If `homed` restarted or silently
  dropped notification delivery (OS update, memory pressure, HomeKit
  daemon hiccup) *without* a reachability flip, the bridge stopped
  receiving state updates and HA went stale until the app was manually
  restarted — a real failure mode for a months-uptime bridge. Two
  safety nets added:
  1. **Periodic resubscribe pass** (every 3 min). Re-asserts notifications
     on every reachable tracked lock. `enableNotification(true)` is
     idempotent — a no-op on a healthy subscription, a revival on a
     dropped one. To avoid waking sleepy lock radios, the periodic pass
     re-enables all four notifying characteristics but only *reads* the
     current-lock-state value (the one whose staleness actually matters,
     and a cache-served read when the subscription is healthy).
  2. **homed-reload re-subscribe.** `considerAccessory` no longer silently
     short-circuits when HomeKit re-hands an already-tracked accessory
     (which happens on a homed reload). It now refreshes the stored
     `HMAccessory` reference + delegate and re-asserts notifications —
     fixing the case where homed hands back a *fresh* accessory instance
     and our delegate ends up registered on a dead object.
- **Characteristic subscription failures now retry.** `enableNotification`
  failures previously logged and gave up, leaving that characteristic
  non-notifying until a reachability flip. It now retries up to 3 attempts
  with 5s/15s backoff (mirroring the existing serial-number read), with
  the periodic resubscribe pass as the long-term backstop.

### Changed
- `MARKETING_VERSION` 0.5.9 → 0.5.10, `CURRENT_PROJECT_VERSION` 11 → 12.

## [0.5.9] — 2026-06-05

### Fixed
- **Bridge no longer gets throttled by App Nap when its window is hidden.**
  A headless `.accessory`-policy app with no visible window is the
  canonical App Nap target: macOS throttles the whole process, coalescing
  both main-queue `asyncAfter` retry timers AND NIO-scheduled WebSocket
  ping tasks. Symptom: lock commands would stall and HA's WebSocket could
  time out (the bridge pings every 15s; HA closes after 30s of silence)
  while the status window was hidden — and snap back to life the instant
  the window was opened, because making the app visible releases App Nap.
  The bridge now holds a process-lifetime
  `ProcessInfo.beginActivity(options: [.idleSystemSleepDisabled,
  .automaticTerminationDisabled, .suddenTerminationDisabled])` assertion,
  acquired before the HomeKit monitor and server start. This disables App
  Nap process-wide (un-throttling retry timers and the WS keepalive
  together) and additionally prevents idle system sleep — a sleeping Mac
  is a down bridge. Chosen over the `NSAppSleepDisabled` Info.plist key
  because (a) the plist key only addresses App Nap, not system sleep, and
  (b) Catalyst has a documented history of silently ignoring Info.plist
  keys in this project, whereas `beginActivity` is a Foundation call that
  definitely executes.
  Note: `.idleSystemSleepDisabled` prevents *idle* sleep, not lid-close or
  a manual sleep — correct for a desktop/Mac-mini bridge; keep the system
  Energy Saver "never sleep" setting as belt-and-suspenders.

### Changed
- `MARKETING_VERSION` 0.5.8 → 0.5.9, `CURRENT_PROJECT_VERSION` 10 → 11.

## [0.5.8] — 2026-06-05

### Removed
- **0.5.7's accessory characteristic dump.** The diagnostic served its
  purpose — confirmed empirically that neither ThorBolt X1 nor August
  Assure Lock 2 Plus implements `LockMechanismLastKnownAction`,
  `Logs`, or any sensor service (contact / motion) beyond the standard
  LockMechanism profile. Findings are captured in `IDEAS.md` along
  with the future-work proposals (external-state-change events,
  Heart Beat as a health signal) those findings inform. Removes the
  `diagSink` property on `HomeKitMonitor`, the `dumpAccessoryDiagnostic`
  method + helpers, the `accessory-dump.txt` file write in AppDelegate,
  and the stderr DIAG: lines. Functional behavior unchanged.

### Added
- **`IDEAS.md`** at repo root. Tracks optional future work that came
  out of the 0.5.7 investigation: external-state-change events on the
  Stats page (no source attribution but cleanly tags "bridge" vs
  "external"), Heart Beat / Sleep Interval as a leading-indicator
  health signal, and a "ruled out" section so we don't re-litigate
  the things we already confirmed aren't possible
  (`LockMechanismLastKnownAction`, iCloud user attribution, contact
  sensors, etc.).

### Changed
- `MARKETING_VERSION` 0.5.7 → 0.5.8, `CURRENT_PROJECT_VERSION` 9 → 10.

## [0.5.7] — 2026-06-05

### Added
- **One-shot accessory characteristic dump for diagnostics.** On every
  bridge startup, each tracked lock's full service + characteristic
  tree (with values, properties, and metadata including `validValues`
  for enum-typed characteristics) is written to a new
  `accessory-dump.txt` file next to `config.json`, and mirrored to
  stderr with a `[ha-lockbridge] DIAG:` prefix. Used to discover
  which extended characteristics each lock implements
  (`LockMechanismLastKnownAction`, `LockManagementAutoSecureTimeout`,
  `ContactState`, `MotionDetected`, `Logs`, etc.) so future versions
  can selectively surface them. Pretty-prints well-known HMService and
  HMCharacteristic UUIDs; falls back to `(unknown)` for vendor-custom
  types — a missing entry is still useful information (the raw UUID
  is always printed).
  The dump file is truncated at each bridge startup so it always
  reflects the current run, never accumulates across restarts. Sink
  is gated on `monitor.diagSink != nil` so CLI-test mode and tests
  skip it silently.

### Changed
- `MARKETING_VERSION` 0.5.6 → 0.5.7, `CURRENT_PROJECT_VERSION` 8 → 9.

## [0.5.6] — 2026-06-05

### Changed
- **Background-write retry budget 30s → 90s** (and the matched
  `transitionWindow` in `deriveLifecycle` along with it). Real-world
  testing showed sleeping locks commonly take 30–60s to wake when
  prodded by `homed` — the previous 30s budget was reverting commands
  that would have succeeded at ~45s. The new 90s window covers nearly
  all observed wake-up paths while still capping unbounded delays for
  the genuinely-unreachable case.
- **Backoff schedule extended** from `[1, 2, 4, 8]`s to
  `[1, 2, 4, 8, 16]`s capped, so cumulative retries (1+2+4+8+16×5 ≈
  95s) fit inside the new deadline with slack. Reachability-recovery
  callbacks still short-circuit the backoff timer on the fast path,
  so the schedule only matters when the lock stays asleep.
- `MARKETING_VERSION` 0.5.5 → 0.5.6, `CURRENT_PROJECT_VERSION` 7 → 8.

### Added
- **"Performance" section in the top-level README and the HA
  integration README.** Sets expectations clearly: awake locks respond
  in under a second; sleeping locks can take up to 90s while the
  bridge handles wake-up retries transparently. Explains why (HomeKit
  radios sleep aggressively for battery) and how the bridge handles
  it (optimistic accept + background retry + silent revert on
  exhaustion).

## [0.5.5] — 2026-06-05

### Changed
- **Status window is taller (570pt → 720pt, +26%).** The "Lock
  Errors/Warnings" section added in 0.5.3 squeezed every other section
  when populated. The extra 150pt mostly benefits the warnings
  section's internal ScrollView: its `frame(maxHeight:)` cap raised
  from 140pt to 240pt, so ~10+ event rows are visible at once when
  the bridge is actively reporting health events. Empty state stays
  compact — the ScrollView is only rendered when there are events to
  show. Width unchanged at 440pt.
- `MARKETING_VERSION` 0.5.4 → 0.5.5, `CURRENT_PROJECT_VERSION` 6 → 7.

## [0.5.4] — 2026-06-05

### Fixed
- **Wire-protocol version no longer lies.** Three places that publish a
  "version" field — the Bonjour TXT record, the WebSocket `hello`
  envelope, and the `/info` HTTP endpoint — all carried a hardcoded
  `"0.5.0"` literal that survived through 0.5.1/0.5.2/0.5.3 (the
  marketing version moved; this didn't). `curl /info` was lying about
  which build was running, which is a real footgun for anyone
  debugging a misbehaving deployment.
  All three now read `CFBundleShortVersionString` at runtime via a
  new `Bundle.bridgeMarketingVersion` extension (Version.swift), so
  the value can't drift again — it's the same source the App Store
  uses for the user-visible version.

### Changed
- `MARKETING_VERSION` 0.5.3 → 0.5.4, `CURRENT_PROJECT_VERSION` 5 → 6.

## [0.5.3] — 2026-06-05

### Added
- **"Lock Errors/Warnings" section on the Stats & Debug page.** Surfaces
  the rough edges that 0.5.2 handles transparently behind the scenes, so
  the user can see when the system is healing things on their behalf
  (and when it isn't). Two event types are recorded into a new ring
  buffer (`LockEventLog`, capacity 100) and shown in a 140pt-tall
  scrollable list, most-recent first:
  - **Write retries.** Open on the first `HMError 82` for a setLockState
    command, advance per attempt, close with one of four outcomes
    — `ongoing` (live), `succeeded` (retry resolved), `reverted` (30s
    budget elapsed, optimistic state silently reverted), or
    `satisfiedExternally` (current_state reached target via HomeKey /
    manual / another controller while we were retrying). Single-attempt
    successes don't create an event — only the rough edges are shown.
  - **Reachability gaps.** Opened when `HMAccessory.isReachable` goes
    `false` (including the startup-already-unreachable case), closed
    with the wall-clock duration when it returns to `true`. Open gaps
    render as "currently unreachable — Xs"; closed gaps as
    "unreachable — recovered" with the final duration.
- New `LockEventLog` class follows the existing `InteractionLog` pattern
  (thread-safe ring buffer, `onChange` callback, AppDelegate forwards
  snapshot into `StatusViewModel.recentLockEvents` `@Published`,
  StatusView renders). Injected into `HomeKitMonitor` the same way
  `identityCache` is.

### Changed
- `MARKETING_VERSION` 0.5.2 → 0.5.3, `CURRENT_PROJECT_VERSION` 4 → 5.

## [0.5.2] — 2026-06-05

### Fixed
- **Transient "lock unreachable" failures no longer surface as 502 errors in
  HA.** Apple's `homed` daemon returns `HMError 82 (accessory not reachable)`
  from a cached probe state when the HomeKit hub has briefly lost contact
  with the lock; in practice the underlying radio link recovers within
  seconds to ~half a minute. Previously the bridge synchronously waited
  on the write and surfaced the failure to HA as a 502, leaving the lock
  entity in an error state that required user retry. The bridge now
  accepts the command *immediately* with an optimistic
  `lifecycle_state = "locking"/"unlocking"`, returns 200 OK to HA in
  ~100ms so the UI flips to the "in-progress" indicator without
  perceptible delay, and retries the underlying HomeKit write in the
  background for up to 30 seconds. On success the real `current_state`
  arrives via the existing observer pipeline; on exhaustion the
  optimistic state is silently reverted (no error toast — the lock UI
  flips back to its last-known state). A reachability-recovery callback
  fires the next retry immediately when HomeKit's `isReachable` flips
  back to true, avoiding wasted backoff wait on the fast-recovery path.
- **External lock operations during a pending retry cancel the retry.**
  If someone taps a HomeKey, manually operates the lock, or another
  HomeKit controller successfully writes the same target while our
  background retry is still running, the bridge cancels the retry as
  soon as the live `current_state` matches the pending target. No
  competing writes to homed.
- **Commands accepted even when `accessory.isReachable == false`.** The
  property's value can be stale (cached from the last probe), and the
  underlying link often recovers within the retry window. The previous
  synchronous early-out short-circuited too aggressively.

### Changed
- `transitionWindow` in `deriveLifecycle` 15s → 30s, matching the new
  background write retry budget. HA's UI shows "locking"/"unlocking" for
  the entire retry window without prematurely settling.
- `MARKETING_VERSION` 0.5.1 → 0.5.2, `CURRENT_PROJECT_VERSION` 3 → 4.
- HA integration `manifest.json` version 0.5.0 → 0.5.2 (was lagging the
  bridge; bumped now so HA reloads the integration to pick up the new
  optimistic-state handling).

### Notes
- `SetLockResult.unreachable` and `.timeout` are now unused on the
  setLockState path but retained in the enum for source compatibility
  with `BridgeServer.handleSetState`'s response mapping; if either is
  ever produced by a future code path it'll still translate to the
  same HTTP status as before.

## [0.5.1] — 2026-06-05

### Fixed
- **Wire-IDs survive re-signs.** HA was orphaning lock entities every time
  the bridge got re-signed (free-tier 7-day cert rotation, paid Developer
  Program profile renewal, bundle-ID changes, etc.) because
  `HMAccessory.uniqueIdentifier` is per-app and rotates on every signing
  identity change, and any accessory whose SerialNumber characteristic
  hadn't been read in time would publish that rotating UUID as its wire
  ID. The new `AccessoryIdentityCache` (persisted to
  `accessory-identity.json` next to `config.json`) pins each lock's wire
  ID at first sight and keeps it stable across re-signs via a
  `(home, accessory name)` secondary index — after a re-sign the cache
  recognizes the lock under its rotated HMAccessory UUID and reuses the
  previously-pinned wire ID.
- **First publish doesn't pin a temporary fallback.** `recomputeAndPublish`
  now defers committing a wire ID to the cache until the SerialNumber
  characteristic has either been read successfully or has been
  demonstrated unreadable after retries. Previously the "initial" publish
  raced ahead of the async SerialNumber read and pinned the fallback
  HMAccessory UUID even for locks whose proper content-addressed
  serial-hash ID would have arrived seconds later.
- **SerialNumber reads retry on failure.** HomeKit reads of
  `HMCharacteristicTypeSerialNumber` now retry up to 3 attempts with 5s/30s
  backoff. After all attempts fail the cache pins the current
  HMAccessory.uniqueIdentifier as the wire ID, and the (home, name)
  index keeps it stable across future re-signs — so even locks whose
  serial read fails permanently end up with a re-sign-safe identifier.
- **Blank ghost window after the briefStatus countdown.** UIKit's
  `UIWindow.isHidden = true` doesn't reliably propagate to the backing
  NSWindow on Catalyst, so on first start the briefStatus countdown
  would finish and leave a window showing only the system-painted title
  bar (no SwiftUI content) instead of disappearing. The orderOut path
  now filters NSWindow vs NSPanel by class rather than relying on a
  capture that raced Catalyst's UIWindow → NSWindow materialization.
- **Spell-check / language-picker popups on Close stay gone.** The new
  class-based filter (skip NSPanels) achieves the same goal as the
  previous explicit-capture approach without the capture race.
- **Reset Pairing forcibly closes WebSockets.** Token auth runs only at
  the WS upgrade handshake; HA's WS connection used to outlive its
  revoked token, making Reset Pairing feel like a no-op until the app
  was restarted. Now the WS drops immediately, HA's client surfaces the
  disconnect, and re-pairing works without a restart.

### Added
- `macos-app/ExportOptions.plist` for `xcodebuild -exportArchive` with the
  Mac App Store distribution method. Generates a local `.pkg` for review
  + upload via Transporter or `xcrun notarytool` rather than auto-shipping
  to App Store Connect.
- `schemes` block in `macos-app/project.yml` so `xcodegen generate`
  produces a shared scheme without needing a prior Xcode-GUI open.

### Changed
- `MARKETING_VERSION` 0.5.0 → 0.5.1, `CURRENT_PROJECT_VERSION` 2 → 3.

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
