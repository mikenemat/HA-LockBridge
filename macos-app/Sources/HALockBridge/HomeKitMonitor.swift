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

    /// Reverse map from the *wire* ID (the stable hash we publish to HA) to
    /// the underlying HMAccessory.uniqueIdentifier. Populated by
    /// `recomputeAndPublish` and cleared in `forgetAccessory`. Used to route
    /// HA's inbound `/accessories/{id}` and POST `.../state` calls — those
    /// arrive with the wire ID, and we need the HMAccessory UUID to talk to
    /// HomeKit. Without this, every lock/unlock command would fail with
    /// "accessory not known to bridge" because trackedAccessories is keyed
    /// by HMAccessory.uniqueIdentifier, not by the published wire ID.
    private var wireIDToHMUUID: [UUID: UUID] = [:]

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

    /// Set lock target state. Completion called on main thread.
    /// Returns immediately after HomeKit acknowledges the write; the current_state
    /// update will arrive separately via the observer pipeline.
    func setLockState(id: UUID, target: Int, completion: @escaping (SetLockResult) -> Void) {
        // Resolve the wire ID HA sent us to the HMAccessory UUID. See the
        // comment on `wireIDToHMUUID` for why this exists.
        let hmID = wireIDToHMUUID[id] ?? id
        guard let accessory = trackedAccessories[hmID] else {
            completion(.notFound); return
        }
        guard accessory.isReachable else {
            completion(.unreachable); return
        }
        guard let service = accessory.services.first(where: { $0.serviceType == HMServiceTypeLockMechanism }),
              let targetChar = service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeTargetLockMechanismState }) else {
            completion(.homekitError("lock characteristic missing")); return
        }

        let timeoutWork = DispatchWorkItem { completion(.timeout) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeoutWork)

        targetChar.writeValue(NSNumber(value: target)) { [weak self] error in
            guard !timeoutWork.isCancelled else { return }
            timeoutWork.cancel()
            if let error = error {
                completion(.homekitError(error.localizedDescription))
                return
            }
            // Mark the target change so a subsequent state recompute returns
            // the right `lifecycle_state` ("locking"/"unlocking") even if our
            // HMAccessoryDelegate hasn't received the target update yet.
            self?.lastTargetChange[hmID] = Date()
            self?.recomputeAndPublish(for: accessory, reason: "post-write")
            let state = self?.stateStore[hmID] ?? AccessoryState.from(
                accessory: accessory,
                info: self?.infoCache[hmID] ?? [:],
                lastTargetChange: self?.lastTargetChange[hmID]
            )
            completion(.ok(state))
        }
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
                considerAccessory(accessory)
            }
        }
        if manager.homes.isEmpty {
            log("No homes returned. If this Mac is signed into iCloud with HomeKit sync, give it a few minutes — sync can lag on first run.")
        }
    }

    func homeManager(_ manager: HMHomeManager, didAdd home: HMHome) {
        log("Home added: \(home.name)")
        home.delegate = self
        for accessory in home.accessories { considerAccessory(accessory) }
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
        considerAccessory(accessory)
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
        for o in observers {
            o.onRemoved(removedWireID)
        }
    }

    // MARK: - Accessory discovery

    private func considerAccessory(_ accessory: HMAccessory) {
        let lockServices = accessory.services.filter { $0.serviceType == HMServiceTypeLockMechanism }
        guard !lockServices.isEmpty else { return }

        if trackedAccessories[accessory.uniqueIdentifier] != nil { return }
        trackedAccessories[accessory.uniqueIdentifier] = accessory

        log("Lock discovered: \(accessory.name) [\(accessory.uniqueIdentifier.uuidString)] reachable=\(accessory.isReachable)")
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
        characteristic.readValue { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.log("readValue (info) failed for \(self.shortType(characteristic.characteristicType)) on \(accessory.name): \(error.localizedDescription)")
                return
            }
            guard let value = characteristic.value as? String else { return }
            let key = self.shortType(characteristic.characteristicType)
            self.infoCache[accessory.uniqueIdentifier, default: [:]][key] = value
            // Only serial_number arrives via this path now; manufacturer +
            // model are logged synchronously at discovery time in
            // considerAccessory(). Keep the same log shape for grep
            // continuity in dashboards / debug scripts.
            if key == "serial_number" {
                self.log("  \(accessory.name): \(key)=\(value)")
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
        log("Reachability change: \(accessory.name) reachable=\(accessory.isReachable)")
        if accessory.isReachable, trackedAccessories[accessory.uniqueIdentifier] != nil {
            subscribeAndRead(accessory)
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

        let newState = AccessoryState.from(
            accessory: accessory,
            info: info,
            lastTargetChange: lastTargetChange[id]
        )
        let prior = stateStore[id]
        stateStore[id] = newState

        // Refresh the reverse map every publish — the wire ID can change at
        // runtime when initial info reads complete (e.g. SerialNumber arrives
        // after manufacturer/model), shifting from the fallback HM UUID to a
        // stable hash. Always overwriting is cheap and correct.
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
