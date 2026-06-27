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
        /// The lock CONFIRMED the new state — its physical current_state
        /// reached the requested target. The only true success. (A late
        /// confirmation of an `.unconfirmed` write transitions to this.)
        case succeeded
        /// The 30s budget elapsed while the lock was UNREACHABLE
        /// (HMError 82 throughout); the optimistic state was reverted to
        /// the last-known-good. HA already shows the lock unavailable in
        /// this case, so the revert isn't the user-facing signal — the
        /// unavailability is. Contrast with `.unconfirmed`.
        case reverted
        /// The lock's physical current_state reached the requested
        /// target via an external path (HomeKey, manual operation,
        /// other HomeKit controller) while we were still retrying.
        /// The pending write was cancelled — no revert needed.
        case satisfiedExternally
        /// The 30s budget elapsed while the lock was REACHABLE but its
        /// current_state never reached the target — homed accepted the
        /// write (or kept 82-ing on a still-reachable lock) yet the bolt
        /// didn't move. The optimistic state is deliberately LEFT in
        /// place so HA keeps showing "locking"/"unlocking" (a visible
        /// "this didn't complete" hang) until the lock confirms, a new
        /// command supersedes it, or it's operated externally. Becomes
        /// `.succeeded` if the lock confirms late.
        case unconfirmed
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
        /// A HomeKit write failed with a non-82 (non-retryable) error. The
        /// optimistic state was reverted. `detail` carries the localized
        /// HomeKit error so the Stats page can show why.
        case writeFailed(targetAction: String, detail: String)
        /// The app tried to grab foreground focus for a lock write but was
        /// still not `.active` afterwards — HomeKit may stall the write. A
        /// diagnostic for the appliance-mode focus invariant.
        case focusGrabFailed
        /// A command that DID confirm (current reached target) but took longer
        /// than the slow-confirm threshold to do so. Informational — the
        /// command succeeded — but surfaces a sluggish lock that responds
        /// within budget yet slowly. `durationMs` is command → confirmation.
        case slowConfirm(targetAction: String, durationMs: Int)
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

        /// JSON dict for the `GET /debug/events` diagnostics endpoint.
        var jsonObject: [String: Any] {
            var obj: [String: Any] = [
                "id": id.uuidString,
                "accessory_name": accessoryName,
                "accessory_id": accessoryID,
                "t": timestamp.timeIntervalSince1970,
            ]
            switch kind {
            case .writeRetry(let action, let attempts, let durationMs, let outcome):
                obj["kind"] = "write_retry"
                obj["action"] = action
                obj["attempts"] = attempts
                obj["duration_ms"] = durationMs
                obj["outcome"] = outcome.rawValue
            case .unreachableGap(let durationSec):
                obj["kind"] = "unreachable_gap"
                if let d = durationSec { obj["duration_sec"] = d } else { obj["ongoing"] = true }
            case .writeFailed(let action, let detail):
                obj["kind"] = "write_failed"
                obj["action"] = action
                obj["detail"] = detail
            case .focusGrabFailed:
                obj["kind"] = "focus_grab_failed"
            case .slowConfirm(let action, let durationMs):
                obj["kind"] = "slow_confirm"
                obj["action"] = action
                obj["duration_ms"] = durationMs
            }
            return obj
        }
    }

    private let lock = NSLock()
    private var events: [Event] = []
    // Intentionally UNBOUNDED — the full health history is retained for the
    // entire app run (the Stats page scrolls it). Event rate is low (lock
    // operations + reachability gaps), so this stays small in practice.

    /// Index of currently-open `.unreachableGap` events: accessoryID → event
    /// ID. Lets `openGapID(forAccessory:)` be O(1) instead of an O(n) reverse
    /// scan of the (unbounded) history. Maintained by `record` (insert on a
    /// gap-open), `update` (remove when a gap closes), and `byID` lookups.
    private var openGapByAccessory: [String: UUID] = [:]
    /// Index of event positions by ID so `update(id:)` is O(1) instead of an
    /// O(n) `firstIndex`. Stays valid because events are only ever appended
    /// (never removed) — an index never shifts once assigned.
    private var indexByID: [UUID: Int] = [:]

    /// Fires after each `record(_:)` or `update(id:_:)`. AppDelegate
    /// subscribes and pushes the full history into StatusViewModel so the
    /// Stats page repaints.
    var onChange: (() -> Void)?

    func record(_ event: Event) {
        lock.lock()
        let idx = events.count
        events.append(event)
        indexByID[event.id] = idx
        if case .unreachableGap(let dur) = event.kind, dur == nil {
            openGapByAccessory[event.accessoryID] = event.id
        }
        lock.unlock()
        onChange?()
    }

    /// In-place update of an event by ID. Used to advance an open
    /// `.writeRetry` event's `attempts` / `durationMs` / `outcome` as
    /// the retry loop progresses, and to close an open
    /// `.unreachableGap` event with its final duration.
    func update(id: UUID, transform: (inout Event) -> Void) {
        lock.lock()
        var changed = false
        if let idx = indexByID[id] {
            transform(&events[idx])
            // If this update closed an open gap, drop it from the open-gap
            // index so a later open for the same accessory isn't shadowed.
            if case .unreachableGap(let dur) = events[idx].kind, dur != nil,
               openGapByAccessory[events[idx].accessoryID] == id {
                openGapByAccessory.removeValue(forKey: events[idx].accessoryID)
            }
            changed = true
        }
        lock.unlock()
        if changed { onChange?() }
    }

    /// Find the most recently opened, still-open gap for `accessoryID`.
    /// Used by the reachability delegate to locate which event to
    /// close on a true-recovery. Returns nil if no open gap exists. O(1)
    /// via the `openGapByAccessory` index.
    func openGapID(forAccessory accessoryID: String) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return openGapByAccessory[accessoryID]
    }

    /// The entire history, most-recent first.
    func all() -> [Event] {
        lock.lock(); defer { lock.unlock() }
        return events.reversed()
    }

    /// The newest `limit` events, most-recent first. History stays unbounded
    /// in memory; this caps what's pushed into the SwiftUI @Published list so
    /// the per-event copy + SwiftUI diff on the main (HomeKit) thread stays
    /// O(limit) instead of O(history).
    func recent(_ limit: Int) -> [Event] {
        lock.lock(); defer { lock.unlock() }
        return events.suffix(limit).reversed()
    }
}
