import UIKit
import SwiftUI

/// Hosts the StatusView in a UIWindow on the Catalyst scene. Visibility is
/// controlled by AppDelegate via the shared StatusViewModel.
final class MainSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    // Height bumped from 570 to 720 in 0.5.5 — the "Lock Errors/Warnings"
    // section added in 0.5.3 squeezed everything else when populated; the
    // extra 150pt mostly benefits that section's internal ScrollView cap
    // (see StatusView's lock-events frame(maxHeight:)). Width unchanged.
    private static let windowSize = CGSize(width: 440, height: 720)

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
