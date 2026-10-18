import AppKit
import PanefloCore

/// The menu-bar icon and its menu. The icon can be hidden ("Hide menu bar icon") while Paneflo keeps running; opening
/// Paneflo again from Finder, Spotlight or Launchpad shows Settings, whose "Show menu bar icon" brings it back.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    var onOpen: ((DesktopMode) -> Void)?
    var onSettings: (() -> Void)?
    var onFinishSetup: (() -> Void)?
    /// Called with the new wanted state: true to enable shortcuts, false to disable them.
    var onToggleShortcuts: ((Bool) -> Void)?
    var onRefreshWindows: (() -> Void)?
    var onDeveloperFixtures: (() -> Void)?
    var onQuit: (() -> Void)?
    /// The icon was shown or hidden (Settings mirrors it in "Show menu bar icon").
    var onIconVisibilityChanged: ((Bool) -> Void)?
    /// Adds "Check for Updates…" and its automatic toggle.
    var addUpdateItems: ((NSMenu) -> Void)?
    /// Asked before hiding the icon; replaceable in own-window checks.
    var confirmHide: @MainActor () -> Bool = { StatusMenuController.runHideConfirmation() }

    var showsDeveloperFixtures = false
    /// Something required is missing: the icon gets a warning badge and the menu offers "Finish setup…".
    var setupNeeded = false { didSet { if setupNeeded != oldValue { updateIcon() } } }
    var shortcutsActive = false

    private let preferences: SetupPreferences
    private var statusItem: NSStatusItem?

    init(preferences: SetupPreferences) {
        self.preferences = preferences
        super.init()
    }

    var isIconVisible: Bool { !preferences.menuBarIconHidden }

    /// Creates the status item (call once at launch). Own-window checks never call it.
    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = ""; item.button?.toolTip = "Paneflo"
        item.button?.setAccessibilityLabel("Paneflo menu")
        item.menu = makeMenu()
        statusItem = item
        updateIcon()
        item.isVisible = isIconVisible
    }

    /// "Hide menu bar icon": explains how to get it back, then hides it. Returns whether it was hidden.
    @discardableResult
    func requestHide() -> Bool {
        guard isIconVisible else { return true }
        guard confirmHide() else { onIconVisibilityChanged?(true); return false }
        setIconVisible(false)
        return true
    }

    func setIconVisible(_ visible: Bool) {
        preferences.menuBarIconHidden = !visible
        statusItem?.isVisible = visible
        onIconVisibilityChanged?(visible)
    }

    static func runHideConfirmation() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Hide the menu bar icon?"
        alert.informativeText = "Paneflo keeps running and ⌘Tab keeps working. To get the icon back, open Paneflo again from Finder, Spotlight or Launchpad: Settings opens, and “Show menu bar icon” brings it back."
        alert.addButton(withTitle: "Hide Icon")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Menu

    private enum Tag: Int { case finishSetup = 100, shortcuts, fixtures }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        for (index, title) in ["Switch windows", "Arrange windows", "Organized overview"].enumerated() {
            menu.addItem(item(title, #selector(open(_:)), tag: index))
        }
        menu.addItem(.separator())
        let finish = item("Finish setup…", #selector(finishSetup), tag: Tag.finishSetup.rawValue)
        finish.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Setup needed")
        menu.addItem(finish)
        menu.addItem(item("Settings…", #selector(settings), key: ","))
        addUpdateItems?(menu)
        menu.addItem(.separator())
        menu.addItem(item("Disable shortcuts", #selector(toggleShortcuts), tag: Tag.shortcuts.rawValue))
        menu.addItem(item("Refresh windows", #selector(refreshWindows)))
        menu.addItem(item("Synthetic developer fixtures", #selector(fixtures), tag: Tag.fixtures.rawValue))
        menu.addItem(.separator())
        menu.addItem(item("Hide menu bar icon", #selector(hideIcon)))
        menu.addItem(item("Quit Paneflo", #selector(quit), key: "q"))
        refresh(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh(menu) }

    private func refresh(_ menu: NSMenu) {
        menu.item(withTag: Tag.finishSetup.rawValue)?.isHidden = !setupNeeded
        menu.item(withTag: Tag.shortcuts.rawValue)?.title = shortcutsActive ? "Disable shortcuts" : "Enable shortcuts"
        menu.item(withTag: Tag.fixtures.rawValue)?.isHidden = !showsDeveloperFixtures
    }

    private func item(_ title: String, _ action: Selector, key: String = "", tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; item.tag = tag
        return item
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let base = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Paneflo")
        button.image = setupNeeded ? base.map(Self.badged) : base
        button.toolTip = setupNeeded ? "Paneflo: finish setup" : "Paneflo"
    }

    /// The template symbol in the menu-bar text color with a small orange dot at its top right.
    private static func badged(_ base: NSImage) -> NSImage {
        let size = NSSize(width: base.size.width + 3, height: max(base.size.height, 16))
        let image = NSImage(size: size, flipped: false) { rect in
            let symbolRect = NSRect(x: 0, y: (rect.height - base.size.height) / 2, width: base.size.width, height: base.size.height)
            let tinted = NSImage(size: base.size, flipped: false) { inner in
                base.draw(in: inner)
                NSColor.labelColor.set()
                inner.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: symbolRect)
            let dot = NSRect(x: rect.width - 7, y: rect.height - 7, width: 7, height: 7)
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Paneflo, setup needed"
        return image
    }

    @objc private func open(_ sender: NSMenuItem) { onOpen?(DesktopMode(rawValue: sender.tag) ?? .switcher) }
    @objc private func finishSetup() { onFinishSetup?() }
    @objc private func settings() { onSettings?() }
    @objc private func toggleShortcuts() { onToggleShortcuts?(!shortcutsActive) }
    @objc private func refreshWindows() { onRefreshWindows?() }
    @objc private func fixtures() { onDeveloperFixtures?() }
    @objc private func hideIcon() { requestHide() }
    @objc private func quit() { onQuit?() }

    #if PANEFLO_NATIVE_CHECK
    /// Visible titles of a freshly refreshed menu.
    func nativeCheckMenuTitles() -> [String] {
        let menu = makeMenu()
        return menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title)
    }
    #endif
}
