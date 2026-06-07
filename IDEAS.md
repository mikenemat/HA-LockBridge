# Ideas / Optional Future Work

Improvement ideas that aren't on the immediate roadmap. None of these
are committed work — they're "we could do this if it turns out to
matter." Captured here so they don't get lost in chat scrollback.

Each idea has enough context (mechanism, files touched, rough effort)
that future-us can pick it up cold.

---

## 1. External state change events on the Stats page

**What.** Add a new `LockEventLog.Kind` variant —
`externalStateChange(newState: "locked" | "unlocked")` — that fires
whenever a lock's `current_state` changes AND there's no in-flight
`setLockState` we initiated. Shows on the Stats page as e.g.
"Front Door — externally locked — 7:42:13pm". Optionally also emit
as an HA `event` entity so users can drive automations off "lock
state changed but not by this bridge."

**Why.** The 0.5.7 accessory dump confirmed that *neither* ThorBolt X1
nor August Assure Lock 2 Plus implements
`HMCharacteristicTypeLockMechanismLastKnownAction`, so we can't get
per-event source attribution (HomeKey vs keypad vs manual vs HomeKit
remote) from the standard HAP path. But we DO know what commands the
bridge itself issued, so we can cleanly tag state changes as "this
bridge" vs "external" — partial attribution without faking what we
don't have.

**Effort.** Small (~50 lines of Swift). No new characteristic
subscriptions needed; we already get `current_state` updates.

**Files.**
- `macos-app/Sources/HALockBridge/LockEventLog.swift` — new `Kind` variant
- `macos-app/Sources/HALockBridge/HomeKitMonitor.swift` — detection in `recomputeAndPublish`
- `macos-app/Sources/HALockBridge/StatusView.swift` — `formatLockEvent` rendering
- `custom_components/ha_lockbridge/` — optional HA event entity

---

## 2. Heart Beat / Sleep Interval as a lock health signal

**What.** Subscribe to the vendor "Heart Beat" characteristic (uint32,
notify-capable, present on BOTH ThorBolt X1 and August Assure Lock 2
Plus as `0000024A-0000-1000-8000-0026BB765291`). Track last received
tick per lock. Surface as:
- "Last heart beat: 8s ago" on the Stats page lock detail
- A new `LockEventLog` entry when a lock goes silent for >2× its
  configured Sleep Interval (`0000023A-…`, ThorBolt only) — a
  leading indicator of "lock dropped off the mesh," predicting
  unreachability *before* write attempts fail with HMError 82.

ThorBolt X1 also exposes "Thread Status" (`00000703-…`, uint16 0-127,
notify-capable). Could surface as a graded connectivity indicator if
we can decode the encoding empirically (likely a state enum, possibly
with signal strength in low bits).

**Why.** Would give the Lock Errors/Warnings section predictive
value — instead of only learning a lock is unreachable when HA tries
to use it, we'd surface it in advance from the bridge's own
observations.

**Effort.** Bigger. New characteristic subscriptions, new fields on
`AccessoryState`, new view rendering. Thread Status encoding needs
empirical reverse-engineering. Probably 2 commits.

**Files.**
- `macos-app/Sources/HALockBridge/HomeKitMonitor.swift` — extend
  `subscribeAndRead` to also subscribe to Heart Beat (and Thread
  Status on ThorBolt). Add `lastHeartBeat: [UUID: Date]` tracking.
- `macos-app/Sources/HALockBridge/AccessoryState.swift` — new fields
  (e.g. `last_heart_beat_seconds_ago`, `thread_status_raw`)
- `macos-app/Sources/HALockBridge/StatusView.swift` — lock detail UI
- Possibly `LockEventLog.swift` for the silent-too-long event

---

## Already ruled out (don't re-litigate)

- **`HMCharacteristicTypeLockMechanismLastKnownAction`** — the HAP
  standard for per-event source attribution (HomeKit / keypad /
  physical / auto-relock). Neither vendor implements it. Confirmed
  empirically via the 0.5.7 accessory dump.
- **`HMCharacteristicTypeLogs` (TLV8 event history)** — would have
  given a historical event log with per-event attribution. Neither
  vendor implements it.
- **iCloud user attribution** ("Locked by Alice"). Comes from Apple's
  private iCloud sync layer, NOT exposed to third-party apps via
  `HomeKit.framework`. No legitimate API path. Apple Home's display
  of who-did-what is using internal-only data.
- **Door contact sensors / handle motion sensors.** Neither vendor
  exposes a `ContactSensor` or `MotionSensor` service. Both are
  standard lock-mechanism profiles with no auxiliary sensing.
- **Vendor-custom characteristics on the ThorBolt
  `00000400-5E50-11EC-…` service.** 13 mostly-uint8 characteristics
  with no descriptions in the HAP metadata. Could be motor
  calibration, settings, event counters, etc. — but ship would
  require ThorBolt support docs (none public) or empirical
  reverse-engineering, neither of which is justified by the
  upside. Revisit if Sleekpoint ever publishes a developer doc.
