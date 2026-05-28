import Foundation

/// Owns the lifecycle of pending pair requests.
///
/// Flow:
/// 1. HA calls POST /pair/initiate {client_name} → `createRequest(...)` → returns request_id
/// 2. SwiftUI status window pops up with Approve/Deny buttons
/// 3. HA polls GET /pair/status/{request_id} → returns pending / approved+token / denied / expired
/// 4. User clicks Approve in the window → `approveByNotification(...)` issues a 32-byte token,
///    stores it in TokenStore, marks the request approved
/// 5. HA's next poll sees `approved` + token, persists it
///
/// All state lives in memory — pending pair requests don't survive a bridge restart.
/// That's fine: if you walk away mid-pairing, just restart the flow.
final class PairingManager {

    enum State: String, Codable {
        case pending, approved, denied, expired
    }

    struct PairRequest {
        let requestID: String       // UUID for HA-side polling
        let clientName: String
        let createdAt: Date
        var state: State
        var token: String?          // populated on approve
    }

    private let store: TokenStore
    private let logger: (String) -> Void
    private var requests: [String: PairRequest] = [:]
    private let expiry: TimeInterval = 300  // 5 minutes

    /// Fires when a new pair request arrives. Wired up by AppDelegate to push
    /// the request into the SwiftUI status window.
    var onRequestStarted: ((_ requestID: String, _ clientName: String) -> Void)?

    /// Fires when a request transitions away from .pending (approved/denied/expired).
    var onRequestFinalized: ((_ requestID: String, _ state: State) -> Void)?

    init(store: TokenStore, logger: @escaping (String) -> Void) {
        self.store = store
        self.logger = logger
    }

    @discardableResult
    func createRequest(clientName: String) -> String {
        cleanupExpired()
        let requestID = UUID().uuidString
        let req = PairRequest(
            requestID: requestID,
            clientName: clientName,
            createdAt: Date(),
            state: .pending,
            token: nil
        )
        requests[requestID] = req

        logger("Pair request from \"\(clientName)\". Approve in the bridge window.")
        onRequestStarted?(requestID, clientName)

        return requestID
    }

    func status(of requestID: String) -> (state: State, token: String?)? {
        cleanupExpired()
        guard let req = requests[requestID] else { return nil }
        return (req.state, req.token)
    }

    /// Approve via the SwiftUI window's Approve button — the user's physical
    /// click at the Mac console IS the auth.
    @discardableResult
    func approveByNotification(requestID: String) -> Bool {
        cleanupExpired()
        guard var req = requests[requestID] else { return false }
        guard req.state == .pending else { return false }

        let token = Self.generateToken()
        store.addToken(token, clientName: req.clientName)

        req.state = .approved
        req.token = token
        requests[requestID] = req

        onRequestFinalized?(requestID, .approved)
        logger("Pair request from \"\(req.clientName)\" approved. Token issued.")
        return true
    }

    /// Deny via the SwiftUI window's Deny button.
    @discardableResult
    func deny(requestID: String) -> Bool {
        guard var req = requests[requestID] else { return false }
        guard req.state == .pending else { return false }
        req.state = .denied
        requests[requestID] = req
        onRequestFinalized?(requestID, .denied)
        logger("Pair request \(requestID) denied")
        return true
    }

    private func cleanupExpired() {
        let cutoff = Date().addingTimeInterval(-expiry)
        for (id, req) in requests where req.state == .pending && req.createdAt < cutoff {
            var expired = req
            expired.state = .expired
            requests[id] = expired
            onRequestFinalized?(id, .expired)
            logger("Pair request \(id) expired")
        }
    }

    // MARK: - Token generation

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
