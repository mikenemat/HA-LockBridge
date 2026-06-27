import Foundation
import HomeKit

final class HomeKitMonitor: NSObject, HMHomeManagerDelegate, HMHomeDelegate, HMAccessoryDelegate {

    // MARK: - Public types

    enum PendingAction { case toggle, lock, unlock }

    struct PendingCommand {
        let nameOrUUID: String
        let action: PendingAction
    }

    enum SetLockResult {
        case ok(AccessoryState)
        case notFound
        case unreachable
        case homekitError(String)
        case timeout
    }

    /// State for an in-flight background write. setLockState returns to HA
    /// immediately with an optimistic state; the underlying writeValue is
    /// retried in the background within a budget (transient HMError 82
    /// "not reachable" responses from homed often resolve on their own once
    /// the HomeKit hub re-establishes contact with the lock — typically
    /// within seconds to ~half a minute). On exhaustion the optimistic
    /// state is silently reverted so HA's UI flips back to the last-known
    /// real state without an error toast.
    fileprivate final class PendingWrite {
        let target: Int
        let priorState: AccessoryState?
        let deadline: Date
        /// When this command was accepted. Used to compute the
        /// writeRetry event's duration on completion.
        let startedAt: Date
        var completed: Bool = false
        var triggered: Bool = false
        /// Set once homed has accepted the write (the writeValue completion
        /// returned no error). We then stop hammering writeValue and just
        /// wait for the lock to CONFIRM (current_state == target) or for the
        /// deadline to flag it `.unconfirmed`.
        var acked: Bool = false
        var attempt: Int = 0
        /// LockEventLog event ID for this command's retry record.
        /// Nil until the first HMError 82 fires — successful first-try
        /// writes don't create a log entry (the user only wants to see
        /// the rough edges, not every successful command).
        var retryLogEventID: UUID?

        init(target: Int, priorState: AccessoryState?, deadline: Date, startedAt: Date) {
            self.target = target
            self.priorState = priorState
            self.deadline = deadline
            self.startedAt = startedAt
        }
    }

    /// Backoff schedule for the background write retry loop. After exhausting
    /// the array we cap at the last value. Cumulative 1+2+4+8+16 ≈ 31s of
    /// retry potential, sized to fit the 30s deadline below. A
    /// reachability-recovery callback can fire the next retry immediately,
    /// ignoring the scheduled delay — so on the fast-recovery path the
    /// schedule is irrelevant.
    private static let writeBackoffDelays: [Double] = [1.0, 2.0, 4.0, 8.0, 16.0]
    /// Background write budget. Matched to the `transitionWindow` in
    /// `deriveLifecycle`. Standardized to 30s in 0.6.7 (was 90s).
    ///
    /// Two things happen at this deadline if the lock hasn't CONFIRMED the
    /// new state (current_state == target):
    ///   - lock still REACHABLE → we record an `.unconfirmed` warning and
    ///     LEAVE HA showing locking/unlocking (a deliberate "it didn't
    ///     respond" hang), until it confirms / is superseded / changes.
    ///   - lock UNREACHABLE → we revert (HA already shows it unavailable).
    /// The earlier 90s value was sized for slow deep-sleep wake-ups; per
    /// the maintainer those delays were really the pre-0.6.0 foreground
    /// write-stall (now fixed by appliance mode), so 30s is sufficient.
    private static let writeBudgetSeconds: TimeInterval = 30

    /// A command that DOES confirm (current reaches target) but takes longer
    /// than this is logged as a `.slowConfirm` warning even though it
    /// succeeded — visibility into a lock that responds but sluggishly. Lower
    /// than `writeBudgetSeconds` (the hang/revert threshold) so a
    /// slow-but-successful write (the common case for a flaky lock) is
    /// surfaced instead of silently passing. 15s per the maintainer.
    private static let slowConfirmThresholdSeconds: TimeInterval = 15

    typealias StateObserver = (AccessoryState) -> Void
    typealias RemovalObserver = (UUID) -> Void
    /// (wireID, target "secured"|"unsecured", reason "budget_exhausted"|"error", accessoryName)
    typealias WriteRevertedObserver = (String, String, String, String) -> Void

    final class ObserverToken {
        fileprivate let id = UUID()
    }

    // MARK: - Internals

    private let homeManager = HMHomeManager()
    private var trackedAccessories: [UUID: HMAccessory] = [:]
    private var infoCache: [UUID: [String: String]] = [:]
    private var stateStore: [UUID: AccessoryState] = [:]
    private var lastTargetChange: [UUID: Date] = [:]
    private var observers: [(token: ObserverToken, onState: StateObserver, onRemoved: RemovalObserver, onWriteReverted: WriteRevertedObserver?)] = []
    /// Home name per accessory, populated during enumeration. Needed by the
    /// AccessoryIdentityCache so it can match by (homeName, accessoryName)
    /// after a re-sign rotates HMAccessory.uniqueIdentifier.
    private var homeNameForAccessory: [UUID: String] = [:]
    /// Persistent identity pinning. Injected from AppDelegate before
    /// `start()` so that the first `recomputeAndPublish` for each accessory
    /// already routes through the cache. Optional only to keep tests +
    /// CLI-mode paths buildable without one — real launches always set it.
    var identityCache: AccessoryIdentityCache?

    /// Health-event sink for the Stats page's "Lock Errors/Warnings"
    /// section. Injected from AppDelegate before `start()`. Optional
    /// only to keep tests + CLI-mode paths buildable without one —
    /// real launches always set it. When nil, all event-emitting paths
    /// (background-write retries, reachability gaps) silently no-op
    /// on the logging side; functional behavior is unaffected.
    var lockEventLog: LockEventLog?

    /// Fired on the main thread at the start of every HA-initiated lock
    /// write, before the HomeKit `writeValue`. AppDelegate wires this to
    /// bring the app to the foreground / activate it — HomeKit (`homed`)
    /// only services accessory writes promptly for the *frontmost* app, so
    /// a write request is our cue to grab focus. See the README's appliance
    /// section for the full rationale. Optional so CLI/test paths no-op.
    var onWriteRequested: (() -> Void)?

    /// Fired on the main thread when the last in-flight lock write resolves
    /// (success, revert, or external satisfaction) and no writes remain
    /// pending. AppDelegate uses this to hand focus back to whatever app was
    /// frontmost before we stole it for the write. Optional so CLI/test
    /// paths no-op.
    var onAllWritesSettled: (() -> Void)?

    /// Fired on the main thread with `true` when the controller is authorized
    /// but HomeKit reports zero homes for a sustained window (likely iCloud
    /// HomeKit session rot), and `false` once homes appear. AppDelegate wires
    /// this to a status-window warning banner. Optional so CLI/test paths
    /// no-op.
    var onHomesVisibilityChanged: ((Bool) -> Void)?

    /// Tracks the last warning state pushed to `onHomesVisibilityChanged` so
    /// we only fire on transitions, not on every check.
    private var lastHomesEmptyWarning = false
    /// How long the controller can be authorized-but-homeless before we warn.
    /// Long enough to ride out first-launch iCloud sync lag (which can take a
    /// few minutes) without crying wolf.
    private static let emptyHomesWarnDelay: TimeInterval = 120

    /// Fire `onAllWritesSettled` when no background writes remain pending.
    /// Called at every terminal write resolution so focus can be returned to
    /// the app we stole it from — but only once the *last* concurrent write
    /// finishes, so overlapping commands don't bounce focus around.
    private func notifyIfAllWritesSettled() {
        if pendingWrites.isEmpty { onAllWritesSettled?() }
    }

    /// Fan a `write_reverted` notification out to observers (the BridgeServer
    /// turns it into a WS envelope). Emitted whenever an optimistic write is
    /// rolled back — budget exhausted or a non-retryable HomeKit error. The
    /// UI revert stays silent; this is purely for HA-side automation. The
    /// wire ID is resolved from the reverted state (falls back to the HM UUID
    /// string only if no stable wire ID was ever pinned).
    private func emitWriteReverted(hmID: UUID, target: Int, reason: String, accessoryName: String) {
        let wireID = stateStore[hmID]?.id ?? hmID.uuidString
        let targetStr = target == 1 ? "secured" : "unsecured"
        for o in observers {
            o.onWriteReverted?(wireID, targetStr, reason, accessoryName)
        }
    }
    /// Accessories whose SerialNumber characteristic exists but failed all
    /// retry attempts. Treated as "no serial available, ever" — the cache
    /// commits the fallback HMAccessory.uniqueIdentifier instead of
    /// waiting forever. The (home, name) secondary index in the cache
    /// then keeps that wireID stable across re-signs.
    private var serialReadExhausted: Set<UUID> = []
    /// Per-accessory retry counter for the SerialNumber characteristic.
    /// Reset to 0 on successful read so future reachability transitions
    /// don't inherit stale state.
    private var serialAttempts: [UUID: Int] = [:]
    /// Max read attempts before pinning the fallback wireID. 3 = initial
    /// attempt + 2 retries; combined with the backoff below, ~95s of
    /// real-world wait before we give up and commit fallback.
    private static let maxSerialAttempts = 3

    /// Lock-mechanism + battery characteristics we subscribe to for live
    /// notifications. Hoisted to a static so both the initial
    /// `subscribeAndRead` and the periodic `reassertNotifications` health
    /// pass share one source of truth.
    private static let notifyingCharacteristicTypes: Set<String> = [
        HMCharacteristicTypeCurrentLockMechanismState,
        HMCharacteristicTypeTargetLockMechanismState,
        HMCharacteristicTypeBatteryLevel,
        HMCharacteristicTypeStatusLowBattery,
    ]

    /// Max attempts to (re-)enable a characteristic notification before
    /// giving up for this pass. 3 = initial + 2 retries with the backoff
    /// below. Exhausting these isn't fatal — the periodic resubscribe
    /// timer is the long-term backstop.
    private static let maxSubscribeAttempts = 3
    /// Backoff after a failed `enableNotification`, in seconds. Capped at
    /// the last entry.
    private static let subscribeBackoffDelays: [Double] = [5, 15]

    /// How often to re-assert notifications on reachable tracked
    /// accessories. `homed` can silently drop notification delivery
    /// (daemon restart on OS update / memory pressure / HomeKit hiccup)
    /// WITHOUT firing a reachability transition — and a reachability flip
    /// is otherwise the only thing that re-runs subscription. Without this
    /// pass, a months-uptime bridge can go silently stale until an app
    /// restart. `enableNotification(true)` on an already-live subscription
    /// is a cheap no-op; on a dropped one it revives delivery.
    private static let resubscribeInterval: TimeInterval = 180  // 3 min
    /// Repeating main-queue timer driving the resubscribe health pass.
    /// Held for the monitor's lifetime; cancelled is never needed (the
    /// monitor lives as long as the process).
    private var resubscribeTimer: DispatchSourceTimer?

    /// Reverse map from the *wire* ID (the stable hash we publish to HA) to
    /// the underlying HMAccessory.uniqueIdentifier. Populated by
    /// `recomputeAndPublish` and cleared in `forgetAccessory`. Used to route
    /// HA's inbound `/accessories/{id}` and POST `.../state` calls — those
    /// arrive with the wire ID, and we need the HMAccessory UUID to talk to
    /// HomeKit. Without this, every lock/unlock command would fail with
    /// "accessory not known to bridge" because trackedAccessories is keyed
    /// by HMAccessory.uniqueIdentifier, not by the published wire ID.
    private var wireIDToHMUUID: [UUID: UUID] = [:]

    /// In-flight async-accept writes. Keyed by HMAccessory UUID (NOT wire ID).
    /// At most one entry per accessory; a new setLockState call supersedes
    /// any prior pending write for the same accessory.
    private var pendingWrites: [UUID: PendingWrite] = [:]

    /// A write that hit its 30s budget while the lock was REACHABLE but
    /// never confirmed (current_state never reached target). Moved here out
    /// of `pendingWrites` so focus is released and retries stop, but the
    /// accessory is still considered "in transition" — `hasOutstandingWrite`
    /// keeps `deriveLifecycle` showing locking/unlocking (the HA "hang")
    /// until the lock confirms, is superseded, or is retargeted externally.
    /// Keyed by HMAccessory UUID. See `resolveWriteAtDeadline`.
    private struct HangingWrite {
        let target: Int
        let startedAt: Date
        /// The `.unconfirmed` LockEventLog event, so a late confirmation can
        /// flip it to `.succeeded`.
        let eventID: UUID?
        /// Genuine last-known-good state from before the (now hung) command,
        /// carried so a superseding command can still revert to reality
        /// rather than to the phantom "locking"/"unlocking" optimistic state.
        let priorState: AccessoryState?
    }
    private var hangingWrites: [UUID: HangingWrite] = [:]

    /// True while a command we issued is still outstanding for `id` — either
    /// actively pending (within budget) or hanging unconfirmed past it. While
    /// true, `recomputeAndPublish` feeds `deriveLifecycle` an infinite
    /// transition window so HA keeps showing the in-progress state.
    private func hasOutstandingWrite(_ id: UUID) -> Bool {
        return pendingWrites[id] != nil || hangingWrites[id] != nil
    }

    /// Callbacks waiting for an accessory's reachability to flip back to
    /// `true`. Fired and drained by `accessoryDidUpdateReachability` when
    /// the accessory becomes reachable. Used by the background write retry
    /// loop to retry immediately on recovery instead of waiting out the
    /// backoff timer.
    private var reachabilityRecoveryWaiters: [UUID: [() -> Void]] = [:]

    /// Per-accessory wall-clock timestamp of when isReachable last went
    /// `false`. Cleared on recovery. Used to compute the gap duration
    /// recorded into the LockEventLog when isReachable returns to true.
    /// Populated by both `considerAccessory` (startup-unreachable case)
    /// and `accessoryDidUpdateReachability`.
    private var unreachableSince: [UUID: Date] = [:]

    private var pendingCommand: PendingCommand?
    private var commandFired = false
    private var commandTargetUUID: UUID?
    private var commandTargetValue: Int?

    // MARK: - Lifecycle

    func setPendingCommand(_ cmd: PendingCommand) {
        pendingCommand = cmd
        log("Pending command: \(cmd.action) on \"\(cmd.nameOrUUID)\"")
    }

    func start() {
        homeManager.delegate = self
        log("Started. Waiting for HomeKit authorization and home data…")
        log("Authorization status: \(describe(homeManager.authorizationStatus))")
        startResubscribeTimer()
    }

    /// Kick off the periodic notification-health pass. See
    /// `resubscribeInterval` for why this exists. Runs on the main queue
    /// (same thread as all HomeKit bookkeeping). Early fires before any
    /// accessory is discovered are harmless no-ops — `reassertSubscriptions`
    /// just iterates an empty `trackedAccessories`.
    private func startResubscribeTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.resubscribeInterval,
                       repeating: Self.resubscribeInterval)
        timer.setEventHandler { [weak self] in
            self?.reassertSubscriptions(reason: "periodic")
        }
        timer.resume()
        resubscribeTimer = timer
    }

    /// Re-assert HomeKit notifications on every reachable tracked
    /// accessory. The safety net against `homed` silently dropping
    /// notification delivery without a reachability transition.
    private func reassertSubscriptions(reason: String) {
        let reachable = trackedAccessories.values.filter { $0.isReachable }
        guard !reachable.isEmpty else { return }
        log("Resubscribe pass (\(reason)): re-asserting notifications on \(reachable.count) reachable lock(s)")
        for accessory in reachable {
            // readValues: false → re-enable all notifications cheaply but
            // only read current-lock-state (see reassertNotifications), so
            // the every-3-min pass doesn't wake sleepy lock radios on every
            // characteristic.
            reassertNotifications(for: accessory, readValues: false)
        }
    }

    // MARK: - Public API for BridgeServer

    /// An accessory is considered "healthy" once we've successfully read its
    /// manufacturer characteristic at least once. Until then, it's a ghost
    /// (e.g. stale HomeKit pairing for a device that's been gone for months).
    /// Ghosts stay in `stateStore` (so they can recover if they come back) but
    /// never leak through to API consumers.
    private func isHealthy(_ state: AccessoryState) -> Bool {
        return state.manufacturer != nil
    }

    /// Returns the current snapshot of healthy accessories, sorted by name.
    /// Must be called from the main thread.
    func snapshot() -> [AccessoryState] {
        return stateStore.values
            .filter(isHealthy)
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Whether HomeKit currently reports any homes to this controller. False
    /// is the signature of the most likely real-world appliance-rot mode:
    /// the app is authorized but its iCloud HomeKit session silently lost
    /// sync, so every home (and every lock) vanished. Surfaced via /health's
    /// `homes_visible` and the status-window warning. Must be called from the
    /// main thread (HomeKit's delegate queue).
    func homesVisible() -> Bool {
        return !homeManager.homes.isEmpty
    }

    /// Returns a single accessory state by UUID, or nil if the accessory is
    /// unknown or a ghost. Must be called from main thread.
    func state(forID id: UUID) -> AccessoryState? {
        // `id` here is the wire ID HA sent us. Resolve through the reverse
        // map to the HMAccessory UUID that stateStore is keyed by. Fall back
        // to the raw lookup so legacy IDs (when serial wasn't readable and
        // AccessoryState.from fell back to HMAccessory.uniqueIdentifier)
        // still resolve.
        let hmID = wireIDToHMUUID[id] ?? id
        guard let s = stateStore[hmID], isHealthy(s) else { return nil }
        return s
    }

    /// Registers a set of callbacks. Returns a token used for removal.
    /// All callbacks are invoked on the main thread. `onWriteReverted` is
    /// optional — only the BridgeServer (which fans it out over WS) supplies
    /// one; the status-window observer doesn't need it.
    func addObserver(
        onState: @escaping StateObserver,
        onRemoved: @escaping RemovalObserver,
        onWriteReverted: WriteRevertedObserver? = nil
    ) -> ObserverToken {
        let token = ObserverToken()
        observers.append((token, onState, onRemoved, onWriteReverted))
        return token
    }

    func removeObserver(_ token: ObserverToken) {
        observers.removeAll { $0.token === token }
    }

    /// Set lock target state. Completion called on the main thread.
    ///
    /// **Async-accept semantics.** The completion fires *immediately* with
    /// an optimistic `.ok(state)` reflecting the requested target, before
    /// `writeValue` has been attempted (or retried). HA's UI sees
    /// `lifecycle_state = "locking"/"unlocking"` instantly. A background
    /// retry loop then writes to HomeKit with up to a 30-second budget,
    /// recovering from transient `HMError 82 (not reachable)` responses
    /// when the HomeKit hub re-establishes contact with the lock. The write
    /// is only "done" once the lock CONFIRMS it (current_state == target),
    /// which arrives via the observer pipeline. At the budget without a
    /// confirmation, `resolveWriteAtDeadline` decides: a still-REACHABLE lock
    /// is left showing locking/unlocking (an `.unconfirmed` "hang" so HA and
    /// the Stats page surface that it didn't respond); an UNREACHABLE lock is
    /// reverted (HA already shows it unavailable).
    ///
    /// The only synchronous failure modes returned through completion are
    /// `.notFound` (no matching tracked accessory) and `.homekitError`
    /// (the accessory lacks the lock-mechanism characteristic). Note
    /// `.unreachable` is **never** returned — we accept the command even
    /// when `accessory.isReachable == false` because that value can be
    /// stale and the underlying connectivity often recovers within the
    /// retry budget. `.timeout` and `.unreachable` remain in the enum for
    /// backward-compatibility with BridgeServer's response mapping but
    /// are unused on this path.
    func setLockState(id: UUID, target: Int, completion: @escaping (SetLockResult) -> Void) {
        // Resolve the wire ID HA sent us to the HMAccessory UUID. See the
        // comment on `wireIDToHMUUID` for why this exists.
        let hmID = wireIDToHMUUID[id] ?? id
        guard let accessory = trackedAccessories[hmID] else {
            completion(.notFound); return
        }
        guard let service = accessory.services.first(where: { $0.serviceType == HMServiceTypeLockMechanism }),
              let targetChar = service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeTargetLockMechanismState }) else {
            completion(.homekitError("lock characteristic missing")); return
        }

        // HA wants a (valid) write — grab focus now so the app is frontmost
        // for the write and its retries. Placed after the guards so an
        // unknown-accessory request never yanks focus for nothing (and so we
        // don't owe a focus-restore for a write that never started).
        onWriteRequested?()

        // Cancel any prior in-flight write for this accessory. The user
        // has changed their mind (e.g. tapped Unlock while a previous Lock
        // command was still retrying); the old retry loop becomes a no-op
        // on its next callback by checking `completed`.
        //
        // Carry the superseded write's `priorState` forward (below). At this
        // point `stateStore[hmID]` already holds the superseded write's
        // *optimistic* (transition) state, so using it as this write's
        // revert target would republish a phantom frozen "locking"/"unlocking"
        // state on failure. The real last-known-good state is the superseded
        // write's own priorState — thread it through so a chain of superseded
        // writes still reverts to the genuine pre-command state.
        var carriedPriorState: AccessoryState?
        if let existing = pendingWrites[hmID] {
            log("Lock \(accessory.name): superseding prior pending write (target=\(existing.target)) with new target=\(target)")
            existing.completed = true
            carriedPriorState = existing.priorState
            pendingWrites.removeValue(forKey: hmID)
        }
        // A previously-hung (unconfirmed) write is also superseded by this new
        // command — drop the hang marker and carry its genuine prior forward.
        if let hung = hangingWrites.removeValue(forKey: hmID) {
            log("Lock \(accessory.name): superseding prior UNCONFIRMED write (target=\(hung.target)) with new target=\(target)")
            if carriedPriorState == nil { carriedPriorState = hung.priorState }
        }

        // Capture the pre-optimistic-update state for potential revert. Prefer
        // the carried-forward prior from a superseded write (the genuine
        // last-known-good); otherwise use the current published state. If
        // neither exists, fall back to nil — revert logic handles that by
        // recomputing from HMCharacteristic.
        let priorState = carriedPriorState ?? stateStore[hmID]

        // Mark target change so deriveLifecycle returns "locking" /
        // "unlocking" for the entire 30-second retry window.
        lastTargetChange[hmID] = Date()

        // Build the optimistic state. Either overlay the new target on the
        // prior published state (preserves the wire ID and accessory
        // metadata), or, if no prior state exists, compute fresh from
        // HMCharacteristic and overlay target.
        let optimisticState: AccessoryState
        if let prior = priorState {
            optimisticState = prior.with(target: target, lastTargetChange: lastTargetChange[hmID])
        } else {
            let computed = AccessoryState.from(
                accessory: accessory,
                info: infoCache[hmID] ?? [:],
                homeName: homeManager.homes.count > 1 ? homeNameForAccessory[hmID] : nil,
                lastTargetChange: lastTargetChange[hmID]
            )
            optimisticState = computed.with(target: target, lastTargetChange: lastTargetChange[hmID])
        }

        // Publish the optimistic state to observers AND store it so
        // recomputeAndPublish's dedup uses it as the baseline.
        stateStore[hmID] = optimisticState
        if let wireUUID = UUID(uuidString: optimisticState.id) {
            wireIDToHMUUID[wireUUID] = hmID
        }
        emitDebugJSON(newState: optimisticState, reason: "optimistic")
        if isHealthy(optimisticState) {
            for o in observers { o.onState(optimisticState) }
        }

        // Return immediately to HA. The bridge has accepted the command;
        // the underlying HomeKit write will succeed or fail in the
        // background.
        completion(.ok(optimisticState))

        // Spin up the background retry loop.
        let pending = PendingWrite(
            target: target,
            priorState: priorState,
            deadline: Date().addingTimeInterval(Self.writeBudgetSeconds),
            startedAt: Date()
        )
        pendingWrites[hmID] = pending

        // Safety net: a deadline timer that calls revert() if the loop is
        // still pending when the budget expires. The retry loop also
        // checks the deadline before scheduling, so in the common case the
        // loop's own check fires first and the safety net is a no-op.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.writeBudgetSeconds) { [weak self] in
            guard let self = self, let still = self.pendingWrites[hmID], still === pending, !still.completed else { return }
            self.log("Lock \(accessory.name): write budget (\(Int(Self.writeBudgetSeconds))s) elapsed via safety timer")
            self.resolveWriteAtDeadline(hmID: hmID, accessory: accessory, pending: still)
        }

        attemptBackgroundWrite(targetChar: targetChar, accessory: accessory, hmID: hmID, pending: pending)
    }

    /// One write attempt for a pending background write. Reschedules itself
    /// on transient `HMError 82` until the deadline. On a non-82 error it
    /// reverts; on homed-ack it marks the write `acked` and waits for the lock
    /// to confirm; at the deadline it hands off to `resolveWriteAtDeadline`.
    /// Always called on the main thread.
    private func attemptBackgroundWrite(
        targetChar: HMCharacteristic,
        accessory: HMAccessory,
        hmID: UUID,
        pending: PendingWrite
    ) {
        guard !pending.completed else { return }
        pending.attempt += 1
        pending.triggered = false
        let thisAttempt = pending.attempt

        targetChar.writeValue(NSNumber(value: pending.target)) { [weak self] error in
            guard let self = self, !pending.completed else { return }

            if let error = error {
                let nsError = error as NSError
                let isNotReachable = nsError.domain == HMErrorDomain && nsError.code == 82
                if !isNotReachable {
                    self.log("Lock \(accessory.name): background write failed (attempt \(thisAttempt)) with non-retryable error: \(error.localizedDescription)")
                    // Non-82 failures previously left zero trace; record one in
                    // the LockEventLog so the Stats page shows the failure.
                    self.recordWriteFailed(pending: pending, accessory: accessory, detail: error.localizedDescription)
                    self.revertPending(hmID: hmID, accessory: accessory, pending: pending, reason: "error")
                    return
                }
                if Date() >= pending.deadline {
                    self.log("Lock \(accessory.name): background write budget exhausted after \(thisAttempt) attempt(s)")
                    self.resolveWriteAtDeadline(hmID: hmID, accessory: accessory, pending: pending)
                    return
                }
                let delayIdx = min(thisAttempt - 1, Self.writeBackoffDelays.count - 1)
                let delay = Self.writeBackoffDelays[delayIdx]
                self.log("Lock \(accessory.name): write rejected as not-reachable (attempt \(thisAttempt), retry in up to \(delay)s or on reachability recovery)")

                // Surface this rough edge to the Stats page. On the very
                // first 82 we open a new event; on subsequent 82s we just
                // advance the attempt counter on the open event.
                self.recordOrAdvanceWriteRetry(pending: pending, accessory: accessory)

                // The fire closure is idempotent AND generation-stamped to
                // THIS attempt. Two waiters of the same generation (the backoff
                // timer and a reachability-recovery callback) can both fire;
                // `pending.triggered` lets only the first win. But that flag is
                // reset to false at the START of every attempt — so a stale
                // waiter left over from a *previous* generation could see
                // triggered==false again and fire a duplicate. Capturing
                // `thisAttempt` and bailing when `pending.attempt` has already
                // advanced closes that double-fire window (deterministic when
                // stacked waiters drain after a reachability flip).
                let fire: () -> Void = { [weak self] in
                    guard let self = self,
                          !pending.completed,
                          !pending.triggered,
                          pending.attempt == thisAttempt else { return }
                    pending.triggered = true
                    self.attemptBackgroundWrite(targetChar: targetChar, accessory: accessory, hmID: hmID, pending: pending)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { fire() }
                self.waitForReachabilityRecovery(of: hmID) { [weak self] in
                    self?.log("Lock \(accessory.name): reachability recovered mid-retry; firing write immediately")
                    fire()
                }
                return
            }

            // homed ACCEPTED the write — but "accepted" is not "the bolt
            // moved." Do NOT treat this as done: keep the pending write and
            // wait for the lock to CONFIRM (current_state == target). Stop
            // hammering writeValue (mark acked; the retry loop only reschedules
            // on the 82 path, so simply returning here halts retries). Refresh
            // the transition window and re-publish so HA shows
            // locking/unlocking until confirmation arrives — via the
            // characteristic-update path (recomputeAndPublish's confirmation
            // block) or the deadline, which flags it `.unconfirmed` and leaves
            // HA hanging. If current_state already equals target (e.g. locking
            // an already-locked lock, or a fast actuation that already
            // reported), that same recompute settles it immediately.
            self.log("Lock \(accessory.name): background write accepted on attempt \(thisAttempt); awaiting confirmation")
            pending.acked = true
            self.lastTargetChange[hmID] = Date()
            self.recomputeAndPublish(for: accessory, reason: "post-write-ack")
        }
    }

    /// Open a writeRetry event on the first HMError 82 for this command,
    /// or advance the attempt counter on subsequent 82s.
    private func recordOrAdvanceWriteRetry(pending: PendingWrite, accessory: HMAccessory) {
        guard let log = lockEventLog else { return }
        let actionLabel = pending.target == 1 ? "lock" : "unlock"
        let elapsedMs = Int(Date().timeIntervalSince(pending.startedAt) * 1000)
        if let id = pending.retryLogEventID {
            log.update(id: id) { e in
                if case .writeRetry(let action, _, _, _) = e.kind {
                    e.kind = .writeRetry(
                        targetAction: action,
                        attempts: pending.attempt,
                        durationMs: elapsedMs,
                        outcome: .ongoing
                    )
                }
            }
        } else {
            let newID = UUID()
            pending.retryLogEventID = newID
            log.record(.init(
                id: newID,
                accessoryName: accessory.name,
                accessoryID: accessory.uniqueIdentifier.uuidString,
                timestamp: pending.startedAt,
                kind: .writeRetry(
                    targetAction: actionLabel,
                    attempts: pending.attempt,
                    durationMs: elapsedMs,
                    outcome: .ongoing
                )
            ))
        }
    }

    /// Record a `.writeFailed` event for a non-retryable (non-82) HomeKit
    /// write error. These used to leave zero trace anywhere. Distinct from the
    /// `.writeRetry`/`.reverted` path, which only covers the 82-retry budget.
    private func recordWriteFailed(pending: PendingWrite, accessory: HMAccessory, detail: String) {
        guard let log = lockEventLog else { return }
        let actionLabel = pending.target == 1 ? "lock" : "unlock"
        log.record(.init(
            id: UUID(),
            accessoryName: accessory.name,
            accessoryID: accessory.uniqueIdentifier.uuidString,
            timestamp: Date(),
            kind: .writeFailed(targetAction: actionLabel, detail: detail)
        ))
    }

    /// Close the open writeRetry event for a terminating background
    /// write. No-op if no event was opened (single-attempt success).
    private func closeWriteRetryEvent(pending: PendingWrite, outcome: LockEventLog.WriteOutcome) {
        guard let log = lockEventLog, let id = pending.retryLogEventID else { return }
        let finalMs = Int(Date().timeIntervalSince(pending.startedAt) * 1000)
        log.update(id: id) { e in
            if case .writeRetry(let action, let attempts, _, _) = e.kind {
                e.kind = .writeRetry(
                    targetAction: action,
                    attempts: attempts,
                    durationMs: finalMs,
                    outcome: outcome
                )
            }
        }
    }

    /// Decide what to do when a write reaches its 30s budget without the lock
    /// having CONFIRMED (current_state == target). Three outcomes:
    ///
    ///   1. The lock confirmed in the meantime → settle as a (late) success.
    ///   2. Lock REACHABLE but unconfirmed → record an `.unconfirmed` warning
    ///      and move the command into `hangingWrites`, leaving HA showing
    ///      locking/unlocking (the deliberate "it didn't respond" hang). We do
    ///      NOT revert and do NOT emit `write_reverted` — the persisting
    ///      transition IS the signal.
    ///   3. Lock UNREACHABLE → revert (Option B). HA already shows the lock
    ///      unavailable, and the `unreachableGap` event records the outage, so
    ///      we don't manufacture a competing hang; we just roll the optimistic
    ///      state back to reality.
    private func resolveWriteAtDeadline(hmID: UUID, accessory: HMAccessory, pending: PendingWrite) {
        guard !pending.completed else { return }

        let currentChar = accessory.services
            .flatMap { $0.characteristics }
            .first { $0.characteristicType == HMCharacteristicTypeCurrentLockMechanismState }

        // For a REACHABLE lock, take a FRESH read of current_state before
        // deciding. homed can silently drop a confirmation push (the very
        // reason the resubscribe pass exists); the cached characteristic value
        // could then be stale and we'd falsely flag a confirmed write as
        // `.unconfirmed` and hang HA. For an unreachable lock the read can't
        // succeed and we're reverting regardless, so skip it and use the cache.
        if accessory.isReachable, let currentChar = currentChar {
            currentChar.readValue { [weak self] _ in
                // HomeKit delivers readValue completions on the main thread
                // (same as subscribe()/readInfo()). On a read error the value
                // simply stays whatever was cached — no worse than before.
                self?.finishResolveAtDeadline(
                    hmID: hmID, accessory: accessory, pending: pending,
                    liveCurrent: (currentChar.value as? NSNumber)?.intValue
                )
            }
            return
        }
        finishResolveAtDeadline(
            hmID: hmID, accessory: accessory, pending: pending,
            liveCurrent: (currentChar?.value as? NSNumber)?.intValue
        )
    }

    /// Apply the deadline decision (confirmed / hang / revert) given the
    /// best-available `current_state`. Split out of `resolveWriteAtDeadline` so
    /// the reachable path can fetch a fresh read first.
    private func finishResolveAtDeadline(hmID: UUID, accessory: HMAccessory, pending: PendingWrite, liveCurrent: Int?) {
        guard !pending.completed else { return }

        // 1. Confirmed — current reached target. Settle as a (late) success;
        // `.satisfiedExternally` if we never even got an ack (some other path
        // got there), matching the recomputeAndPublish confirmation block.
        if let c = liveCurrent, c == pending.target {
            log("Lock \(accessory.name): confirmed at deadline (current=\(pending.target))")
            pending.completed = true
            pendingWrites.removeValue(forKey: hmID)
            recordSlowConfirmIfNeeded(target: pending.target, startedAt: pending.startedAt,
                                      hadRetryEvent: pending.retryLogEventID != nil, accessory: accessory)
            closeWriteRetryEvent(pending: pending, outcome: pending.acked ? .succeeded : .satisfiedExternally)
            recomputeAndPublish(for: accessory, reason: "deadline-confirmed")
            notifyIfAllWritesSettled()
            return
        }

        if accessory.isReachable {
            // 2. Reachable but unconfirmed → hang + warn.
            pending.completed = true
            pendingWrites.removeValue(forKey: hmID)   // stop retrying; release focus
            let eventID = recordUnconfirmed(pending: pending, accessory: accessory)
            hangingWrites[hmID] = HangingWrite(
                target: pending.target,
                startedAt: pending.startedAt,
                eventID: eventID,
                priorState: pending.priorState
            )
            log("Lock \(accessory.name): reachable but \(pending.target == 1 ? "lock" : "unlock") not confirmed after \(Int(Self.writeBudgetSeconds))s — leaving HA in-progress (hang)")
            notifyIfAllWritesSettled()
            // Re-publish with the hang marker now set so deriveLifecycle keeps
            // showing locking/unlocking past the transition window.
            recomputeAndPublish(for: accessory, reason: "write-unconfirmed-hang")
        } else {
            // 3. Unreachable → revert (HA already shows unavailable).
            revertPending(hmID: hmID, accessory: accessory, pending: pending)
        }
    }

    /// Record (or finalize) the `.unconfirmed` warning for a write that hit its
    /// budget on a reachable lock. If an `.writeRetry` event was already opened
    /// (the lock 82'd at least once), flip it to `.unconfirmed`; otherwise open
    /// a fresh one (the homed-accepted-but-never-actuated case left no trace
    /// yet). Returns the event ID so a late confirmation can flip it to
    /// `.succeeded`.
    private func recordUnconfirmed(pending: PendingWrite, accessory: HMAccessory) -> UUID? {
        guard let log = lockEventLog else { return nil }
        let actionLabel = pending.target == 1 ? "lock" : "unlock"
        let elapsedMs = Int(Date().timeIntervalSince(pending.startedAt) * 1000)
        if let id = pending.retryLogEventID {
            log.update(id: id) { e in
                if case .writeRetry(let action, let attempts, _, _) = e.kind {
                    e.kind = .writeRetry(targetAction: action, attempts: attempts,
                                         durationMs: elapsedMs, outcome: .unconfirmed)
                }
            }
            return id
        }
        let newID = UUID()
        log.record(.init(
            id: newID,
            accessoryName: accessory.name,
            accessoryID: accessory.uniqueIdentifier.uuidString,
            timestamp: pending.startedAt,
            kind: .writeRetry(targetAction: actionLabel, attempts: max(1, pending.attempt),
                              durationMs: elapsedMs, outcome: .unconfirmed)
        ))
        return newID
    }

    /// Record a `.slowConfirm` warning if a command confirmed (current reached
    /// target) but took longer than the slow threshold. Skipped when a
    /// writeRetry event already exists (an 82 write whose own event shows the
    /// delay) to avoid double-logging; the `>writeBudgetSeconds` hang case is
    /// likewise covered by its own `.unconfirmed`→`.succeeded` row, so this
    /// fires for the in-budget-but-slow (≈15–30s) confirmations that would
    /// otherwise leave no trace.
    private func recordSlowConfirmIfNeeded(target: Int, startedAt: Date, hadRetryEvent: Bool, accessory: HMAccessory) {
        guard !hadRetryEvent, let log = lockEventLog else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed >= Self.slowConfirmThresholdSeconds else { return }
        log.record(.init(
            id: UUID(),
            accessoryName: accessory.name,
            accessoryID: accessory.uniqueIdentifier.uuidString,
            timestamp: startedAt,
            kind: .slowConfirm(targetAction: target == 1 ? "lock" : "unlock",
                               durationMs: Int(elapsed * 1000))
        ))
    }

    /// A hung (`.unconfirmed`) write was confirmed late — the lock finally
    /// reached the target. Clear the hang marker and flip its warning to
    /// `.succeeded`. Called from recomputeAndPublish's confirmation block.
    private func resolveHangingWrite(_ hung: HangingWrite, id: UUID, accessoryName: String) {
        hangingWrites.removeValue(forKey: id)
        lastTargetChange.removeValue(forKey: id)
        log("Lock \(accessoryName): previously-unconfirmed write (target=\(hung.target)) confirmed late")
        if let eventID = hung.eventID, let log = lockEventLog {
            let finalMs = Int(Date().timeIntervalSince(hung.startedAt) * 1000)
            log.update(id: eventID) { e in
                if case .writeRetry(let action, let attempts, _, _) = e.kind {
                    e.kind = .writeRetry(targetAction: action, attempts: attempts,
                                         durationMs: finalMs, outcome: .succeeded)
                }
            }
        }
    }

    /// Revert an optimistic state publish after the background retry budget
    /// has been exhausted (or a non-retryable HomeKit error). Behavior:
    ///
    /// - If the lock's *physical* current_state characteristic already
    ///   matches the pending target (e.g. someone else issued a command
    ///   that reached the lock, or it was manually operated), we don't
    ///   revert — the user's intent ended up satisfied. We just clear the
    ///   transition window and let recomputeAndPublish settle the
    ///   lifecycle naturally.
    /// - Otherwise restore the captured priorState (the published state
    ///   from before this command's optimistic update) so HA's UI flips
    ///   back to the last-known real state. Silent — no error toast.
    /// - If no priorState was captured (first-ever command on this
    ///   accessory), fall back to recomputing from HMCharacteristic.
    /// `reason` distinguishes budget-exhaustion ("budget_exhausted") from a
    /// non-retryable HomeKit error ("error") for the `write_reverted` wire
    /// event. Defaults to budget exhaustion since most reverts come from the
    /// retry-budget path (deadline / safety timer).
    private func revertPending(hmID: UUID, accessory: HMAccessory, pending: PendingWrite, reason: String = "budget_exhausted") {
        guard !pending.completed else { return }
        pending.completed = true
        pendingWrites.removeValue(forKey: hmID)
        lastTargetChange.removeValue(forKey: hmID)
        defer { notifyIfAllWritesSettled() }

        let liveCurrent: Int? = accessory.services
            .flatMap { $0.characteristics }
            .first { $0.characteristicType == HMCharacteristicTypeCurrentLockMechanismState }
            .flatMap { ($0.value as? NSNumber)?.intValue }

        if let c = liveCurrent, c == pending.target {
            log("Lock \(accessory.name): physical current_state already matches pending target=\(pending.target); skipping revert")
            closeWriteRetryEvent(pending: pending, outcome: .satisfiedExternally)
            recomputeAndPublish(for: accessory, reason: "write-giveup-already-at-target")
            return
        }

        closeWriteRetryEvent(pending: pending, outcome: .reverted)

        // Put the revert on the wire so HA-side automations can react to a
        // failed lock/unlock (the #1 review finding). The on-screen UI revert
        // stays silent; this is the automatable signal. Emitted only on a
        // genuine revert — not when the intent was satisfied externally above.
        emitWriteReverted(hmID: hmID, target: pending.target, reason: reason, accessoryName: accessory.name)

        guard let prior = pending.priorState else {
            recomputeAndPublish(for: accessory, reason: "write-giveup-no-prior")
            return
        }

        // Restore the prior published state directly. We bypass
        // recomputeAndPublish because we want the *exact* prior snapshot
        // (id, name, current_state-at-the-time, etc.) republished to HA —
        // not a fresh derivation that would re-run the target-change
        // detection logic.
        stateStore[hmID] = prior
        if let wireUUID = UUID(uuidString: prior.id) {
            wireIDToHMUUID[wireUUID] = hmID
        }
        emitDebugJSON(newState: prior, reason: "write-giveup-revert")
        if isHealthy(prior) {
            for o in observers { o.onState(prior) }
        }
    }

    /// Register a callback to fire when `hmID` next transitions to
    /// `isReachable == true`. Drained by `accessoryDidUpdateReachability`.
    /// Multiple waiters allowed (FIFO).
    private func waitForReachabilityRecovery(of hmID: UUID, callback: @escaping () -> Void) {
        reachabilityRecoveryWaiters[hmID, default: []].append(callback)
    }

    // MARK: - HMHomeManagerDelegate

    func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        log("Authorization status changed: \(describe(status))")
        // Apple's docs say homeManagerDidUpdateHomes(_:) is called
        // automatically when the framework gains access to home data, which
        // *should* cover the TCC-grant transition. Empirically, on Mac
        // Catalyst first launch (and only first launch — after that, the
        // homes are already cached), homeManagerDidUpdateHomes(_:) does not
        // reliably fire on the undetermined → authorized transition, leaving
        // the accessory list stuck at zero until the app is restarted.
        // Trigger the enumeration explicitly here. The call is idempotent
        // — considerAccessory() short-circuits on accessories already in
        // trackedAccessories — so if Apple's delegate method does fire
        // afterwards, nothing happens twice.
        if status.contains(.authorized) {
            homeManagerDidUpdateHomes(manager)
        }
    }

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        log("Homes updated. \(manager.homes.count) home(s) visible.")
        for home in manager.homes {
            home.delegate = self  // so we get accessory add/remove events
            log("Home: \(home.name) — \(home.accessories.count) accessories")
            for accessory in home.accessories {
                considerAccessory(accessory, in: home)
            }
        }
        if manager.homes.isEmpty {
            log("No homes returned. If this Mac is signed into iCloud with HomeKit sync, give it a few minutes — sync can lag on first run.")
            // Schedule a delayed re-check — if still authorized-but-homeless
            // after the grace window, surface a status-window warning.
            scheduleEmptyHomesCheck()
        } else {
            // Homes are back (or were never gone) — clear any standing warning.
            updateHomesVisibilityWarning(empty: false)
        }
    }

    /// After the grace window, if the controller is authorized but still has
    /// zero homes, raise the status-window warning. Re-armed on every empty
    /// `homeManagerDidUpdateHomes` so transient first-launch sync lag clears
    /// itself once homes arrive.
    private func scheduleEmptyHomesCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.emptyHomesWarnDelay) { [weak self] in
            guard let self = self else { return }
            let authorized = self.homeManager.authorizationStatus.contains(.authorized)
            self.updateHomesVisibilityWarning(empty: authorized && self.homeManager.homes.isEmpty)
        }
    }

    /// Fire `onHomesVisibilityChanged` only on a transition so the banner
    /// isn't churned on every check.
    private func updateHomesVisibilityWarning(empty: Bool) {
        guard empty != lastHomesEmptyWarning else { return }
        lastHomesEmptyWarning = empty
        if empty {
            log("WARNING: authorized but no HomeKit homes visible after \(Int(Self.emptyHomesWarnDelay))s — iCloud HomeKit session may have lost sync.")
        }
        onHomesVisibilityChanged?(empty)
    }

    func homeManager(_ manager: HMHomeManager, didAdd home: HMHome) {
        log("Home added: \(home.name)")
        home.delegate = self
        for accessory in home.accessories { considerAccessory(accessory, in: home) }
        // The home count may have just crossed the >1 boundary (e.g. a 2nd home
        // synced in late). The display-home prefix is gated on homes.count > 1
        // and evaluated per-publish, so re-publish ALL tracked locks — otherwise
        // the already-published first-home locks keep their bare name while the
        // new home's locks are prefixed (asymmetric). Display only; identity is
        // untouched (the prefix never feeds the wire id), so this can't orphan.
        republishAllTracked(reason: "home-added")
    }

    func homeManager(_ manager: HMHomeManager, didRemove home: HMHome) {
        log("Home removed: \(home.name) — \(home.accessories.count) accessories")
        for accessory in home.accessories {
            forgetAccessory(accessory.uniqueIdentifier, name: accessory.name)
        }
        // Count may have dropped back to 1 — re-publish remaining locks so they
        // shed the now-unwarranted home prefix. (Display only; identity safe.)
        republishAllTracked(reason: "home-removed")
    }

    /// Re-run `recomputeAndPublish` for every tracked accessory. Used when the
    /// HomeKit *home set* changes (added / removed / renamed), because the
    /// display-home prefix is gated on `homeManager.homes.count > 1` and
    /// evaluated per-publish — without this, already-published locks keep a
    /// stale prefix (or stale home name) until unrelated activity happens to
    /// republish them. Goes through the normal publish path, so the per-accessory
    /// dedup makes unchanged locks no-ops, and the wire id is resolved by the
    /// identity cache exactly as before (keyed on the stable HMAccessory UUID /
    /// serial hash — never the display prefix), so this CANNOT reassign,
    /// orphan, or duplicate an entity.
    private func republishAllTracked(reason: String) {
        for accessory in trackedAccessories.values {
            recomputeAndPublish(for: accessory, reason: reason)
        }
    }

    // MARK: - HMHomeDelegate

    /// Fires when a HomeKit home is renamed. Refresh the cached home name for
    /// its accessories and re-publish so the display prefix tracks the rename
    /// live instead of going stale until an app restart. Within a run the
    /// identity cache resolves each accessory by its (stable) HMAccessory UUID,
    /// so updating the home name only refreshes the cache's secondary-index
    /// metadata and the display field — it never changes a wire id.
    func homeDidUpdateName(_ home: HMHome) {
        log("Home renamed: \(home.name)")
        for accessory in home.accessories {
            homeNameForAccessory[accessory.uniqueIdentifier] = home.name
        }
        republishAllTracked(reason: "home-renamed")
    }

    /// Fires when a new HomeKit accessory is paired into a home AFTER the
    /// bridge has already discovered the home. This is how a fresh ThorBolt
    /// (or any other lock) appears in the bridge without restarting it.
    func home(_ home: HMHome, didAdd accessory: HMAccessory) {
        log("Accessory added to home \(home.name): \(accessory.name)")
        considerAccessory(accessory, in: home)
    }

    func home(_ home: HMHome, didRemove accessory: HMAccessory) {
        log("Accessory removed from home \(home.name): \(accessory.name)")
        forgetAccessory(accessory.uniqueIdentifier, name: accessory.name)
    }

    private func forgetAccessory(_ id: UUID, name: String) {
        // Capture the wire ID *before* clearing stateStore — observers (HA)
        // track entities by the wire ID, so the removal event has to use
        // that, not the HMAccessory UUID. Fall back to the HM UUID for the
        // rare case where stateStore never got populated (e.g. ghost).
        let removedWireID = stateStore[id].flatMap { UUID(uuidString: $0.id) } ?? id
        wireIDToHMUUID.removeValue(forKey: removedWireID)
        // Detach our delegate so HomeKit stops delivering characteristic /
        // reachability callbacks for this (now-forgotten) accessory — those
        // would otherwise drive recomputeAndPublish and resurrect a phantom
        // entity. Belt-and-braces with the zombie guard in recomputeAndPublish.
        if let removed = trackedAccessories[id], removed.delegate === self {
            removed.delegate = nil
        }
        trackedAccessories.removeValue(forKey: id)
        stateStore.removeValue(forKey: id)
        infoCache.removeValue(forKey: id)
        lastTargetChange.removeValue(forKey: id)
        homeNameForAccessory.removeValue(forKey: id)
        // Cancel any in-flight background write — the accessory is gone,
        // there's nothing to write to and nowhere to revert to.
        if let pending = pendingWrites.removeValue(forKey: id) {
            pending.completed = true
        }
        // Drop any unconfirmed-hang marker too (no lock left to confirm it).
        hangingWrites.removeValue(forKey: id)
        notifyIfAllWritesSettled()
        reachabilityRecoveryWaiters.removeValue(forKey: id)
        // If we were tracking an open reachability gap, drop it on the
        // floor — the accessory is gone, the gap duration is moot and
        // there's no UI value in surfacing it as "lasted forever".
        unreachableSince.removeValue(forKey: id)
        for o in observers {
            o.onRemoved(removedWireID)
        }
    }

    // MARK: - Accessory discovery

    private func considerAccessory(_ accessory: HMAccessory, in home: HMHome) {
        let lockServices = accessory.services.filter { $0.serviceType == HMServiceTypeLockMechanism }
        guard !lockServices.isEmpty else { return }

        // Record home membership even on re-discovery so a fresh
        // recomputeAndPublish always has it.
        homeNameForAccessory[accessory.uniqueIdentifier] = home.name

        if trackedAccessories[accessory.uniqueIdentifier] != nil {
            // Already tracked, and we're being re-handed this accessory —
            // typically because HomeKit reloaded home data (e.g. homed
            // restarted). That reload can silently drop our characteristic
            // notifications, and HomeKit may even hand back a *fresh*
            // HMAccessory instance for the same uniqueIdentifier, leaving
            // our stored object (and its delegate registration) pointing
            // at a dead instance. Refresh the stored reference + delegate
            // and re-assert notifications so a homed bounce doesn't leave
            // us silently stale until an app restart. (The periodic
            // resubscribe timer is the other half of this safety net.)
            trackedAccessories[accessory.uniqueIdentifier] = accessory
            accessory.delegate = self
            if accessory.isReachable {
                reassertNotifications(for: accessory)
            }
            return
        }
        trackedAccessories[accessory.uniqueIdentifier] = accessory

        log("Lock discovered: \(accessory.name) [\(accessory.uniqueIdentifier.uuidString)] home=\(home.name) reachable=\(accessory.isReachable)")
        // Log manufacturer + model from the synchronous HMAccessory
        // properties so the discovery trace shows accessory identity even
        // when reachable=false. (HomeKit eagerly caches these regardless
        // of reachability.)
        if let m = accessory.manufacturer {
            log("  \(accessory.name): manufacturer=\(m)")
        }
        if let m = accessory.model {
            log("  \(accessory.name): model=\(m)")
        }
        accessory.delegate = self

        if accessory.isReachable {
            subscribeAndRead(accessory)
        } else {
            log("  \(accessory.name): unreachable at startup, will retry on reachability change")
            // Track the gap start so we can record duration on recovery.
            openUnreachableGap(for: accessory, at: Date())
            // Still publish the initial (unreachable) state so consumers know it exists.
            recomputeAndPublish(for: accessory, reason: "initial-unreachable")
        }

        maybeFirePendingCommand(against: accessory)
    }


    private func subscribeAndRead(_ accessory: HMAccessory) {
        // Establish live notifications on the lock + battery characteristics.
        reassertNotifications(for: accessory)

        // Read the SerialNumber characteristic once. The other info fields
        // (Manufacturer, Model, FirmwareVersion) are deprecated since iOS 11
        // and unavailable on macOS — Apple's replacement is direct
        // HMAccessory.manufacturer / .model / .firmwareVersion properties,
        // which we read synchronously in recomputeAndPublish. SerialNumber
        // has no equivalent property and stays on the characteristic path.
        for service in accessory.services {
            for characteristic in service.characteristics
            where characteristic.characteristicType == HMCharacteristicTypeSerialNumber {
                readInfo(characteristic, accessory: accessory)
            }
        }

        recomputeAndPublish(for: accessory, reason: "initial")
    }

    /// (Re-)enable notifications on the lock + battery characteristics for
    /// one accessory. Idempotent — `enableNotification(true)` on an
    /// already-live subscription is a no-op, on a dropped one it revives
    /// delivery. Used both for the initial subscribe and by the periodic /
    /// homed-reload resubscribe health paths.
    ///
    /// `readValues` controls whether the success path also reads each
    /// characteristic's current value. The initial subscribe and the
    /// homed-reload re-entry pass `true` (infrequent; we want fresh state
    /// immediately). The periodic health pass passes `false` to avoid
    /// waking sleepy lock radios on every characteristic every few minutes
    /// — but we always read the *current-lock-state* characteristic
    /// regardless, since that's the one value whose staleness genuinely
    /// matters and the read is cache-served by homed when the subscription
    /// is healthy.
    private func reassertNotifications(for accessory: HMAccessory, readValues: Bool = true) {
        for service in accessory.services {
            for characteristic in service.characteristics
            where Self.notifyingCharacteristicTypes.contains(characteristic.characteristicType) {
                let read = readValues
                    || characteristic.characteristicType == HMCharacteristicTypeCurrentLockMechanismState
                subscribe(characteristic, accessory: accessory, readOnSuccess: read)
            }
        }
    }

    private func subscribe(_ characteristic: HMCharacteristic, accessory: HMAccessory, attempt: Int = 1, readOnSuccess: Bool = true) {
        characteristic.enableNotification(true) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.log("enableNotification failed for \(self.shortType(characteristic.characteristicType)) on \(accessory.name) [attempt \(attempt)/\(Self.maxSubscribeAttempts)]: \(error.localizedDescription)")
                // Retry with backoff. A transient failure here (lock
                // briefly unreachable at subscribe time) would otherwise
                // leave this characteristic permanently non-notifying until
                // a reachability flip happened to re-run subscription. If
                // all attempts fail, the periodic resubscribe timer is the
                // long-term backstop.
                guard attempt < Self.maxSubscribeAttempts else { return }
                let delay = Self.subscribeBackoffDelays[min(attempt - 1, Self.subscribeBackoffDelays.count - 1)]
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self,
                          self.trackedAccessories[accessory.uniqueIdentifier] != nil,
                          accessory.isReachable else { return }
                    self.subscribe(characteristic, accessory: accessory, attempt: attempt + 1, readOnSuccess: readOnSuccess)
                }
                return
            }
            guard readOnSuccess else { return }
            characteristic.readValue { [weak self] readError in
                if let readError = readError {
                    self?.log("readValue failed for \(self?.shortType(characteristic.characteristicType) ?? "?") on \(accessory.name): \(readError.localizedDescription)")
                    return
                }
                self?.recomputeAndPublish(for: accessory, reason: "read")
            }
        }
    }

    private func readInfo(_ characteristic: HMCharacteristic, accessory: HMAccessory) {
        let id = accessory.uniqueIdentifier
        let isSerial = characteristic.characteristicType == HMCharacteristicTypeSerialNumber

        // Don't waste cycles re-attempting a serial read we've already
        // given up on — the cache has the fallback wireID pinned and a
        // late-arriving real serial wouldn't change it anyway.
        if isSerial && serialReadExhausted.contains(id) {
            return
        }

        characteristic.readValue { [weak self] error in
            guard let self = self else { return }
            let key = self.shortType(characteristic.characteristicType)

            if let error = error {
                let attempt = (self.serialAttempts[id] ?? 0) + 1
                self.log("readValue (info) failed for \(key) on \(accessory.name) [attempt \(attempt)\(isSerial ? "/\(Self.maxSerialAttempts)" : "")]: \(error.localizedDescription)")
                if !isSerial {
                    return  // Non-serial reads aren't retried; their values aren't load-bearing for wire-ID stability.
                }
                self.serialAttempts[id] = attempt
                if attempt < Self.maxSerialAttempts {
                    // Backoff: 5s after first failure, 30s after second.
                    let backoffs: [Double] = [5, 30]
                    let delay = backoffs[min(attempt - 1, backoffs.count - 1)]
                    self.log("  Retrying serial_number read for \(accessory.name) in \(Int(delay))s")
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.readInfo(characteristic, accessory: accessory)
                    }
                } else {
                    // All retries exhausted. Mark this accessory as
                    // "serial unavailable for the rest of this run" and
                    // force a recomputeAndPublish so the cache commits the
                    // fallback HMAccessory.uniqueIdentifier as the wireID.
                    // The (home, name) lookup in AccessoryIdentityCache
                    // keeps that wireID stable across re-signs even though
                    // HMAccessory.uniqueIdentifier itself rotates per-app.
                    self.log("  serial_number for \(accessory.name) failed all \(Self.maxSerialAttempts) attempts; pinning HMAccessory.uniqueIdentifier as fallback wireID.")
                    self.serialReadExhausted.insert(id)
                    self.recomputeAndPublish(for: accessory, reason: "serial-giveup")
                }
                return
            }

            guard let value = characteristic.value as? String else { return }
            self.infoCache[id, default: [:]][key] = value
            // Only serial_number arrives via this path now; manufacturer +
            // model are logged synchronously at discovery time in
            // considerAccessory(). Keep the same log shape for grep
            // continuity in dashboards / debug scripts.
            if key == "serial_number" {
                self.log("  \(accessory.name): \(key)=\(value)")
                // Reset retry state on success — if reachability flaps and
                // we end up re-subscribing later, the counter starts fresh.
                self.serialAttempts.removeValue(forKey: id)
            }
            self.recomputeAndPublish(for: accessory, reason: "info:\(key)")
        }
    }

    // MARK: - Pending command (CLI test mode)

    private func maybeFirePendingCommand(against accessory: HMAccessory) {
        guard !commandFired, let cmd = pendingCommand else { return }
        guard matches(accessory, identifier: cmd.nameOrUUID) else { return }
        guard accessory.isReachable else {
            log("Match for \"\(cmd.nameOrUUID)\" found but unreachable: \(accessory.name). Aborting.")
            exit(2)
        }

        guard let service = accessory.services.first(where: { $0.serviceType == HMServiceTypeLockMechanism }),
              let target = service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeTargetLockMechanismState }),
              let current = service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeCurrentLockMechanismState }) else {
            log("Lock characteristics not found on \(accessory.name)")
            exit(2)
        }

        current.readValue { [weak self] readError in
            guard let self = self else { return }
            if let readError = readError {
                self.log("Failed to read current state for \(accessory.name): \(readError.localizedDescription)")
                exit(2)
            }
            let currentRaw = (current.value as? NSNumber)?.intValue ?? 1
            let newValue: Int
            switch cmd.action {
            case .toggle: newValue = currentRaw == 0 ? 1 : 0
            case .lock:   newValue = 1
            case .unlock: newValue = 0
            }
            self.commandFired = true
            self.commandTargetUUID = accessory.uniqueIdentifier
            self.commandTargetValue = newValue
            self.log("Writing target=\(targetStateName(newValue)) on \(accessory.name) (current=\(lockStateName(currentRaw)))")

            target.writeValue(NSNumber(value: newValue)) { [weak self] writeError in
                guard let self = self else { return }
                if let writeError = writeError {
                    self.log("writeValue failed: \(writeError.localizedDescription)")
                    exit(2)
                }
                self.log("Write accepted. Waiting up to 20s for current state to confirm…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                    if self.commandFired {
                        self.log("Timeout: lock did not reach target state within 20s. Exiting.")
                        exit(3)
                    }
                }
            }
        }
    }

    private func matches(_ accessory: HMAccessory, identifier: String) -> Bool {
        let needle = identifier.lowercased()
        if accessory.name.lowercased() == needle { return true }
        if accessory.uniqueIdentifier.uuidString.lowercased() == needle { return true }
        return false
    }

    // MARK: - HMAccessoryDelegate

    func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        recomputeAndPublish(for: accessory, reason: "update:\(shortType(characteristic.characteristicType))")

        if commandFired,
           let targetUUID = commandTargetUUID, targetUUID == accessory.uniqueIdentifier,
           let targetValue = commandTargetValue,
           characteristic.characteristicType == HMCharacteristicTypeCurrentLockMechanismState,
           let raw = (characteristic.value as? NSNumber)?.intValue,
           raw == targetValue {
            log("Confirmed: \(accessory.name) current state = \(lockStateName(raw)). Exiting.")
            commandFired = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
        }
    }

    func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        let hmID = accessory.uniqueIdentifier
        log("Reachability change: \(accessory.name) reachable=\(accessory.isReachable)")
        if accessory.isReachable, trackedAccessories[hmID] != nil {
            subscribeAndRead(accessory)
            // Drain any background-write waiters for this accessory so the
            // retry fires immediately on recovery rather than waiting out
            // its backoff timer.
            if let waiters = reachabilityRecoveryWaiters.removeValue(forKey: hmID), !waiters.isEmpty {
                log("  firing \(waiters.count) reachability waiter(s) for \(accessory.name)")
                for w in waiters { w() }
            }
            // Close any open unreachable-gap event for this accessory
            // with its final wall-clock duration.
            closeUnreachableGap(for: accessory, at: Date())
        } else if !accessory.isReachable, trackedAccessories[hmID] != nil {
            // Open a new gap event. Guarded against double-open in case
            // we get back-to-back reach=false delegate calls (rare but
            // possible per Apple's docs — the property may settle).
            openUnreachableGap(for: accessory, at: Date())
        }
        recomputeAndPublish(for: accessory, reason: "reachability")
    }

    /// Open a `.unreachableGap` event for this accessory at `at`, unless
    /// one is already open. Tracks the start time in `unreachableSince`
    /// for duration computation on close.
    private func openUnreachableGap(for accessory: HMAccessory, at: Date) {
        let hmID = accessory.uniqueIdentifier
        if unreachableSince[hmID] != nil { return }  // already open
        unreachableSince[hmID] = at
        guard let log = lockEventLog else { return }
        log.record(.init(
            id: UUID(),
            accessoryName: accessory.name,
            accessoryID: hmID.uuidString,
            timestamp: at,
            kind: .unreachableGap(durationSec: nil)
        ))
    }

    /// Close the most recently opened, still-open `.unreachableGap`
    /// event for this accessory, recording the final duration. No-op if
    /// no gap is currently tracked (either we never saw the close-side
    /// transition, or the event has aged out of the buffer).
    private func closeUnreachableGap(for accessory: HMAccessory, at: Date) {
        let hmID = accessory.uniqueIdentifier
        guard let started = unreachableSince.removeValue(forKey: hmID) else { return }
        let duration = at.timeIntervalSince(started)
        guard let log = lockEventLog,
              let eventID = log.openGapID(forAccessory: hmID.uuidString) else { return }
        log.update(id: eventID) { e in
            e.kind = .unreachableGap(durationSec: duration)
        }
    }

    func accessoryDidUpdateName(_ accessory: HMAccessory) {
        recomputeAndPublish(for: accessory, reason: "rename")
    }

    // MARK: - Publish

    private func recomputeAndPublish(for accessory: HMAccessory, reason: String) {
        let id = accessory.uniqueIdentifier
        // Zombie guard: a late-arriving in-flight completion (background-write
        // callback, serial read, subscribe callback) can call this for an
        // accessory that `forgetAccessory` already removed — which would
        // resurrect it as a phantom, uncontrollable HA entity (it's no longer
        // in trackedAccessories, so commands would fail). Bail unless the
        // accessory is still tracked. The legitimate initial-publish paths
        // (considerAccessory / subscribeAndRead) always run AFTER the
        // accessory is inserted into trackedAccessories, so they pass.
        guard trackedAccessories[id] != nil else {
            log("Ignoring recomputeAndPublish (\(reason)) for untracked accessory \(accessory.name) [\(id.uuidString)] — already removed")
            return
        }
        // Start from the cached info (currently just serial_number from the
        // characteristic-read path) and overlay the live HMAccessory
        // properties for manufacturer / model / firmwareVersion. These were
        // previously read as characteristics but those types are deprecated
        // on Mac Catalyst and unavailable on macOS — the direct accessor
        // properties are Apple's replacement.
        var info = infoCache[id] ?? [:]
        if let m = accessory.manufacturer { info["manufacturer"] = m }
        if let m = accessory.model { info["model"] = m }
        if let fv = accessory.firmwareVersion { info["firmware_version"] = fv }

        // Detect target_state change so the lifecycle derivation can produce
        // "locking"/"unlocking" during the transition window.
        let newTargetRaw: Int? = accessory.services
            .flatMap { $0.characteristics }
            .first { $0.characteristicType == HMCharacteristicTypeTargetLockMechanismState }
            .flatMap { ($0.value as? NSNumber)?.intValue }
        let priorTargetRaw = stateStore[id]?.targetStateRaw
        if let nt = newTargetRaw, nt != priorTargetRaw {
            lastTargetChange[id] = Date()
            // An external retarget (someone changed the target via Apple Home,
            // HomeKey, another controller, etc.) in a different direction
            // supersedes a hung command — drop the stale hang marker so we
            // stop showing the old transition forever.
            if let hung = hangingWrites[id], hung.target != nt {
                log("Lock \(accessory.name): hung write (target=\(hung.target)) superseded by external retarget=\(nt)")
                hangingWrites.removeValue(forKey: id)
            }
        }

        let computed = AccessoryState.from(
            accessory: accessory,
            info: info,
            // Display-only home prefix, surfaced only in multi-home setups.
            // NOT fed into stableID or the identity cache (those still use the
            // bare accessory name), so this can't reassign existing wire ids.
            homeName: homeManager.homes.count > 1 ? homeNameForAccessory[id] : nil,
            lastTargetChange: lastTargetChange[id],
            // While a command is outstanding-and-unconfirmed, keep showing the
            // transition indefinitely (the HA "hang") instead of settling to
            // the stale current_state after the window. Confirmation (c == t)
            // still settles immediately — see deriveLifecycle.
            transitionWindow: hasOutstandingWrite(id) ? .greatestFiniteMagnitude : Self.writeBudgetSeconds
        )

        // Pin the wire ID via the persistent identity cache so it stays
        // constant across re-signs, reachability flapping, and async info
        // reads completing in different orders. Three cases for *when*
        // we're willing to commit a wire ID to the cache:
        //
        //   1. Serial is already in `info` → the SHA-hash ID is the
        //      best-possible identifier (content-addressed, never rotates).
        //      Pin it. This is the path we *want* every accessory to take.
        //
        //   2. The accessory exposes no SerialNumber characteristic at all
        //      → no read is coming, ever. The fallback HMAccessory UUID is
        //      all we'll ever have. Pin it; the cache's (home, name)
        //      secondary index keeps it stable across re-signs even though
        //      HMAccessory.uniqueIdentifier itself rotates.
        //
        //   3. SerialNumber characteristic exists but the async read hasn't
        //      returned yet → don't commit. If the cache already has a
        //      record from a previous run, honor it (likely already the
        //      serial-hash). Otherwise publish the computed fallback ID
        //      WITHOUT pinning, so the next recomputeAndPublish (after the
        //      read completes) gets to write the proper serial-hash to
        //      the cache.
        //
        // This avoids the bug where the "initial" publish raced ahead of
        // the serial read and pinned a fallback UUID for accessories whose
        // proper ID would have been a stable serial-hash, then watched HA's
        // entity registry orphan everything on the next re-sign.
        let pinnedID: String
        if let cache = identityCache {
            let hasSerialNow = !(info["serial_number"]?.isEmpty ?? true)
            let hasSerialChar = accessory.services.contains { svc in
                svc.characteristics.contains { ch in
                    ch.characteristicType == HMCharacteristicTypeSerialNumber
                }
            }
            // serialReadExhausted = retries have run their course; treat the
            // accessory as if it never had a SerialNumber characteristic
            // (commit the current fallback HMAccessory.uniqueIdentifier to
            // the cache so future re-signs use (home, name) lookup to keep
            // it stable).
            let serialGivenUp = serialReadExhausted.contains(id)
            if hasSerialNow || !hasSerialChar || serialGivenUp {
                // When a serial is in hand, `computed.id` is the content-
                // addressed serial-hash — pass it as `serialHash` so the cache
                // can verify (and refuse) a same-name migration that would
                // otherwise swap this lock's wire ID onto a different physical
                // lock. Nil when there's no serial (fallback UUID, unverifiable).
                pinnedID = cache.wireID(
                    forHMUUID: id.uuidString,
                    accessoryName: accessory.name,
                    homeName: homeNameForAccessory[id],
                    serialHash: hasSerialNow ? computed.id : nil,
                    computeIfMissing: { computed.id }
                )
            } else if let existing = cache.peekWireID(
                forHMUUID: id.uuidString,
                accessoryName: accessory.name,
                homeName: homeNameForAccessory[id]
            ) {
                pinnedID = existing
            } else {
                // Read pending, no cache entry — publish fallback transiently,
                // don't commit. The next publish (success or serial-giveup)
                // will pin the right wireID.
                pinnedID = computed.id
            }
        } else {
            pinnedID = computed.id
        }
        let newState = computed.with(id: pinnedID)

        // External-satisfaction shortcut: if a background write is pending
        // for this accessory and the *live* current_state we just computed
        // already matches the pending target, the user's intent was
        // achieved by some other path (HomeKey tap, manual operation,
        // another HomeKit controller). Cancel the retry and let the
        // natural lifecycle settle. Note this runs BEFORE the dedup check
        // below so it triggers even on no-op recomputes.
        if let pending = pendingWrites[id], let cr = newState.currentStateRaw, cr == pending.target {
            // If homed already accepted our write (acked), reaching the target
            // is OUR command confirming → `.succeeded`. If it hasn't acked yet
            // (still retrying / pre-ack), the target was reached by some other
            // path (HomeKey, manual, another controller) → `.satisfiedExternally`.
            let outcome: LockEventLog.WriteOutcome = pending.acked ? .succeeded : .satisfiedExternally
            log("Lock \(accessory.name): pending write target=\(pending.target) confirmed (\(outcome.rawValue)); cancelling background retry")
            pending.completed = true
            pendingWrites.removeValue(forKey: id)
            recordSlowConfirmIfNeeded(target: pending.target, startedAt: pending.startedAt,
                                      hadRetryEvent: pending.retryLogEventID != nil, accessory: accessory)
            closeWriteRetryEvent(pending: pending, outcome: outcome)
            notifyIfAllWritesSettled()
            // Clearing the transition window lets deriveLifecycle return
            // a stable "locked"/"unlocked" since current==target. We don't
            // change `newState.lifecycleState` here — the next
            // recomputeAndPublish (driven by a subsequent HMCharacteristic
            // update or a natural quiescence) will pick this up cleanly,
            // and the optimistic state we published earlier will fade
            // into the stable state via that path.
            lastTargetChange.removeValue(forKey: id)
        }

        // Late confirmation of a previously-hung (`.unconfirmed`) write: the
        // lock finally reached the target. Clear the hang and flip its warning
        // to succeeded. (An id is only ever in pendingWrites OR hangingWrites,
        // never both, so this and the block above don't both fire.) `newState`
        // was computed with current==target, so deriveLifecycle already
        // returned the settled state — publishing it below ends the HA hang.
        if let hung = hangingWrites[id], let cr = newState.currentStateRaw, cr == hung.target {
            resolveHangingWrite(hung, id: id, accessoryName: accessory.name)
        }

        let prior = stateStore[id]
        stateStore[id] = newState

        // Wire-ID change → emit `removed` for the OLD id before publishing the
        // new one. This is the root-cause fix for the v0.5.3 duplicate-lock
        // bug: a newly-added lock is first published under a fallback wire id
        // (serial read still in flight), then under its stable serial-hash id.
        // Without a `removed` for the fallback, HA's `client.states`
        // accumulates BOTH until a reconnect. Only fire when the prior state
        // was healthy (already published to HA) so we don't emit spurious
        // removals for ghosts that never reached the API surface. Also drop
        // the stale reverse-map entry so a late inbound command on the old
        // wire id can't mis-route.
        if let prior = prior, prior.id != newState.id, isHealthy(prior) {
            log("Lock \(accessory.name): wire id changed \(prior.id) → \(newState.id); emitting removed for the old id")
            if let oldWireUUID = UUID(uuidString: prior.id) {
                wireIDToHMUUID.removeValue(forKey: oldWireUUID)
                for o in observers { o.onRemoved(oldWireUUID) }
            }
        }

        // Refresh the reverse map every publish. With the identity cache in
        // place the wire ID rarely changes after first sight, but the map
        // still needs to be populated initially so /accessories/{id}/state
        // commands route correctly.
        if let wireUUID = UUID(uuidString: newState.id) {
            wireIDToHMUUID[wireUUID] = id
        }

        // Dedupe — skip notifying observers + stdout when nothing material changed.
        if let prior = prior, prior.equalsIgnoringTimestamp(newState) { return }

        // Keep ghosts out of the API surface. They still get the debug
        // stdout line (useful for diagnosing why a device isn't showing up)
        // but observers (and therefore WS / HTTP) never see them.
        emitDebugJSON(newState: newState, reason: reason)
        guard isHealthy(newState) else { return }
        for o in observers {
            o.onState(newState)
        }
    }

    private func emitDebugJSON(newState: AccessoryState, reason: String) {
        guard let data = try? JSONEncoder.sortedKeys.encode(newState),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        obj["reason"] = reason
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              var line = String(data: out, encoding: .utf8) else { return }
        line.append("\n")
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    // MARK: - Helpers

    private func describe(_ status: HMHomeManagerAuthorizationStatus) -> String {
        var parts: [String] = []
        if status.contains(.determined) { parts.append("determined") }
        if status.contains(.authorized) { parts.append("authorized") }
        if status.contains(.restricted) { parts.append("restricted") }
        return parts.isEmpty ? "undetermined" : parts.joined(separator: "|")
    }

    private func shortType(_ uuidString: String) -> String {
        switch uuidString {
        case HMCharacteristicTypeCurrentLockMechanismState: return "current_state"
        case HMCharacteristicTypeTargetLockMechanismState: return "target_state"
        case HMCharacteristicTypeBatteryLevel: return "battery_level"
        case HMCharacteristicTypeStatusLowBattery: return "low_battery"
        case HMCharacteristicTypeSerialNumber: return "serial_number"
        default: return uuidString
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[ha-lockbridge] \(message)\n".utf8))
    }
}

extension JSONEncoder {
    static var sortedKeys: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }
}
