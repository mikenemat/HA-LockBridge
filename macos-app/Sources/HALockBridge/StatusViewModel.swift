import Foundation
import Combine

/// Source of truth for what the StatusView shows. AppDelegate observes
/// `display` to drive window visibility + macOS activation policy.
@MainActor
final class StatusViewModel: ObservableObject {

    enum Display: Equatable {
        case initializing
        case waitingForFirstPair
        case pendingRequest(requestID: String, clientName: String)
        case approved(countdown: Int)
        case denied(countdown: Int)
        case expired(countdown: Int)
        case briefStatus(countdown: Int)
        case debug(accessories: [AccessoryState], pairedCount: Int)
        case resetConfirm
        case hidden

        var isVisible: Bool {
            if case .hidden = self { return false }
            return true
        }
    }

    @Published var display: Display = .initializing
    @Published var pairedCount: Int = 0
    @Published var accessoryCount: Int = 0
    /// Most-recent-first list of recent HA↔bridge interactions, updated
    /// live as events arrive. Surfaced in the debug view's header so the
    /// user can watch activity flow without leaving the status window.
    @Published var recentInteractions: [InteractionLog.Event] = []
    /// Live remote-IP list for every currently-connected HA WebSocket.
    /// Drives the green/red indicator in the debug view. Kept @Published
    /// (vs. a snapshot value in the .debug enum case) so the indicator
    /// updates while the page is already open — HA reconnect/disconnect
    /// cycles change this in real time.
    @Published var connectedClients: [String] = []

    var onApprove: ((String) -> Void)?
    var onDeny: ((String) -> Void)?
    var onResetConfirmed: (() -> Void)?

    private var countdownTask: Task<Void, Never>?

    // MARK: - Transitions

    func showWaitingForFirstPair() {
        cancelCountdown()
        display = .waitingForFirstPair
    }

    func showBriefStatus(seconds: Int = 5) {
        startCountdown(seconds: seconds) { .briefStatus(countdown: $0) }
    }

    func showPendingRequest(requestID: String, clientName: String) {
        cancelCountdown()
        display = .pendingRequest(requestID: requestID, clientName: clientName)
    }

    func showApproved() {
        startCountdown(seconds: 5, build: { .approved(countdown: $0) }, then: .hidden)
    }

    func showDenied() {
        startCountdown(seconds: 5, build: { .denied(countdown: $0) }, then: .waitingForFirstPair)
    }

    func showExpired() {
        startCountdown(seconds: 5, build: { .expired(countdown: $0) }, then: .waitingForFirstPair)
    }

    func showDebug(accessories: [AccessoryState], pairedCount: Int) {
        cancelCountdown()
        display = .debug(accessories: accessories, pairedCount: pairedCount)
    }

    func showResetConfirm() {
        cancelCountdown()
        display = .resetConfirm
    }

    func hide() {
        cancelCountdown()
        display = .hidden
    }

    // MARK: - Actions called from SwiftUI buttons

    func approveTapped() {
        if case .pendingRequest(let id, _) = display {
            onApprove?(id)
        }
    }

    func denyTapped() {
        if case .pendingRequest(let id, _) = display {
            onDeny?(id)
        }
    }

    func confirmResetTapped() {
        onResetConfirmed?()
    }

    func cancelResetTapped() {
        dismissOverlay()
    }

    /// Dismiss a manually-opened overlay (debug / resetConfirm). When no
    /// clients are paired, return to the persistent waitingForFirstPair view
    /// — going to .hidden would make the window AND Dock icon vanish, which
    /// reads as a crash. With paired clients, hide is fine: the bridge is
    /// expected to recede into the menu bar.
    func dismissOverlay() {
        if pairedCount == 0 {
            showWaitingForFirstPair()
        } else {
            hide()
        }
    }

    // MARK: - Countdown helper

    private func startCountdown(seconds: Int, build: @escaping (Int) -> Display, then finalDisplay: Display = .hidden) {
        cancelCountdown()
        countdownTask = Task { [weak self] in
            for i in stride(from: seconds, through: 1, by: -1) {
                if Task.isCancelled { return }
                await MainActor.run { self?.display = build(i) }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if Task.isCancelled { return }
            await MainActor.run { self?.display = finalDisplay }
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
    }
}
