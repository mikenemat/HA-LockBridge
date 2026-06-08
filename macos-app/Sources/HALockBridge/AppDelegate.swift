import UIKit
import SwiftUI
import ObjectiveC.runtime

/// Appliance-mode AppDelegate.
///
/// Earlier versions of this app went to great lengths to be a *hidden*
/// menu-bar utility (LSUIElement, `.accessory` policy, a four-layer window
/// hider, rogue-NSWindow neutralizing). That is all gone. HomeKit only
/// services accessory *writes* promptly for the frontmost/active app (see
/// README → "Why the bridge runs as a visible app"), so a headless bridge
/// fundamentally can't control locks without lag. The bridge is now a normal
/// foreground app: a single always-visible window, a Dock icon, and it grabs
/// focus when Home Assistant issues a lock command. Intended to run on a
/// dedicated Mac.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var monitor: HomeKitMonitor?
    var server: BridgeServer?
    var pairingManager: PairingManager?
    var bonjour: BonjourService?
    var store: TokenStore?
    var interactionLog: InteractionLog?
    var lockEventLog: LockEventLog?

    /// Process-lifetime activity assertion. Held for the entire run to keep
    /// the app and Mac fully awake and unthrottled. Options are load-bearing:
    ///   - `.userInitiated` carries the priority bits that actually suppress
    ///     App Nap (and already implies idle-system-sleep + termination
    ///     disabled). `.idleSystemSleepDisabled` ALONE does NOT suppress App
    ///     Nap — that was the 0.5.9 bug.
    ///   - `.idleDisplaySleepDisabled` keeps the *display* awake. This is what
    ///     keeps the app `.active`: the real thing that drops an unattended
    ///     Mac out of the active state is the screen lock, whose timer is
    ///     gated on the screensaver / display sleep starting. Keep the display
    ///     awake → that timer never starts → the session stays unlocked → the
    ///     app stays frontmost → HomeKit keeps servicing writes.
    /// Stored so the token lives as long as the app; released at process exit.
    private var activityToken: NSObjectProtocol?

    // SwiftUI status window
    var statusVM: StatusViewModel?
    var mainWindow: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        setbuf(stdout, nil)
        setbuf(stderr, nil)

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled],
            reason: "HomeKit lock bridge must stay awake, unthrottled, and frontmost"
        )
        FileHandle.standardError.write(Data("[lockbridge-server] App Nap + idle sleep + display sleep disabled (beginActivity held)\n".utf8))

        let vm = StatusViewModel()
        statusVM = vm

        let m = HomeKitMonitor()
        // Inject the persistent identity cache BEFORE start() so the very
        // first recomputeAndPublish for each accessory routes through it.
        m.identityCache = AccessoryIdentityCache(path: AccessoryIdentityCache.defaultPath())
        // Bring the app to the foreground whenever HA requests a write —
        // HomeKit services accessory writes promptly only for the frontmost
        // app. Runs on the main thread (setLockState is main-thread).
        m.onWriteRequested = { [weak self] in
            self?.activateApp()
            self?.bringWindowToFront()
        }
        let cliCommand = Self.parseCommand(from: CommandLine.arguments)
        if let cmd = cliCommand {
            m.setPendingCommand(cmd)
        }
        m.start()
        self.monitor = m

        if cliCommand == nil {
            startBridgeServer(monitor: m, viewModel: vm)
        }
        return true
    }

    private func startBridgeServer(monitor: HomeKitMonitor, viewModel: StatusViewModel) {
        do {
            let (config, path, wasMigrated, wasGenerated) = try Config.load()
            let log: (String) -> Void = { msg in
                FileHandle.standardError.write(Data("[lockbridge-server] \(msg)\n".utf8))
            }
            log("Config: \(path.path)")
            log("Instance ID: \(config.instance_id)")
            if wasGenerated {
                log("Fresh config — bridge is ready to pair with HomeAssistant.")
            } else if wasMigrated {
                log("Migrated legacy bearer_token into paired_clients.")
            }
            log("Paired clients: \(config.paired_clients.count)")

            let store = TokenStore(config: config, path: path)
            let pairing = PairingManager(store: store, logger: log)

            let interactionLog = InteractionLog()
            interactionLog.onChange = { [weak self, weak viewModel] in
                guard let log = self?.interactionLog else { return }
                let snapshot = log.all()
                Task { @MainActor in
                    viewModel?.recentInteractions = snapshot
                }
            }
            self.interactionLog = interactionLog

            let lockEventLog = LockEventLog()
            lockEventLog.onChange = { [weak self, weak viewModel] in
                guard let log = self?.lockEventLog else { return }
                let snapshot = log.all()
                Task { @MainActor in
                    viewModel?.recentLockEvents = snapshot
                }
            }
            self.lockEventLog = lockEventLog
            monitor.lockEventLog = lockEventLog

            // Pair request → show the inline banner and grab focus so the
            // user sees it (no Dock-bounce needed now that we're frontmost).
            pairing.onRequestStarted = { [weak self, weak viewModel] reqID, name in
                Task { @MainActor in
                    viewModel?.showPendingRequest(requestID: reqID, clientName: name)
                    self?.activateApp()
                    self?.bringWindowToFront()
                }
            }
            pairing.onRequestFinalized = { [weak self, weak viewModel] _, _ in
                Task { @MainActor in
                    viewModel?.clearPendingRequest()
                    if let count = self?.store?.snapshotConfig().paired_clients.count {
                        viewModel?.pairedCount = count
                    }
                    viewModel?.refreshMainView()
                }
            }

            // Wire view-model controls → app actions.
            viewModel.onApprove = { [weak pairing] reqID in
                pairing?.approveByNotification(requestID: reqID)
            }
            viewModel.onDeny = { [weak pairing] reqID in
                pairing?.deny(requestID: reqID)
            }
            viewModel.onResetConfirmed = { [weak self] in
                self?.performReset()
            }
            viewModel.onToggleLoginItem = { [weak self] in
                self?.toggleLoginItem()
            }
            viewModel.onQuit = {
                exit(0)
            }

            // Seed counts + login-item state, then settle into the right
            // main screen (paired → stats panel, else → waiting).
            viewModel.pairedCount = config.paired_clients.count
            viewModel.accessoryCount = 0
            viewModel.loginItemEnabled = LoginItemManager.isEnabled
            viewModel.loginItemAvailable = LoginItemManager.isAvailable
            Task { @MainActor in viewModel.refreshMainView() }

            // Keep the panel's live accessory list + count in sync.
            _ = monitor.addObserver(
                onState: { [weak viewModel, weak monitor] _ in
                    let snap = monitor?.snapshot().sorted { $0.name.lowercased() < $1.name.lowercased() } ?? []
                    Task { @MainActor in
                        viewModel?.accessories = snap
                        viewModel?.accessoryCount = snap.count
                    }
                },
                onRemoved: { [weak viewModel, weak monitor] _ in
                    let snap = monitor?.snapshot().sorted { $0.name.lowercased() < $1.name.lowercased() } ?? []
                    Task { @MainActor in
                        viewModel?.accessories = snap
                        viewModel?.accessoryCount = snap.count
                    }
                }
            )

            let s = BridgeServer(monitor: monitor, store: store, pairingManager: pairing, interactionLog: interactionLog, logger: log)
            s.onConnectionsChanged = { [weak viewModel] ips in
                Task { @MainActor in
                    viewModel?.connectedClients = ips
                }
            }
            try s.start()

            let bj = BonjourService(port: store.port, instanceID: store.instanceID, logger: log)
            bj.start()

            self.store = store
            self.pairingManager = pairing
            self.server = s
            self.bonjour = bj
        } catch {
            FileHandle.standardError.write(Data("[lockbridge-server] FAILED to start: \(error)\n".utf8))
        }
    }

    // MARK: - Login Item

    private func toggleLoginItem() {
        do {
            try LoginItemManager.toggle()
        } catch {
            FileHandle.standardError.write(
                Data("[ha-lockbridge] Login Item toggle failed: \(error.localizedDescription)\n".utf8)
            )
        }
        // Re-query authoritative state and reflect it in the toggle.
        let enabled = LoginItemManager.isEnabled
        let available = LoginItemManager.isAvailable
        Task { @MainActor in
            self.statusVM?.loginItemEnabled = enabled
            self.statusVM?.loginItemAvailable = available
        }
    }

    // MARK: - Reset pairing

    private func performReset() {
        guard let store = self.store else { return }
        let tokens = Array(store.snapshotConfig().paired_clients.keys)
        for token in tokens {
            store.removeToken(token)
        }
        // Token auth runs only at WS-upgrade time, so HA's already-upgraded
        // socket would outlive the tokens we just revoked. Drop it now.
        server?.closeAllWSConnections()
        Task { @MainActor in
            self.statusVM?.pairedCount = 0
            self.statusVM?.clearPendingRequest()
            self.statusVM?.refreshMainView()
        }
    }

    // MARK: - Scene config

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Main", sessionRole: connectingSceneSession.role)
        config.delegateClass = MainSceneDelegate.self
        return config
    }

    // MARK: - Window setup (called by MainSceneDelegate once the window exists)

    /// Final setup once the SwiftUI window is key+visible: become a normal
    /// foreground app, center the window, prevent it being closed/minimized
    /// (either would drop us out of `.active` and break HomeKit writes), and
    /// bring ourselves to the front.
    @MainActor
    func onWindowReady() {
        setAppKitActivationPolicy(.regular)
        centerNSWindow()
        disableWindowDismissal()
        activateApp()
        bringWindowToFront()
    }

    // MARK: - AppKit bridge (Catalyst exposes no AppKit directly)

    private func nsApp() -> NSObject? {
        guard let cls = NSClassFromString("NSApplication") else { return nil }
        return (cls as AnyObject)
            .perform(NSSelectorFromString("sharedApplication"))?
            .takeUnretainedValue() as? NSObject
    }

    private enum ActivationPolicy: Int {
        case regular = 0
        case accessory = 1
    }

    private func setAppKitActivationPolicy(_ policy: ActivationPolicy) {
        guard let nsApp = nsApp() else { return }
        let sel = NSSelectorFromString("setActivationPolicy:")
        guard nsApp.responds(to: sel), let imp = nsApp.method(for: sel) else { return }
        typealias Fn = @convention(c) (NSObject, Selector, Int) -> Bool
        _ = unsafeBitCast(imp, to: Fn.self)(nsApp, sel, policy.rawValue)
    }

    /// Bring this app to the foreground / make it the active (frontmost) app.
    /// Tries the macOS-14+ parameterless `activate()` first, falls back to
    /// `activateIgnoringOtherApps:`.
    private func activateApp() {
        guard let nsApp = nsApp() else { return }
        let newSel = NSSelectorFromString("activate")
        if nsApp.responds(to: newSel), let imp = nsApp.method(for: newSel) {
            typealias Fn = @convention(c) (NSObject, Selector) -> Void
            unsafeBitCast(imp, to: Fn.self)(nsApp, newSel)
            return
        }
        let oldSel = NSSelectorFromString("activateIgnoringOtherApps:")
        guard nsApp.responds(to: oldSel), let imp = nsApp.method(for: oldSel) else { return }
        typealias OldFn = @convention(c) (NSObject, Selector, Bool) -> Void
        unsafeBitCast(imp, to: OldFn.self)(nsApp, oldSel, true)
    }

    /// Order our window above everyone else. `orderFrontRegardless` isn't
    /// gated by the macOS-14+ activation-token policy, so it reliably lifts
    /// our window over other apps even when we weren't already active.
    private func bringWindowToFront() {
        guard let nsApp = nsApp() else { return }
        let sel = NSSelectorFromString("orderFrontRegardless")
        if let keyWin = nsApp.value(forKey: "keyWindow") as? NSObject, keyWin.responds(to: sel) {
            _ = keyWin.perform(sel)
            return
        }
        guard let windows = nsApp.value(forKey: "windows") as? [NSObject] else { return }
        for w in windows where w.responds(to: sel) {
            _ = w.perform(sel)
        }
    }

    /// Center the backing NSWindow. UIWindow.frame changes don't reliably
    /// position the NSWindow on Catalyst, so reach through to -[NSWindow center].
    private func centerNSWindow() {
        guard let nsApp = nsApp() else { return }
        guard let windows = nsApp.value(forKey: "windows") as? [NSObject] else { return }
        let centerSel = NSSelectorFromString("center")
        for w in windows where w.responds(to: centerSel) {
            _ = w.perform(centerSel)
        }
    }

    /// Hide the close + miniaturize window buttons. Closing the window tears
    /// down the backing NSWindow (which Catalyst won't rebuild) and minimizing
    /// drops the app out of `.active` — both break HomeKit writes. The only
    /// way to stop the bridge is the in-panel Quit (or Cmd-Q). Zoom is left
    /// alone (harmless).
    private func disableWindowDismissal() {
        guard let nsApp = nsApp() else { return }
        guard let windows = nsApp.value(forKey: "windows") as? [NSObject] else { return }
        let stdBtnSel = NSSelectorFromString("standardWindowButton:")
        typealias GetBtnFn = @convention(c) (NSObject, Selector, Int) -> NSObject?
        for w in windows where w.responds(to: stdBtnSel) {
            guard let imp = w.method(for: stdBtnSel) else { continue }
            let getBtn = unsafeBitCast(imp, to: GetBtnFn.self)
            // NSWindowButton: closeButton=0, miniaturizeButton=1.
            for which in 0...1 {
                if let btn = getBtn(w, stdBtnSel, which) {
                    btn.setValue(true, forKey: "hidden")
                }
            }
        }
    }

    // MARK: - CLI parsing

    static func parseCommand(from args: [String]) -> HomeKitMonitor.PendingCommand? {
        let pairs: [(String, HomeKitMonitor.PendingAction)] = [
            ("--toggle", .toggle),
            ("--lock", .lock),
            ("--unlock", .unlock),
        ]
        for (flag, action) in pairs {
            if let idx = args.firstIndex(of: flag), idx + 1 < args.count {
                return .init(nameOrUUID: args[idx + 1], action: action)
            }
        }
        return nil
    }
}
