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

/// What a surface needs from the coordinator: the registry, shared icon cache and the
/// cross-surface actions (dismiss, focus, tile) whose state outlives one presentation.
@MainActor
protocol SurfaceHost: AnyObject {
    var service: WindowService { get }
    func icon(for record: WindowRecord) -> NSImage?
    func surfaceKeyboardChanged(_ surface: SurfacePanelController)
    func surfaceSelectionChanged(_ surface: SurfacePanelController)
    func surfaceDismiss(_ surface: SurfacePanelController)
    func surfaceActivate(_ id: WindowIdentity)
    func surfaceTile(_ zone: LayoutZone)
    func surfaceUndo()
}

/// Shared chrome, keyboard handling, selection and preview plumbing for one pre-created panel.
/// Subclasses own their content model, sizing and navigation rules.
@MainActor
class SurfacePanelController: NSObject, NSSearchFieldDelegate, NSWindowDelegate {
    weak var host: SurfaceHost?
    let panel: SurfacePanel
    let heading = NSTextField(labelWithString: "")
    let search = NSSearchField()
    let scroll = NSScrollView()
    private(set) var grid: CardGrid!
    let failureFeedback = NSTextField(wrappingLabelWithString: "")
    let keyboardHint = NSTextField(labelWithString: "")
    private(set) var selectedID: WindowIdentity?
    /// Window → card for the cards on display, refreshed after every grid diff.
    private(set) var cardsByWindow: [WindowIdentity: CardView] = [:]
    private(set) var layoutFeedback: [WindowIdentity: String] = [:]
    /// Cards whose previews the engine should keep current; rebuilt after a diff, scroll or search.
    private var previewCandidates: [PreviewCard]?
    private var previewRows: ClosedRange<Int>?
    private var viewportObserver: NSObjectProtocol?
    private var prewarming = false
    private var prewarmToken = 0

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
        configureChrome()
    }

    isolated deinit {
        if let viewportObserver { NotificationCenter.default.removeObserver(viewportObserver) }
    }

    private func configureChrome() {
        panel.title = "Paneflo"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = .floating
        panel.delegate = self
        panel.onEscape = { [weak self] in
            guard let self else { return }
            RuntimeDiagnostics.mark("desktop escape source=window queryPresent=\(!self.search.stringValue.isEmpty)")
            self.host?.surfaceDismiss(self)
        }
        panel.onKey = { [weak self] in self?.handleKey($0) ?? false }
        let root = NSVisualEffectView()
        root.material = .popover; root.blendingMode = .behindWindow; root.state = .active
        root.wantsLayer = true; root.layer?.cornerRadius = 18; root.layer?.masksToBounds = true
        panel.contentView = root
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10; stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 15),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -15)
        ])
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        stack.addArrangedSubview(heading)
        search.focusRingType = .none
        search.placeholderString = "Find a window"
        search.delegate = self; search.setAccessibilityLabel("Search windows")
        stack.addArrangedSubview(search)
        search.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.documentView = grid
        scroll.contentView.postsBoundsChangedNotifications = true
        viewportObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewportScrolled() }
        }
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        scroll.setContentCompressionResistancePriority(.init(1), for: .vertical)
        failureFeedback.font = .systemFont(ofSize: 11)
        failureFeedback.textColor = .secondaryLabelColor
        failureFeedback.isHidden = true
        stack.addArrangedSubview(failureFeedback)
        failureFeedback.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        keyboardHint.font = .systemFont(ofSize: 11)
        keyboardHint.textColor = .secondaryLabelColor
        keyboardHint.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(keyboardHint)
        keyboardHint.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for view in [heading, search, failureFeedback, keyboardHint] as [NSView] {
            view.setContentHuggingPriority(.defaultHigh, for: .vertical)
            view.setContentCompressionResistancePriority(.required, for: .vertical)
        }
    }

    // MARK: Subclass hooks

    func makeCard() -> CardView {
        let card = CardView(frame: .zero)
        card.target = self; card.action = #selector(cardClicked(_:))
        card.onDoubleClick = { [weak self] id in self?.cardDoubleClicked(id) }
        return card
    }
    /// Window identities that can be selected under the current search.
    func eligibleSelectionIDs() -> [WindowIdentity] { [] }
    func isEligible(_ id: WindowIdentity) -> Bool { eligibleSelectionIDs().contains(id) }
    func navigate(_ direction: CycleDirection) {}
    func navigateRows(_ delta: Int) {}
    func searchChanged() {}
    func cardSelected(_ card: CardView) {}
    func failureFeedbackChanged() {}
    /// Plain ←/→ in the search field move the selection (only when the query is empty).
    var linearArrowsLeaveSearch: Bool { false }
    func activateSelected() {
        guard let id = selectedID, isEligible(id) else { return }
        host?.surfaceActivate(id)
    }

    // MARK: Presentation

    /// Clears per-presentation decoration before a new presentation.
    func beginPresentation() {
        cancelPrewarm()
        layoutFeedback.removeAll()
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
        for card in grid.cards { card.releasePayload() }
        layoutFeedback.removeAll()
        previewCandidates = nil; previewRows = nil
    }

    /// Pays the first-display cost (window backing, vibrancy, field editor, card drawing)
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

    /// Records the grid's cards for window lookups after a diff.
    func indexCards(_ ids: [WindowIdentity?]) {
        var map: [WindowIdentity: CardView] = [:]
        map.reserveCapacity(ids.count)
        for (id, card) in zip(ids, grid.cards) { if let id { map[id] = card } }
        cardsByWindow = map
        previewCandidates = nil
    }

    /// Moves the selection: only the previous and new cards change appearance.
    func select(_ id: WindowIdentity?, notify: Bool = true) {
        let previous = selectedID
        selectedID = id
        // Preview content follows engine updates; the outgoing card keeps its last frame, relabelled.
        if let previous, previous != id, let card = cardsByWindow[previous] { card.selected = false }
        if let id, let card = cardsByWindow[id] {
            card.selected = true
            if isShown { revealCard(card) }
        }
        if notify { host?.surfaceSelectionChanged(self) }
    }

    /// Sets `selectedID` without touching cards (used before a diff that configures them).
    func setSelectedID(_ id: WindowIdentity?) { selectedID = id }

    func revealCard(_ card: CardView) {
        let visible = scroll.contentView.documentVisibleRect
        guard visible.height > 0, !visible.contains(card.frame) else { return }
        _ = card.scrollToVisible(card.bounds)
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
            .insetBy(dx: 0, dy: -grid.metrics.cardHeight / 2)
        previewRows = visibleRows()
        let cards = grid.cards.compactMap { card -> PreviewCard? in
            guard card.matches, let record = card.record, card.frame.intersects(viewport) else { return nil }
            return PreviewCard(id: record.id, windowNumber: service?.captureWindowNumber(for: record.id),
                               isMinimized: record.isMinimized)
        }
        previewCandidates = cards
        return cards
    }

    /// The card preview area in backing pixels (all cards in a grid share one size).
    var previewPixelSize: CGSize? {
        guard let card = grid.cards.first else { return nil }
        let area = card.previewRect.size
        guard area.width >= 1, area.height >= 1 else { return nil }
        let scale = panel.backingScaleFactor
        return CGSize(width: (area.width * scale).rounded(), height: (area.height * scale).rounded())
    }

    /// Grid rows touched by the viewport plus margin; scrolling within a row changes nothing.
    private func visibleRows() -> ClosedRange<Int>? {
        let viewport = scroll.contentView.documentVisibleRect
        let pitch = grid.metrics.cardHeight + grid.metrics.spacing
        guard pitch > 0, grid.rows > 0 else { return nil }
        let margin = grid.metrics.cardHeight / 2
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
    private func cardDoubleClicked(_ id: WindowIdentity) { select(id, notify: false); activateSelected() }

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

    // MARK: Geometry

    /// Columns for a card count on a screen of the given width (shared by both surfaces).
    static func columns(for count: Int, screenWidth: CGFloat) -> Int {
        min(max(1, min(4, Int((screenWidth - 60) / 190))), max(1, count))
    }

    /// Resizes and places the panel only when its size or screen changed.
    func place(contentSize: NSSize, on screen: NSScreen) {
        let usable = screen.visibleFrame.insetBy(dx: 16, dy: 16)
        if panel.contentRect(forFrameRect: panel.frame).size != contentSize {
            panel.setContentSize(contentSize)
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.center()
        } else if !usable.contains(panel.frame) {
            panel.center()
        }
        var frame = panel.frame
        frame.origin.x = min(max(frame.minX, usable.minX), usable.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, usable.minY), usable.maxY - frame.height)
        if frame != panel.frame { panel.setFrame(frame, display: false) }
    }
}
