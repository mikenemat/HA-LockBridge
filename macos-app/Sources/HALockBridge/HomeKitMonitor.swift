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
        var completed: Bool = false
        var triggered: Bool = false
        var attempt: Int = 0

        init(target: Int, priorState: AccessoryState?, deadline: Date) {
            self.target = target
            self.priorState = priorState
            self.deadline = deadline
        }
    }

    /// Backoff schedule for the background write retry loop. After exhausting
    /// the array we cap at the last value. Cumulative: 1+2+4+8+8+8 ≈ 31s of
    /// retry potential, which matches the 30s deadline. A reachability
    /// recovery callback can fire the next retry immediately, ignoring the
    /// scheduled delay.
    private static let writeBackoffDelays: [Double] = [1.0, 2.0, 4.0, 8.0]
    /// Background retry budget. Matches the `transitionWindow` in
    /// `deriveLifecycle` so HA's UI shows "locking"/"unlocking" for the
    /// entire retry window without prematurely settling.
    private static let writeBudgetSeconds: TimeInterval = 30

    typealias StateObserver = (AccessoryState) -> Void
    typealias RemovalObserver = (UUID) -> Void

    final class ObserverToken {
        fileprivate let id = UUID()
    }

    // MARK: - Internals

    private let homeManager = HMHomeManager()
    private var trackedAccessories: [UUID: HMAccessory] = [:]
    private var infoCache: [UUID: [String: String]] = [:]
    private var stateStore: [UUID: AccessoryState] = [:]
    private var lastTargetChange: [UUID: Date] = [:]
    private var observers: [(token: ObserverToken, onState: StateObserver, onRemoved: RemovalObserver)] = []
    /// Home name per accessory, populated during enumeration. Needed by the
    /// AccessoryIdentityCache so it can match by (homeName, accessoryName)
    /// after a re-sign rotates HMAccessory.uniqueIdentifier.
    private var homeNameForAccessory: [UUID: String] = [:]
    /// Persistent identity pinning. Injected from AppDelegate before
    /// `start()` so that the first `recomputeAndPublish` for each accessory
    /// already routes through the cache. Optional only to keep tests +
    /// CLI-mode paths buildable without one — real launches always set it.
    var identityCache: AccessoryIdentityCache?
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

    /// Callbacks waiting for an accessory's reachability to flip back to
    /// `true`. Fired and drained by `accessoryDidUpdateReachability` when
    /// the accessory becomes reachable. Used by the background write retry
    /// loop to retry immediately on recovery instead of waiting out the
    /// backoff timer.
    private var reachabilityRecoveryWaiters: [UUID: [() -> Void]] = [:]

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

    /// Registers a pair of callbacks. Returns a token used for removal.
    /// Both callbacks are invoked on the main thread.
    func addObserver(onState: @escaping StateObserver, onRemoved: @escaping RemovalObserver) -> ObserverToken {
        let token = ObserverToken()
        observers.append((token, onState, onRemoved))
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
    /// when the HomeKit hub re-establishes contact with the lock. On
    /// success the real `current_state` update arrives via the observer
    /// pipeline; on exhaustion the optimistic state is silently reverted.
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

        // Cancel any prior in-flight write for this accessory. The user
        // has changed their mind (e.g. tapped Unlock while a previous Lock
        // command was still retrying); the old retry loop becomes a no-op
        // on its next callback by checking `completed`.
        if let existing = pendingWrites[hmID] {
            log("Lock \(accessory.name): superseding prior pending write (target=\(existing.target)) with new target=\(target)")
            existing.completed = true
            pendingWrites.removeValue(forKey: hmID)
        }

        // Capture the pre-optimistic-update state for potential revert. If
        // there's no prior state in the store, fall back to nil — revert
        // logic handles that case by recomputing from HMCharacteristic.
        let priorState = stateStore[hmID]

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
            deadline: Date().addingTimeInterval(Self.writeBudgetSeconds)
        )
        pendingWrites[hmID] = pending

        // Safety net: a deadline timer that calls revert() if the loop is
        // still pending when the budget expires. The retry loop also
        // checks the deadline before scheduling, so in the common case the
        // loop's own check fires first and the safety net is a no-op.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.writeBudgetSeconds) { [weak self] in
            guard let self = self, let still = self.pendingWrites[hmID], still === pending, !still.completed else { return }
            self.log("Lock \(accessory.name): write budget (\(Int(Self.writeBudgetSeconds))s) elapsed via safety timer")
            self.revertPending(hmID: hmID, accessory: accessory, pending: still)
        }

        attemptBackgroundWrite(targetChar: targetChar, accessory: accessory, hmID: hmID, pending: pending)
    }

    /// One write attempt for a pending background write. Reschedules itself
    /// on transient `HMError 82` until the deadline; calls `revertPending`
    /// or `completeSuccess` on terminal outcomes. Always called on the
    /// main thread.
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
                    self.revertPending(hmID: hmID, accessory: accessory, pending: pending)
                    return
                }
                if Date() >= pending.deadline {
                    self.log("Lock \(accessory.name): background write budget exhausted after \(thisAttempt) attempt(s); reverting")
                    self.revertPending(hmID: hmID, accessory: accessory, pending: pending)
                    return
                }
                let delayIdx = min(thisAttempt - 1, Self.writeBackoffDelays.count - 1)
                let delay = Self.writeBackoffDelays[delayIdx]
                self.log("Lock \(accessory.name): write rejected as not-reachable (attempt \(thisAttempt), retry in up to \(delay)s or on reachability recovery)")

                // The fire closure is idempotent — only the first caller
                // (timer OR reachability waiter) actually triggers the
                // next attempt. The other is a no-op.
                let fire: () -> Void = { [weak self] in
                    guard let self = self, !pending.completed, !pending.triggered else { return }
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

            // Success. Refresh the transition window so HA's UI shows
            // "locking"/"unlocking" until current_state physically matches
            // target, then re-publish from live HMCharacteristic so any
            // characteristic updates that landed during the retry are
            // reflected. (The optimistic state already has target=target,
            // so dedup will typically skip the broadcast unless other
            // fields changed.)
            self.log("Lock \(accessory.name): background write accepted on attempt \(thisAttempt)")
            pending.completed = true
            self.pendingWrites.removeValue(forKey: hmID)
            self.lastTargetChange[hmID] = Date()
            self.recomputeAndPublish(for: accessory, reason: "post-write")
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
    private func revertPending(hmID: UUID, accessory: HMAccessory, pending: PendingWrite) {
        guard !pending.completed else { return }
        pending.completed = true
        pendingWrites.removeValue(forKey: hmID)
        lastTargetChange.removeValue(forKey: hmID)

        let liveCurrent: Int? = accessory.services
            .flatMap { $0.characteristics }
            .first { $0.characteristicType == HMCharacteristicTypeCurrentLockMechanismState }
            .flatMap { ($0.value as? NSNumber)?.intValue }

        if let c = liveCurrent, c == pending.target {
            log("Lock \(accessory.name): physical current_state already matches pending target=\(pending.target); skipping revert")
            recomputeAndPublish(for: accessory, reason: "write-giveup-already-at-target")
            return
        }

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
        }
    }

    func homeManager(_ manager: HMHomeManager, didAdd home: HMHome) {
        log("Home added: \(home.name)")
        home.delegate = self
        for accessory in home.accessories { considerAccessory(accessory, in: home) }
    }

    func homeManager(_ manager: HMHomeManager, didRemove home: HMHome) {
        log("Home removed: \(home.name) — \(home.accessories.count) accessories")
        for accessory in home.accessories {
            forgetAccessory(accessory.uniqueIdentifier, name: accessory.name)
        }
    }

    // MARK: - HMHomeDelegate

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
        reachabilityRecoveryWaiters.removeValue(forKey: id)
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

        if trackedAccessories[accessory.uniqueIdentifier] != nil { return }
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
            // Still publish the initial (unreachable) state so consumers know it exists.
            recomputeAndPublish(for: accessory, reason: "initial-unreachable")
        }

        maybeFirePendingCommand(against: accessory)
    }

    private func subscribeAndRead(_ accessory: HMAccessory) {
        let notifyingTypes: Set<String> = [
            HMCharacteristicTypeCurrentLockMechanismState,
            HMCharacteristicTypeTargetLockMechanismState,
            HMCharacteristicTypeBatteryLevel,
            HMCharacteristicTypeStatusLowBattery,
        ]
        // Only SerialNumber is read as a characteristic. The other three
        // (Manufacturer, Model, FirmwareVersion) are deprecated since iOS 11
        // and unavailable on macOS — Apple's replacement is direct
        // HMAccessory.manufacturer / .model / .firmwareVersion properties,
        // which we read synchronously in recomputeAndPublish. SerialNumber
        // has no equivalent property and stays on the characteristic path.
        let readOnceTypes: Set<String> = [
            HMCharacteristicTypeSerialNumber,
        ]

        for service in accessory.services {
            for characteristic in service.characteristics {
                if notifyingTypes.contains(characteristic.characteristicType) {
                    subscribe(characteristic, accessory: accessory)
                } else if readOnceTypes.contains(characteristic.characteristicType) {
                    readInfo(characteristic, accessory: accessory)
                }
            }
        }

        recomputeAndPublish(for: accessory, reason: "initial")
    }

    private func subscribe(_ characteristic: HMCharacteristic, accessory: HMAccessory) {
        characteristic.enableNotification(true) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.log("enableNotification failed for \(self.shortType(characteristic.characteristicType)) on \(accessory.name): \(error.localizedDescription)")
                return
            }
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
        }
        recomputeAndPublish(for: accessory, reason: "reachability")
    }

    func accessoryDidUpdateName(_ accessory: HMAccessory) {
        recomputeAndPublish(for: accessory, reason: "rename")
    }

    // MARK: - Publish

    private func recomputeAndPublish(for accessory: HMAccessory, reason: String) {
        let id = accessory.uniqueIdentifier
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
        }

        let computed = AccessoryState.from(
            accessory: accessory,
            info: info,
            lastTargetChange: lastTargetChange[id]
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
                pinnedID = cache.wireID(
                    forHMUUID: id.uuidString,
                    accessoryName: accessory.name,
                    homeName: homeNameForAccessory[id],
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
            log("Lock \(accessory.name): pending write target=\(pending.target) satisfied by external change; cancelling background retry")
            pending.completed = true
            pendingWrites.removeValue(forKey: id)
            // Clearing the transition window lets deriveLifecycle return
            // a stable "locked"/"unlocked" since current==target. We don't
            // change `newState.lifecycleState` here — the next
            // recomputeAndPublish (driven by a subsequent HMCharacteristic
            // update or a natural quiescence) will pick this up cleanly,
            // and the optimistic state we published earlier will fade
            // into the stable state via that path.
            lastTargetChange.removeValue(forKey: id)
        }

        let prior = stateStore[id]
        stateStore[id] = newState

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
