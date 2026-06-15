import Foundation

/// Thread-safe ring buffer of recent HA↔bridge interactions. The status
/// window's "Stats & Debug" view subscribes to it (via AppDelegate) and
/// re-renders as new events arrive.
///
/// Two kinds of events are recorded:
///   - `.command`     — HA → bridge → lock (POST /accessories/{id}/state)
///   - `.stateUpdate` — lock → bridge → HA (WS push of an .state envelope)
///
/// Snapshots sent at WS connect time and ghost-accessory churn are
/// intentionally NOT logged — they're noisy and not per-lock.
final class InteractionLog {

    enum Direction: String {
        case command       // HA → bridge → lock
        case stateUpdate   // lock → bridge → HA
    }

    struct Event: Identifiable, Equatable {
        /// Stable ID for SwiftUI's ForEach. Generated at record time; two
        /// otherwise-identical events have different IDs.
        let id: UUID = UUID()
        let direction: Direction
        let accessoryName: String
        let accessoryID: String
        /// Short, human-readable description of what flowed.
        /// For .command: the target ("secured" / "unsecured").
        /// For .stateUpdate: the lifecycle state ("locked" / "unlocking" / …).
        let detail: String
        let timestamp: Date
        /// Client IP address. "unknown" if the underlying channel had no
        /// remote address (shouldn't happen for TCP connections in practice).
        let clientAddress: String
    }

    private let lock = NSLock()
    private var events: [Event] = []
    // Intentionally UNBOUNDED — the full interaction history is retained for
    // the entire app run (the Stats page scrolls it). At realistic lock-bridge
    // event rates this is a few hundred bytes per entry, so even months of
    // uptime is a modest, bounded-in-practice amount of memory.

    /// Fires after each `record(_:)`. AppDelegate subscribes and pushes the
    /// full history into StatusViewModel so the debug view repaints.
    var onChange: (() -> Void)?

    func record(_ event: Event) {
        lock.lock()
        events.append(event)
        lock.unlock()
        onChange?()
    }

    /// The entire history, most-recent first.
    func all() -> [Event] {
        lock.lock(); defer { lock.unlock() }
        return events.reversed()
    }

    /// The newest `limit` events, most-recent first. History stays unbounded
    /// in memory; this just caps what gets pushed into the SwiftUI @Published
    /// list so the per-event copy + SwiftUI diff on the main (HomeKit) thread
    /// stays O(limit) instead of O(history). The Stats panel only renders a
    /// scroll region of finite height anyway.
    func recent(_ limit: Int) -> [Event] {
        lock.lock(); defer { lock.unlock() }
        return events.suffix(limit).reversed()
    }
}
