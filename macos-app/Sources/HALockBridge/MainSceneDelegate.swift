import UIKit
import SwiftUI

/// Hosts the StatusView in a UIWindow on the Catalyst scene. Visibility is
/// controlled by AppDelegate via the shared StatusViewModel.
final class MainSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    private static let windowSize = CGSize(width: 440, height: 570)

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate,
              let viewModel = appDelegate.statusVM else { return }

        // Pin the window to a fixed size. Without this, AppKit gives us a
        // default-sized window and the SwiftUI content ends up small + corner-pinned.
        if let restrictions = windowScene.sizeRestrictions {
            restrictions.minimumSize = Self.windowSize
            restrictions.maximumSize = Self.windowSize
        }

        // Capture any NSWindow that already exists before we attach ours.
        // On Finder-initiated launches Catalyst auto-spawns a blank window
        // (LSUIElement=true gets ignored) before this delegate runs — by
        // definition anything in NSApp.windows right now is a rogue. We
        // hand the list to AppDelegate.neutralizeRogueNSWindows so the
        // user never sees a ghost "HA-LockBridge" window after we hide ours.
        appDelegate.knownRogueNSWindows = appDelegate.snapshotNSWindows()

        let host = UIHostingController(rootView: StatusView(viewModel: viewModel))
        let w = UIWindow(windowScene: windowScene)
        w.rootViewController = host
        w.windowLevel = .normal
        window = w
        appDelegate.mainWindow = w

        appDelegate.refreshWindowVisibility()
    }
}
