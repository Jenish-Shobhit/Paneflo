import AppKit
import PanefloCore

@MainActor
enum DesktopMode: Int { case switcher, tiling, overview }

/// A borderless, non-activating key panel. Escape is taken here only when the panel is key
/// and no input method is composing; the event tap owns Escape whenever a surface is visible.
@MainActor
final class SurfacePanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onEscape: (() -> Void)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, isKeyWindow,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           (firstResponder as? NSTextView)?.hasMarkedText() != true {
            if !event.isARepeat { onEscape?() }
            return
        }
        super.sendEvent(event)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let chord = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if chord == .command || chord == [.command, .option], (123...126).contains(event.keyCode), onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// A flipped container for frame-based chrome layout (no Auto Layout pass on present).
@MainActor
final class SurfaceContentView: NSView {
    override var isFlipped: Bool { true }
    /// Clicks that reach the container itself (empty backdrop, not a card or control).
    var onBackgroundClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if let onBackgroundClick { onBackgroundClick() } else { super.mouseDown(with: event) }
    }
}

/// What a surface needs from the coordinator: the registry, shared icon cache and the
/// cross-surface actions (dismiss, focus, tile) whose state outlives one presentation.
@MainActor
protocol SurfaceHost: AnyObject {
    var service: WindowService { get }
    func icon(for record: WindowRecord) -> NSImage?
    /// A cached icon for an app that may have no window right now (kept Overview slots); never launches a lookup that
    /// blocks.
    func icon(forApp appIdentifier: String) -> NSImage?
    /// A display name for an app identifier (kept Overview slots).
    func appName(forApp appIdentifier: String) -> String?
    func surfaceKeyboardChanged(_ surface: SurfacePanelController)
    func surfaceSelectionChanged(_ surface: SurfacePanelController)
    func surfaceDismiss(_ surface: SurfacePanelController)
    func surfaceActivate(_ id: WindowIdentity)
    func surfaceTile(_ zone: LayoutZone)
    func surfaceUndo()
    /// Loop mode for a new switcher session (`.hidden` without a Desktop entry).
    var desktopLoopMode: DesktopLoopMode { get }
    /// Whether the Overview shows its Desktop home tile.
    var showsDesktopHomeTile: Bool { get }
    var desktopIsCurrent: Bool { get }
    /// The Desktop entry was chosen.
    func surfaceActivateDesktop()
    /// Puts the current wallpaper on a visible surface's Desktop card (cached image at once, refresh later).
    func surfaceShowWallpaper(_ card: CardView, on surface: SurfacePanelController)
    /// The tile partner of a window, from the prepared pair registry; nil when unpaired.
    func pairPartner(of id: WindowIdentity) -> WindowIdentity?
    /// Tile pairs to keep side by side in a new switcher session (empty when the setting is off).
    var sessionPairs: [TilePairMembers] { get }
    var preferences: SurfacePreferences { get }
    /// Open `id` together with its tile partner.
    func surfaceOpenPair(_ id: WindowIdentity)
    /// Open `id` without its tile partner.
    func surfaceOpenAlone(_ id: WindowIdentity)
    /// Dissolve the tile pair containing `id`.
    func surfaceUngroup(_ id: WindowIdentity)
}

/// Shared panel, keyboard handling, selection and preview plumbing for one pre-created panel.
/// Subclasses own their backdrop, chrome layout, content model, sizing and navigation rules.
@MainActor
class SurfacePanelController: NSObject, NSSearchFieldDelegate, NSWindowDelegate {
    weak var host: SurfaceHost?
    let panel: SurfacePanel
    let search = NSSearchField()
    let scroll = NSScrollView()
    private(set) var grid: CardGrid!
    let failureFeedback = NSTextField(wrappingLabelWithString: "")
    /// Hosts the chrome in flipped, frame-based layout.
    let content = SurfaceContentView()
    /// The selected window or the Desktop entry.
    private(set) var selectedTarget: SwitchTarget?
    /// The selected window; nil while nothing or the Desktop entry is selected.
    var selectedID: WindowIdentity? { selectedTarget?.windowID }
    /// Window → card for the cards on display, refreshed after every grid diff.
    private(set) var cardsByWindow: [WindowIdentity: CardView] = [:]
    /// The Desktop entry's card while one is displayed.
    private(set) var desktopCard: CardView?
    /// The screen the panel was last placed on (the pointer's screen at presentation).
    private(set) var placedScreen: NSScreen?
    private(set) var layoutFeedback: [WindowIdentity: String] = [:]
    /// Cards whose previews the engine should keep current; rebuilt after a diff, scroll or search.
    private var previewCandidates: [PreviewCard]?
    private var previewRows: ClosedRange<Int>?
    private var viewportObserver: NSObjectProtocol?
    private var prewarming = false
    private var prewarmToken = 0
    /// The card currently drawn with the dashed partner ring.
    private weak var partnerCard: CardView?
    /// Snap assist: the half the selected window would take next, shown as a faint glyph on the selected card.
    private(set) var snapZone: LayoutZone?
    private var snapAnchor: WindowIdentity?
    private weak var ghostCard: CardView?

    /// On screen for the user. A pre-warm pass (alpha 0, ignoring the mouse) does not count.
    var isShown: Bool { panel.isVisible && !prewarming }
    var keyboardOwned: Bool { isShown && panel.isKeyWindow }
    var composing: Bool { keyboardOwned && (panel.firstResponder as? NSTextView)?.hasMarkedText() == true }
    var showsPreviews: Bool { true }
    var service: WindowService? { host?.service }

    init(contentSize: NSSize) {
        panel = SurfacePanel(contentRect: NSRect(origin: .zero, size: contentSize),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        grid = CardGrid { [weak self] in self?.makeCard() ?? CardView(frame: .zero) }
        configurePanel()
    }

    isolated deinit {
        if let viewportObserver { NotificationCenter.default.removeObserver(viewportObserver) }
    }

    private func configurePanel() {
        panel.title = "Paneflo"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Appear, select and dismiss are instant: no window animation.
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = .floating
        panel.delegate = self
        panel.onEscape = { [weak self] in
            guard let self else { return }
            RuntimeDiagnostics.mark("desktop escape source=window queryPresent=\(!self.search.stringValue.isEmpty)")
            self.host?.surfaceDismiss(self)
        }
        panel.onKey = { [weak self] in self?.handleKey($0) ?? false }
        search.focusRingType = .none
        search.placeholderString = "Search windows"
        search.delegate = self
        search.setAccessibilityLabel("Search windows")
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.documentView = grid
        scroll.contentView.postsBoundsChangedNotifications = true
        viewportObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewportScrolled() }
        }
        failureFeedback.font = PanefloStyle.Font.failure
        failureFeedback.textColor = .secondaryLabelColor
        failureFeedback.alignment = .center
        failureFeedback.isHidden = true
        for view in [search, scroll, failureFeedback] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            content.addSubview(view)
        }
        content.translatesAutoresizingMaskIntoConstraints = true
        panel.contentView = makeBackdrop(content: content)
    }

    // MARK: Subclass hooks

    /// The panel's root view wrapping `content` (glass shelf, full-screen material...).
    func makeBackdrop(content: NSView) -> NSView {
        let root = NSVisualEffectView()
        root.material = .hudWindow; root.blendingMode = .behindWindow; root.state = .active
        content.frame = root.bounds
        content.autoresizingMask = [.width, .height]
        root.addSubview(content)
        return root
    }
    /// Places the chrome views in `content` for a content size. Called only when the panel is resized or its chrome
    /// set changes, never on selection.
    func layoutChrome() {}

    func makeCard() -> CardView {
        let card = CardView(frame: .zero)
        card.target = self; card.action = #selector(cardClicked(_:))
        card.onDoubleClick = { [weak self] id in self?.cardDoubleClicked(id) }
        return card
    }
    /// Window identities that can be selected under the current search.
    func eligibleSelectionIDs() -> [WindowIdentity] { [] }
    func isEligible(_ id: WindowIdentity) -> Bool { eligibleSelectionIDs().contains(id) }
    /// The Desktop entry is displayed and matches the current search.
    var isDesktopEligible: Bool { false }
    func isEligible(_ target: SwitchTarget) -> Bool {
        switch target {
        case .window(let id): isEligible(id)
        case .desktop: isDesktopEligible
        }
    }
    func navigate(_ direction: CycleDirection) {}
    func navigateRows(_ delta: Int) {}
    func searchChanged() {}
    func cardSelected(_ card: CardView) {}
    func failureFeedbackChanged() {}
    /// The selected card changed (any cause). Subclasses update one-line chrome such as the switcher's title line.
    func selectionDidChange() {}
    /// Plain ←/→ in the search field move the selection (only when the query is empty).
    var linearArrowsLeaveSearch: Bool { false }
    func activateSelected() {
        guard let target = selectedTarget, isEligible(target) else { return }
        activate(target)
    }

    /// Option-Return (and "Open Alone"): the selected window without its tile partner. The Desktop entry just opens.
    func activateSelectedAlone() {
        guard let target = selectedTarget, isEligible(target) else { return }
        guard case .window(let id) = target else { activate(target); return }
        host?.surfaceOpenAlone(id)
    }

    func activate(_ target: SwitchTarget) {
        switch target {
        case .window(let id): host?.surfaceActivate(id)
        case .desktop: host?.surfaceActivateDesktop()
        }
    }

    /// Display configuration changed. Re-fits a visible panel to `screen`; prepares a hidden one for it.
    func screenParametersChanged(to screen: NSScreen) {}

    // MARK: Presentation

    /// Clears per-presentation decoration before a new presentation.
    func beginPresentation() {
        cancelPrewarm()
        layoutFeedback.removeAll()
        snapZone = nil; snapAnchor = nil; ghostCard = nil
        if !failureFeedback.isHidden { failureFeedback.isHidden = true; failureFeedbackChanged() }
    }

    func orderFront(searchFocused: Bool) {
        cancelPrewarm()
        panel.makeKeyAndOrderFront(nil)
        if searchFocused { panel.makeFirstResponder(search) }
        else if panel.firstResponder is NSText || panel.firstResponder === search { panel.makeFirstResponder(nil) }
    }

    /// Shows the panel above other windows without taking key focus from the frontmost app.
    func orderFrontWithoutKey() {
        cancelPrewarm()
        if panel.firstResponder is NSText || panel.firstResponder === search { panel.makeFirstResponder(nil) }
        panel.orderFrontRegardless()
    }

    /// Orders the panel out and drops window content. Card views stay for reuse.
    func hide() {
        cancelPrewarm()
        panel.orderOut(nil)
        PanefloStyle.withoutAnimation { for card in grid.cards { card.releasePayload() } }
        partnerCard = nil
        grid.highlightPair(containing: nil)
        layoutFeedback.removeAll()
        snapZone = nil; snapAnchor = nil; ghostCard = nil
        previewCandidates = nil; previewRows = nil
    }

    /// Pays the first-display cost (window backing, materials, field editor, every card layer type)
    /// off the input path: alpha 0, mouse-transparent, never key, ordered out after one commit.
    func prewarm() {
        panel.contentView?.layoutSubtreeIfNeeded()
        _ = panel.fieldEditor(true, for: search)
        guard !panel.isVisible else { return }
        prewarming = true
        prewarmToken &+= 1
        let token = prewarmToken
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.prewarming, self.prewarmToken == token else { return }
            self.panel.orderOut(nil)
            self.cancelPrewarm()
        }
    }

    private func cancelPrewarm() {
        guard prewarming else { return }
        prewarming = false
        prewarmToken &+= 1
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
    }

    // MARK: Selection and content

    /// Records the grid's cards for window lookups after a diff. `desktopIndex` is the Desktop entry's position.
    func indexCards(_ ids: [WindowIdentity?], desktopIndex: Int? = nil) {
        var map: [WindowIdentity: CardView] = [:]
        map.reserveCapacity(ids.count)
        for (id, card) in zip(ids, grid.cards) { if let id { map[id] = card } }
        cardsByWindow = map
        desktopCard = desktopIndex.flatMap { grid.cards.indices.contains($0) ? grid.cards[$0] : nil }
        previewCandidates = nil
    }

    func card(for target: SwitchTarget) -> CardView? {
        switch target {
        case .window(let id): cardsByWindow[id]
        case .desktop: desktopCard
        }
    }

    /// Moves the selection: only the previous and new cards (and their tile partners) change, as layer properties.
    func select(_ id: WindowIdentity?, notify: Bool = true) { select(target: id.map(SwitchTarget.window), notify: notify) }

    func select(target: SwitchTarget?, notify: Bool = true) {
        let previous = selectedTarget
        selectedTarget = target
        // Preview content follows engine updates; the outgoing card keeps its last frame.
        if let previous, previous != target, let card = card(for: previous) { card.selected = false }
        let card = target.flatMap { card(for: $0) }
        if let card {
            card.selected = true
            if isShown { revealCard(card) }
        }
        updatePartnerHighlight(for: target)
        updateSnapGhost()
        selectionDidChange()
        if notify { host?.surfaceSelectionChanged(self) }
    }

    /// The selection's tile partner gets the dashed ring and the pair's background washes. At most two cards change.
    private func updatePartnerHighlight(for target: SwitchTarget?) {
        let partner = target?.windowID.flatMap { host?.pairPartner(of: $0) }.flatMap { cardsByWindow[$0] }
        if partnerCard !== partner {
            partnerCard?.isPartnerHighlighted = false
            partner?.isPartnerHighlighted = true
            partnerCard = partner
        }
        grid.highlightPair(containing: partner != nil ? target.flatMap { card(for: $0) }?.tag : nil)
    }

    /// Snap assist is waiting for the other half (`zone`) after `anchor` was tiled; nil ends it.
    func setSnapAssist(zone: LayoutZone?, anchor: WindowIdentity?) {
        guard zone != snapZone || anchor != snapAnchor else { return }
        snapZone = zone
        snapAnchor = anchor
        updateSnapGhost()
    }

    private func updateSnapGhost() {
        let next: CardView? = snapZone == nil ? nil : selectedID.flatMap { $0 == snapAnchor ? nil : cardsByWindow[$0] }
        if ghostCard !== next { ghostCard?.snapGhost = nil; ghostCard = next }
        next?.snapGhost = snapZone
    }

    /// Sets the selection without touching cards (used before a diff that configures them).
    func setSelectedID(_ id: WindowIdentity?) { selectedTarget = id.map(SwitchTarget.window) }
    func setSelectedTarget(_ target: SwitchTarget?) { selectedTarget = target }

    /// Configures a grid card as the Desktop entry. Its wallpaper is applied by `showDesktopWallpaper` once shown.
    func configureDesktopCard(_ card: CardView, matches: Bool = true) {
        card.record = nil
        card.vacancy = nil
        card.isDesktopEntry = true
        card.desktopIsCurrent = host?.desktopIsCurrent ?? false
        card.icon = nil
        card.isPinned = false
        card.dragEnabled = false
        card.layoutBadge = nil
        card.pairRole = .none
        card.pairPartnerName = nil
        card.selected = selectedTarget == .desktop
        card.matches = matches
        card.setEnabledIfChanged(matches)
    }

    /// Visible surfaces only: hidden cards hold no pixels, wallpaper included.
    func showDesktopWallpaper() {
        guard isShown, let desktopCard else { return }
        host?.surfaceShowWallpaper(desktopCard, on: self)
    }

    /// The Desktop state changed (shown, restored, setting toggled) while this surface may be visible.
    func desktopStateChanged() {
        desktopCard?.desktopIsCurrent = host?.desktopIsCurrent ?? false
    }

    func revealCard(_ card: CardView) {
        let visible = scroll.contentView.documentVisibleRect
        guard visible.height > 0, !visible.contains(card.frame) else { return }
        _ = card.scrollToVisible(card.bounds.insetBy(dx: -8, dy: -8))
    }

    func setLayoutBadge(_ text: String?, for id: WindowIdentity) {
        layoutFeedback[id] = text
        cardsByWindow[id]?.layoutBadge = text
    }

    func showFailure(_ text: String) {
        failureFeedback.stringValue = text
        if failureFeedback.isHidden { failureFeedback.isHidden = false; failureFeedbackChanged() }
    }

    func invalidatePreviewCandidates() { previewCandidates = nil }

    /// Matching window cards in the scroll viewport plus half a row of margin, selection included.
    /// Built from the prepared registry only (no AX or capture call); cached until the cards,
    /// search or viewport change.
    func previewCards() -> [PreviewCard] {
        if let previewCandidates { return previewCandidates }
        let viewport = scroll.contentView.documentVisibleRect
            .insetBy(dx: 0, dy: -grid.cardHeight / 2)
        previewRows = visibleRows()
        let cards = grid.cards.compactMap { card -> PreviewCard? in
            guard card.matches, let record = card.record, card.frame.intersects(viewport) else { return nil }
            return PreviewCard(id: record.id, windowNumber: service?.captureWindowNumber(for: record.id),
                               isMinimized: record.isMinimized)
        }
        previewCandidates = cards
        return cards
    }

    /// The card preview well in backing pixels (all cards in a grid share one size).
    var previewPixelSize: CGSize? {
        guard let card = grid.cards.first(where: { !$0.isDesktopEntry }) ?? grid.cards.first else { return nil }
        let area = card.previewRect.size
        guard area.width >= 1, area.height >= 1 else { return nil }
        let scale = panel.backingScaleFactor
        return CGSize(width: (area.width * scale).rounded(), height: (area.height * scale).rounded())
    }

    /// Grid rows touched by the viewport plus margin; scrolling within a row changes nothing.
    private func visibleRows() -> ClosedRange<Int>? {
        let viewport = scroll.contentView.documentVisibleRect
        let pitch = grid.rowPitch
        guard pitch > 0, grid.rows > 0 else { return nil }
        let margin = grid.cardHeight / 2
        let first = max(0, Int(((viewport.minY - margin) / pitch).rounded(.down)))
        let last = min(grid.rows - 1, Int(((viewport.maxY + margin) / pitch).rounded(.down)))
        return first <= last ? first...last : nil
    }

    private func viewportScrolled() {
        guard visibleRows() != previewRows || previewCandidates == nil else { return }
        previewCandidates = nil
        if isShown { host?.surfaceSelectionChanged(self) }
    }

    // MARK: Input

    @objc private func cardClicked(_ card: CardView) { cardSelected(card) }
    private func cardDoubleClicked(_ target: SwitchTarget) { select(target: target, notify: false); activateSelected() }

    func controlTextDidChange(_ notification: Notification) {
        host?.surfaceKeyboardChanged(self)
        searchChanged()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch NSStringFromSelector(selector) {
        case "moveLeft:" where linearArrowsLeaveSearch && search.stringValue.isEmpty && !textView.hasMarkedText():
            navigate(.backward); return true
        case "moveRight:" where linearArrowsLeaveSearch && search.stringValue.isEmpty && !textView.hasMarkedText():
            navigate(.forward); return true
        case "moveUp:": navigateRows(-1); return true
        case "moveDown:": navigateRows(1); return true
        case "insertNewline:": activateSelected(); return true
        // Option-Return in the search field.
        case "insertNewlineIgnoringFieldEditor:" where !textView.hasMarkedText(): activateSelectedAlone(); return true
        case "cancelOperation:" where textView.hasMarkedText(): return false
        case "cancelOperation:": host?.surfaceDismiss(self); return true
        default: return false
        }
    }

    func windowDidBecomeKey(_ notification: Notification) { host?.surfaceKeyboardChanged(self) }
    func windowDidResignKey(_ notification: Notification) { host?.surfaceKeyboardChanged(self) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { host?.surfaceDismiss(self); return false }

    private func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { host?.surfaceDismiss(self); return true }
        let commandModifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if (123...126).contains(event.keyCode) {
            // Every surface: Command–arrows select (like plain arrows); Command–Option–arrows arrange.
            if commandModifiers == [.command, .option] {
                if event.isARepeat { return true }
                switch event.keyCode {
                case 123: host?.surfaceTile(.leftHalf)
                case 124: host?.surfaceTile(.rightHalf)
                case 126: host?.surfaceTile(.maximize)
                default: host?.surfaceUndo()
                }
                return true
            }
            if commandModifiers == .command {
                switch event.keyCode {
                case 123: navigate(.backward)
                case 124: navigate(.forward)
                case 126: navigateRows(-1)
                default: navigateRows(1)
                }
                return true
            }
        }
        if commandModifiers == .option, event.keyCode == 36 || event.keyCode == 76 {
            if !event.isARepeat { activateSelectedAlone() }
            return true
        }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 123: navigate(.backward); return true
        case 124: navigate(.forward); return true
        case 126: navigateRows(-1); return true
        case 125: navigateRows(1); return true
        case 48: navigate(event.modifierFlags.contains(.shift) ? .backward : .forward); return true
        case 36, 76: activateSelected(); return true
        default: return false
        }
    }

    // MARK: Tile pairs

    /// Updates every displayed window card's partner name and pair role, and the grid's pair backgrounds. Runs when
    /// cards or pairs change (presentation, registry change, pairing), never on a selection step.
    func refreshPairs() {
        var starts = Set<Int>()
        let names = Dictionary(grid.cards.compactMap { $0.record.map { ($0.id, $0.appName) } }, uniquingKeysWith: { first, _ in first })
        for (id, card) in cardsByWindow {
            guard let partner = host?.pairPartner(of: id) else {
                card.pairPartnerName = nil; card.pairRole = .none
                continue
            }
            card.pairPartnerName = names[partner] ?? service?.snapshot.records.first { $0.id == partner }?.appName
            let partnerCard = cardsByWindow[partner]
            if let partnerCard, partnerCard.tag == card.tag + 1, grid.row(of: card.tag) == grid.row(of: partnerCard.tag) {
                card.pairRole = .leading
                starts.insert(card.tag)
            } else if let partnerCard, partnerCard.tag == card.tag - 1, grid.row(of: card.tag) == grid.row(of: partnerCard.tag) {
                card.pairRole = .trailing
            } else {
                card.pairRole = .detached
            }
        }
        grid.pairStarts = starts
        updatePartnerHighlight(for: selectedTarget)
    }

    /// Appends "Open Pair", "Open Alone" and "Unpair" to a card's context menu when its window has a tile partner.
    func appendPairItems(to menu: NSMenu, for id: WindowIdentity) {
        guard host?.pairPartner(of: id) != nil else { return }
        menu.addItem(.separator())
        for (title, symbol, action) in [("Open Pair", "rectangle.split.2x1", #selector(openPairFromMenu(_:))),
                                        ("Open Alone", "macwindow", #selector(openAloneFromMenu(_:))),
                                        ("Unpair", "link.badge.plus", #selector(ungroupFromMenu(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.target = self; item.representedObject = id
            menu.addItem(item)
        }
    }

    @objc private func openPairFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? WindowIdentity { host?.surfaceOpenPair(id) }
    }

    @objc private func openAloneFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? WindowIdentity { host?.surfaceOpenAlone(id) }
    }

    @objc private func ungroupFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? WindowIdentity { host?.surfaceUngroup(id) }
    }

    private var fadeMask: CAGradientLayer?

    /// An overflowing grid fades out at its top and bottom edges. Set when the chrome is laid out, never on selection.
    func applyScrollFade(_ overflows: Bool, fade: CGFloat) {
        scroll.wantsLayer = true
        guard overflows else { if scroll.layer?.mask != nil { scroll.layer?.mask = nil }; return }
        let mask = fadeMask ?? { let layer = CAGradientLayer(); layer.actions = GlyphLayer.noActions; return layer }()
        fadeMask = mask
        let share = fade / max(1, scroll.bounds.height)
        PanefloStyle.withoutAnimation {
            mask.frame = scroll.bounds
            mask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            mask.locations = [0, NSNumber(value: Double(share)), NSNumber(value: Double(1 - share)), 1]
            if scroll.layer?.mask !== mask { scroll.layer?.mask = mask }
        }
    }

    /// Re-resolves every card's colors (accent color or Increase Contrast changed).
    func refreshColors() {
        for card in grid.cards { card.refreshColors() }
    }

    // MARK: Geometry

    /// The display the panel was last placed on.
    var placedDisplayID: CGDirectDisplayID? {
        #if PANEFLO_NATIVE_CHECK
        if nativeCheckDetached { return CGDirectDisplayID.max }
        #endif
        return placedScreen?.displayID
    }

    #if PANEFLO_NATIVE_CHECK
    private var nativeCheckDetached = false
    func nativeCheckForgetPlacedScreen() { nativeCheckDetached = true }
    #endif

    /// The screen for layout decisions: where the panel was placed, else the pointer's screen.
    var layoutScreen: NSScreen? { placedScreen ?? NSScreen.pointerScreen }

    /// Resizes and places the panel only when its size or screen changed. A resized panel, or one outside
    /// `screen`, is centred on `screen` (slightly above centre, like `NSWindow.center()`), never on its old screen.
    func place(contentSize: NSSize, on screen: NSScreen) {
        placedScreen = screen
        #if PANEFLO_NATIVE_CHECK
        nativeCheckDetached = false
        #endif
        let usable = screen.visibleFrame.insetBy(dx: 16, dy: 16)
        let size = panel.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
        var frame = panel.frame
        let resized = frame.size != size
        frame.size = size
        if resized || !usable.contains(panel.frame) {
            frame.origin.x = (usable.midX - size.width / 2).rounded()
            frame.origin.y = (usable.minY + (usable.height - size.height) * 0.6).rounded()
        }
        frame.origin.x = min(max(frame.minX, usable.minX), usable.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, usable.minY), usable.maxY - frame.height)
        setPanelFrame(frame, resized: resized)
    }

    /// Covers `screen`'s visible frame exactly (the Overview overlay).
    func placeFilling(_ screen: NSScreen) {
        placedScreen = screen
        #if PANEFLO_NATIVE_CHECK
        nativeCheckDetached = false
        #endif
        let frame = screen.visibleFrame
        setPanelFrame(frame, resized: frame.size != panel.frame.size)
    }

    private func setPanelFrame(_ frame: NSRect, resized: Bool) {
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: false)
        if resized { layoutChrome() }
    }
}
