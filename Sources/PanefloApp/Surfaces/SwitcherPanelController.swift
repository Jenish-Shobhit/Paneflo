import AppKit
import PanefloCore

/// The ⌘Tab picker (held, non-activating) and the manual Switch/Arrange lists.
/// Built from the registry snapshot only when presented; nothing runs while hidden.
@MainActor
final class SwitcherPanelController: SurfacePanelController {
    static let cardHeight: CGFloat = 142
    private(set) var mode = DesktopMode.switcher
    private(set) var shortcutSession = false
    private var session = SwitcherSession(snapshot: WindowSnapshot(records: []))
    private(set) var displayed: [WindowIdentity] = []
    private var records: [WindowIdentity: WindowRecord] = [:]
    private var appliedQuery = ""

    override var showsPreviews: Bool { mode != .tiling }

    init() {
        // Pre-sized for the common held picker: four columns, two rows, no search field.
        let initial = NSSize(width: 4 * 208 + 36, height: 2 * SwitcherPanelController.cardHeight + 10 + 94)
        super.init(contentSize: initial)
        heading.stringValue = "Switch windows"
        search.isHidden = true
    }

    func present(mode: DesktopMode, fromShortcut: Bool, backwards: Bool) {
        guard let service else { return }
        beginPresentation()
        self.mode = mode
        shortcutSession = fromShortcut && mode == .switcher
        let headingText = mode == .tiling ? "Arrange a window" : "Switch windows"
        if heading.stringValue != headingText { heading.stringValue = headingText }
        let hint = shortcutSession ? "⇥ or arrows select   ⌥← → tile   ⌥↑ fill   ⌥↓ undo   release ⌘ to open   esc cancel"
            : "arrows select   ⌘⌥← → tile   ⌘⌥↑ fill   ⌘⌥↓ undo   return open   esc close"
        if keyboardHint.stringValue != hint { keyboardHint.stringValue = hint }
        if search.isHidden != shortcutSession { search.isHidden = shortcutSession }
        if !search.stringValue.isEmpty { search.stringValue = "" }
        let snapshot = service.snapshot
        session = SwitcherSession(snapshot: snapshot, direction: backwards ? .backward : .forward)
        if mode == .switcher { setSelectedID(session.selectedID) }
        else { setSelectedID(service.focusedID ?? snapshot.orderedRecords.first?.id) }
        rebuild(snapshot: snapshot)
        fit()
        // The held picker receives every key through the event tap, so it never takes key focus
        // from the frontmost app. Manual Switch/Arrange sessions need the search field.
        if shortcutSession { orderFrontWithoutKey() } else { orderFront(searchFocused: true) }
        if let id = selectedID, let card = cardsByWindow[id] { revealCard(card) }
    }

    /// One-time launch preparation: builds cards for the current registry while hidden and
    /// draws them once, so the first ⌘Tab pays neither card construction nor first display.
    func prepareHidden() {
        guard !isShown, let service else { return }
        let snapshot = service.snapshot
        mode = .switcher
        shortcutSession = true
        search.isHidden = true
        session = SwitcherSession(snapshot: snapshot)
        setSelectedID(session.selectedID)
        rebuild(snapshot: snapshot)
        fit()
        session.cancel()
        shortcutSession = false
        prewarm()
    }

    func step(backwards: Bool) {
        session.advance(backwards ? .backward : .forward)
        select(session.selectedID)
    }

    func cancelSession() { session.cancel(); shortcutSession = false }

    func commitShortcut() { if shortcutSession { activateSelected() } }

    /// Registry change while presented. A held ⌘Tab keeps its frozen order (dead windows drop out);
    /// a manual session accepts newly discovered windows.
    func snapshotChanged() {
        guard isShown, let service else { return }
        let snapshot = service.snapshot
        if mode == .switcher {
            if shortcutSession {
                let live = Set(snapshot.records.map(\.id))
                for id in session.orderedIDs where !live.contains(id) { session.remove(id) }
            } else {
                session.refresh(snapshot: snapshot)
            }
            setSelectedID(session.selectedID)
        }
        rebuild(snapshot: snapshot)
        for card in grid.cards where card.thumbnail != nil {
            if let record = card.record, service.captureWindowNumber(for: record.id) == nil { card.thumbnail = nil }
        }
        fit()
    }

    override func hide() {
        cancelSession()
        super.hide()
    }

    // MARK: Content

    private func rebuild(snapshot: WindowSnapshot) {
        records = Dictionary(snapshot.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        displayed = mode == .switcher ? session.filteredIDs : snapshot.orderedRecords.map(\.id)
        appliedQuery = search.stringValue
        let screenWidth = (panel.screen ?? NSScreen.main)?.visibleFrame.width ?? 1000
        grid.metrics = .init(columns: Self.columns(for: displayed.count, screenWidth: screenWidth), cardHeight: Self.cardHeight)
        let query = search.stringValue
        let selected = selectedID
        grid.apply(keys: displayed.map(AnyHashable.init)) { card, index in
            let id = displayed[index]
            let record = records[id]
            card.record = record
            card.icon = record.flatMap { host?.icon(for: $0) }
            card.isVacancyPinned = false
            card.dragEnabled = false
            card.layoutBadge = layoutFeedback[id]
            card.selected = record != nil && id == selected
            let matches = mode != .tiling || query.isEmpty
                || record.map { ($0.appName + " " + $0.title).localizedCaseInsensitiveContains(query) } ?? false
            card.matches = matches
            card.setEnabledIfChanged(matches)
            if !card.selected, card.preview != nil { card.preview = nil; card.previewLabel = "Icon preview" }
        }
        indexCards(displayed)
        if displayed.isEmpty {
            let accessible = service?.hasAccessibility ?? false
            grid.showEmpty(!query.isEmpty ? "No windows match this search."
                : accessible ? "No eligible windows found. Open a normal application window, then refresh."
                : "Your windows will appear here after Accessibility access is enabled.")
        } else { grid.showEmpty(nil) }
    }

    private func fit() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let usable = screen.visibleFrame.insetBy(dx: 16, dy: 16)
        let columns = grid.metrics.columns
        let rows = max(1, (displayed.count + columns - 1) / columns)
        let visibleRows = CGFloat(min(rows, 2))
        let viewport = min(visibleRows * Self.cardHeight + (visibleRows - 1) * 10,
                           max(80, usable.height - (search.isHidden ? 110 : 145)))
        let size = NSSize(width: min(CGFloat(columns) * 208 + 36, usable.width),
                          height: min(viewport + (search.isHidden ? 94 : 128) + (failureFeedback.isHidden ? 0 : 30), usable.height))
        place(contentSize: size, on: screen)
    }

    override func failureFeedbackChanged() { if isShown { fit() } }

    // MARK: Navigation

    override func eligibleSelectionIDs() -> [WindowIdentity] {
        if mode == .switcher { return session.filteredIDs }
        let query = search.stringValue
        guard !query.isEmpty else { return displayed }
        return displayed.filter { id in
            records[id].map { ($0.appName + " " + $0.title).localizedCaseInsensitiveContains(query) } ?? false
        }
    }

    override func navigate(_ direction: CycleDirection) {
        guard isShown else { return }
        if mode == .switcher { session.advance(direction); select(session.selectedID); return }
        let eligible = eligibleSelectionIDs()
        guard !eligible.isEmpty else { select(nil); return }
        if let current = selectedID, let index = eligible.firstIndex(of: current) {
            select(eligible[(index + (direction == .forward ? 1 : eligible.count - 1)) % eligible.count])
        } else {
            select(direction == .forward ? eligible.first : eligible.last)
        }
    }

    override func navigateRows(_ delta: Int) {
        guard isShown else { return }
        let columns = grid.metrics.columns
        let current = selectedID.flatMap { displayed.firstIndex(of: $0) }
        if mode == .switcher {
            // Rows exist only when the picker wraps; a single row has nothing above or below.
            if let next = GridNavigation.vertical(from: current, columns: columns, count: displayed.count,
                                                   eligible: Array(displayed.indices), direction: delta),
               session.select(displayed[next]) {
                select(session.selectedID)
            }
            return
        }
        let eligible = Set(eligibleSelectionIDs())
        let indices = displayed.indices.filter { eligible.contains(displayed[$0]) }
        if let next = GridNavigation.vertical(from: current, columns: columns, count: displayed.count, eligible: indices, direction: delta) {
            select(displayed[next])
        }
    }

    override func searchChanged() {
        if mode == .switcher {
            session.setSearchQuery(search.stringValue)
            setSelectedID(session.selectedID)
            if let service { rebuild(snapshot: service.snapshot) }
            fit()
            select(selectedID)
            return
        }
        let eligible = eligibleSelectionIDs()
        if selectedID.map({ eligible.contains($0) }) != true { setSelectedID(eligible.first) }
        if let service { rebuild(snapshot: service.snapshot) }
        select(selectedID)
    }

    override func cardSelected(_ card: CardView) {
        guard let id = card.record?.id else { return }
        if mode == .switcher { _ = session.select(id) }
        select(id)
    }

    override func activateSelected() {
        guard let id = selectedID, isEligible(id) else {
            if shortcutSession { host?.surfaceDismiss(self) }
            return
        }
        if mode == .switcher { _ = session.commit() }
        host?.surfaceActivate(id)
    }
}
