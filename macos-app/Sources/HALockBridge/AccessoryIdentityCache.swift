import Foundation

/// Persistent record of the wire ID we've chosen for one physical lock.
struct AccessoryIdentityRecord: Codable, Equatable {
    /// The wire ID published to HA. Immutable once written.
    var wireID: String
    /// Most recently observed HMAccessory.uniqueIdentifier. May change on a
    /// re-sign — we update this field but keep `wireID` constant.
    var hmUUID: String
    /// Accessory name at first sight. Used as the resign-survival lookup
    /// key alongside `homeName` — if hmUUID rotates, we match on this.
    var accessoryName: String
    /// Home the accessory belongs to. Optional only because HMHome can
    /// theoretically have an empty name.
    var homeName: String?
    /// ISO 8601 of when this record was first written. Diagnostic only;
    /// not used for matching.
    var firstSeen: String
}

/// Persistent cache that pins the wire ID published to HA for each physical
/// lock. Solves the orphan-on-resign bug:
///
/// - `HMAccessory.uniqueIdentifier` is per-app and rotates whenever the
///   bridge gets re-signed (free-tier 7-day cert rotation, the
///   launch-wrapper's auto-resign, bundle-ID renames, etc.).
/// - `stableID()` in AccessoryState.swift only produces a content-addressed
///   hash when the lock exposes `HMCharacteristicTypeSerialNumber`. ThorBolts
///   (and many other locks) don't, so they fall back to the rotating UUID.
/// - Result without this cache: every re-sign breaks HA's entity registry
///   because the bridge starts publishing fresh wire IDs.
///
/// This cache pins the wire ID at the moment we first see each accessory.
/// On every subsequent run — including across re-signs — we look up the
/// cached wire ID first by hmUUID, then (if hmUUID rotated) by
/// (homeName, accessoryName). Once a wire ID is chosen for an accessory,
/// it never changes for the life of the cache file.
///
/// Persistence: a single JSON file written atomically next to `config.json`
/// in the bridge's Application Support directory (sandboxed container on
/// signed builds, ~/Library/Application Support/HALockBridge on legacy
/// unsandboxed builds). Thread-safe via NSLock — `wireID(for:…)` is called
/// from the main thread (HomeKit's delegate queue) but the persist hop
/// happens with the lock released.
final class AccessoryIdentityCache {

    private let lock = NSLock()
    private var records: [String: AccessoryIdentityRecord] = [:]  // keyed by hmUUID
    private let path: URL

    init(path: URL) {
        self.path = path
        if let data = try? Data(contentsOf: path),
           let decoded = try? JSONDecoder().decode([String: AccessoryIdentityRecord].self, from: data) {
            records = decoded
        }
    }

    /// Return a stable wire ID for the given accessory. Looks up by hmUUID
    /// first; on miss, scans by (homeName, accessoryName) to find a record
    /// from before a re-sign and migrates it to the new hmUUID. Only when
    /// both lookups miss does it call `computeIfMissing()` and persist the
    /// returned wire ID — that's the only path that creates a new record.
    func wireID(
        forHMUUID hmUUID: String,
        accessoryName: String,
        homeName: String?,
        computeIfMissing: () -> String
    ) -> String {
        lock.lock()

        if let existing = records[hmUUID] {
            // Keep the cached name/home current — a user-initiated rename
            // updates metadata but never the wire ID.
            if existing.accessoryName != accessoryName || existing.homeName != homeName {
                var updated = existing
                updated.accessoryName = accessoryName
                updated.homeName = homeName
                records[hmUUID] = updated
                let snapshot = records
                lock.unlock()
                persist(snapshot)
                return existing.wireID
            }
            lock.unlock()
            return existing.wireID
        }

        // hmUUID miss — try resign-survival match by (homeName, accessoryName).
        let nameMatch = records.first { _, rec in
            rec.accessoryName == accessoryName && rec.homeName == homeName
        }
        if let (oldKey, rec) = nameMatch {
            // Migrate the record to the new hmUUID. Remove the stale key
            // so we don't accumulate ghost entries after every re-sign.
            records.removeValue(forKey: oldKey)
            var migrated = rec
            migrated.hmUUID = hmUUID
            records[hmUUID] = migrated
            let snapshot = records
            lock.unlock()
            persist(snapshot)
            return rec.wireID
        }

        // Both lookups missed. New accessory — compute, persist, return.
        let newWireID = computeIfMissing()
        records[hmUUID] = AccessoryIdentityRecord(
            wireID: newWireID,
            hmUUID: hmUUID,
            accessoryName: accessoryName,
            homeName: homeName,
            firstSeen: Self.now()
        )
        let snapshot = records
        lock.unlock()
        persist(snapshot)
        return newWireID
    }

    /// Read-only lookup. Returns the pinned wire ID if one exists for this
    /// accessory (by hmUUID first, then by name match), or nil if no record
    /// is present. Used by HomeKitMonitor to check before committing to the
    /// cache — when a serial-number read is still in flight, we'd rather
    /// publish the temporary fallback ID without pinning than pin the
    /// fallback and forever lose the chance to use the stable serial-hash.
    func peekWireID(forHMUUID hmUUID: String, accessoryName: String, homeName: String?) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let existing = records[hmUUID] {
            return existing.wireID
        }
        let nameMatch = records.first { _, rec in
            rec.accessoryName == accessoryName && rec.homeName == homeName
        }
        return nameMatch?.value.wireID
    }

    /// All currently-cached records. Used by the diagnostics endpoint so
    /// users can audit what's pinned.
    func allRecords() -> [AccessoryIdentityRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(records.values)
    }

    private func persist(_ snapshot: [String: AccessoryIdentityRecord]) {
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: path, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path.path
            )
        } catch {
            FileHandle.standardError.write(
                Data("[identity-cache] failed to persist: \(error)\n".utf8)
            )
        }
    }

    static func defaultPath() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("HALockBridge")
            .appendingPathComponent("accessory-identity.json")
    }

    private static func now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}
