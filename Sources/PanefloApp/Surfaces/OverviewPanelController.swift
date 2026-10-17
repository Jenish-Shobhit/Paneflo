import AppKit
import PanefloCore

/// Paneflo's organized Overview: user-ordered slots in a dedicated, pre-sized,
/// non-activating key panel. Registry changes while hidden are coalesced (at most one
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
        guard let screen = panel.screen ?? NSScreen.main else { return }
        beginPresentation()
        if !search.stringValue.isEmpty { search.stringValue = "" }
        if screen.visibleFrame != appliedScreenFrame { snapshotDirty = true }
        if snapshotDirty { applySnapshot(screen: screen) }
        if appliedQuery != search.stringValue { updateMatches() }
        if !slots.slots.contains(where: { $0.id == selectedSlot && $0.binding != nil }) {
            selectedSlot = slots.slots.first(where: { $0.binding != nil })?.id
        }
        select(slots.slots.first(where: { $0.id == selectedSlot })?.binding, notify: false)
        place(contentSize: Self.contentSize(for: screen.visibleFrame), on: screen)
        orderFront(searchFocused: true)
        if let id = selectedID, let card = cardsByWindow[id] { revealCard(card) }
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
            guard let screen = panel.screen ?? NSScreen.main else { return }
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
                  let screen = self.panel.screen ?? NSScreen.main else { return }
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
        let frame = appliedScreenFrame ?? (panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        grid.metrics = .init(columns: Self.columns(for: slots.slots.count, screenWidth: frame.width), cardHeight: Self.cardHeight(for: frame))
        let query = search.stringValue
        appliedQuery = query
        let matching = slots.matches(query: query, records: service.snapshot.records)
        let slotList = slots.slots
        let selected = selectedID
        grid.apply(keys: slotList.map { AnyHashable($0.id) }) { card, index in
            let slot = slotList[index]
            let record = slot.binding.flatMap { records[$0] }
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
        indexCards(slotList.map { slot in slot.binding.flatMap { records[$0] != nil ? $0 : nil } })
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
        for (index, card) in grid.cards.enumerated() where slots.slots.indices.contains(index) {
            let matches = matching.contains(slots.slots[index].id)
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
        guard slots.slots.indices.contains(card.tag) else { return nil }
        let slot = slots.slots[card.tag]
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

    private func selectWindow(_ id: WindowIdentity?) {
        selectedSlot = slots.slots.first(where: { $0.binding == id && $0.binding != nil })?.id
        select(id)
    }

    private func reconcileSelectionWithSearch() {
        let eligible = eligibleSelectionIDs()
        if selectedID.map({ eligible.contains($0) }) != true { selectWindow(eligible.first) }
        else { select(selectedID) }
    }

    override func navigate(_ direction: CycleDirection) {
        guard isShown else { return }
        let eligible = eligibleSelectionIDs()
        if let current = selectedID, let index = eligible.firstIndex(of: current), !eligible.isEmpty {
            selectWindow(eligible[(index + (direction == .forward ? 1 : eligible.count - 1)) % eligible.count])
        } else {
            selectWindow(direction == .forward ? eligible.first : eligible.last)
        }
    }

    override func navigateRows(_ delta: Int) {
        guard isShown else { return }
        let bindings = slotBindings
        let eligible = Set(eligibleSelectionIDs())
        let indices = bindings.indices.filter { bindings[$0].map { eligible.contains($0) } ?? false }
        let current = bindings.firstIndex(where: { $0 != nil && $0 == selectedID })
        if let next = GridNavigation.vertical(from: current, columns: grid.metrics.columns, count: bindings.count, eligible: indices, direction: delta) {
            selectWindow(bindings[next])
        }
    }

    override func searchChanged() {
        updateMatches()
        reconcileSelectionWithSearch()
    }

    override func cardSelected(_ card: CardView) {
        guard slots.slots.indices.contains(card.tag) else { return }
        selectedSlot = slots.slots[card.tag].id
        select(card.record?.id)
    }

    // MARK: Slot editing

    private func moveSlot(by delta: Int) {
        guard let selectedSlot, let index = slots.slots.firstIndex(where: { $0.id == selectedSlot }) else { return }
        slots.move(slotID: selectedSlot, to: index + delta); saveSlots(); applySlots(); select(selectedID)
    }

    private func moveDraggedSlot(from index: Int, at point: NSPoint) {
        guard slots.slots.indices.contains(index), !grid.cards.isEmpty else { return }
        let target = grid.cards.indices.min { a, b in
            let ar = grid.cards[a].convert(grid.cards[a].bounds, to: nil), br = grid.cards[b].convert(grid.cards[b].bounds, to: nil)
            return hypot(ar.midX - point.x, ar.midY - point.y) < hypot(br.midX - point.x, br.midY - point.y)
        }!
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
