import Foundation
import ServiceManagement

/// "Start at Login" helper.
///
/// We deliberately do **not** register the app as a login item with
/// `SMAppService.mainApp.register()`. On **Mac Catalyst** that API doesn't
/// work — `SMAppService.mainApp.status` returns `.notFound` and registration
/// never takes effect, because ServiceManagement's "register the main app
/// bundle itself" path is a native-macOS facility that doesn't recognize a
/// Catalyst bundle (Apple documents the related `SMLoginItemSetEnabled` API as
/// unsupported under Catalyst, and ServiceManagement-from-Catalyst as not
/// officially supported). That's why the old in-app toggle was permanently
/// greyed out (`.notFound` → unavailable) even from a correctly-installed
/// /Applications build.
///
/// Rather than ship a control that silently can't work, the UI sends the user
/// to System Settings → Login Items, where adding the app is a reliable,
/// one-time step. Confirmed empirically + via Apple DTS forum guidance.
enum LoginItemManager {
    /// Open System Settings → General → Login Items so the user can add the app.
    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
