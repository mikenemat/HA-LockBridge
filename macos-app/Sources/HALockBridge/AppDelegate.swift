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
    /// The app that was frontmost before we stole focus for a lock write
    /// (an NSRunningApplication, via the Obj-C bridge). We hand focus back to
    /// it once the write settles. nil when we owe no restore.
    private var focusRestoreTarget: NSObject?
    /// The pending +0.2s focus re-grab. Stored so a sub-200ms settle can
    /// cancel it in `restoreFocusTarget()` — otherwise the late re-grab fires
    /// AFTER we've already restored focus, permanently re-stealing it.
    private var pendingFocusReGrab: DispatchWorkItem?

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
            guard let self = self else { return }
            // Remember who was in front, then take focus.
            self.captureFocusTargetIfNeeded()
            self.grabFocus()
            // Re-assert shortly after: macOS 14+ cooperative activation can
            // silently drop a self-activation that arrives without an
            // activation token, so a single attempt occasionally doesn't
            // take. A second pass a beat later makes it reliable. Stored as a
            // cancellable work item so a sub-200ms settle can cancel it in
            // restoreFocusTarget() — otherwise this late re-grab fires after
            // we've already handed focus back and permanently re-steals it.
            self.pendingFocusReGrab?.cancel()
            let reGrab = DispatchWorkItem { [weak self] in
                self?.pendingFocusReGrab = nil
                self?.grabFocus()
                // Verify shortly after the re-grab — cooperative activation is
                // async, so check on the next runloop hop rather than inline.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.verifyFocusGrab()
                }
            }
            self.pendingFocusReGrab = reGrab
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: reGrab)
        }
        // When the last in-flight write settles, hand focus back to whatever
        // app we stole it from — return things to how they were.
        m.onAllWritesSettled = { [weak self] in
            self?.restoreFocusTarget()
        }
        // Surface the authorized-but-homeless appliance-rot mode in the UI.
        m.onHomesVisibilityChanged = { [weak vm] empty in
            Task { @MainActor in vm?.homesVisibilityWarning = empty }
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

            // Cap the rows we push into the @Published lists. History stays
            // unbounded in the logs; this bounds the per-event copy + SwiftUI
            // diff that runs on the main (HomeKit) thread so a months-uptime
            // bridge doesn't pay O(history) on every single event. The Stats
            // panel's scroll regions only show a finite window anyway.
            let maxUIRows = 200

            let interactionLog = InteractionLog()
            interactionLog.onChange = { [weak self, weak viewModel] in
                guard let log = self?.interactionLog else { return }
                let snapshot = log.recent(maxUIRows)
                Task { @MainActor in
                    viewModel?.recentInteractions = snapshot
                }
            }
            self.interactionLog = interactionLog

            let lockEventLog = LockEventLog()
            lockEventLog.onChange = { [weak self, weak viewModel] in
                guard let log = self?.lockEventLog else { return }
                let snapshot = log.recent(maxUIRows)
                Task { @MainActor in
                    viewModel?.recentLockEvents = snapshot
                }
            }
            self.lockEventLog = lockEventLog
            monitor.lockEventLog = lockEventLog

            // Pair request → show the inline banner and grab focus so the
            // user sees it (no Dock-bounce needed now that we're frontmost).
            pairing.onRequestStarted = { [weak self, weak viewModel] reqID, name, requesterIP in
                Task { @MainActor in
                    viewModel?.showPendingRequest(requestID: reqID, clientName: name, requesterIP: requesterIP)
                    self?.activateApp()
                    self?.bringWindowToFront()
                }
            }
            pairing.onRequestFinalized = { [weak self, weak viewModel] reqID, _ in
                Task { @MainActor in
                    // Only clear the banner if it's still showing THIS request.
                    // An old request's expiry must not wipe a banner that has
                    // since advanced to an unrelated pending request.
                    viewModel?.clearPendingRequest(ifMatching: reqID)
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
            viewModel.onOpenLoginItemsSettings = {
                LoginItemManager.openSettings()
            }
            viewModel.onQuit = {
                exit(0)
            }

            // Seed counts + login-item state. Deliberately DON'T settle into
            // the main screen yet — the "advertising on your network" screen
            // must not show before the server has actually bound its port.
            // refreshMainView() is called below, after `try s.start()`
            // succeeds, so a bind failure surfaces the error screen instead.
            viewModel.pairedCount = config.paired_clients.count
            viewModel.accessoryCount = 0

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

            let s = BridgeServer(monitor: monitor, store: store, pairingManager: pairing, interactionLog: interactionLog, lockEventLog: lockEventLog, logger: log)
            s.onConnectionsChanged = { [weak viewModel] ips in
                Task { @MainActor in
                    viewModel?.connectedClients = ips
                }
            }
            try s.start()

            // Server is bound and listening — NOW settle into the main screen
            // (paired → stats panel, else → waiting). Doing this only after a
            // successful start() means a bind failure can't show the
            // "advertising on your network" screen with a dead server behind it.
            Task { @MainActor in viewModel.refreshMainView() }

            let bj = BonjourService(port: store.port, instanceID: store.instanceID, logger: log)
            bj.start()

            self.store = store
            self.pairingManager = pairing
            self.server = s
            self.bonjour = bj
        } catch {
            FileHandle.standardError.write(Data("[lockbridge-server] FAILED to start: \(error)\n".utf8))
            // Surface the failure in the UI instead of sitting on the
            // initializing/advertising screen with no working server. Common
            // causes: port 8765 already in use, or a corrupt config.json.
            let message = (error as NSError).localizedDescription
            Task { @MainActor in viewModel.showError(message) }
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

    // MARK: - Menu hardening (Catalyst)

    /// Strip the menu commands that would background or close the appliance:
    /// Close (Cmd-W), Minimize/Zoom (Cmd-M), and Hide (Cmd-H). Either closing
    /// or minimizing/hiding drops the app out of `.active`, which stalls
    /// HomeKit writes (see the appliance rationale at the top of this file).
    /// Quit (Cmd-Q) is deliberately left intact — it's the supported way to
    /// stop the bridge, alongside the in-window Quit button.
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        builder.remove(menu: .close)
        builder.remove(menu: .minimizeAndZoom)
        builder.remove(menu: .hide)
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
        checkAppKitBridgeSelectors()
        setAppKitActivationPolicy(.regular)
        centerNSWindow()
        disableWindowDismissal()
        activateApp()
        bringWindowToFront()
    }

    /// One-time startup probe: log a warning if the AppKit runtime-bridge
    /// selectors we depend on can't be resolved on this OS. Without this,
    /// every runtime-bridge call (activate, order-front, styleMask, etc.)
    /// fails silently — and the user only discovers the appliance can't grab
    /// focus when a 3am lock command stalls. Surfacing it at launch turns a
    /// silent degradation into a visible log line.
    private func checkAppKitBridgeSelectors() {
        guard let nsApp = nsApp() else {
            FileHandle.standardError.write(Data("[lockbridge-server] AppKit bridge: NSApplication unavailable — focus-steal and window hardening will NOT work\n".utf8))
            return
        }
        let appSelectors = ["setActivationPolicy:", "activate", "activateIgnoringOtherApps:", "isActive"]
        let missing = appSelectors.filter { !nsApp.responds(to: NSSelectorFromString($0)) }
        if !missing.isEmpty {
            FileHandle.standardError.write(Data("[lockbridge-server] AppKit bridge: NSApplication missing selectors \(missing.joined(separator: ", ")) — focus-steal may be unreliable\n".utf8))
        }
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
        // Modern cooperative activate (macOS 14+).
        let newSel = NSSelectorFromString("activate")
        if nsApp.responds(to: newSel), let imp = nsApp.method(for: newSel) {
            typealias Fn = @convention(c) (NSObject, Selector) -> Void
            unsafeBitCast(imp, to: Fn.self)(nsApp, newSel)
        }
        // Legacy forceful activate — deprecated, but it isn't gated on an
        // activation token, so it's more reliable for a background app
        // self-activating. Call BOTH (no early return); doubling up is
        // harmless and noticeably more robust than either alone.
        let oldSel = NSSelectorFromString("activateIgnoringOtherApps:")
        if nsApp.responds(to: oldSel), let imp = nsApp.method(for: oldSel) {
            typealias OldFn = @convention(c) (NSObject, Selector, Bool) -> Void
            unsafeBitCast(imp, to: OldFn.self)(nsApp, oldSel, true)
        }
    }

    /// Make ourselves the active app AND lift our window to the front.
    private func grabFocus() {
        activateApp()
        bringWindowToFront()
    }

    /// Whether NSApplication currently reports `.active`. nil if the selector
    /// can't be resolved (which itself is a signal the AppKit bridge is
    /// broken on this OS). Read via the KVC bridge.
    private func isAppActive() -> Bool? {
        guard let nsApp = nsApp() else { return nil }
        let sel = NSSelectorFromString("isActive")
        guard nsApp.responds(to: sel) else { return nil }
        return (nsApp.value(forKey: "active") as? NSNumber)?.boolValue
    }

    /// After a focus-grab, verify we actually became `.active`. If not, the
    /// next HomeKit write may stall (the whole reason we grab focus). Record a
    /// diagnostic into the LockEventLog so the failure is visible on the Stats
    /// page rather than silently degrading. Runs a beat after the re-grab so
    /// cooperative activation has settled.
    private func verifyFocusGrab() {
        switch isAppActive() {
        case .some(true):
            return  // grabbed successfully
        case .some(false):
            lockEventLog?.record(.init(
                id: UUID(),
                accessoryName: "(app)",
                accessoryID: "",
                timestamp: Date(),
                kind: .focusGrabFailed
            ))
            FileHandle.standardError.write(Data("[lockbridge-server] focus grab verification: app is NOT active after grab — HomeKit write may stall\n".utf8))
        case .none:
            // Selector didn't resolve — logged once at startup already; don't
            // spam a LockEventLog entry per write.
            break
        }
    }

    /// The current frontmost application (NSRunningApplication) via
    /// NSWorkspace. nil if unavailable.
    private func frontmostApp() -> NSObject? {
        guard let cls = NSClassFromString("NSWorkspace") else { return nil }
        guard let ws = (cls as AnyObject)
            .perform(NSSelectorFromString("sharedWorkspace"))?
            .takeUnretainedValue() as? NSObject else { return nil }
        return ws.value(forKey: "frontmostApplication") as? NSObject
    }

    /// Before stealing focus, remember which app was frontmost so we can hand
    /// it back once the write settles. Skips if we're already frontmost
    /// (nothing to restore) or a capture is already outstanding for an
    /// in-flight write batch (keep the original target — don't overwrite it
    /// with ourselves on the second of two overlapping writes).
    private func captureFocusTargetIfNeeded() {
        guard focusRestoreTarget == nil else { return }
        guard let app = frontmostApp() else { return }
        let pid = (app.value(forKey: "processIdentifier") as? Int32) ?? -1
        if pid == ProcessInfo.processInfo.processIdentifier { return }  // it's us
        focusRestoreTarget = app
    }

    /// Hand focus back to the app we stole it from, if any. Called when the
    /// last in-flight write settles (lock confirmed / reverted).
    private func restoreFocusTarget() {
        // Cancel the +0.2s re-grab — if this settle landed within 200ms of the
        // write request, that timer hasn't fired yet and would re-steal focus
        // right after we hand it back.
        pendingFocusReGrab?.cancel()
        pendingFocusReGrab = nil
        guard let app = focusRestoreTarget else { return }
        focusRestoreTarget = nil
        let sel = NSSelectorFromString("activateWithOptions:")
        guard app.responds(to: sel), let imp = app.method(for: sel) else { return }
        typealias Fn = @convention(c) (NSObject, Selector, UInt) -> Bool
        _ = unsafeBitCast(imp, to: Fn.self)(app, sel, 0)  // 0 = default options
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
        // Fallback (no key window — app wasn't active yet): front our content
        // window, but SKIP system NSPanels. macOS parks text-services panels
        // (Spelling & Grammar, Substitutions, Languages, dictation) in our
        // window list; order-fronting those surfaces them as stray popups —
        // the exact bug that returned when the old NSPanel-filtering
        // window-hider was removed. Our SwiftUI content window is a plain
        // NSWindow, so the class filter cleanly separates it from the panels.
        guard let windows = nsApp.value(forKey: "windows") as? [NSObject] else { return }
        let panelCls = NSClassFromString("NSPanel")
        for w in windows where w.responds(to: sel) {
            if let panelCls = panelCls, w.isKind(of: panelCls) { continue }
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

    /// Hide the close + miniaturize window buttons AND clear the matching
    /// styleMask bits. Hiding the buttons alone left two ways to still kill
    /// the appliance: Cmd-W / Cmd-M (the menu commands), and double-clicking
    /// the titlebar (which minimizes when the miniaturizable bit is set).
    /// Closing the window tears down the backing NSWindow (which Catalyst
    /// won't rebuild) and minimizing drops the app out of `.active` — both
    /// break HomeKit writes. Clearing the styleMask bits makes Cmd-W/Cmd-M
    /// no-ops at the AppKit level and stops the titlebar-double-click minimize
    /// (`buildMenu(with:)` strips the menu items too). The only way to stop
    /// the bridge is the in-panel Quit (or Cmd-Q). Zoom is left alone
    /// (harmless).
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
            clearWindowStyleMaskBits(w)
        }
    }

    /// Clear the `closable` (1<<1) and `miniaturizable` (1<<2) bits from an
    /// NSWindow's styleMask via the KVC bridge. With these cleared, Cmd-W and
    /// Cmd-M (and the titlebar double-click minimize) become no-ops even if
    /// the menu items somehow remain. `styleMask` is an NSUInteger property
    /// exposed to KVC, so read-modify-write through `value(forKey:)` /
    /// `setValue(_:forKey:)`.
    private func clearWindowStyleMaskBits(_ window: NSObject) {
        let closableBit: UInt = 1 << 1
        let miniaturizableBit: UInt = 1 << 2
        guard let current = (window.value(forKey: "styleMask") as? NSNumber)?.uintValue else { return }
        let cleared = current & ~(closableBit | miniaturizableBit)
        if cleared != current {
            window.setValue(NSNumber(value: cleared), forKey: "styleMask")
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
