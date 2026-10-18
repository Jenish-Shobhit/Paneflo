import AppKit
import PanefloCore

/// The menu bar icon and its menu (design spec §9). The icon can be hidden from Settings › General while Paneflo keeps
/// running; opening Paneflo again from Finder or Spotlight shows Settings, whose "Show menu bar icon" brings it back.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    var onOpen: ((DesktopMode) -> Void)?
    var onSettings: (() -> Void)?
    var onAbout: (() -> Void)?
    var onFinishSetup: (() -> Void)?
    /// Called with the new wanted state: true to resume shortcuts, false to pause them.
    var onToggleShortcuts: ((Bool) -> Void)?
    var onRefreshWindows: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onDeveloperFixtures: (() -> Void)?
    var onQuit: (() -> Void)?
    /// The icon was shown or hidden (Settings mirrors it in "Show menu bar icon").
    var onIconVisibilityChanged: ((Bool) -> Void)?

    var showsDeveloperFixtures = false
    /// Drives the header line, the icon state and Finish Setup….
    private(set) var status: PanefloStatus = .starting
    /// The user's saved shortcuts choice: Pause Shortcuts while on, Resume Shortcuts while off.
    private(set) var shortcutsWanted = true

    private let preferences: SetupPreferences
    private var statusItem: NSStatusItem?

    init(preferences: SetupPreferences) {
        self.preferences = preferences
        super.init()
    }

    var isIconVisible: Bool { !preferences.menuBarIconHidden }
    var iconState: MenuBarIcon.State { MenuBarIcon.state(for: status) }

    func update(status: PanefloStatus, shortcutsWanted: Bool) {
        self.shortcutsWanted = shortcutsWanted
        guard status != self.status else { return }
        self.status = status
        updateIcon()
    }

    /// Creates the status item (call once at launch). Own-window checks never call it.
    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = ""
        item.button?.imagePosition = .imageOnly
        item.menu = makeMenu()
        statusItem = item
        updateIcon()
        item.isVisible = isIconVisible
    }

    func setIconVisible(_ visible: Bool) {
        preferences.menuBarIconHidden = !visible
        statusItem?.isVisible = visible
        onIconVisibilityChanged?(visible)
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let state = iconState
        button.image = MenuBarIcon.image(state)
        button.toolTip = MenuBarIcon.toolTip(state)
        button.setAccessibilityLabel(MenuBarIcon.accessibilityLabel(state))
    }

    // MARK: Menu

    private enum Tag: Int { case header = 100, headerSeparator, finishSetup, finishSeparator, shortcuts, developer }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let header = NSMenuItem(title: status.title, action: nil, keyEquivalent: "")
        header.tag = Tag.header.rawValue
        header.isEnabled = false
        menu.addItem(header)
        let headerSeparator = NSMenuItem.separator()
        headerSeparator.tag = Tag.headerSeparator.rawValue
        menu.addItem(headerSeparator)
        let finish = item("Finish Setup…", "exclamationmark.triangle.fill", #selector(finishSetup), tag: Tag.finishSetup.rawValue)
        finish.image = symbol("exclamationmark.triangle.fill", color: .systemOrange)
        menu.addItem(finish)
        let finishSeparator = NSMenuItem.separator()
        finishSeparator.tag = Tag.finishSeparator.rawValue
        menu.addItem(finishSeparator)
        // Display-only key equivalents: the actions are global shortcuts, so choosing them here runs the same action.
        menu.addItem(item("Switch Windows…", "rectangle.stack", #selector(open(_:)), key: "\t", modifiers: .command,
                          tag: DesktopMode.switcher.rawValue))
        menu.addItem(item("Arrange Windows…", "rectangle.split.2x1", #selector(open(_:)), tag: DesktopMode.tiling.rawValue))
        menu.addItem(item("Overview", "square.grid.2x2", #selector(open(_:)), key: " ", modifiers: [.control, .option],
                          tag: DesktopMode.overview.rawValue))
        menu.addItem(.separator())
        menu.addItem(item("Pause Shortcuts", "pause.circle", #selector(toggleShortcuts), tag: Tag.shortcuts.rawValue))
        menu.addItem(item("Refresh Window List", "arrow.clockwise", #selector(refreshWindows)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", "gearshape", #selector(settings), key: ",", modifiers: .command))
        menu.addItem(item("Check for Updates…", "arrow.down.circle", #selector(checkForUpdates)))
        menu.addItem(item("About Paneflo", "info.circle", #selector(about)))
        menu.addItem(.separator())
        let developer = NSMenuItem(title: "Developer", action: nil, keyEquivalent: "")
        developer.tag = Tag.developer.rawValue
        developer.image = NSImage(systemSymbolName: "hammer", accessibilityDescription: nil)
        let developerMenu = NSMenu(title: "Developer")
        developerMenu.autoenablesItems = false
        developerMenu.addItem(item("Synthetic Developer Fixtures", "rectangle.dashed", #selector(fixtures)))
        developer.submenu = developerMenu
        menu.addItem(developer)
        menu.addItem(item("Quit Paneflo", nil, #selector(quit), key: "q", modifiers: .command))
        refresh(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh(menu) }

    private func refresh(_ menu: NSMenu) {
        if let header = menu.item(withTag: Tag.header.rawValue) {
            header.title = status.title
            header.attributedTitle = NSAttributedString(string: status.title, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
            header.image = MenuBarIcon.dot(dotColor)
            header.setAccessibilityLabel("Status: \(status.title)")
        }
        let setupNeeded = status == .setupNeeded
        menu.item(withTag: Tag.finishSetup.rawValue)?.isHidden = !setupNeeded
        menu.item(withTag: Tag.finishSeparator.rawValue)?.isHidden = !setupNeeded
        if let toggle = menu.item(withTag: Tag.shortcuts.rawValue) {
            toggle.title = shortcutsWanted ? "Pause Shortcuts" : "Resume Shortcuts"
            toggle.image = NSImage(systemSymbolName: shortcutsWanted ? "pause.circle" : "play.circle", accessibilityDescription: nil)
        }
        menu.item(withTag: Tag.developer.rawValue)?.isHidden = !showsDeveloperFixtures
    }

    private var dotColor: NSColor {
        switch status {
        case .ready: .systemGreen
        case .setupNeeded: .systemOrange
        case .starting, .paused: .systemGray
        }
    }

    private func item(_ title: String, _ symbolName: String?, _ action: Selector, key: String = "",
                      modifiers: NSEvent.ModifierFlags = [], tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self; item.tag = tag
        if let symbolName { item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) }
        return item
    }

    private func symbol(_ name: String, color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
    }

    @objc private func open(_ sender: NSMenuItem) { onOpen?(DesktopMode(rawValue: sender.tag) ?? .switcher) }
    @objc private func finishSetup() { onFinishSetup?() }
    @objc private func settings() { onSettings?() }
    @objc private func about() { onAbout?() }
    @objc private func toggleShortcuts() { onToggleShortcuts?(!shortcutsWanted) }
    @objc private func refreshWindows() { onRefreshWindows?() }
    @objc private func checkForUpdates() { onCheckForUpdates?() }
    @objc private func fixtures() { onDeveloperFixtures?() }
    @objc private func quit() { onQuit?() }

    #if PANEFLO_NATIVE_CHECK
    /// Visible titles of a freshly refreshed menu (the status header first).
    func nativeCheckMenuTitles() -> [String] {
        makeMenu().items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title)
    }
    /// Title, key equivalent and modifiers of each visible item.
    func nativeCheckMenuKeys() -> [String: (String, NSEvent.ModifierFlags)] {
        Dictionary(makeMenu().items.filter { !$0.isSeparatorItem && !$0.isHidden && !$0.keyEquivalent.isEmpty }
            .map { ($0.title, ($0.keyEquivalent, $0.keyEquivalentModifierMask)) }, uniquingKeysWith: { a, _ in a })
    }
    var nativeCheckDeveloperTitles: [String] {
        makeMenu().item(withTag: Tag.developer.rawValue)?.submenu?.items.map(\.title) ?? []
    }
    var nativeCheckItemsWithoutSymbol: [String] {
        makeMenu().items.filter { !$0.isSeparatorItem && $0.isEnabled && $0.image == nil && $0.title != "Quit Paneflo" }.map(\.title)
    }
    #endif
}
