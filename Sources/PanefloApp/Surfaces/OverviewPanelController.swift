import AppKit
import PanefloCore

/// Paneflo's organized Overview: an optional Desktop home tile, then user-ordered slots in a
/// dedicated, pre-sized, non-activating key panel. The home tile sits outside the slot store, so
/// slot order, pins and bindings are unaffected by it. Registry changes while hidden are coalesced (at most one
/// diff per second, and any pending change is applied on open); a dismissal never rebuilds.
@MainActor
final class OverviewPanelController: SurfacePanelController {
    static let hiddenCoalescingInterval: TimeInterval = 1.0
    static let hiddenBurstDelay: TimeInterval = 0.3
    private var slots = OverviewSlotStore()
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

    override var linearArrowsLeaveSearch: Bool { true }

    init() {
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        super.init(contentSize: OverviewPanelController.contentSize(for: frame))
        if let data = defaults.data(forKey: "overview.slots.v1"), let stored = try? OverviewSlotStore(metadata: data) { slots = stored }
        heading.stringValue = "Your overview"
        keyboardHint.stringValue = "arrows select   ⌘⌥← → tile   ⌘⌥↑ fill   ⌘⌥↓ undo   return open   esc close"
    }

    static func contentSize(for visibleFrame: NSRect) -> NSSize {
        let usable = visibleFrame.insetBy(dx: 16, dy: 16)
        let viewport = min(usable.height * 0.9 - 128, max(80, usable.height - 145))
        return NSSize(width: usable.width * 0.92, height: min(viewport + 128, usable.height))
    }

    static func cardHeight(for visibleFrame: NSRect) -> CGFloat {
        max(174, min(280, (visibleFrame.height * 0.9 - 160) / 3))
    }

    var slotBindings: [WindowIdentity?] { slots.slots.map(\.binding) }

    // MARK: Presentation

    func present() {
        guard let screen = NSScreen.pointerScreen else { return }
        beginPresentation()
        if !search.stringValue.isEmpty { search.stringValue = "" }
        if screen.visibleFrame != appliedScreenFrame || wantsHomeTile != (tileOffset == 1) { snapshotDirty = true }
        if snapshotDirty { applySnapshot(screen: screen) }
        if appliedQuery != search.stringValue { updateMatches() }
        if !slots.slots.contains(where: { $0.id == selectedSlot && $0.binding != nil }) {
            selectedSlot = slots.slots.first(where: { $0.binding != nil })?.id
        }
        // A window is selected first; the home tile is the selection only when no window is bound.
        if let binding = slots.slots.first(where: { $0.id == selectedSlot })?.binding {
            select(binding, notify: false)
        } else {
            select(target: tileOffset == 1 ? .desktop : nil, notify: false)
        }
        place(contentSize: Self.contentSize(for: screen.visibleFrame), on: screen)
        orderFront(searchFocused: true)
        if let target = selectedTarget, let card = card(for: target) { revealCard(card) }
        showDesktopWallpaper()
    }

    private var wantsHomeTile: Bool { host?.showsDesktopHomeTile ?? false }

    override func screenParametersChanged(to screen: NSScreen) {
        appliedScreenFrame = nil
        snapshotDirty = true
        eligibleCache = nil
        if isShown {
            applySnapshot(screen: screen)
            reconcileSelectionWithSearch()
        } else {
            // Size the pre-warmed panel for the new display and draw it once more off the input path.
            place(contentSize: Self.contentSize(for: screen.visibleFrame), on: screen)
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
            // Draw the first real set of cards once, so the first open does not pay for it.
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
        if !isShown, !slots.slots.contains(where: { $0.id == selectedSlot && $0.binding != nil }) {
            selectedSlot = slots.slots.first(where: { $0.binding != nil })?.id
        }
        if screen.visibleFrame != appliedScreenFrame {
            appliedScreenFrame = screen.visibleFrame
            if isShown { place(contentSize: Self.contentSize(for: screen.visibleFrame), on: screen) }
            else if panel.contentRect(forFrameRect: panel.frame).size != Self.contentSize(for: screen.visibleFrame) {
                panel.setContentSize(Self.contentSize(for: screen.visibleFrame))
            }
        }
        applySlots()
    }

    /// Diffs the cards against the slot order. Reuses views; moves only what moved.
    private func applySlots() {
        guard let service else { return }
        let records = Dictionary(service.snapshot.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let frame = appliedScreenFrame ?? layoutScreen?.visibleFrame ?? .zero
        let offset = wantsHomeTile ? 1 : 0
        tileOffset = offset
        if offset == 0, selectedTarget == .desktop { setSelectedTarget(nil) }
        grid.metrics = .init(columns: Self.columns(for: slots.slots.count + offset, screenWidth: frame.width), cardHeight: Self.cardHeight(for: frame))
        let query = search.stringValue
        appliedQuery = query
        let matching = slots.matches(query: query, records: service.snapshot.records)
        homeTileMatches = SwitcherSession.desktopMatches(query)
        let slotList = slots.slots
        let selected = selectedID
        let tileMatches = homeTileMatches
        let keys = (offset == 1 ? [AnyHashable(SwitchTarget.desktop)] : []) + slotList.map { AnyHashable($0.id) }
        grid.apply(keys: keys) { card, index in
            guard index >= offset else { configureDesktopCard(card, matches: tileMatches); return }
            let slot = slotList[index - offset]
            let record = slot.binding.flatMap { records[$0] }
            card.isDesktopEntry = false
            card.record = record
            card.icon = record.flatMap { host?.icon(for: $0) }
            card.isVacancyPinned = slot.isPinned
            card.dragEnabled = true
            card.layoutBadge = record.flatMap { layoutFeedback[$0.id] }
            card.selected = record != nil && record?.id == selected
            let matches = matching.contains(slot.id)
            card.matches = matches
            card.setEnabledIfChanged(matches || (record == nil && query.isEmpty))
        }
        indexCards((offset == 1 ? [nil] : []) + slotList.map { slot in slot.binding.flatMap { records[$0] != nil ? $0 : nil } },
                   desktopIndex: offset == 1 ? 0 : nil)
        eligibleCache = nil
        if slotList.isEmpty {
            grid.showEmpty(service.hasAccessibility ? "No eligible windows found. Open a normal application window, then refresh."
                : "Your windows will appear here after Accessibility access is enabled.")
        } else { grid.showEmpty(nil) }
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
        for (index, card) in grid.cards.enumerated() where slots.slots.indices.contains(index - tileOffset) {
            let matches = matching.contains(slots.slots[index - tileOffset].id)
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
        card.onDragEnd = { [weak self] index, point in self?.moveDraggedSlot(from: index, at: point) }
        card.menuProvider = { [weak self] card in self?.menu(for: card) }
        return card
    }

    private func menu(for card: CardView) -> NSMenu? {
        guard !card.isDesktopEntry, slots.slots.indices.contains(card.tag - tileOffset) else { return nil }
        let slot = slots.slots[card.tag - tileOffset]
        let menu = NSMenu()
        for (title, action) in [("Move slot left", #selector(moveLeft(_:))), ("Move slot right", #selector(moveRight(_:))),
                                (slot.isPinned ? "Unpin slot" : "Pin slot", #selector(togglePin(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.representedObject = slot.id.uuidString
            menu.addItem(item)
        }
        return menu
    }

    // MARK: Selection

    override func eligibleSelectionIDs() -> [WindowIdentity] {
        if let eligibleCache { return eligibleCache }
        let ids = service.map { slots.matchingWindowIDs(query: search.stringValue, records: $0.snapshot.records) } ?? []
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
        if let next = GridNavigation.vertical(from: current, columns: grid.metrics.columns, count: positions.count, eligible: indices, direction: delta) {
            selectTarget(positions[next])
        }
    }

    override func searchChanged() {
        updateMatches()
        reconcileSelectionWithSearch()
    }

    override func cardSelected(_ card: CardView) {
        if card.isDesktopEntry { select(target: .desktop); return }
        guard slots.slots.indices.contains(card.tag - tileOffset) else { return }
        selectedSlot = slots.slots[card.tag - tileOffset].id
        select(card.record?.id)
    }

    // MARK: Slot editing

    private func moveSlot(by delta: Int) {
        guard let selectedSlot, let index = slots.slots.firstIndex(where: { $0.id == selectedSlot }) else { return }
        slots.move(slotID: selectedSlot, to: index + delta); saveSlots(); applySlots(); select(selectedID)
    }

    private func moveDraggedSlot(from cardIndex: Int, at point: NSPoint) {
        let index = cardIndex - tileOffset
        guard slots.slots.indices.contains(index), !grid.cards.isEmpty else { return }
        let nearest = grid.cards.indices.min { a, b in
            let ar = grid.cards[a].convert(grid.cards[a].bounds, to: nil), br = grid.cards[b].convert(grid.cards[b].bounds, to: nil)
            return hypot(ar.midX - point.x, ar.midY - point.y) < hypot(br.midX - point.x, br.midY - point.y)
        }!
        // Dropping on the home tile moves the slot to the front; the tile itself never moves.
        let target = max(0, nearest - tileOffset)
        let id = slots.slots[index].id
        selectedSlot = id
        setSelectedID(slots.slots[index].binding)
        slots.move(slotID: id, to: target); saveSlots(); applySlots(); select(selectedID)
    }

    private func selectMenuSlot(_ sender: NSMenuItem?) {
        if let text = sender?.representedObject as? String, let id = UUID(uuidString: text) {
            selectedSlot = id
            select(slots.slots.first { $0.id == id }?.binding, notify: false)
        }
    }

    @objc private func moveLeft(_ sender: NSMenuItem?) { selectMenuSlot(sender); moveSlot(by: -1) }
    @objc private func moveRight(_ sender: NSMenuItem?) { selectMenuSlot(sender); moveSlot(by: 1) }
    @objc private func togglePin(_ sender: NSMenuItem?) {
        selectMenuSlot(sender)
        guard let slot = slots.slots.first(where: { $0.id == selectedSlot }) else { return }
        if slot.isPinned { slots.unpin(slotID: slot.id) }
        else {
            let record = service?.snapshot.records.first { $0.id == slot.binding }
            slots.pin(slotID: slot.id, matchingRule: record.map { SlotMatchingRule(appIdentifier: $0.appIdentifier) })
        }
        saveSlots(); applySlots(); select(selectedID)
    }
}
