import UIKit
import SwiftUI

/// Hosts the StatusView in a single always-visible UIWindow on the Catalyst
/// scene. In appliance mode the window is never hidden — AppDelegate's
/// `onWindowReady` finishes setup (center, disable close/minimize, activate).
final class MainSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    private static let windowSize = CGSize(width: 440, height: 720)

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate,
              let viewModel = appDelegate.statusVM else { return }

        // Pin the window to a fixed size.
        if let restrictions = windowScene.sizeRestrictions {
            restrictions.minimumSize = Self.windowSize
            restrictions.maximumSize = Self.windowSize
        }

        let host = UIHostingController(rootView: StatusView(viewModel: viewModel))
        let w = UIWindow(windowScene: windowScene)
        w.rootViewController = host
        w.windowLevel = .normal
        window = w
        appDelegate.mainWindow = w

        w.makeKeyAndVisible()
        appDelegate.onWindowReady()
    }
}
