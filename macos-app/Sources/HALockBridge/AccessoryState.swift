import Foundation
import HomeKit
import CryptoKit

struct AccessoryState: Codable, Equatable {
    let id: String
    let name: String
    let manufacturer: String?
    let model: String?
    let firmwareVersion: String?
    let serialNumber: String?
    let reachable: Bool
    let currentState: String?
    let currentStateRaw: Int?
    let targetState: String?
    let targetStateRaw: Int?
    let lifecycleState: String
    let batteryLevel: Int?
    let lowBattery: Bool?
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, manufacturer, model
        case firmwareVersion = "firmware_version"
        case serialNumber = "serial_number"
        case reachable
        case currentState = "current_state"
        case currentStateRaw = "current_state_raw"
        case targetState = "target_state"
        case targetStateRaw = "target_state_raw"
        case lifecycleState = "lifecycle_state"
        case batteryLevel = "battery_level"
        case lowBattery = "low_battery"
        case updatedAt = "updated_at"
    }

    /// Return a copy with `target_state` and `lifecycle_state` overlaid with
    /// the requested target, recomputing lifecycle from current/target/now.
    /// Used by setLockState's async-accept path to synthesize an optimistic
    /// state for HA before HomeKit has actually accepted the write — the
    /// HMCharacteristic value for target hasn't been written yet, so we
    /// can't get this from `AccessoryState.from` directly.
    func with(target newTargetRaw: Int, lastTargetChange: Date?, now: Date = Date()) -> AccessoryState {
        let newLifecycle = deriveLifecycle(
            current: self.currentStateRaw,
            target: newTargetRaw,
            reachable: self.reachable,
            lastTargetChange: lastTargetChange,
            now: now
        )
        return AccessoryState(
            id: self.id,
            name: self.name,
            manufacturer: self.manufacturer,
            model: self.model,
            firmwareVersion: self.firmwareVersion,
            serialNumber: self.serialNumber,
            reachable: self.reachable,
            currentState: self.currentState,
            currentStateRaw: self.currentStateRaw,
            targetState: targetStateName(newTargetRaw),
            targetStateRaw: newTargetRaw,
            lifecycleState: newLifecycle,
            batteryLevel: self.batteryLevel,
            lowBattery: self.lowBattery,
            updatedAt: iso8601.string(from: now)
        )
    }

    /// Return a copy with `id` replaced. Used by HomeKitMonitor to pin the
    /// wire ID from AccessoryIdentityCache after construction — the cache
    /// holds the immutable wire ID chosen at first sight, which may differ
    /// from what `stableID()` would compute on this run if the accessory's
    /// manufacturer/model/serial weren't all available the first time.
    func with(id newID: String) -> AccessoryState {
        return AccessoryState(
            id: newID,
            name: name,
            manufacturer: manufacturer,
            model: model,
            firmwareVersion: firmwareVersion,
            serialNumber: serialNumber,
            reachable: reachable,
            currentState: currentState,
            currentStateRaw: currentStateRaw,
            targetState: targetState,
            targetStateRaw: targetStateRaw,
            lifecycleState: lifecycleState,
            batteryLevel: batteryLevel,
            lowBattery: lowBattery,
            updatedAt: updatedAt
        )
    }

    /// Equality used for dedupe — ignores `updatedAt`.
    func equalsIgnoringTimestamp(_ other: AccessoryState) -> Bool {
        return id == other.id
            && name == other.name
            && manufacturer == other.manufacturer
            && model == other.model
            && firmwareVersion == other.firmwareVersion
            && serialNumber == other.serialNumber
            && reachable == other.reachable
            && currentState == other.currentState
            && currentStateRaw == other.currentStateRaw
            && targetState == other.targetState
            && targetStateRaw == other.targetStateRaw
            && lifecycleState == other.lifecycleState
            && batteryLevel == other.batteryLevel
            && lowBattery == other.lowBattery
    }

    static func from(accessory: HMAccessory, info: [String: String], lastTargetChange: Date? = nil, now: Date = Date()) -> AccessoryState {
        var current: Int?
        var target: Int?
        var battery: Int?
        var low: Bool?

        for service in accessory.services {
            for ch in service.characteristics {
                switch ch.characteristicType {
                case HMCharacteristicTypeCurrentLockMechanismState:
                    current = (ch.value as? NSNumber)?.intValue
                case HMCharacteristicTypeTargetLockMechanismState:
                    target = (ch.value as? NSNumber)?.intValue
                case HMCharacteristicTypeBatteryLevel:
                    battery = (ch.value as? NSNumber)?.intValue
                case HMCharacteristicTypeStatusLowBattery:
                    if let raw = (ch.value as? NSNumber)?.intValue { low = raw != 0 }
                default: break
                }
            }
        }

        let lifecycle = deriveLifecycle(
            current: current,
            target: target,
            reachable: accessory.isReachable,
            lastTargetChange: lastTargetChange,
            now: now
        )

        return AccessoryState(
            id: stableID(
                manufacturer: info["manufacturer"],
                model: info["model"],
                serialNumber: info["serial_number"],
                fallback: accessory.uniqueIdentifier
            ),
            name: accessory.name,
            manufacturer: info["manufacturer"],
            model: prettifyModel(manufacturer: info["manufacturer"], model: info["model"]),
            firmwareVersion: info["firmware_version"],
            serialNumber: info["serial_number"],
            reachable: accessory.isReachable,
            currentState: current.flatMap(lockStateName),
            currentStateRaw: current,
            targetState: target.flatMap(targetStateName),
            targetStateRaw: target,
            lifecycleState: lifecycle,
            batteryLevel: battery,
            lowBattery: low,
            updatedAt: iso8601.string(from: now)
        )
    }
}

/// Sleekpoint Innovations (the OEM that makes ThorBolt) reports model strings
/// like "X1", "X3", etc. without the brand prefix. Prepend "ThorBolt " so the
/// HA UI shows recognizable model names like "ThorBolt X1" instead of "X1".
func prettifyModel(manufacturer: String?, model: String?) -> String? {
    guard let model = model else { return nil }
    guard manufacturer == "Sleekpoint Innovations" else { return model }
    if model.hasPrefix("ThorBolt") { return model }
    return "ThorBolt \(model)"
}

/// Maps to HA's lock entity state strings (locked / unlocked / locking / unlocking / jammed / unknown).
///
/// Rules:
/// - `current == 2` (HomeKit "jammed") → `jammed` regardless of target
/// - `current == target` → stable `locked` / `unlocked` from current
/// - `current != target` AND target changed within `transitionWindow` → `locking` / `unlocking`
/// - `current != target` AND target change is stale → fall back to current. This handles
///   the "someone physically operated the lock and target_state is stale" case — better
///   to report what physically *is* than to claim an animation that isn't happening.
func deriveLifecycle(
    current: Int?,
    target: Int?,
    reachable: Bool,
    lastTargetChange: Date?,
    now: Date,
    // Matched to `writeBudgetSeconds` in HomeKitMonitor.setLockState so
    // HA's UI keeps showing "locking"/"unlocking" for the entire retry
    // window rather than reverting to a stable state derived from the
    // stale current_state. Bumped 15s → 30s → 90s in lockstep with the
    // retry budget; see the comment on writeBudgetSeconds for why
    // 90s covers most real-world deep-sleep wake-up paths.
    transitionWindow: TimeInterval = 90
) -> String {
    if current == 2 { return "jammed" }
    guard let c = current else { return "unknown" }

    // If we don't know target yet, derive from current alone
    guard let t = target else {
        switch c {
        case 1: return "locked"
        case 0: return "unlocked"
        default: return "unknown"
        }
    }

    if c == t {
        switch c {
        case 1: return "locked"
        case 0: return "unlocked"
        default: return "unknown"
        }
    }

    // current != target
    if let last = lastTargetChange, now.timeIntervalSince(last) < transitionWindow {
        switch t {
        case 1: return "locking"
        case 0: return "unlocking"
        default: break
        }
    }

    // Stale mismatch — trust current_state, not the heuristic
    switch c {
    case 1: return "locked"
    case 0: return "unlocked"
    default: return "unknown"
    }
}

private let iso8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

/// Derive a wire-level accessory ID that survives the bridge's per-app
/// HomeKit identity changes.
///
/// Why this exists: `HMAccessory.uniqueIdentifier` is per-app on iOS/tvOS/Mac
/// Catalyst. Every time the app's signing identity changes (free-tier
/// provisioning profile rotates every 7 days, paid-tier cert renews, etc.),
/// HomeKit re-issues fresh UUIDs for the same physical accessories. HA's
/// entity registry then sees the new IDs as different devices, orphaning
/// every entity on the user. Untenable for a "leave it in a closet" bridge.
///
/// The fix: hash the lock's manufacturer-reported identity. Serial numbers
/// come from the physical lock firmware (HMCharacteristicTypeSerialNumber),
/// so they're stable across every app-side change. We hash with manufacturer
/// and the *raw* model string (not the prettified version, so changes to
/// `prettifyModel` don't shift IDs) and trim the SHA-256 hex down to 32 chars
/// formatted as a UUID — so HA's existing zeroconf/unique_id plumbing keeps
/// treating the value as opaque.
///
/// When any of manufacturer / model / serial are missing (initial discovery
/// before reads complete; locks-that-don't-implement-SerialNumber; or
/// locks-currently-unreachable), fall back to `HMAccessory.uniqueIdentifier`
/// so the bridge still publishes *something*. The reachability-retry path in
/// HomeKitMonitor re-reads info characteristics when a lock comes back
/// online, at which point the next published state will carry the stable ID
/// and HA picks it up as a new entity. A one-time orphan on first upgrade
/// is the only cost; after that it's stable forever.
func stableID(manufacturer: String?, model: String?, serialNumber: String?, fallback: UUID) -> String {
    guard let manufacturer = manufacturer, !manufacturer.isEmpty,
          let model = model, !model.isEmpty,
          let serialNumber = serialNumber, !serialNumber.isEmpty else {
        return fallback.uuidString
    }
    let raw = "\(manufacturer)|\(model)|\(serialNumber)"
    let digest = SHA256.hash(data: Data(raw.utf8))
    let hex = digest.map { String(format: "%02X", $0) }.joined()
    let s = String(hex.prefix(32))
    // 8-4-4-4-12 like a UUID.
    return [
        s.prefix(8),
        s.dropFirst(8).prefix(4),
        s.dropFirst(12).prefix(4),
        s.dropFirst(16).prefix(4),
        s.dropFirst(20).prefix(12),
    ].map(String.init).joined(separator: "-")
}

func lockStateName(_ raw: Int) -> String {
    switch raw {
    case 0: return "unsecured"
    case 1: return "secured"
    case 2: return "jammed"
    case 3: return "unknown"
    default: return "invalid(\(raw))"
    }
}

func targetStateName(_ raw: Int) -> String {
    switch raw {
    case 0: return "unsecured"
    case 1: return "secured"
    default: return "invalid(\(raw))"
    }
}
