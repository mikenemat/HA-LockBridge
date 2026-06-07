import UIKit
import SwiftUI
import Combine
import ObjectiveC.runtime

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// Static-init "first layer" of the four-layer defense against Catalyst
    /// spawning a blank window despite LSUIElement=true. Runs once at class
    /// load, before any of the other lifecycle hooks. Accessing the property
    /// from `init` and `willFinishLaunching` forces the side-effect.
    static let _earlyActivationPolicy: Void = {
        AppDelegate.applyAccessoryPolicy()
    }()

    override init() {
        super.init()
        _ = AppDelegate._earlyActivationPolicy
        AppDelegate.applyAccessoryPolicy()
    }

    /// Static helper used by every layer of the defense. Doesn't touch
    /// `lastActivationPolicy` because that's instance state for the
    /// status-bar reinstall logic, which isn't ready this early.
    private static func applyAccessoryPolicy() {
        guard let cls = NSClassFromString("NSApplication") else { return }
        guard let nsApp = (cls as AnyObject)
            .perform(NSSelectorFromString("sharedApplication"))?
            .takeUnretainedValue() as? NSObject else { return }
        let sel = NSSelectorFromString("setActivationPolicy:")
        guard nsApp.responds(to: sel), let imp = nsApp.method(for: sel) else { return }
        typealias Fn = @convention(c) (NSObject, Selector, Int) -> Bool
        _ = unsafeBitCast(imp, to: Fn.self)(nsApp, sel, 1 /* .accessory */)
    }
    var monitor: HomeKitMonitor?
    var server: BridgeServer?
    var pairingManager: PairingManager?
    var bonjour: BonjourService?
    var store: TokenStore?
    var statusBar: StatusBarController?
    var interactionLog: InteractionLog?
    var lockEventLog: LockEventLog?

    /// Process-lifetime activity assertion. Held for the entire run to (a)
    /// disable App Nap — without this, a headless `.accessory` app with no
    /// visible window gets throttled: main-queue `asyncAfter` retry timers
    /// AND NIO-scheduled WS ping tasks get coalesced, so lock commands stall
    /// and HA's WebSocket can time out (30s of ping silence) until the
    /// window is opened and the OS releases the nap — and (b) prevent idle
    /// system sleep, since a bridge that's asleep is a bridge that's down.
    /// `.idleSystemSleepDisabled` stops *idle* sleep (not lid-close / manual
    /// sleep); combined with `begin/endActivity` semantics it also disables
    /// App Nap for the duration. Kept as a stored property so the token
    /// lives as long as the app — if it deallocated, the assertion would
    /// lift. Released implicitly at process exit.
    private var activityToken: NSObjectProtocol?

    // SwiftUI status window
    var statusVM: StatusViewModel?
    var mainWindow: UIWindow?
    private var visibilityCancellable: AnyCancellable?
    /// Whether refreshWindowVisibility last set the window hidden. Tracked
    /// separately from `mainWindow.isHidden` because closing the underlying
    /// NSWindow via the title-bar red X (or Cmd-W) doesn't update UIWindow's
    /// isHidden — Catalyst's UIWindow ↔ NSWindow bridge is one-way. Without
    /// this flag we'd skip `makeKeyAndVisible` on the next show attempt
    /// because `isHidden` still reads `false`, leaving a Dock icon with no
    /// window.
    private var windowWasHidden = true
    /// Last activation policy we asked AppKit for, so we can reinstall the
    /// status bar item only on real transitions (each reinstall briefly
    /// blanks the menu icon, so we don't want one per refresh).
    private var lastActivationPolicy: ActivationPolicy?
    /// NSWindows that existed before MainSceneDelegate created our own
    /// UIWindow. On a Finder/LaunchServices launch, Catalyst auto-spawns a
    /// blank window on the scene before our delegate runs (LSUIElement=true
    /// is ignored). Without keeping handles to these and explicitly hiding
    /// them, setting our own UIWindow.isHidden=true leaves the blank ones
    /// visible — the user sees an empty "HA-LockBridge" window when the
    /// bridge should be headless. Captured in MainSceneDelegate and
    /// neutralized below.
    var knownRogueNSWindows: [NSObject] = []
    // (Previously we tracked `ourNSWindow` here and orderOut'd only that
    // handle in hide. The synchronous capture race after `makeKeyAndVisible`
    // sometimes returned nil on first show, leaving hide a no-op and the
    // user seeing a ghost window with just the title bar after the
    // briefStatus countdown. Now we filter by NSWindow vs NSPanel class
    // instead — system text-services use NSPanel, our content windows
    // (and Catalyst rogues) are plain NSWindow, so the class check cleanly
    // separates them without any capture race.)

    func application(
        _ application: UIApplication,
        willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Third layer of the defense: set policy before any scene setup.
        AppDelegate.applyAccessoryPolicy()
        return true
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        setbuf(stdout, nil)
        setbuf(stderr, nil)

        // Opt out of App Nap + idle system sleep for the app's lifetime.
        // This MUST happen before the HomeKit monitor and bridge server
        // spin up, so their timers/WS pings are never throttled even
        // momentarily. See the comment on `activityToken` for the full
        // rationale (headless accessory apps are the canonical App Nap
        // target; throttling stalls lock commands + WS keepalive).
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .automaticTerminationDisabled, .suddenTerminationDisabled],
            reason: "HomeKit lock bridge must stay awake and unthrottled while running"
        )
        FileHandle.standardError.write(Data("[lockbridge-server] App Nap + idle sleep disabled (beginActivity held)\n".utf8))

        // Fourth layer: set again here, in case the scene system already
        // resurrected something. The snapshot-based rogue detection in
        // MainSceneDelegate plus orderOutAllNSWindows on hide handles
        // anything that slips through.
        setAppKitActivationPolicy(.accessory)

        let vm = StatusViewModel()
        statusVM = vm

        // Observe vm.display → drive window + activation policy
        visibilityCancellable = vm.$display
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshWindowVisibility() }

        let m = HomeKitMonitor()
        // Inject the persistent identity cache BEFORE start() so the very
        // first recomputeAndPublish for each accessory routes through it.
        // The cache pins wire IDs across re-signs (HMAccessory.uniqueIdentifier
        // is per-app and rotates), which is the only thing keeping HA's
        // entity registry from orphaning every lock without a usable
        // SerialNumber characteristic.
        m.identityCache = AccessoryIdentityCache(path: AccessoryIdentityCache.defaultPath())
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
                let snapshot = log.recent(3)
                Task { @MainActor in
                    viewModel?.recentInteractions = snapshot
                }
            }
            self.interactionLog = interactionLog

            // Lock health log. Mirrors the InteractionLog wiring pattern
            // but with a longer display window (20) since these events
            // are higher signal-to-noise and the user wants history.
            let lockEventLog = LockEventLog()
            lockEventLog.onChange = { [weak self, weak viewModel] in
                guard let log = self?.lockEventLog else { return }
                let snapshot = log.recent(20)
                Task { @MainActor in
                    viewModel?.recentLockEvents = snapshot
                }
            }
            self.lockEventLog = lockEventLog
            // Inject into the monitor so the background-write retry loop
            // and reachability delegate can record events. Done here (vs.
            // in startup before m.start()) because the log is owned by
            // the bridge-server scope; the CLI-test mode doesn't need it
            // and intentionally leaves monitor.lockEventLog == nil.
            monitor.lockEventLog = lockEventLog

            // Wire PairingManager → ViewModel. Also bounce the Dock icon so
            // the user notices even if the pair window is behind other apps.
            pairing.onRequestStarted = { [weak self, weak viewModel] reqID, name in
                Task { @MainActor in
                    viewModel?.showPendingRequest(requestID: reqID, clientName: name)
                    self?.bounceDockIcon(critical: true)
                }
            }
            pairing.onRequestFinalized = { [weak self, weak viewModel] _, state in
                Task { @MainActor in
                    // Refresh pairedCount from the store so dismissOverlay,
                    // the footer label, and the single-pair gate all reflect
                    // the post-approval reality.
                    if let count = self?.store?.snapshotConfig().paired_clients.count {
                        viewModel?.pairedCount = count
                    }
                    switch state {
                    case .approved: viewModel?.showApproved()
                    case .denied:   viewModel?.showDenied()
                    case .expired:  viewModel?.showExpired()
                    case .pending:  break
                    }
                }
            }

            // Wire ViewModel buttons → PairingManager
            viewModel.onApprove = { [weak pairing] reqID in
                pairing?.approveByNotification(requestID: reqID)
            }
            viewModel.onDeny = { [weak pairing] reqID in
                pairing?.deny(requestID: reqID)
            }

            // Push paired/lock counts into the VM so the footer always reflects truth
            viewModel.pairedCount = config.paired_clients.count
            viewModel.accessoryCount = 0  // populated below as accessories arrive

            // Update VM accessoryCount when HomeKit state changes
            _ = monitor.addObserver(
                onState: { [weak viewModel, weak monitor] _ in
                    let count = monitor?.snapshot().count ?? 0
                    Task { @MainActor in
                        viewModel?.accessoryCount = count
                    }
                },
                onRemoved: { [weak viewModel, weak monitor] _ in
                    let count = monitor?.snapshot().count ?? 0
                    Task { @MainActor in
                        viewModel?.accessoryCount = count
                    }
                }
            )

            let s = BridgeServer(monitor: monitor, store: store, pairingManager: pairing, interactionLog: interactionLog, logger: log)
            // Mirror the live WS client list into the view model so the
            // Stats & Debug page's HA-connected indicator updates in real
            // time, not just at snapshot-open. Fires on every connect /
            // disconnect, on the main thread.
            s.onConnectionsChanged = { [weak viewModel] ips in
                Task { @MainActor in
                    viewModel?.connectedClients = ips
                }
            }
            try s.start()

            let bj = BonjourService(port: store.port, instanceID: store.instanceID, logger: log)
            bj.start()

            // Status bar menu — wire actions to view-model + token store
            let statusBar = StatusBarController()
            statusBar.onShowDebug = { [weak self, weak viewModel, weak monitor] in
                guard let viewModel = viewModel, let monitor = monitor else { return }
                Task { @MainActor in
                    let accessories = monitor.snapshot()
                        .sorted { $0.name.lowercased() < $1.name.lowercased() }
                    viewModel.showDebug(
                        accessories: accessories,
                        pairedCount: self?.store?.snapshotConfig().paired_clients.count ?? 0
                    )
                    self?.bounceDockIcon(critical: false)
                }
            }
            statusBar.onResetRequested = { [weak self, weak viewModel] in
                Task { @MainActor in
                    viewModel?.showResetConfirm()
                    self?.bounceDockIcon(critical: false)
                }
            }
            statusBar.onToggleLoginItem = { [weak self] in
                self?.toggleLoginItem()
            }
            statusBar.onQuit = {
                exit(0)
            }
            viewModel.onResetConfirmed = { [weak self] in
                self?.performReset()
            }
            // Seed initial Login Item state before first install so the
            // menu's checkmark renders correctly on first open.
            statusBar.loginItemEnabled = LoginItemManager.isEnabled
            statusBar.loginItemAvailable = LoginItemManager.isAvailable
            statusBar.install()
            self.statusBar = statusBar

            self.store = store
            self.pairingManager = pairing
            self.server = s
            self.bonjour = bj

            // Initial window state
            Task { @MainActor in
                if config.paired_clients.isEmpty {
                    viewModel.showWaitingForFirstPair()
                } else {
                    viewModel.showBriefStatus(seconds: 5)
                }
            }
        } catch {
            FileHandle.standardError.write(Data("[lockbridge-server] FAILED to start: \(error)\n".utf8))
        }
    }

    // MARK: - Login Item (called from status bar menu)

    /// Toggle the app's "Start at Login" registration via SMAppService, then
    /// refresh the status bar so the checkmark reflects the new state.
    private func toggleLoginItem() {
        do {
            try LoginItemManager.toggle()
        } catch {
            FileHandle.standardError.write(
                Data("[ha-lockbridge] Login Item toggle failed: \(error.localizedDescription)\n".utf8)
            )
        }
        // Re-query the authoritative state — register/unregister may have
        // surfaced an approval-pending state we want reflected accurately.
        statusBar?.loginItemEnabled = LoginItemManager.isEnabled
        statusBar?.loginItemAvailable = LoginItemManager.isAvailable
        statusBar?.reinstall()
    }

    // MARK: - Reset pairing (called from status bar menu after user confirms)

    private func performReset() {
        guard let store = self.store else { return }
        let tokens = Array(store.snapshotConfig().paired_clients.keys)
        for token in tokens {
            store.removeToken(token)
        }
        // Forcibly close any live WS connections. Token auth runs only at
        // WS-upgrade time, so HA's already-upgraded socket would otherwise
        // outlive the tokens we just revoked, and Reset Pairing would
        // appear to do nothing until the user restarted the app. Now the
        // socket drops immediately; HA's client surfaces the disconnect
        // and the user can re-pair without a restart.
        server?.closeAllWSConnections()
        // Hide the confirm dialog and re-enter "waiting" state if no clients left
        Task { @MainActor in
            self.statusVM?.pairedCount = 0
            self.statusVM?.showWaitingForFirstPair()
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

    // MARK: - Window visibility

    /// Reflect the view-model's display into the actual window + activation policy.
    /// Called when the VM publishes a new display state, and once after the scene
    /// connects.
    @MainActor
    func refreshWindowVisibility() {
        guard let vm = statusVM else { return }
        guard let window = mainWindow else { return }
        let shouldShow = vm.display.isVisible

        if shouldShow {
            setAppKitActivationPolicy(.regular)
            // makeKeyAndVisible is idempotent for an already-visible UIWindow.
            // Catalyst won't reliably re-create a destroyed backing NSWindow
            // from this call, which is why we hide the standard close button
            // below — so the user can't trigger that destroy path in the
            // first place. The only dismissal route is now our own buttons,
            // which go through dismissOverlay → display=.hidden / .waiting…
            window.makeKeyAndVisible()
            hideStandardWindowControls()
            // Re-neutralize any rogue Catalyst-spawned windows in case the
            // OS un-hid them when we flipped to .regular. Defense in depth.
            neutralizeRogueNSWindows()
            // Bring the window above everyone else. `activate()` alone
            // doesn't reliably do this on macOS 14+ — apps need an
            // activation token, and status-bar-menu clicks don't grant
            // one. orderFrontRegardless bypasses that policy.
            activateApp()
            bringWindowToFront()
            // Only re-center on a real hidden→visible transition so we don't
            // yank the window out from under a user who's moved it.
            if windowWasHidden {
                centerNSWindow()
                windowWasHidden = false
            }
        } else {
            window.isHidden = true
            setAppKitActivationPolicy(.accessory)
            // UIWindow.isHidden=true does NOT reliably hide the backing
            // NSWindow on Catalyst — UIKit→AppKit bridging is one-way and
            // patchy. If we stop here the user sees a ghost window with
            // only the system-painted title bar after the briefStatus
            // countdown. So reach through to AppKit and orderOut every
            // NSWindow that isn't an NSPanel — see
            // `orderOutOurContentWindows` for why the NSPanel filter
            // matters for the spell-check / language picker bug.
            orderOutOurContentWindows()
            windowWasHidden = true
        }
    }

    /// orderOut every NSWindow in `NSApp.windows` that isn't an NSPanel.
    ///
    /// NSPanel is the parent class for system-owned text-services panels:
    /// spell-check, grammar, language picker, dictation, etc. macOS
    /// occasionally parks those inside an app's window list; if we
    /// orderOut them indiscriminately, the system surfaces a "configure
    /// language" prompt to resolve the orphaned input session — that's
    /// the source of the unkillable language-picker popups we hit
    /// earlier. Filtering on `isKind(of: NSPanel)` leaves those alone.
    ///
    /// Plain NSWindow instances are either ours (our SwiftUI window's
    /// backing NSWindow) or Catalyst-auto-spawned rogue blanks — both
    /// safe to orderOut.
    private func orderOutOurContentWindows() {
        guard let cls = NSClassFromString("NSApplication") else { return }
        guard let nsApp = (cls as AnyObject)
            .perform(NSSelectorFromString("sharedApplication"))?
            .takeUnretainedValue() as? NSObject else { return }
        guard let windows = nsApp.value(forKey: "windows") as? [NSObject] else { return }
        let panelCls = NSClassFromString("NSPanel")
        let sel = NSSelectorFromString("orderOut:")
        for w in windows where w.responds(to: sel) {
            if let panelCls = panelCls, w.isKind(of: panelCls) {
                continue
            }
            _ = w.perform(sel, with: nil)
        }
    }

/// Permanently disable any NSWindow that existed before our UIWindow was
    /// attached to the scene. On Finder-initiated launches Catalyst spawns a
    /// blank window despite LSUIElement=true, and there's no Catalyst API to
    /// suppress it — orderOut + alphaValue=0 makes it invisible whether or
    /// not the OS resurrects it later. Safe to call repeatedly; each call
    /// re-applies the same neutralization to the same captured handles.
    private func neutralizeRogueNSWindows() {
        let orderOutSel = NSSelectorFromString("orderOut:")
        for w in knownRogueNSWindows {
            w.setValue(0.0, forKey: "alphaValue")
            w.setValue(true, forKey: "ignoresMouseEvents")
            if w.responds(to: orderOutSel) {
                _ = w.perform(orderOutSel, with: nil)
            }
        }
    }

    /// Snapshot of NSApp.windows right now. MainSceneDelegate uses this to
    /// capture pre-existing rogue windows before adding our real one.
    func snapshotNSWindows() -> [NSObject] {
        guard let cls = NSClassFromString("NSApplication") else { return [] }
        guard let nsApp = (cls as AnyObject)
            .perform(NSSelectorFromString("sharedApplication"))?
            .takeUnretainedValue() as? NSObject else { return [] }
        return (nsApp.value(forKey: "windows") as? [NSObject]) ?? []
    }

    /// Bring this app to the foreground. Needed when a status-bar-menu click
    /// flips us from .accessory to .regular — without explicit activation,
    /// the window can come up behind whatever was foreground a moment ago.
    /// Tries the macOS-14+ parameterless `activate()` first, falls back to
    /// the older `activateIgnoringOtherApps:` for older systems.
    private func activateApp() {
        guard let cls = NSClassFromString("NSApplication") else { return }
        guard let nsApp = (cls as AnyObject)
            .perform(NSSelectorFromString("sharedApplication"))?
            .takeUnretainedValue() as? NSObject else { return }
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

    /// Send every NSWindow to the very front. Used in addition to
    /// `activateApp` because on macOS 14+ a non-foreground app can't always
    /// grant itself activation (the "activation token" requirement) — but
    /// `orderFrontRegardless` is not gated by that policy, so it reliably
    /// lifts our window above other apps' windows on a menu-bar click.
    private func bringWindowToFront() {
        guard let cls = NSClassFromString("NSApplication") else { return }
        guard let nsApp = (cls as AnyObject)
            .perform(NSSelectorFromString("sharedApplication"))?
            .takeUnretainedValue() as? NSObject else { return }
        let sel = NSSelectorFromString("orderFrontRegardless")
        // Prefer NSApp.keyWindow — after `makeKeyAndVisible` our window is
        // key and this is the safest single-window target.
        if let keyWin = nsApp.value(forKey: "keyWindow") as? NSObject,
           keyWin.responds(to: sel) {
            _ = keyWin.perform(sel)
            return
        }
        // Fallback: when our app isn't the active app (e.g. Finder kept
        // focus after launching us, or the user clicked our menu without
        // activating us), keyWindow is nil. Order front everything that
        // isn't a known rogue.
        guard let windows = nsApp.value(forKey: "windows") as? [NSObject] else { return }
        let rogues = Set(knownRogueNSWindows.map(ObjectIdentifier.init))
        for w in windows where w.responds(to: sel) {
            if rogues.contains(ObjectIdentifier(w)) { continue }
            _ = w.perform(sel)
        }
    }

    /// Hide the NSWindow's close, miniaturize, and zoom buttons. Catalyst
    /// presents these by default on any UIWindow-backed NSWindow. Clicking
    /// the red X or pressing Cmd-W tears down the backing NSWindow without
    /// updating UIWindow.isHidden — UIWindow's makeKeyAndVisible can't
    /// rebuild the destroyed NSWindow, so the only recovery would be
    /// restarting the bridge. Hiding the buttons forces the user through
    /// our own Close button (which calls viewModel.dismissOverlay) and
    /// keeps the window state coherent.
    private func hideStandardWindowControls() {
        guard let cls = NSClassFromString("NSApplication") else { return }
        guard let nsApp = (cls as AnyObject)
            .perform(NSSelectorFromString("sharedApplication"))?
            .takeUnretainedValue() as? NSObject else { return }
        guard let windows = nsApp.value(forKey: "windows") as? [NSObject] else { return }

        let stdBtnSel = NSSelectorFromString("standardWindowButton:")
        typealias GetBtnFn = @convention(c) (NSObject, Selector, Int) -> NSObject?

        for w in windows where w.responds(to: stdBtnSel) {
            guard let imp = w.method(for: stdBtnSel) else { continue }
            let getBtn = unsafeBitCast(imp, to: GetBtnFn.self)
            // NSWindowButton: closeButton=0, miniaturizeButton=1, zoomButton=2.
            for which in 0...2 {
                if let btn = getBtn(w, stdBtnSel, which) {
                    btn.setValue(true, forKey: "hidden")
                }
            }
        }
    }

    /// Bounce the Dock icon to get the user's attention when a pair request
    /// arrives. `critical=true` bounces continuously until the user clicks
    /// the icon (NSCriticalRequest=0); `false` bounces once
    /// (NSInformationalRequest=10).
    private func bounceDockIcon(critical: Bool = true) {
        guard let cls = NSClassFromString("NSApplication") else { return }
        guard let nsApp = (cls as AnyObject)
            .perform(NSSelectorFromString("sharedApplication"))?
            .takeUnretainedValue() as? NSObject else { return }
        let sel = NSSelectorFromString("requestUserAttention:")
        guard nsApp.responds(to: sel), let imp = nsApp.method(for: sel) else { return }
        typealias Fn = @convention(c) (NSObject, Selector, Int) -> Int
        _ = unsafeBitCast(imp, to: Fn.self)(nsApp, sel, critical ? 0 : 10)
    }

    /// Center the underlying NSWindow on screen via AppKit. UIWindow.frame
    /// changes on Catalyst don't reliably position the backing NSWindow, so
    /// we reach through the bridge and call -[NSWindow center].
    private func centerNSWindow() {
        guard let cls = NSClassFromString("NSApplication") else { return }
        guard let nsApp = (cls as AnyObject)
            .perform(NSSelectorFromString("sharedApplication"))?
            .takeUnretainedValue() as? NSObject else { return }
        guard let windows = nsApp.value(forKey: "windows") as? [NSObject] else { return }
        let centerSel = NSSelectorFromString("center")
        for w in windows where w.responds(to: centerSel) {
            _ = w.perform(centerSel)
        }
    }

    // MARK: - AppKit activation policy

    private enum ActivationPolicy: Int {
        case regular = 0
        case accessory = 1
    }

    private func setAppKitActivationPolicy(_ policy: ActivationPolicy) {
        guard let cls = NSClassFromString("NSApplication") else { return }
        guard let nsApp = (cls as AnyObject)
            .perform(NSSelectorFromString("sharedApplication"))?
            .takeUnretainedValue() as? NSObject else { return }
        let sel = NSSelectorFromString("setActivationPolicy:")
        guard nsApp.responds(to: sel), let imp = nsApp.method(for: sel) else { return }
        typealias Fn = @convention(c) (NSObject, Selector, Int) -> Bool
        _ = unsafeBitCast(imp, to: Fn.self)(nsApp, sel, policy.rawValue)

        // Real transition? Reinstall the status bar item so its menu
        // anchor matches the post-policy menu-bar layout. Otherwise the
        // status item visually moves with the layout but the cached
        // drop-down origin stays at the pre-policy position, and the
        // menu drops to the left of the icon on the next click.
        if let prior = lastActivationPolicy, prior != policy {
            statusBar?.reinstall()
        }
        lastActivationPolicy = policy
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
