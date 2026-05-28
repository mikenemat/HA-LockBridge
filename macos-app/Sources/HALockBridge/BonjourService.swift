import Foundation
import UIKit

/// Publishes the bridge over mDNS as `_ha-lockbridge._tcp.` with the instance
/// UUID baked into the TXT records. HomeAssistant's zeroconf integration uses
/// the UUID as the config-entry unique_id; the hostname is treated as transport
/// plumbing and can change freely without breaking the integration.
final class BonjourService: NSObject, NetServiceDelegate {

    static let serviceType = "_ha-lockbridge._tcp."

    private let port: Int32
    private let instanceID: String
    private let logger: (String) -> Void
    private var service: NetService?

    init(port: Int, instanceID: String, logger: @escaping (String) -> Void) {
        self.port = Int32(port)
        self.instanceID = instanceID
        self.logger = logger
    }

    func start() {
        // Bonjour instance name must be unique on the LAN, else publish fails
        // with NSNetServicesCollisionError. Combine the device's user-set name
        // with a short UUID suffix so two bridges (e.g. this Mac + an AppleTV)
        // can coexist. The full UUID lives in TXT records for HA's identity.
        //
        // ProcessInfo.processInfo.hostName returns the network hostname like
        // "Macbook-Air-M42025.local" — the only fully-Catalyst-safe way to
        // get a device-identifying string. `NSHost`/`Host.current()` and
        // `SCDynamicStoreCopyComputerName` would return the friendlier
        // "Michael's MacBook Pro" but neither is available in Catalyst.
        // UIDevice.current.name is hardcoded to "iPad" on Catalyst, so it's
        // only useful as a last-resort fallback.
        let rawHost = ProcessInfo.processInfo.hostName
        let trimmed = rawHost.hasSuffix(".local") ? String(rawHost.dropLast(6)) : rawHost
        let deviceName = trimmed.isEmpty ? UIDevice.current.name : trimmed
        let suffix = String(instanceID.prefix(4)).uppercased()
        let name = "HA-LockBridge (\(deviceName) \(suffix))"
        let svc = NetService(domain: "", type: Self.serviceType, name: name, port: port)
        svc.delegate = self

        let txtData = NetService.data(fromTXTRecord: [
            "uuid": Data(instanceID.utf8),
            "name": Data(name.utf8),
            "version": Data("0.4.5".utf8),
            "api": Data("1".utf8),
        ])
        svc.setTXTRecord(txtData)
        svc.publish()
        service = svc
        logger("Bonjour: publishing \(Self.serviceType) name=\"\(name)\" uuid=\(instanceID) port=\(port)")
    }

    func stop() {
        service?.stop()
        service = nil
    }

    // MARK: - NetServiceDelegate

    func netServiceDidPublish(_ sender: NetService) {
        logger("Bonjour: published as \"\(sender.name).\(sender.type)\(sender.domain)\"")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        logger("Bonjour: publish FAILED: \(errorDict)")
    }
}
