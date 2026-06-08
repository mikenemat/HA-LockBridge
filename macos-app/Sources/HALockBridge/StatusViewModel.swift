import Foundation
import Combine

/// Source of truth for what the StatusView shows. In appliance mode the
/// window is ALWAYS visible — there are only two real screens (waiting for
/// the first pair, and the stats/control panel), plus a reset-confirm
/// overlay. The old hidden/briefStatus/countdown states are gone: the app
/// is a normal foreground app now (see AppDelegate / README for why —
/// HomeKit only services accessory writes for the frontmost app).
@MainActor
final class StatusViewModel: ObservableObject {

    enum Display: Equatable {
        case initializing
        case waiting        // waiting for the first HA to pair
        case debug          // stats + controls panel (the main screen once paired)
        case resetConfirm   // confirmation overlay for Reset Pairing
    }

    struct PendingPair: Equatable {
        let requestID: String
        let clientName: String
    }

    @Published var display: Display = .initializing
    @Published var pairedCount: Int = 0
    @Published var accessoryCount: Int = 0
    /// Live list of tracked accessories for the panel. Updated by the
    /// HomeKit observer (replaces the snapshot the old `.debug(accessories:)`
    /// enum case used to carry, since the panel is now always-on).
    @Published var accessories: [AccessoryState] = []
    /// Most-recent-first list of recent HA↔bridge interactions.
    @Published var recentInteractions: [InteractionLog.Event] = []
    /// Most-recent-first list of lock health events (write retries + gaps).
    @Published var recentLockEvents: [LockEventLog.Event] = []
    /// Live remote-IP list for every currently-connected HA WebSocket.
    @Published var connectedClients: [String] = []
    /// Inline pair-approval prompt. Non-nil while a request is pending;
    /// rendered as a banner above the main content in either screen.
    @Published var pendingRequest: PendingPair?
    /// Start-at-Login control state, surfaced as a toggle in the panel.
    @Published var loginItemEnabled: Bool = false
    @Published var loginItemAvailable: Bool = true

    // Callbacks wired by AppDelegate.
    var onApprove: ((String) -> Void)?
    var onDeny: ((String) -> Void)?
    var onResetConfirmed: (() -> Void)?
    var onToggleLoginItem: (() -> Void)?
    var onQuit: (() -> Void)?

    // MARK: - Transitions

    func showWaiting() { display = .waiting }
    func showDebug() { display = .debug }
    func showResetConfirm() { display = .resetConfirm }

    /// Settle into the correct main screen based on pairing state, unless a
    /// modal overlay (reset confirm) is currently up. Called on launch and
    /// after a pairing finalizes / reset completes.
    func refreshMainView() {
        if display == .resetConfirm { return }
        display = pairedCount > 0 ? .debug : .waiting
    }

    // MARK: - Pair request banner

    func showPendingRequest(requestID: String, clientName: String) {
        pendingRequest = PendingPair(requestID: requestID, clientName: clientName)
    }

    func clearPendingRequest() {
        pendingRequest = nil
    }

    // MARK: - Actions called from SwiftUI buttons

    func approveTapped() {
        if let r = pendingRequest { onApprove?(r.requestID) }
    }

    func denyTapped() {
        if let r = pendingRequest { onDeny?(r.requestID) }
    }

    func toggleLoginItemTapped() { onToggleLoginItem?() }

    func quitTapped() { onQuit?() }

    func resetTapped() { showResetConfirm() }

    func confirmResetTapped() { onResetConfirmed?() }

    func cancelResetTapped() { refreshMainView() }
}
