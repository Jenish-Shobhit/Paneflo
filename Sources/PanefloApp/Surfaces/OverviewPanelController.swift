import AppKit
import PanefloCore

/// Paneflo's organized Overview: a full-display translucent overlay with cards floating on the blurred desktop, an
/// optional Desktop home tile, then user-ordered slots. Only a search pill and a quiet count sit above the grid; no
/// key legend. The home tile sits outside the slot store, so slot order, pins and bindings are unaffected by it.
/// Registry changes while hidden are coalesced (at most one diff per second, and any pending change is applied on
/// open); a dismissal never rebuilds.
@MainActor
final class OverviewPanelController: SurfacePanelController {
    static let hiddenCoalescingInterval: TimeInterval = 1.0
    static let hiddenBurstDelay: TimeInterval = 0.3
    private var slots = OverviewSlotStore()
    /// The slots on display: all of them, or without free slots when that setting is off.
    private var shownSlots: [OverviewSlot] = []
    private var selectedSlot: UUID?
    private let defaults = UserDefaults.standard
    private var lastSavedMetadata: Data?
    /// The registry changed since the cards were last reconciled.
    private var snapshotDirty = true
    private var hiddenApplyScheduled = false
    private var lastHiddenApply: TimeInterval = -.infinity
    private var appliedQuery = ""
    private var appliedScreenFrame: NSRect?
    private var eligibleCache: [WindowIdentity]?
    /// Grid cards before the first slot card: 1 while the Desktop home tile is displayed.
    private var tileOffset = 0
    private var homeTileMatches = true
    private var warmedWithCards = false
    private(set) var applyCount = 0
    /// Called once, after the first hidden diff that produced cards (launch warm-up).
    var onFirstCards: (() -> Void)?
    private let countLabel = NSTextField(labelWithString: "")
    private let scrim = NSView()
    private let opaqueBackdrop = NSView()
    private var dragGhost: CALayer?
    private weak var dropTarget: CardView?

    override var linearArrowsLeaveSearch: Bool { true }

    init() {
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        super.init(contentSize: OverviewPanelController.contentSize(for: frame))
        if let data = defaults.data(forKey: "overview.slots.v1"), let stored = try? OverviewSlotStore(metadata: data) { slots = stored }
        panel.hasShadow = false
        countLabel.font = PanefloStyle.Font.overviewHeaderCount
        countLabel.textColor = .secondaryLabelColor
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.translatesAutoresizingMaskIntoConstraints = true
        content.addSubview(countLabel)
        search.controlSize = .large
        content.onBackgroundClick = { [weak self] in
            guard let self else { return }
            RuntimeDiagnostics.mark("desktop overview dismissed reason=backdropClick")
            self.host?.surfaceDismiss(self)
        }
        layoutChrome()
    }

    /// The overlay covers the display's visible frame.
    static func contentSize(for visibleFrame: NSRect) -> NSSize { visibleFrame.size }

    /// The most a card may be tall so three rows fit.
    static func cardHeight(for visibleFrame: NSRect) -> CGFloat {
        max(174, min(280, (visibleFrame.height * 0.9 - 160) / 3))
    }

    var slotBindings: [WindowIdentity?] { shownSlots.map(\.binding) }

    override func makeBackdrop(content: NSView) -> NSView {
        let root = NSVisualEffectView()
        root.material = .fullScreenUI
        root.blendingMode = .behindWindow
        root.state = .active
        for view in [opaqueBackdrop, scrim] {
            view.wantsLayer = true
            view.frame = root.bounds
            view.autoresizingMask = [.width, .height]
            root.addSubview(view)
        }
        content.frame = root.bounds
        content.autoresizingMask = [.width, .height]
        root.addSubview(content)
        root.setAccessibilityLabel("Overview")
        applyBackdropAppearance(root)
        return root
    }

    /// Reduce Transparency: an opaque backdrop and no scrim. Otherwise a light dim over the blurred desktop.
    private func applyBackdropAppearance(_ root: NSView? = nil) {
        let root = root ?? panel.contentView
        let appearance = root?.effectiveAppearance ?? NSApp.effectiveAppearance
        let reduce = PanefloStyle.Accessibility.current.reduceTransparency
        PanefloStyle.withoutAnimation {
            scrim.isHidden = reduce
            scrim.layer?.backgroundColor = PanefloStyle.cgColor(PanefloStyle.Color.scrim(dark: PanefloStyle.isDark(appearance)), for: appearance)
            opaqueBackdrop.isHidden = !reduce
            opaqueBackdrop.layer?.backgroundColor = PanefloStyle.cgColor(PanefloStyle.Color.opaqueBackdrop, for: appearance)
        }
    }

    /// Reduce Transparency or Increase Contrast changed.
    func accessibilityDisplayChanged() { applyBackdropAppearance() }

    override func layoutChrome() {
        let bounds = content.bounds
        guard bounds.width > 0 else { return }
        let margin = PanefloStyle.Overview.outerMargin
        let column = min(PanefloStyle.Overview.maxContentWidth, max(200, bounds.width - 2 * margin))
        let left = ((bounds.width - column) / 2).rounded()
        let headerTop: CGFloat = 20
        let searchSize = PanefloStyle.Overview.searchSize
        set(search, NSRect(x: (bounds.midX - searchSize.width / 2).rounded(), y: headerTop + (PanefloStyle.Overview.headerHeight - searchSize.height) / 2,
                           width: searchSize.width, height: searchSize.height))
        set(countLabel, NSRect(x: left, y: headerTop + (PanefloStyle.Overview.headerHeight - 16) / 2, width: max(0, search.frame.minX - left - 16), height: 16))
        let gridTop = headerTop + PanefloStyle.Overview.headerHeight + 8
        let inset = gridInset
        let failureHeight: CGFloat = failureFeedback.isHidden ? 0 : 24
        set(scroll, NSRect(x: left - inset, y: gridTop, width: column + 2 * inset, height: max(80, bounds.height - gridTop - margin - failureHeight)))
        if !failureFeedback.isHidden {
            set(failureFeedback, NSRect(x: left, y: scroll.frame.maxY + 6, width: column, height: 16))
        }
        applyScrollFade(grid.contentHeight > scroll.bounds.height + 1, fade: PanefloStyle.Overview.scrollFade)
    }

    /// Room around the cards for the selection ring.
    private var gridInset: CGFloat { 6 }

    private func set(_ view: NSView, _ frame: NSRect) { if view.frame != frame { view.frame = frame } }

    override func failureFeedbackChanged() { layoutChrome() }

    // MARK: Presentation

    func present() {
        guard let screen = NSScreen.pointerScreen else { return }
        beginPresentation()
        if !search.stringValue.isEmpty { search.stringValue = "" }
        if screen.visibleFrame != appliedScreenFrame || wantsHomeTile != (tileOffset == 1)
            || (host?.preferences.showsFreeSlots ?? true) != showsFreeSlots { snapshotDirty = true }
        if snapshotDirty { applySnapshot(screen: screen) }
        if appliedQuery != search.stringValue { updateMatches() }
        if !shownSlots.contains(where: { $0.id == selectedSlot && $0.binding != nil }) {
            selectedSlot = shownSlots.first(where: { $0.binding != nil })?.id
        }
        placeFilling(screen)
        layoutChrome()
        applyBackdropAppearance()
        // A window is selected first; the home tile is the selection only when no window is bound.
        if let binding = shownSlots.first(where: { $0.id == selectedSlot })?.binding {
            select(binding, notify: false)
        } else {
            select(target: tileOffset == 1 ? .desktop : nil, notify: false)
        }
        orderFront(searchFocused: true)
        fadeInScrim()
        if let target = selectedTarget, let card = card(for: target) { revealCard(card) }
        showDesktopWallpaper()
    }

    /// The dim fades in over 120 ms while keys already work (instant with Reduce Motion). The panel itself is instant.
    private func fadeInScrim() {
        let duration = PanefloStyle.Motion.duration(PanefloStyle.Motion.overviewScrim)
        guard duration > 0, !scrim.isHidden, let layer = scrim.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "fadeIn")
    }

    private var wantsHomeTile: Bool { host?.showsDesktopHomeTile ?? false }
    private var showsFreeSlots = true

    override func screenParametersChanged(to screen: NSScreen) {
        appliedScreenFrame = nil
        snapshotDirty = true
        eligibleCache = nil
        if isShown {
            placeFilling(screen)
            applySnapshot(screen: screen)
            layoutChrome()
            reconcileSelectionWithSearch()
        } else {
            // Size the pre-warmed panel for the new display and render it once more off the input path.
            placeFilling(screen)
            applySnapshot(screen: screen)
            prewarm()
        }
    }

    /// The Desktop setting or state changed: add/remove the home tile, or refresh its subtitle.
    override func desktopStateChanged() {
        guard wantsHomeTile == (tileOffset == 1) else {
            snapshotDirty = true
            if isShown, let screen = layoutScreen {
                applySnapshot(screen: screen)
                reconcileSelectionWithSearch()
                showDesktopWallpaper()
            }
            return
        }
        super.desktopStateChanged()
    }

    /// Preferences changed (free slots shown or hidden). Hidden: applied on next open.
    func preferencesChanged() {
        snapshotDirty = true
        if isShown, let screen = layoutScreen { applySnapshot(screen: screen); reconcileSelectionWithSearch() }
    }

    /// Re-takes keyboard focus for an Overview that is already on screen. Never activates Paneflo.
    func reacquireKeyboard() {
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
    }

    func snapshotChanged() {
        snapshotDirty = true
        eligibleCache = nil
        if isShown {
            guard let screen = layoutScreen else { return }
            applySnapshot(screen: screen)
            reconcileSelectionWithSearch()
            return
        }
        scheduleHiddenApply()
    }

    private func scheduleHiddenApply() {
        guard !hiddenApplyScheduled else { return }
        hiddenApplyScheduled = true
        let now = ProcessInfo.processInfo.systemUptime
        let delay = max(Self.hiddenBurstDelay, lastHiddenApply + Self.hiddenCoalescingInterval - now)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.hiddenApplyScheduled = false
            guard self.snapshotDirty, !self.isShown, !NSApp.isHidden,
                  let screen = self.panel.screen ?? NSScreen.pointerScreen else { return }
            let started = ProcessInfo.processInfo.systemUptime
            self.lastHiddenApply = started
            self.applySnapshot(screen: screen)
            if RuntimeDiagnostics.isEnabled {
                RuntimeDiagnostics.mark("desktop hiddenOverviewDiffMilliseconds=\((ProcessInfo.processInfo.systemUptime - started) * 1000) cards=\(self.grid.cards.count)")
            }
            // Render the first real set of cards once, so the first open does not pay for it.
            if !self.warmedWithCards, !self.grid.cards.isEmpty {
                self.warmedWithCards = true
                self.prewarm()
                self.onFirstCards?()
            }
        }
    }

    // MARK: Content

    private func applySnapshot(screen: NSScreen) {
        guard let service else { return }
        snapshotDirty = false
        applyCount += 1
        slots.reconcile(service.snapshot.records)
        saveSlots()
        if screen.visibleFrame != appliedScreenFrame {
            appliedScreenFrame = screen.visibleFrame
            if isShown { placeFilling(screen) }
            else if panel.contentRect(forFrameRect: panel.frame).size != Self.contentSize(for: screen.visibleFrame) {
                panel.setContentSize(Self.contentSize(for: screen.visibleFrame))
                layoutChrome()
            }
        }
        applySlots()
        if !isShown, !shownSlots.contains(where: { $0.id == selectedSlot && $0.binding != nil }) {
            selectedSlot = shownSlots.first(where: { $0.binding != nil })?.id
        }
    }

    /// Columns and card height for the grid column width.
    private func gridLayout(width: CGFloat, visibleFrame: NSRect) -> CardGrid.Layout {
        let usable = width - 2 * gridInset
        let gap = PanefloStyle.Overview.gridGap
        let columns = min(PanefloStyle.Overview.maxColumns, max(PanefloStyle.Overview.minColumns,
                          Int(((usable + gap) / (PanefloStyle.Overview.minCardWidth + gap)).rounded(.down))))
        let cardWidth = ((usable - CGFloat(columns - 1) * gap) / CGFloat(columns)).rounded(.down)
        let viewport = max(200, scroll.bounds.height - 2 * gridInset)
        let cap = min(Self.cardHeight(for: visibleFrame), ((viewport - 2 * gap) / 3).rounded(.down))
        return .overview(columns: columns, cardHeight: max(120, min(CardStyle.overviewHeight(forWidth: cardWidth), cap)), inset: gridInset)
    }

    /// Diffs the cards against the slot order. Reuses views; moves only what moved.
    private func applySlots() {
        guard let service else { return }
        let records = Dictionary(service.snapshot.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let frame = appliedScreenFrame ?? layoutScreen?.visibleFrame ?? .zero
        let offset = wantsHomeTile ? 1 : 0
        tileOffset = offset
        showsFreeSlots = host?.preferences.showsFreeSlots ?? true
        shownSlots = showsFreeSlots ? slots.slots : slots.slots.filter { !OverviewSlotStore.isFree($0) }
        if offset == 0, selectedTarget == .desktop { setSelectedTarget(nil) }
        if scroll.bounds.width < 1 { layoutChrome() }
        grid.layout = gridLayout(width: scroll.bounds.width, visibleFrame: frame)
        let query = search.stringValue
        appliedQuery = query
        let matching = slots.matches(query: query, records: service.snapshot.records)
        homeTileMatches = SwitcherSession.desktopMatches(query)
        let slotList = shownSlots
        let selected = selectedID
        let tileMatches = homeTileMatches
        let keys = (offset == 1 ? [AnyHashable(SwitchTarget.desktop)] : []) + slotList.map { AnyHashable($0.id) }
        grid.apply(keys: keys) { card, index in
            card.style = .overview
            card.hoverEnabled = true
            guard index >= offset else { configureDesktopCard(card, matches: tileMatches); return }
            let slot = slotList[index - offset]
            let record = slot.binding.flatMap { records[$0] }
            card.isDesktopEntry = false
            card.record = record
            card.icon = record.flatMap { host?.icon(for: $0) }
            if record == nil {
                if let rule = slot.matchingRule, slot.isPinned {
                    card.vacancy = .kept(appName: host?.appName(forApp: rule.appIdentifier))
                    card.vacancyIcon = host?.icon(forApp: rule.appIdentifier)
                } else {
                    card.vacancy = slot.isPinned ? .kept(appName: nil) : .free
                    card.vacancyIcon = nil
                }
            } else {
                card.vacancy = nil
                card.vacancyIcon = nil
            }
            card.isPinned = slot.isPinned
            card.dragEnabled = true
            card.layoutBadge = record.flatMap { layoutFeedback[$0.id] }
            card.selected = record != nil && record?.id == selected
            let matches = record == nil ? query.isEmpty : matching.contains(slot.id)
            card.matches = matches
            card.setEnabledIfChanged(matches || (record == nil && query.isEmpty))
        }
        indexCards((offset == 1 ? [nil] : []) + slotList.map { slot in slot.binding.flatMap { records[$0] != nil ? $0 : nil } },
                   desktopIndex: offset == 1 ? 0 : nil)
        eligibleCache = nil
        updateCount(records: records)
        if slotList.isEmpty {
            grid.showEmpty(service.hasAccessibility ? "No eligible windows found. Open a normal application window, then refresh."
                : "Your windows will appear here after Accessibility access is enabled.")
        } else { grid.showEmpty(nil) }
        refreshPairs()
        applyScrollFade(grid.contentHeight > scroll.bounds.height + 1, fade: PanefloStyle.Overview.scrollFade)
    }

    private func updateCount(records: [WindowIdentity: WindowRecord]) {
        let windows = shownSlots.filter { $0.binding.map { records[$0] != nil } ?? false }.count
        let free = shownSlots.filter(OverviewSlotStore.isFree).count
        var text = windows == 1 ? "1 window" : "\(windows) windows"
        if free > 0 { text += free == 1 ? " · 1 free slot" : " · \(free) free slots" }
        if countLabel.stringValue != text { countLabel.stringValue = text }
    }

    /// Search dims cards in place; slot order and bindings never change.
    private func updateMatches() {
        guard let service else { return }
        let query = search.stringValue
        appliedQuery = query
        eligibleCache = nil
        let matching = slots.matches(query: query, records: service.snapshot.records)
        homeTileMatches = SwitcherSession.desktopMatches(query)
        if let desktopCard { desktopCard.matches = homeTileMatches; desktopCard.setEnabledIfChanged(homeTileMatches) }
        for (index, card) in grid.cards.enumerated() where shownSlots.indices.contains(index - tileOffset) {
            let matches = card.record == nil ? query.isEmpty : matching.contains(shownSlots[index - tileOffset].id)
            card.matches = matches
            card.setEnabledIfChanged(matches || (card.record == nil && query.isEmpty))
        }
        invalidatePreviewCandidates()
    }

    private func saveSlots() {
        if let metadata = try? slots.encodedMetadata(), metadata != lastSavedMetadata {
            defaults.set(metadata, forKey: "overview.slots.v1"); lastSavedMetadata = metadata
        }
    }

    override func makeCard() -> CardView {
        let card = super.makeCard()
        card.onDragMove = { [weak self] index, point in self?.dragMoved(from: index, at: point) }
        card.onDragEnd = { [weak self] index, point in self?.dragEnded(from: index, at: point) }
        card.menuProvider = { [weak self] card in self?.menu(for: card) }
        return card
    }

    private func menuItem(_ title: String, _ symbol: String, _ action: Selector, _ slot: UUID) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.target = self; item.representedObject = slot.uuidString
        return item
    }

    private func menu(for card: CardView) -> NSMenu? {
        guard !card.isDesktopEntry, shownSlots.indices.contains(card.tag - tileOffset) else { return nil }
        let slot = shownSlots[card.tag - tileOffset]
        let menu = NSMenu()
        guard card.record != nil else {
            if slot.isPinned {
                menu.addItem(menuItem("Unpin Slot", "pin.slash", #selector(togglePin(_:)), slot.id))
                menu.addItem(menuItem("Remove Slot", "minus.circle", #selector(removeSlot(_:)), slot.id))
            } else {
                menu.addItem(menuItem("Remove Free Slot", "minus.circle", #selector(removeSlot(_:)), slot.id))
            }
            return menu
        }
        menu.addItem(menuItem("Open", "macwindow", #selector(openSlot(_:)), slot.id))
        if let id = card.record?.id { appendPairItems(to: menu, for: id) }
        menu.addItem(.separator())
        menu.addItem(menuItem("Tile Left", "rectangle.lefthalf.filled", #selector(tileLeft(_:)), slot.id))
        menu.addItem(menuItem("Tile Right", "rectangle.righthalf.filled", #selector(tileRight(_:)), slot.id))
        menu.addItem(menuItem("Fill Display", "rectangle.fill", #selector(fillDisplay(_:)), slot.id))
        menu.addItem(.separator())
        menu.addItem(menuItem(slot.isPinned ? "Unpin Slot" : "Pin Slot", slot.isPinned ? "pin.slash" : "pin", #selector(togglePin(_:)), slot.id))
        menu.addItem(menuItem("Move Slot Left", "arrow.left", #selector(moveLeft(_:)), slot.id))
        menu.addItem(menuItem("Move Slot Right", "arrow.right", #selector(moveRight(_:)), slot.id))
        return menu
    }

    // MARK: Selection

    override func eligibleSelectionIDs() -> [WindowIdentity] {
        if let eligibleCache { return eligibleCache }
        let shown = Set(shownSlots.map(\.id))
        var ids: [WindowIdentity] = []
        if let service {
            let matching = slots.matches(query: search.stringValue, records: service.snapshot.records)
            ids = slots.slots.filter { shown.contains($0.id) && matching.contains($0.id) }.compactMap(\.binding)
        }
        eligibleCache = ids
        return ids
    }

    override var isDesktopEligible: Bool { tileOffset == 1 && homeTileMatches }

    /// Selectable targets in grid order: the home tile (when it matches), then matching bound slots.
    private func eligibleTargets() -> [SwitchTarget] {
        (isDesktopEligible ? [.desktop] : []) + eligibleSelectionIDs().map(SwitchTarget.window)
    }

    /// The remembered slot follows window selections; the home tile or no selection clears it, so the next
    /// presentation starts on the first window.
    private func selectTarget(_ target: SwitchTarget?) {
        let id = target?.windowID
        selectedSlot = id.flatMap { id in slots.slots.first(where: { $0.binding == id })?.id }
        select(target: target)
    }

    private func selectWindow(_ id: WindowIdentity?) { selectTarget(id.map(SwitchTarget.window)) }

    private func reconcileSelectionWithSearch() {
        guard let selectedTarget, isEligible(selectedTarget) else {
            // Prefer a window; the home tile when it is the only match (for example "desktop").
            selectTarget(eligibleSelectionIDs().first.map(SwitchTarget.window) ?? (isDesktopEligible ? .desktop : nil))
            return
        }
        select(target: selectedTarget)
    }

    override func navigate(_ direction: CycleDirection) {
        guard isShown else { return }
        let eligible = eligibleTargets()
        if let current = selectedTarget, let index = eligible.firstIndex(of: current), !eligible.isEmpty {
            selectTarget(eligible[(index + (direction == .forward ? 1 : eligible.count - 1)) % eligible.count])
        } else {
            selectTarget(direction == .forward ? eligible.first : eligible.last)
        }
    }

    override func navigateRows(_ delta: Int) {
        guard isShown else { return }
        let positions: [SwitchTarget?] = (tileOffset == 1 ? [.desktop] : []) + slotBindings.map { $0.map(SwitchTarget.window) }
        let eligible = Set(eligibleTargets())
        let indices = positions.indices.filter { positions[$0].map(eligible.contains) ?? false }
        let current = positions.firstIndex(where: { $0 != nil && $0 == selectedTarget })
        if let next = GridNavigation.vertical(from: current, columns: grid.columns, count: positions.count, eligible: indices, direction: delta) {
            selectTarget(positions[next])
        }
    }

    override func searchChanged() {
        updateMatches()
        reconcileSelectionWithSearch()
    }

    override func cardSelected(_ card: CardView) {
        if card.isDesktopEntry { select(target: .desktop); return }
        guard shownSlots.indices.contains(card.tag - tileOffset) else { return }
        // A click on a free slot selects nothing (free slots are reached by mouse for drops and their menu only).
        guard let id = card.record?.id else { return }
        selectedSlot = shownSlots[card.tag - tileOffset].id
        select(id)
    }

    // MARK: Slot editing

    private func reapply(selecting id: WindowIdentity?) {
        saveSlots(); applySlots()
        if let id { selectWindow(id) } else { select(selectedID) }
    }

    private func moveSlot(by delta: Int) {
        guard let selectedSlot, let index = slots.slots.firstIndex(where: { $0.id == selectedSlot }) else { return }
        slots.move(slotID: selectedSlot, to: index + delta)
        reapply(selecting: nil)
    }

    /// The card under a window point, or nil over empty space.
    private func card(at point: NSPoint) -> CardView? {
        grid.cards.first { $0.convert($0.bounds, to: nil).contains(point) }
    }

    private func dragMoved(from cardIndex: Int, at point: NSPoint) {
        guard grid.cards.indices.contains(cardIndex) else { return }
        let origin = grid.cards[cardIndex]
        origin.isDragOrigin = true
        let target = card(at: point).flatMap { $0 === origin ? nil : $0 }
        if dropTarget !== target {
            dropTarget?.isDropTarget = false
            target?.isDropTarget = true
            dropTarget = target
        }
        moveGhost(of: origin, to: point)
    }

    private func dragEnded(from cardIndex: Int, at point: NSPoint) {
        let target = dropTarget
        dropTarget?.isDropTarget = false
        dropTarget = nil
        dragGhost?.removeFromSuperlayer()
        dragGhost = nil
        if grid.cards.indices.contains(cardIndex) { grid.cards[cardIndex].isDragOrigin = false }
        let index = cardIndex - tileOffset
        guard shownSlots.indices.contains(index), let target else { return }
        let source = shownSlots[index]
        selectedSlot = source.id
        if target.isDesktopEntry {
            // Dropping on the home tile moves the slot to the front; the tile itself never moves.
            slots.move(slotID: source.id, to: 0)
        } else if shownSlots.indices.contains(target.tag - tileOffset) {
            let destination = shownSlots[target.tag - tileOffset]
            if destination.binding == nil { slots.place(slotID: source.id, into: destination.id) }
            else { slots.swap(source.id, destination.id) }
        }
        reapply(selecting: source.binding)
    }

    /// A floating copy of the dragged card follows the pointer (lifted slightly unless Reduce Motion is on).
    private func moveGhost(of card: CardView, to point: NSPoint) {
        guard let root = panel.contentView, let rootLayer = root.layer else { return }
        let ghost: CALayer
        if let dragGhost { ghost = dragGhost } else {
            ghost = CALayer()
            ghost.actions = GlyphLayer.noActions
            ghost.bounds = CGRect(origin: .zero, size: card.bounds.size)
            ghost.cornerRadius = PanefloStyle.Radius.overviewCard
            ghost.cornerCurve = .continuous
            ghost.backgroundColor = PanefloStyle.cgColor(NSColor.windowBackgroundColor.withAlphaComponent(0.92), for: root.effectiveAppearance)
            ghost.shadowColor = NSColor.black.cgColor
            ghost.shadowOpacity = 0.30
            ghost.shadowRadius = 18
            ghost.shadowOffset = CGSize(width: 0, height: -8)
            ghost.opacity = 0.95
            let image = CALayer()
            image.actions = GlyphLayer.noActions
            let well = card.previewRect
            image.frame = CGRect(x: well.minX, y: card.bounds.height - well.maxY, width: well.width, height: well.height)
            image.contentsGravity = .resizeAspect
            image.contents = card.chrome.preview.contents ?? card.chrome.icon.contents
            image.cornerRadius = PanefloStyle.Radius.well
            image.masksToBounds = true
            ghost.addSublayer(image)
            if !PanefloStyle.Accessibility.current.reduceMotion { ghost.setAffineTransform(CGAffineTransform(scaleX: 1.04, y: 1.04)) }
            rootLayer.addSublayer(ghost)
            dragGhost = ghost
        }
        PanefloStyle.withoutAnimation { ghost.position = root.convert(point, from: nil) }
    }

    private func slot(from sender: NSMenuItem?) -> OverviewSlot? {
        guard let text = sender?.representedObject as? String, let id = UUID(uuidString: text) else { return nil }
        return slots.slots.first { $0.id == id }
    }

    private func selectMenuSlot(_ sender: NSMenuItem?) {
        guard let slot = slot(from: sender) else { return }
        selectedSlot = slot.id
        if let binding = slot.binding { select(binding, notify: false) }
    }

    @objc private func openSlot(_ sender: NSMenuItem?) { selectMenuSlot(sender); activateSelected() }
    @objc private func tileLeft(_ sender: NSMenuItem?) { selectMenuSlot(sender); host?.surfaceTile(.leftHalf) }
    @objc private func tileRight(_ sender: NSMenuItem?) { selectMenuSlot(sender); host?.surfaceTile(.rightHalf) }
    @objc private func fillDisplay(_ sender: NSMenuItem?) { selectMenuSlot(sender); host?.surfaceTile(.maximize) }
    @objc private func moveLeft(_ sender: NSMenuItem?) { selectMenuSlot(sender); moveSlot(by: -1) }
    @objc private func moveRight(_ sender: NSMenuItem?) { selectMenuSlot(sender); moveSlot(by: 1) }
    @objc private func togglePin(_ sender: NSMenuItem?) {
        guard let slot = slot(from: sender) else { return }
        if slot.binding != nil { selectMenuSlot(sender) }
        if slot.isPinned { slots.unpin(slotID: slot.id) }
        else {
            let record = service?.snapshot.records.first { $0.id == slot.binding }
            slots.pin(slotID: slot.id, matchingRule: record.map { SlotMatchingRule(appIdentifier: $0.appIdentifier) })
        }
        reapply(selecting: nil)
    }
    @objc private func removeSlot(_ sender: NSMenuItem?) {
        guard let slot = slot(from: sender) else { return }
        slots.remove(slotID: slot.id)
        reapply(selecting: nil)
    }

    /// Removes every free slot (Settings). Kept slots stay.
    @discardableResult
    func removeFreeSlots() -> Int {
        let removed = slots.removeFreeSlots()
        if removed > 0 { snapshotDirty = true; saveSlots(); if isShown { reapply(selecting: nil) } }
        return removed
    }

    /// Clears slots and pins and places the current windows in order (Settings, after confirmation).
    func resetSlots() {
        slots.reset(service?.snapshot.orderedRecords ?? [])
        selectedSlot = nil
        snapshotDirty = true
        saveSlots()
        if isShown { reapply(selecting: nil) }
    }

    #if PANEFLO_NATIVE_CHECK
    var nativeCheckCountText: String { countLabel.stringValue }
    var nativeCheckSlotStore: OverviewSlotStore { slots }
    func nativeCheckDrag(from source: CardView, to target: CardView) {
        let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        dragMoved(from: source.tag, at: point)
        dragEnded(from: source.tag, at: point)
    }
    var nativeCheckScrimVisible: Bool { !scrim.isHidden }
    var nativeCheckOpaqueBackdropVisible: Bool { !opaqueBackdrop.isHidden }
    func nativeCheckRefreshBackdrop() { applyBackdropAppearance() }
    #endif
}
