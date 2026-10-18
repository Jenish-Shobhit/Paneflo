import AppKit
import PanefloCore

/// The ⌘Tab picker (held, non-activating) and the manual Switch/Arrange lists.
///
/// A compact Liquid Glass shelf that hugs the cards: no heading and no key hints, just the cards and, unless Settings
/// turns it off (Show selected window title), one line with the selected window's full title. Tier, columns, rows and panel size are computed once per presentation; a
/// selection step changes layer properties on at most four cards plus one text layer. Nothing runs while hidden.
@MainActor
final class SwitcherPanelController: SurfacePanelController {
    /// The glass shelf; false falls back to the HUD material (kept for measurement and as a safety valve).
    static var usesGlass = true
    private(set) var mode = DesktopMode.switcher
    private(set) var shortcutSession = false
    private var session = SwitcherSession(snapshot: WindowSnapshot(records: []))
    /// Cards in display order: windows and, in a switching session, the Desktop entry.
    private(set) var targets: [SwitchTarget] = []
    /// The displayed windows (the Desktop entry excluded).
    var displayed: [WindowIdentity] { targets.compactMap(\.windowID) }
    private var records: [WindowIdentity: WindowRecord] = [:]
    private var appliedQuery = ""
    private(set) var plan = SwitcherLayout.plan(count: 8, width: 1200, height: 800, chrome: 80)
    private let focusLine = FocusLineView()
    private var viewportHeight: CGFloat = 200

    override var showsPreviews: Bool { mode != .tiling }

    init() {
        let initial = NSSize(width: 4 * 214 + 28, height: 2 * 177 + 10 + 70)
        super.init(contentSize: initial)
        content.addSubview(focusLine)
        search.isHidden = true
        layoutChrome()
    }

    override func makeBackdrop(content: NSView) -> NSView {
        let root: NSView
        if Self.usesGlass {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = PanefloStyle.Radius.panel
            glass.contentView = content
            root = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow; effect.blendingMode = .behindWindow; effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = PanefloStyle.Radius.panel
            effect.layer?.cornerCurve = .continuous
            effect.layer?.masksToBounds = true
            content.frame = effect.bounds
            content.autoresizingMask = [.width, .height]
            effect.addSubview(content)
            root = effect
        }
        root.setAccessibilityLabel("Window switcher")
        return root
    }

    func present(mode: DesktopMode, fromShortcut: Bool, backwards: Bool) {
        guard let service else { return }
        beginPresentation()
        self.mode = mode
        shortcutSession = fromShortcut && mode == .switcher
        if search.isHidden != shortcutSession { search.isHidden = shortcutSession }
        if !search.stringValue.isEmpty { search.stringValue = "" }
        let snapshot = service.snapshot
        let screen = NSScreen.pointerScreen
        // Arrange lists windows only; switching sessions may include the Desktop entry and keep pairs side by side.
        session = SwitcherSession(snapshot: snapshot, direction: backwards ? .backward : .forward,
                                  desktop: mode == .switcher ? host?.desktopLoopMode ?? .hidden : .hidden,
                                  pairs: mode == .switcher ? host?.sessionPairs ?? [] : [])
        if mode == .switcher { setSelectedTarget(session.selectedTarget) }
        else { setSelectedID(service.focusedID ?? snapshot.orderedRecords.first?.id) }
        applyTitlePreference()
        rebuild(snapshot: snapshot, screen: screen)
        fit(on: screen)
        refreshPairs()
        // The held picker receives every key through the event tap, so it never takes key focus
        // from the frontmost app. Manual Switch/Arrange sessions need the search field.
        if shortcutSession { orderFrontWithoutKey() } else { orderFront(searchFocused: true) }
        if let target = selectedTarget, let card = card(for: target) { revealCard(card) }
        selectionDidChange()
        showDesktopWallpaper()
    }

    /// One-time launch preparation: builds cards for the current registry while hidden and
    /// renders them once, so the first ⌘Tab pays neither card construction nor first display.
    func prepareHidden(on preferredScreen: NSScreen? = nil) {
        guard !isShown, let service else { return }
        let snapshot = service.snapshot
        mode = .switcher
        shortcutSession = true
        search.isHidden = true
        session = SwitcherSession(snapshot: snapshot, desktop: host?.desktopLoopMode ?? .hidden, pairs: host?.sessionPairs ?? [])
        setSelectedTarget(session.selectedTarget)
        let screen = preferredScreen ?? NSScreen.pointerScreen
        applyTitlePreference()
        rebuild(snapshot: snapshot, screen: screen)
        fit(on: screen)
        refreshPairs()
        selectionDidChange()
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
        refreshPairs()
        select(target: selectedTarget, notify: false)
        showDesktopWallpaper()
    }

    override func screenParametersChanged(to screen: NSScreen) {
        guard let service else { return }
        if isShown {
            rebuild(snapshot: service.snapshot, screen: screen)
            fit(on: screen)
            refreshPairs()
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

    private func usableArea(_ screen: NSScreen?) -> NSSize {
        let frame = (screen ?? layoutScreen)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSSize(width: frame.width * PanefloStyle.Switcher.widthShare, height: frame.height * PanefloStyle.Switcher.heightShare)
    }

    /// Whether this presentation shows the title line; read once per presentation, never on a selection step.
    private var showsTitleLine = true

    private func applyTitlePreference() {
        let shows = host?.preferences.showsSelectedTitle ?? true
        guard shows != showsTitleLine else { return }
        showsTitleLine = shows
        focusLine.isHidden = !shows
        if !shows { focusLine.show(title: "", app: "") }
    }

    /// Panel height that is not grid. Without the title line the cards sit `panelPadding` from the bottom edge too.
    private var chromeHeight: CGFloat {
        PanefloStyle.Switcher.panelPadding + (search.isHidden ? 0 : PanefloStyle.Switcher.searchHeight + 10)
            + (showsTitleLine ? 10 + FocusLineView.height + 12 : PanefloStyle.Switcher.panelPadding)
            + (failureFeedback.isHidden ? 0 : 4 + 16 + (showsTitleLine ? 0 : 4))
    }

    private func rebuild(snapshot: WindowSnapshot, screen: NSScreen? = nil) {
        records = Dictionary(snapshot.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        targets = mode == .switcher ? session.filteredTargets : snapshot.orderedRecords.map { .window($0.id) }
        appliedQuery = search.stringValue
        let area = usableArea(screen)
        plan = SwitcherLayout.plan(count: targets.count, pairStarts: session.pairStarts(in: targets),
                                   width: Double(area.width), height: Double(area.height), chrome: Double(chromeHeight),
                                   forced: host?.preferences.cardSize.forcedTier)
        let style = CardStyle.switcher(plan.tier)
        grid.layout = .switcher(plan)
        let query = search.stringValue
        let selected = selectedID
        let targets = targets
        grid.apply(keys: targets.map(AnyHashable.init)) { card, index in
            card.style = style
            card.hoverEnabled = false
            guard case .window(let id) = targets[index] else { configureDesktopCard(card); return }
            let record = records[id]
            card.isDesktopEntry = false
            card.vacancy = nil
            card.record = record
            card.icon = record.flatMap { host?.icon(for: $0) }
            card.isPinned = false
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
            grid.showEmpty(!query.isEmpty ? "No windows match “\(query)”."
                : accessible ? "No eligible windows found. Open a normal application window, then refresh."
                : "Your windows will appear here after Accessibility access is enabled.")
        } else { grid.showEmpty(nil) }
    }

    private func fit(on target: NSScreen? = nil) {
        guard let screen = target ?? layoutScreen else { return }
        let usable = screen.visibleFrame.insetBy(dx: 16, dy: 16)
        let visibleGrid = CGFloat(plan.gridHeight(rows: plan.visibleRows))
        let emptyNote: CGFloat = grid.contentHeight > CGFloat(plan.gridHeight(rows: plan.rows)) ? 70 : 0
        viewportHeight = targets.isEmpty ? grid.contentHeight : min(grid.contentHeight, visibleGrid + emptyNote)
        let minimumWidth: CGFloat = search.isHidden ? 0 : 420
        let width = min(max(CGFloat(plan.gridWidth) + 2 * PanefloStyle.Switcher.panelPadding, minimumWidth, 300), usable.width)
        let height = min(viewportHeight + chromeHeight, usable.height)
        place(contentSize: NSSize(width: width, height: height), on: screen)
        layoutChrome()
    }

    override func layoutChrome() {
        let bounds = content.bounds
        let padding = PanefloStyle.Switcher.panelPadding
        let width = max(0, bounds.width - 2 * padding)
        var y = padding
        if !search.isHidden {
            setFrame(search, NSRect(x: padding, y: y, width: width, height: PanefloStyle.Switcher.searchHeight))
            y += PanefloStyle.Switcher.searchHeight + 10
        }
        let available = max(40, bounds.height - y - (chromeHeight - padding - (search.isHidden ? 0 : PanefloStyle.Switcher.searchHeight + 10)))
        let viewport = min(viewportHeight, available)
        setFrame(scroll, NSRect(x: padding, y: y, width: width, height: viewport))
        y += viewport
        if showsTitleLine {
            y += 10
            setFrame(focusLine, NSRect(x: padding + 6, y: y, width: max(0, width - 12), height: FocusLineView.height))
            y += FocusLineView.height
        }
        if !failureFeedback.isHidden {
            setFrame(failureFeedback, NSRect(x: padding, y: y + 4, width: width, height: 16))
        }
        updateFadeMask()
    }

    private func setFrame(_ view: NSView, _ frame: NSRect) { if view.frame != frame { view.frame = frame } }

    private func updateFadeMask() {
        applyScrollFade(plan.rows > plan.visibleRows, fade: PanefloStyle.Switcher.scrollFade)
    }

    override func failureFeedbackChanged() { if isShown { fit() } }

    override func selectionDidChange() {
        guard showsTitleLine else { return }
        guard let target = selectedTarget, let card = card(for: target) else { focusLine.show(title: "", app: ""); return }
        if card.isDesktopEntry {
            focusLine.show(title: SwitcherSession.desktopTitle, app: card.desktopIsCurrent ? "Bring your windows back" : "Show the desktop")
        } else if let record = card.record {
            focusLine.show(title: record.title.isEmpty ? record.appName : record.title, app: record.appName,
                           partner: card.pairPartnerName)
        }
    }

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
        let current = selectedTarget.flatMap { targets.firstIndex(of: $0) }
        if mode == .switcher {
            // Rows exist only when the picker wraps; a single row has nothing above or below.
            if let next = plan.vertical(from: current, direction: delta), session.select(targets[next]) {
                select(target: session.selectedTarget)
            }
            return
        }
        let eligible = Set(eligibleSelectionIDs())
        let indices = Set(targets.indices.filter { targets[$0].windowID.map(eligible.contains) ?? false })
        if let next = plan.vertical(from: current, direction: delta, eligible: indices) {
            select(target: targets[next])
        }
    }

    override func searchChanged() {
        if mode == .switcher {
            session.setSearchQuery(search.stringValue)
            setSelectedTarget(session.selectedTarget)
            if let service { rebuild(snapshot: service.snapshot) }
            fit()
            refreshPairs()
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
    var nativeCheckPlan: SwitcherLayout { plan }
    var nativeCheckFocusLine: String? { focusLine.nativeCheckText }
    var nativeCheckFocusLineVisible: Bool { !focusLine.isHidden && focusLine.superview != nil && focusLine.frame.height > 0 }
    #endif
}
