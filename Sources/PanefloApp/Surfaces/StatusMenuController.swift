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
    /// Tile Front Window › a half or Fill: arranges the frontmost window (the ⌃⌥ shortcuts' action).
    var onTile: ((LayoutZone) -> Void)?
    /// Tile Front Window › Undo (⌃⌥Z).
    var onUndoTile: (() -> Void)?
    var onQuit: (() -> Void)?
    /// The icon was shown or hidden (Settings mirrors it in "Show menu bar icon").
    var onIconVisibilityChanged: ((Bool) -> Void)?
    /// Hide from Menu Bar was chosen; the app runs the confirmation (`hideStep`) and calls `hide(dontAskAgain:)`.
    var onHideRequested: (() -> Void)?
    /// A hidden icon came back on its own because something needs attention.
    var onRestoredForAttention: ((MenuBarIconPolicy.Attention) -> Void)?
    /// Setup needed, or shortcuts the user wants stopped by macOS: the icon must stay reachable.
    private(set) var attention = MenuBarIconPolicy.Attention.none

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

    var isIconVisible: Bool { preferences.menuBarIcon.isVisible }
    /// What Hide from Menu Bar does right now.
    var hideStep: MenuBarIconPolicy.HideStep { preferences.menuBarIcon.hideStep(attention: attention) }
    var iconState: MenuBarIcon.State { MenuBarIcon.state(for: status) }

    /// `shortcutsStopped`: macOS refused or kept disabling the event tap.
    func update(status: PanefloStatus, shortcutsWanted: Bool, shortcutsStopped: Bool = false) {
        self.shortcutsWanted = shortcutsWanted
        attention = MenuBarIconPolicy.attention(status: status, shortcutsWanted: shortcutsWanted, shortcutsStopped: shortcutsStopped)
        var policy = preferences.menuBarIcon
        if policy.attentionChanged(attention) {
            preferences.menuBarIcon = policy
            applyVisibility()
            onRestoredForAttention?(attention)
        }
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

    /// The Settings switch. Hiding goes through `hide(dontAskAgain:)` after the confirmation; this shows or, for
    /// own-window checks, hides without asking.
    func setIconVisible(_ visible: Bool) {
        var policy = preferences.menuBarIcon
        if visible { policy.show() } else { policy.hide(dontAskAgain: false) }
        preferences.menuBarIcon = policy
        applyVisibility()
    }

    /// Hides the icon after the user confirmed (or chose not to be asked again).
    func hide(dontAskAgain: Bool) {
        var policy = preferences.menuBarIcon
        policy.hide(dontAskAgain: dontAskAgain)
        preferences.menuBarIcon = policy
        applyVisibility()
    }

    /// Paneflo was opened again while running: a hidden icon comes back. Returns true when it did.
    func reopened() -> Bool {
        var policy = preferences.menuBarIcon
        guard policy.reopened() else { return false }
        preferences.menuBarIcon = policy
        applyVisibility()
        return true
    }

    private func applyVisibility() {
        statusItem?.isVisible = isIconVisible
        onIconVisibilityChanged?(isIconVisible)
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let state = iconState
        button.image = MenuBarIcon.image(state)
        button.toolTip = MenuBarIcon.toolTip(state)
        button.setAccessibilityLabel(MenuBarIcon.accessibilityLabel(state))
    }

    // MARK: Menu

    private enum Tag: Int { case header = 100, headerSeparator, finishSetup, finishSeparator, shortcuts, tile, hide }

    /// Tile Front Window's items: the chords the tiling keymap routes (`AppDelegate.shortcutConfiguration`), shown as
    /// display-only key equivalents that follow the keymap. Only arrangements that exist are listed.
    static let tileItems: [(title: String, symbol: String, action: TilingShortcutAction)] = [
        ("Left Half", "rectangle.lefthalf.filled", .leftHalf),
        ("Right Half", "rectangle.righthalf.filled", .rightHalf),
        ("Top Half", "rectangle.tophalf.filled", .topHalf),
        ("Bottom Half", "rectangle.bottomhalf.filled", .bottomHalf),
        ("Fill", "rectangle.fill", .maximize),
        ("Undo", "arrow.uturn.backward", .restore),
    ]

    /// The chords shown next to Tile Front Window's items. Changing it updates the open and the next menu.
    var tilingKeymap = TilingKeymap.defaults {
        didSet { if tilingKeymap != oldValue, let menu = statusItem?.menu { refresh(menu) } }
    }

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
        let tile = NSMenuItem(title: "Tile Front Window", action: nil, keyEquivalent: "")
        tile.tag = Tag.tile.rawValue
        tile.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
        let tileMenu = NSMenu(title: "Tile Front Window")
        tileMenu.autoenablesItems = false
        for (index, entry) in Self.tileItems.enumerated() {
            if entry.action.zone == nil { tileMenu.addItem(.separator()) }
            tileMenu.addItem(item(entry.title, entry.symbol, #selector(tileFront(_:)), tag: index))
        }
        tile.submenu = tileMenu
        menu.addItem(tile)
        menu.addItem(item("Overview", "square.grid.2x2", #selector(open(_:)), key: " ", modifiers: [.control, .option],
                          tag: DesktopMode.overview.rawValue))
        menu.addItem(.separator())
        menu.addItem(item("Pause Shortcuts", "pause.circle", #selector(toggleShortcuts), tag: Tag.shortcuts.rawValue))
        menu.addItem(item("Refresh Window List", "arrow.clockwise", #selector(refreshWindows)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", "gearshape", #selector(settings), key: ",", modifiers: .command))
        menu.addItem(item("Check for Updates…", "arrow.down.circle", #selector(checkForUpdates)))
        menu.addItem(item("About Paneflo", "info.circle", #selector(about)))
        menu.addItem(item("Hide from Menu Bar", "eye.slash", #selector(hideFromMenuBar), tag: Tag.hide.rawValue))
        menu.addItem(.separator())
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
        for tileItem in menu.item(withTag: Tag.tile.rawValue)?.submenu?.items ?? [] where !tileItem.isSeparatorItem {
            guard Self.tileItems.indices.contains(tileItem.tag) else { continue }
            let equivalent = tilingKeymap.chord(for: Self.tileItems[tileItem.tag].action).flatMap(ShortcutKeyNames.menuKeyEquivalent)
            tileItem.keyEquivalent = equivalent?.key ?? ""
            tileItem.keyEquivalentModifierMask = equivalent?.modifiers ?? []
        }
        let setupNeeded = status == .setupNeeded
        menu.item(withTag: Tag.finishSetup.rawValue)?.isHidden = !setupNeeded
        menu.item(withTag: Tag.finishSeparator.rawValue)?.isHidden = !setupNeeded
        // Never offered while the icon is what tells the user something needs attention.
        menu.item(withTag: Tag.hide.rawValue)?.isHidden = attention != .none
        if let toggle = menu.item(withTag: Tag.shortcuts.rawValue) {
            toggle.title = shortcutsWanted ? "Pause Shortcuts" : "Resume Shortcuts"
            toggle.image = NSImage(systemSymbolName: shortcutsWanted ? "pause.circle" : "play.circle", accessibilityDescription: nil)
        }
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
    @objc private func hideFromMenuBar() { onHideRequested?() }
    @objc private func tileFront(_ sender: NSMenuItem) {
        guard Self.tileItems.indices.contains(sender.tag) else { return }
        if let zone = Self.tileItems[sender.tag].action.zone { onTile?(zone) } else { onUndoTile?() }
    }
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
    /// Tile Front Window's items: title, key equivalent and modifiers (separators skipped).
    var nativeCheckTileItems: [(String, String, NSEvent.ModifierFlags)] {
        (makeMenu().item(withTag: Tag.tile.rawValue)?.submenu?.items ?? []).filter { !$0.isSeparatorItem }
            .map { ($0.title, $0.keyEquivalent, $0.keyEquivalentModifierMask) }
    }
    /// Chooses Hide from Menu Bar, as a click would.
    func nativeCheckChooseHide() { hideFromMenuBar() }
    /// Chooses one Tile Front Window item by title, as a click would.
    func nativeCheckChooseTileItem(_ title: String) {
        guard let item = makeMenu().item(withTag: Tag.tile.rawValue)?.submenu?.items.first(where: { $0.title == title }) else { return }
        tileFront(item)
    }
    var nativeCheckItemsWithoutSymbol: [String] {
        makeMenu().items.filter { !$0.isSeparatorItem && $0.isEnabled && $0.image == nil && $0.title != "Quit Paneflo" }.map(\.title)
    }
    #endif
}
