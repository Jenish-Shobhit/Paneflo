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
    /// Cards in display order: windows and, in a switching session, the Desktop entry.
    private(set) var targets: [SwitchTarget] = []
    /// The displayed windows (the Desktop entry excluded).
    var displayed: [WindowIdentity] { targets.compactMap(\.windowID) }
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
        let screen = NSScreen.pointerScreen
        // Arrange lists windows only; switching sessions may include the Desktop entry.
        session = SwitcherSession(snapshot: snapshot, direction: backwards ? .backward : .forward,
                                  desktop: mode == .switcher ? host?.desktopLoopMode ?? .hidden : .hidden)
        if mode == .switcher { setSelectedTarget(session.selectedTarget) }
        else { setSelectedID(service.focusedID ?? snapshot.orderedRecords.first?.id) }
        rebuild(snapshot: snapshot, screen: screen)
        fit(on: screen)
        // The held picker receives every key through the event tap, so it never takes key focus
        // from the frontmost app. Manual Switch/Arrange sessions need the search field.
        if shortcutSession { orderFrontWithoutKey() } else { orderFront(searchFocused: true) }
        if let target = selectedTarget, let card = card(for: target) { revealCard(card) }
        showDesktopWallpaper()
    }

    /// One-time launch preparation: builds cards for the current registry while hidden and
    /// draws them once, so the first ⌘Tab pays neither card construction nor first display.
    func prepareHidden(on preferredScreen: NSScreen? = nil) {
        guard !isShown, let service else { return }
        let snapshot = service.snapshot
        mode = .switcher
        shortcutSession = true
        search.isHidden = true
        session = SwitcherSession(snapshot: snapshot, desktop: host?.desktopLoopMode ?? .hidden)
        setSelectedTarget(session.selectedTarget)
        let screen = preferredScreen ?? NSScreen.pointerScreen
        rebuild(snapshot: snapshot, screen: screen)
        fit(on: screen)
        session.cancel()
        shortcutSession = false
        prewarm()
    }

    func step(backwards: Bool) {
        session.advance(backwards ? .backward : .forward)
        select(target: session.selectedTarget)
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
            setSelectedTarget(session.selectedTarget)
        }
        rebuild(snapshot: snapshot)
        fit()
        showDesktopWallpaper()
    }

    override func screenParametersChanged(to screen: NSScreen) {
        guard let service else { return }
        if isShown {
            rebuild(snapshot: service.snapshot, screen: screen)
            fit(on: screen)
        } else {
            // Re-lay out the pre-warmed panel for the new display so the next ⌘Tab is warm there.
            prepareHidden(on: screen)
        }
    }

    override func hide() {
        cancelSession()
        super.hide()
    }

    // MARK: Content

    private func rebuild(snapshot: WindowSnapshot, screen: NSScreen? = nil) {
        records = Dictionary(snapshot.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        targets = mode == .switcher ? session.filteredTargets : snapshot.orderedRecords.map { .window($0.id) }
        appliedQuery = search.stringValue
        let screenWidth = (screen ?? layoutScreen)?.visibleFrame.width ?? 1000
        grid.metrics = .init(columns: Self.columns(for: targets.count, screenWidth: screenWidth), cardHeight: Self.cardHeight)
        let query = search.stringValue
        let selected = selectedID
        let targets = targets
        grid.apply(keys: targets.map(AnyHashable.init)) { card, index in
            guard case .window(let id) = targets[index] else { configureDesktopCard(card); return }
            let record = records[id]
            card.isDesktopEntry = false
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
        }
        indexCards(targets.map(\.windowID), desktopIndex: targets.firstIndex(of: .desktop))
        if targets.allSatisfy({ $0 == .desktop }), query.isEmpty || targets.isEmpty {
            let accessible = service?.hasAccessibility ?? false
            grid.showEmpty(!query.isEmpty ? "No windows match this search."
                : accessible ? "No eligible windows found. Open a normal application window, then refresh."
                : "Your windows will appear here after Accessibility access is enabled.")
        } else { grid.showEmpty(nil) }
    }

    private func fit(on target: NSScreen? = nil) {
        guard let screen = target ?? layoutScreen else { return }
        let usable = screen.visibleFrame.insetBy(dx: 16, dy: 16)
        let columns = grid.metrics.columns
        let rows = max(1, (targets.count + columns - 1) / columns)
        let visibleRows = CGFloat(min(rows, 2))
        // A lone Desktop card leaves room for the empty-state text under it.
        let note: CGFloat = targets == [.desktop] && search.stringValue.isEmpty ? 94 : 0
        let viewport = min(visibleRows * Self.cardHeight + (visibleRows - 1) * 10 + note,
                           max(80, usable.height - (search.isHidden ? 110 : 145)))
        let size = NSSize(width: min(CGFloat(columns) * 208 + 36, usable.width),
                          height: min(viewport + (search.isHidden ? 94 : 128) + (failureFeedback.isHidden ? 0 : 30), usable.height))
        place(contentSize: size, on: screen)
    }

    override func failureFeedbackChanged() { if isShown { fit() } }

    // MARK: Navigation

    override var isDesktopEligible: Bool { mode == .switcher && session.filteredTargets.contains(.desktop) }

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
        if mode == .switcher { session.advance(direction); select(target: session.selectedTarget); return }
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
        let current = selectedTarget.flatMap { targets.firstIndex(of: $0) }
        if mode == .switcher {
            // Rows exist only when the picker wraps; a single row has nothing above or below.
            if let next = GridNavigation.vertical(from: current, columns: columns, count: targets.count,
                                                   eligible: Array(targets.indices), direction: delta),
               session.select(targets[next]) {
                select(target: session.selectedTarget)
            }
            return
        }
        let eligible = Set(eligibleSelectionIDs())
        let indices = targets.indices.filter { targets[$0].windowID.map(eligible.contains) ?? false }
        if let next = GridNavigation.vertical(from: current, columns: columns, count: targets.count, eligible: indices, direction: delta) {
            select(target: targets[next])
        }
    }

    override func searchChanged() {
        if mode == .switcher {
            session.setSearchQuery(search.stringValue)
            setSelectedTarget(session.selectedTarget)
            if let service { rebuild(snapshot: service.snapshot) }
            fit()
            select(target: selectedTarget)
            showDesktopWallpaper()
            return
        }
        let eligible = eligibleSelectionIDs()
        if selectedID.map({ eligible.contains($0) }) != true { setSelectedID(eligible.first) }
        if let service { rebuild(snapshot: service.snapshot) }
        select(selectedID)
    }

    override func cardSelected(_ card: CardView) {
        guard let target = card.switchTarget else { return }
        if mode == .switcher { _ = session.select(target) }
        select(target: target)
    }

    override func activateSelected() {
        guard let target = selectedTarget, isEligible(target) else {
            if shortcutSession { host?.surfaceDismiss(self) }
            return
        }
        if mode == .switcher { _ = session.commitTarget() }
        activate(target)
    }

    #if PANEFLO_NATIVE_CHECK
    var nativeCheckTargets: [SwitchTarget] { targets }
    #endif
}
