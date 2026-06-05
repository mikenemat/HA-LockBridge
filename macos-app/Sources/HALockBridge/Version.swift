import Foundation

extension Bundle {
    /// The marketing version (CFBundleShortVersionString) of this app's main
    /// bundle, used as the bridge's wire-protocol version. Read once at
    /// runtime from Info.plist so the three places that publish a
    /// "version" field — Bonjour TXT, WebSocket `hello` envelope, and the
    /// `/info` HTTP endpoint — always reflect what was actually built,
    /// rather than a string that drifts whenever someone forgets to bump
    /// it. Drift was the bug that prompted this extension: a stale
    /// hardcoded "0.5.0" survived through 0.5.1/0.5.2/0.5.3 and made
    /// `curl /info` lie to anyone debugging which build was running.
    ///
    /// Falls back to `"unknown"` only if Info.plist itself is corrupted
    /// or absent — every valid build has CFBundleShortVersionString set
    /// from MARKETING_VERSION via the xcodegen-generated plist.
    static var bridgeMarketingVersion: String {
        return main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}
