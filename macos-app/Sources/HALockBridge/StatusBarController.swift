import Foundation
import ObjectiveC.runtime
import UIKit

/// Adds an NSStatusBar item to the macOS menu bar with three actions:
///   1. Stats & Debug — opens the main status window with a debug view
///   2. Reset Pairing… — wipes all paired clients (with confirmation)
///   3. Quit
///
/// Catalyst doesn't expose AppKit directly, so this entire file is built on
/// the same Objective-C runtime bridging pattern used in AppDelegate for
/// activation policy and window centering. Same trade-off: more code, but
/// no additional targets or bundle plumbing.
///
/// Action selectors are @objc methods on this NSObject subclass so menu items
/// can invoke them via the standard target/action mechanism.
final class StatusBarController: NSObject {

    var onShowDebug: (() -> Void)?
    var onResetRequested: (() -> Void)?
    var onToggleLoginItem: (() -> Void)?
    var onQuit: (() -> Void)?

    /// AppDelegate sets this before each `install()`/`reinstall()` so the
    /// menu's "Start at Login" item renders the correct checkmark. Treated
    /// as a hint, not authority — the underlying source of truth is
    /// `LoginItemManager.isEnabled`, queried by AppDelegate.
    var loginItemEnabled: Bool = false
    var loginItemAvailable: Bool = true

    private var statusItem: NSObject?
    /// The loaded template NSImage, strongly retained across reinstalls.
    /// Without this, every reinstall() re-reads `status-bar.png` from the
    /// bundle — and when that disk load transiently fails, the install()
    /// fallback paints a color "🔒" emoji as the button title, which sticks
    /// until the next successful reinstall. Caching the image makes the
    /// fallback path unreachable in normal operation.
    private var cachedImage: NSObject?

    func install() {
        guard let statusBarClass = NSClassFromString("NSStatusBar") else { return }
        let systemSel = NSSelectorFromString("systemStatusBar")
        guard let nsStatusBar = (statusBarClass as AnyObject)
            .perform(systemSel)?
            .takeUnretainedValue() as? NSObject else { return }

        // -[NSStatusBar statusItemWithLength:] takes a CGFloat. We pass
        // NSSquareStatusItemLength (-2) so the icon area matches the bar height.
        let createSel = NSSelectorFromString("statusItemWithLength:")
        guard nsStatusBar.responds(to: createSel),
              let imp = nsStatusBar.method(for: createSel) else { return }
        typealias CreateFn = @convention(c) (NSObject, Selector, CGFloat) -> AnyObject?
        let squareLength: CGFloat = -2
        guard let item = unsafeBitCast(imp, to: CreateFn.self)(nsStatusBar, createSel, squareLength) as? NSObject else { return }
        statusItem = item

        // Set the button image (template PNG, OS auto-tints for light/dark).
        // Load from the bundle once, then reuse the cached NSImage on every
        // reinstall — never re-read the file. The "🔒" emoji fallback should
        // only fire if the bundle resource is missing entirely (e.g. a
        // genuinely broken build), not for transient lookup failures.
        if let button = item.value(forKey: "button") as? NSObject {
            if cachedImage == nil {
                cachedImage = loadTemplateImage(named: "status-bar")
            }
            if let image = cachedImage {
                button.setValue(image, forKey: "image")
            } else {
                button.setValue("🔒", forKey: "title")
            }
        }

        item.setValue(buildMenu(), forKey: "menu")
    }

    /// Remove the status item from the system status bar. The owning
    /// AppDelegate calls this immediately before re-`install()`-ing when
    /// the activation policy changes, because NSStatusBar caches the
    /// drop-down menu anchor at the moment of install — without a fresh
    /// install, subsequent clicks would drop the menu at the item's
    /// pre-policy-change position.
    func uninstall() {
        guard let item = statusItem else { return }
        guard let statusBarClass = NSClassFromString("NSStatusBar") else { return }
        let systemSel = NSSelectorFromString("systemStatusBar")
        guard let nsStatusBar = (statusBarClass as AnyObject)
            .perform(systemSel)?
            .takeUnretainedValue() as? NSObject else { return }
        let removeSel = NSSelectorFromString("removeStatusItem:")
        if nsStatusBar.responds(to: removeSel) {
            _ = nsStatusBar.perform(removeSel, with: item)
        }
        statusItem = nil
    }

    func reinstall() {
        uninstall()
        install()
    }

    // MARK: - Image loading

    private func loadTemplateImage(named name: String) -> NSObject? {
        guard let path = Bundle.main.path(forResource: name, ofType: "png") else { return nil }
        guard let imageClass = NSClassFromString("NSImage") else { return nil }
        let allocSel = NSSelectorFromString("alloc")
        guard let alloc = (imageClass as AnyObject).perform(allocSel)?.takeUnretainedValue() as? NSObject else { return nil }
        let initSel = NSSelectorFromString("initWithContentsOfFile:")
        guard let initImp = alloc.method(for: initSel) else { return nil }
        typealias InitFn = @convention(c) (NSObject, Selector, NSString) -> NSObject
        let image = unsafeBitCast(initImp, to: InitFn.self)(alloc, initSel, path as NSString)
        image.setValue(true, forKey: "template")
        return image
    }

    // MARK: - Menu construction

    private func buildMenu() -> NSObject? {
        guard let menuClass = NSClassFromString("NSMenu") else { return nil }
        let allocSel = NSSelectorFromString("alloc")
        let initSel = NSSelectorFromString("init")
        guard let menuAlloc = (menuClass as AnyObject).perform(allocSel)?.takeUnretainedValue() as? NSObject else { return nil }
        guard let menu = menuAlloc.perform(initSel)?.takeUnretainedValue() as? NSObject else { return nil }

        addItem(to: menu, title: "Stats & Debug", action: #selector(statusBarShowDebug))
        addItem(to: menu, title: "Reset Pairing…", action: #selector(statusBarResetRequested))
        addSeparator(to: menu)
        // "Start at Login" — toggleable, checkmark reflects current state.
        // Disabled when the app is running from a non-/Applications path
        // (e.g. Xcode build folder); SMAppService refuses to register from
        // there, so offering a toggle would be misleading.
        addItem(
            to: menu,
            title: "Start at Login",
            action: #selector(statusBarToggleLoginItem),
            state: loginItemEnabled,
            enabled: loginItemAvailable
        )
        addSeparator(to: menu)
        addItem(to: menu, title: "Quit HA-LockBridge", action: #selector(statusBarQuit))
        return menu
    }

    private func addItem(to menu: NSObject, title: String, action: Selector, state: Bool = false, enabled: Bool = true) {
        guard let itemClass = NSClassFromString("NSMenuItem") else { return }
        let allocSel = NSSelectorFromString("alloc")
        guard let alloc = (itemClass as AnyObject).perform(allocSel)?.takeUnretainedValue() as? NSObject else { return }
        let initSel = NSSelectorFromString("initWithTitle:action:keyEquivalent:")
        guard let initImp = alloc.method(for: initSel) else { return }
        typealias InitFn = @convention(c) (NSObject, Selector, NSString, Selector, NSString) -> NSObject
        let item = unsafeBitCast(initImp, to: InitFn.self)(alloc, initSel, title as NSString, action, "" as NSString)
        item.setValue(self, forKey: "target")
        // NSControlStateValueOn = 1, NSControlStateValueOff = 0
        item.setValue(state ? 1 : 0, forKey: "state")
        item.setValue(enabled, forKey: "enabled")
        _ = menu.perform(NSSelectorFromString("addItem:"), with: item)
    }

    private func addSeparator(to menu: NSObject) {
        guard let itemClass = NSClassFromString("NSMenuItem") else { return }
        let sepSel = NSSelectorFromString("separatorItem")
        guard let sepImp = (itemClass as AnyObject).method(for: sepSel) else { return }
        typealias SepFn = @convention(c) (AnyClass, Selector) -> NSObject
        let separator = unsafeBitCast(sepImp, to: SepFn.self)(itemClass, sepSel)
        _ = menu.perform(NSSelectorFromString("addItem:"), with: separator)
    }

    // MARK: - @objc handlers (invoked by NSMenuItem target/action)

    @objc func statusBarShowDebug() {
        onShowDebug?()
    }

    @objc func statusBarResetRequested() {
        onResetRequested?()
    }

    @objc func statusBarToggleLoginItem() {
        onToggleLoginItem?()
    }

    @objc func statusBarQuit() {
        onQuit?()
    }
}
