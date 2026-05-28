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
    /// Capacity is well above the display count of 3 so callers that want a
    /// longer scrollback can pull more without us having to grow on demand.
    private let capacity: Int = 50

    /// Fires after each `record(_:)`. AppDelegate subscribes and pushes the
    /// updated `recent(_:)` into StatusViewModel so the debug view repaints.
    var onChange: (() -> Void)?

    func record(_ event: Event) {
        lock.lock()
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        lock.unlock()
        onChange?()
    }

    /// Most-recent first, up to `count` events. Default 3 matches the
    /// debug view's display count.
    func recent(_ count: Int = 3) -> [Event] {
        lock.lock(); defer { lock.unlock() }
        return Array(events.suffix(count).reversed())
    }
}
