import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` for managing the bridge's
/// "Start at Login" registration. Replaces the old shell-script LaunchAgent
/// workflow (install-launchagent.sh / launch-wrapper.sh / etc.).
///
/// macOS 13+ is the requirement floor for `SMAppService`; this project's
/// deployment target is macOS 14, so it's always available.
///
/// User-facing surface:
///   - On enable: macOS registers the .app as a Login Item. Visible to the
///     user under System Settings → General → Login Items. They can disable
///     it from there at any time without involving the app.
///   - On disable: removed from Login Items.
///   - Status is read-only authoritative — the app should never assume its
///     local state matches reality; always query `SMAppService.mainApp.status`.
///
/// Important constraint: `SMAppService.mainApp` only registers successfully
/// when the .app is installed under `/Applications/` (or `~/Applications/`).
/// Running from an Xcode `build/` path returns a permission error. That's
/// fine for end users — they download the notarized release and drag to
/// /Applications, which is the only supported install path.
enum LoginItemManager {

    /// `true` if the app is currently configured to launch at login.
    static var isEnabled: Bool {
        return SMAppService.mainApp.status == .enabled
    }

    /// Whether the system is in a state where toggling is meaningful.
    /// Returns false when the app is running from a path SMAppService
    /// doesn't recognize (e.g. Xcode build folder). Surface this so the
    /// menu can disable the item rather than offering a toggle that
    /// will fail.
    static var isAvailable: Bool {
        switch SMAppService.mainApp.status {
        case .notFound:
            return false
        default:
            return true
        }
    }

    /// Register or unregister the main app as a Login Item, depending on
    /// current state. Throws if the underlying call fails (e.g. user
    /// previously approved a different version, app not in /Applications).
    /// Caller is responsible for updating any UI that reflects status.
    static func toggle() throws {
        if isEnabled {
            try SMAppService.mainApp.unregister()
        } else {
            try SMAppService.mainApp.register()
        }
    }
}
