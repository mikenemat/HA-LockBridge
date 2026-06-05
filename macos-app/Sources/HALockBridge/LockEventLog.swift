import Foundation

/// Thread-safe ring buffer of "lock health" events — the things HA users
/// experience as a rough edge but that the existing InteractionLog
/// (snapshot of HA↔bridge wire traffic) doesn't surface.
///
/// Two kinds of events are recorded:
///   - `.writeRetry` — A setLockState command couldn't be applied to
///     HomeKit on the first try (got `HMError 82 (accessory not
///     reachable)`). The event opens on the first 82, the retry loop
///     mutates `attempts` as it goes, and the event closes with an
///     outcome (`succeeded` / `reverted` / `satisfiedExternally`) when
///     the loop terminates. Visible to the user via the Stats page's
///     "Lock Errors/Warnings" section.
///   - `.unreachableGap` — A per-accessory `isReachable` gap. Opens when
///     `isReachable` goes `false` (or on startup for a lock that's
///     already unreachable); closes when it returns to `true`, at which
///     point `durationSec` is filled in. While `durationSec == nil` the
///     UI shows the gap as ongoing.
///
/// Pattern mirrors InteractionLog — keeping the two logs separate so the
/// "wire traffic" snapshot stays compact while this log can grow to a
/// useful health history (capacity bumped to 100).
final class LockEventLog {

    enum WriteOutcome: String, Equatable {
        /// Background retry loop is still running. Initial state.
        case ongoing
        /// HomeKit accepted the write before the 30s budget elapsed.
        case succeeded
        /// 30s budget elapsed without HomeKit accepting; optimistic
        /// state was silently reverted (Option 2 Pick A).
        case reverted
        /// The lock's physical current_state reached the requested
        /// target via an external path (HomeKey, manual operation,
        /// other HomeKit controller) while we were still retrying.
        /// The pending write was cancelled — no revert needed.
        case satisfiedExternally
    }

    enum Kind: Equatable {
        /// `targetAction` is "lock" or "unlock". `attempts` counts
        /// completed `writeValue` calls (>=1 once we've recorded an
        /// event at all — events only open after the first 82). When
        /// `outcome == .ongoing`, `durationMs` reflects elapsed time
        /// since the event opened and may go stale until the next view
        /// repaint; once outcome != .ongoing, it's the final value.
        case writeRetry(targetAction: String, attempts: Int, durationMs: Int, outcome: WriteOutcome)
        /// `durationSec == nil` means the gap is still open (the
        /// accessory is currently unreachable). Once closed, it holds
        /// the total wall-clock time the accessory was unreachable.
        case unreachableGap(durationSec: Double?)
    }

    struct Event: Identifiable, Equatable {
        /// Stable ID for SwiftUI's ForEach and for in-place updates via
        /// `LockEventLog.update(id:_:)`.
        let id: UUID
        let accessoryName: String
        let accessoryID: String
        /// When this event *opened* — write-retry start, or
        /// gap-start. Display is "start time + duration", not "now -
        /// duration" — so this stays useful even after the buffer ages.
        let timestamp: Date
        /// Mutable so the retry loop / reachability delegate can close
        /// or update the event in place without rewriting the buffer.
        var kind: Kind
    }

    private let lock = NSLock()
    private var events: [Event] = []
    /// Larger than InteractionLog's 50 — this log is meant to be a
    /// health *history* the user can review, not a wire-traffic peek.
    private let capacity: Int = 100

    /// Fires after each `record(_:)` or `update(id:_:)`. AppDelegate
    /// subscribes and pushes the updated `recent(_:)` snapshot into
    /// StatusViewModel so the Stats page repaints.
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

    /// In-place update of an event by ID. Used to advance an open
    /// `.writeRetry` event's `attempts` / `durationMs` / `outcome` as
    /// the retry loop progresses, and to close an open
    /// `.unreachableGap` event with its final duration. No-op if the
    /// event has already aged out of the ring buffer.
    func update(id: UUID, transform: (inout Event) -> Void) {
        lock.lock()
        var changed = false
        if let idx = events.firstIndex(where: { $0.id == id }) {
            transform(&events[idx])
            changed = true
        }
        lock.unlock()
        if changed { onChange?() }
    }

    /// Find the most recently opened, still-open gap for `accessoryID`.
    /// Used by the reachability delegate to locate which event to
    /// close on a true-recovery. Returns nil if no open gap exists.
    func openGapID(forAccessory accessoryID: String) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        // Reverse iterate — most recent first.
        for event in events.reversed() {
            if event.accessoryID == accessoryID,
               case .unreachableGap(let dur) = event.kind,
               dur == nil {
                return event.id
            }
        }
        return nil
    }

    /// Most-recent first, up to `count` events. The Stats page caps
    /// display at this length.
    func recent(_ count: Int = 20) -> [Event] {
        lock.lock(); defer { lock.unlock() }
        return Array(events.suffix(count).reversed())
    }
}
