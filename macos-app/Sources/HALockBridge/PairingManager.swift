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
        let requesterIP: String     // remote IP that initiated the request
        let createdAt: Date
        var state: State
        var token: String?          // populated on approve
        /// True once HA has polled and received the token at least once.
        /// We null the token on the *next* poll so an approved token isn't
        /// retrievable forever via the unauthenticated /pair/status path.
        var tokenDelivered: Bool = false
    }

    private let store: TokenStore
    private let logger: (String) -> Void
    private var requests: [String: PairRequest] = [:]
    private let expiry: TimeInterval = 300  // 5 minutes

    /// Fires when a new pair request arrives. Wired up by AppDelegate to push
    /// the request into the SwiftUI status window.
    var onRequestStarted: ((_ requestID: String, _ clientName: String, _ requesterIP: String) -> Void)?

    /// Fires when a request transitions away from .pending (approved/denied/expired).
    var onRequestFinalized: ((_ requestID: String, _ state: State) -> Void)?

    init(store: TokenStore, logger: @escaping (String) -> Void) {
        self.store = store
        self.logger = logger
    }

    /// True iff a request is currently awaiting approval. Used by the server
    /// to refuse a second `/pair/initiate` (confused-deputy banner swap).
    var hasPendingRequest: Bool {
        cleanupExpired()
        return requests.values.contains { $0.state == .pending }
    }

    /// Create a new pending request. Returns the request ID, or nil if a
    /// request is already pending approval — the caller (server) maps that
    /// to a 409 so an attacker can't swap the approval banner out from under
    /// the user's cursor.
    func createRequest(clientName: String, requesterIP: String = "unknown") -> String? {
        cleanupExpired()
        if requests.values.contains(where: { $0.state == .pending }) {
            logger("Refusing pair request from \"\(clientName)\" (\(requesterIP)) — another request is already pending approval.")
            return nil
        }
        let requestID = UUID().uuidString
        let req = PairRequest(
            requestID: requestID,
            clientName: clientName,
            requesterIP: requesterIP,
            createdAt: Date(),
            state: .pending,
            token: nil
        )
        requests[requestID] = req

        logger("Pair request from \"\(clientName)\" (\(requesterIP)). Approve in the bridge window.")
        onRequestStarted?(requestID, clientName, requesterIP)

        return requestID
    }

    func status(of requestID: String) -> (state: State, token: String?)? {
        cleanupExpired()
        guard let req = requests[requestID] else { return nil }
        // Approved-token single-delivery: hand the token to the first poll
        // that sees `.approved`, then null it so it can't be re-fetched
        // forever through the unauthenticated /pair/status path. HA persists
        // the token on that first read; a second read just confirms the
        // approved state without re-exposing the secret.
        if req.state == .approved {
            if req.tokenDelivered {
                return (req.state, nil)
            } else {
                var updated = req
                updated.tokenDelivered = true
                requests[requestID] = updated
                return (req.state, req.token)
            }
        }
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
        let now = Date()
        let cutoff = now.addingTimeInterval(-expiry)
        for (id, req) in requests {
            // 1. Expire any pending request past its 5-minute window.
            if req.state == .pending && req.createdAt < cutoff {
                var expired = req
                expired.state = .expired
                expired.token = nil
                requests[id] = expired
                onRequestFinalized?(id, .expired)
                logger("Pair request \(id) expired")
                continue
            }
            // 2. Hard-delete terminal (approved/denied/expired) requests once
            //    they've aged past the expiry window — and, for approved, only
            //    after the token has been delivered to HA at least once. This
            //    keeps the map from growing forever and stops an approved
            //    token being retrievable indefinitely via /pair/status.
            if req.state == .approved && !req.tokenDelivered {
                continue  // give HA time to fetch the token at least once
            }
            if req.state != .pending && req.createdAt < cutoff {
                requests.removeValue(forKey: id)
                logger("Pair request \(id) (\(req.state.rawValue)) purged")
            }
        }
    }

    // MARK: - Token generation

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        // SecRandomCopyBytes returning non-zero means the CSPRNG failed and
        // `bytes` may still be all zeros — issuing that as a bearer token
        // would be a catastrophic, silently-predictable credential. Fall back
        // to the system RNG (SystemRandomNumberGenerator is also CSPRNG-backed)
        // rather than ship a zero token.
        if status != errSecSuccess {
            FileHandle.standardError.write(Data("[lockbridge-server] SecRandomCopyBytes failed (status=\(status)); falling back to SystemRandomNumberGenerator\n".utf8))
            var rng = SystemRandomNumberGenerator()
            for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max, using: &rng) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
