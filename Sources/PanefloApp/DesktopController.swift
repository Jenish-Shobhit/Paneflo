import AppKit
import PanefloCore

@MainActor
enum DesktopMode: Int { case switcher, tiling, overview }

@MainActor
private final class FlippedDesktopDocument: NSView { override var isFlipped: Bool { true } }

@MainActor
private final class DesktopPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
}

/// Native presentation reads prepared snapshots. It never makes remote AX or capture calls.
@MainActor
final class DesktopController: NSObject, NSSearchFieldDelegate, NSWindowDelegate {
    private let service: WindowService
    private let panel = DesktopPanel(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 780), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
    private let modes = NSSegmentedControl(labels: ["Switch", "Arrange", "Overview"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    private let grid = NSStackView()
    private let scroll = NSScrollView()
    private let permissionBar = NSStackView()
    private let shortcutButton = NSButton(checkboxWithTitle: "Enable Paneflo shortcuts", target: nil, action: nil)
    private let previewButton = NSButton(checkboxWithTitle: "Live previews", target: nil, action: nil)
    private let zone = NSPopUpButton(frame: .zero, pullsDown: false)
    private let display = NSPopUpButton(frame: .zero, pullsDown: false)
    private let overviewBar = NSStackView()
    private let pinButton = NSButton(title: "Pin slot", target: nil, action: nil)
    private let activateButton = NSButton(title: "Activate window", target: nil, action: nil)
    private var cards: [DesktopCard] = []
    private var displayed: [WindowIdentity?] = []
    private var iconCache: [String: NSImage] = [:]
    private var session = SwitcherSession(snapshot: WindowSnapshot(records: []))
    private var slots = OverviewSlotStore()
    private var selectedSlot: UUID?
    private var selectedID: WindowIdentity?
    private var mode = DesktopMode.switcher
    private var shortcutSession = false
    private var building = false
    private let defaults = UserDefaults.standard
    private var lastSavedMetadata: Data?
    var onToggleShortcuts: ((Bool) -> Void)?
    var onTogglePreviews: ((Bool) -> Void)?
    var onPreviewSelection: ((UInt32?, Bool, pid_t?) -> Void)?
    var onDismiss: (() -> Void)?
    var isVisible: Bool { panel.isVisible }
    private let zones: [(String, LayoutZone)] = [
        ("Left half", .leftHalf), ("Right half", .rightHalf), ("Top half", .topHalf), ("Bottom half", .bottomHalf),
        ("First third", .firstThird), ("Middle third", .middleThird), ("Last third", .lastThird),
        ("Top left", .topLeftQuarter), ("Top right", .topRightQuarter), ("Bottom left", .bottomLeftQuarter), ("Bottom right", .bottomRightQuarter),
        ("Center", .center), ("Maximize", .maximize),
    ]

    init(service: WindowService) {
        self.service = service
        if let data = defaults.data(forKey: "overview.slots.v1"), let stored = try? OverviewSlotStore(metadata: data) { slots = stored }
        super.init()
        configure()
        updateSnapshot()
    }

    func present(mode: DesktopMode, fromShortcut: Bool = false, backwards: Bool = false) {
        self.mode = mode
        shortcutSession = fromShortcut && mode == .switcher
        search.stringValue = ""
        if mode == .switcher {
            session = SwitcherSession(snapshot: service.snapshot, direction: backwards ? .backward : .forward)
            selectedID = session.selectedID
        } else if mode == .overview {
            if selectedSlot == nil { selectedSlot = slots.slots.first(where: { $0.binding != nil })?.id }
            selectedID = slots.slots.first(where: { $0.id == selectedSlot })?.binding
        } else { selectedID = service.focusedID ?? service.snapshot.orderedRecords.first?.id }
        rebuildCards()
        panel.center()
        fitToVisibleScreen()
        panel.makeKeyAndOrderFront(nil)
        if !fromShortcut { panel.makeFirstResponder(search) }
        RuntimeDiagnostics.mark("desktop mode=\(mode.rawValue) visible=\(panel.isVisible)")
        updatePreviewSelection()
    }

    func switchStep(backwards: Bool) {
        if !panel.isVisible || mode != .switcher || !shortcutSession { present(mode: .switcher, fromShortcut: true, backwards: backwards) }
        else { session.advance(backwards ? .backward : .forward); selectedID = session.selectedID; refreshSelection() }
    }

    func navigate(_ direction: CycleDirection) {
        if mode == .switcher { session.advance(direction); selectedID = session.selectedID }
        else {
            let eligible = eligibleSelectionIDs()
            if let selectedID, let index = eligible.firstIndex(of: selectedID), !eligible.isEmpty {
                self.selectedID = eligible[(index + (direction == .forward ? 1 : eligible.count - 1)) % eligible.count]
                selectedSlot = slots.slots.first(where: { $0.binding == self.selectedID })?.id
            } else {
                selectedID = direction == .forward ? eligible.first : eligible.last
                selectedSlot = slots.slots.first(where: { $0.binding == selectedID })?.id
            }
        }
        refreshSelection()
    }

    func commitShortcut() { if shortcutSession { activateSelected() } }
    func dismiss() {
        session.cancel(); shortcutSession = false
        panel.orderOut(nil)
        for card in cards { card.preview = nil; card.previewLabel = "Icon preview" }
        onPreviewSelection?(nil, false, nil); onDismiss?()
    }

    func updateSnapshot() {
        slots.reconcile(service.snapshot.records)
        saveSlots()
        if panel.isVisible {
            if mode == .switcher {
                if shortcutSession {
                    let live = Set(service.snapshot.records.map(\.id))
                    for id in session.orderedIDs where !live.contains(id) { session.remove(id) }
                } else {
                    // Initial discovery is asynchronous. Manual sessions accept new candidates;
                    // a physical Command–Tab invocation retains its frozen order until dismissed.
                    session.refresh(snapshot: service.snapshot)
                }
                selectedID = session.selectedID
            } else if mode == .overview { reconcileSelectionWithSearch() }
            rebuildCards()
        }
        permissionBar.isHidden = service.hasAccessibility
    }

    func setStatus(_ text: String) { status.stringValue = text }
    func setShortcutsEnabled(_ enabled: Bool) { shortcutButton.state = enabled ? .on : .off }
    func enablePreviewControl() { previewButton.isEnabled = true; previewButton.toolTip = "One live stream for the selected window while this overlay is visible." }
    func refreshPreviewSelection() { updatePreviewSelection() }
    func setPreviewsEnabled(_ enabled: Bool) { previewButton.state = enabled ? .on : .off }
    func showPreview(_ image: CGImage?, label: String) {
        for card in cards where card.record?.id == selectedID { card.preview = image; card.previewLabel = label }
    }

    private func configure() {
        panel.title = "Paneflo"
        panel.minSize = NSSize(width: 860, height: 620)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = .floating
        panel.delegate = self
        panel.onKey = { [weak self] in self?.handleKey($0) ?? false }
        let root = NSView()
        panel.contentView = root
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
        ])
        let title = NSTextField(labelWithString: "Paneflo")
        title.font = .systemFont(ofSize: 27, weight: .semibold)
        let header = NSStackView(views: [title, modes])
        header.orientation = .horizontal; header.spacing = 26
        stack.addArrangedSubview(header)
        modes.target = self; modes.action = #selector(changeMode)
        modes.setAccessibilityLabel("Paneflo function")
        summary.font = .systemFont(ofSize: 12); summary.textColor = .secondaryLabelColor
        stack.addArrangedSubview(summary)

        permissionBar.orientation = .horizontal; permissionBar.spacing = 8
        let permissionLabel = NSTextField(labelWithString: "Connect real windows with Accessibility access.")
        permissionBar.addArrangedSubview(permissionLabel)
        button("Grant Accessibility", #selector(grantAccessibility), permissionBar)
        button("Open Settings", #selector(openAccessibility), permissionBar)
        stack.addArrangedSubview(permissionBar)

        let options = NSStackView(views: [shortcutButton, previewButton])
        options.orientation = .horizontal; options.spacing = 20
        button("Refresh windows", #selector(refreshWindows), options)
        stack.addArrangedSubview(options)
        shortcutButton.target = self; shortcutButton.action = #selector(toggleShortcuts)
        shortcutButton.setAccessibilityLabel("Enable Paneflo shortcuts")
        previewButton.target = self; previewButton.action = #selector(togglePreviews)
        previewButton.setAccessibilityLabel("Enable live window previews")
        previewButton.isEnabled = false
        previewButton.toolTip = "Screen capture will become available after explicit permission."

        search.placeholderString = "Search windows by app or title"
        search.delegate = self; search.setAccessibilityLabel("Search windows")
        stack.addArrangedSubview(search)
        search.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        grid.orientation = .vertical; grid.alignment = .leading; grid.spacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedDesktopDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(grid)
        scroll.documentView = document
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        let preferredHeight = scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 270)
        preferredHeight.priority = .defaultLow
        preferredHeight.isActive = true
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            grid.leadingAnchor.constraint(equalTo: document.leadingAnchor), grid.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            grid.topAnchor.constraint(equalTo: document.topAnchor), grid.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        let actions = NSStackView(); actions.orientation = .horizontal; actions.spacing = 8
        button("Previous", #selector(previous), actions); button("Next", #selector(next), actions)
        activateButton.target = self; activateButton.action = #selector(activate); activateButton.bezelStyle = .rounded
        actions.addArrangedSubview(activateButton)
        button("Minimize", #selector(minimize), actions)
        button("Close overlay", #selector(closePanel), actions)
        stack.addArrangedSubview(actions)

        let tiling = NSStackView(); tiling.orientation = .horizontal; tiling.spacing = 8
        zone.addItems(withTitles: zones.map(\.0)); zone.setAccessibilityLabel("Window layout")
        display.addItem(withTitle: "Current display")
        display.addItems(withTitles: NSScreen.screens.enumerated().map { "Display \($0.offset + 1): \($0.element.localizedName)" })
        display.setAccessibilityLabel("Destination display")
        tiling.addArrangedSubview(zone); tiling.addArrangedSubview(display)
        button("Apply layout", #selector(applyLayout), tiling); button("Undo layout", #selector(undoLayout), tiling)
        stack.addArrangedSubview(tiling)

        overviewBar.orientation = .horizontal; overviewBar.spacing = 8
        button("Move slot left", #selector(moveLeft), overviewBar); button("Move slot right", #selector(moveRight), overviewBar)
        pinButton.target = self; pinButton.action = #selector(togglePin); overviewBar.addArrangedSubview(pinButton)
        let overviewHint = NSTextField(labelWithString: "Drag a card to reorder · Double-click to activate")
        overviewHint.font = .systemFont(ofSize: 11); overviewHint.textColor = .secondaryLabelColor
        overviewBar.addArrangedSubview(overviewHint)
        stack.addArrangedSubview(overviewBar)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.stringValue = "⌘Tab switches · ⌃⌥Space overview · ⌃⌥arrows arrange · ⌃⌥Return maximize · ⌃⌥Z undo"
        stack.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        status.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
    }

    private func button(_ title: String, _ selector: Selector, _ stack: NSStackView) {
        let view = NSButton(title: title, target: self, action: selector); view.bezelStyle = .rounded
        stack.addArrangedSubview(view)
    }

    private func rebuildCards() {
        guard !building else { return }; building = true; defer { building = false }
        modes.selectedSegment = mode.rawValue
        overviewBar.isHidden = mode != .overview
        let selectedPreview = cards.first { $0.record?.id == selectedID && $0.preview != nil }
        let retainedImage = selectedPreview?.preview
        let retainedLabel = selectedPreview?.previewLabel ?? "Icon preview"
        let retainedIdentity = selectedPreview?.record?.id
        let records = service.snapshot.records
        let liveApps = Set(records.map(\.appIdentifier))
        iconCache = iconCache.filter { liveApps.contains($0.key) }
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        if mode == .overview { displayed = slots.slots.map(\.binding) }
        else if mode == .switcher { displayed = session.filteredIDs.map(Optional.some) }
        else { displayed = service.snapshot.orderedRecords.map { Optional($0.id) } }
        for row in grid.arrangedSubviews { grid.removeArrangedSubview(row); row.removeFromSuperview() }
        if cards.count > displayed.count {
            for card in cards[displayed.count...] {
                card.record = nil
                card.icon = nil
                card.preview = nil
                card.previewLabel = "Icon preview"
                card.selected = false
                card.matches = true
                card.isVacancyPinned = false
                card.dragEnabled = false
            }
            let retainedCount = displayed.count + 3
            if cards.count > retainedCount { cards.removeLast(cards.count - retainedCount) }
        }
        while cards.count < displayed.count {
            let card = DesktopCard()
            card.target = self; card.action = #selector(selectCard(_:))
            card.onDoubleClick = { [weak self] id in self?.selectedID = id; self?.activateSelected() }
            card.onDragEnd = { [weak self] index, point in self?.moveDraggedSlot(from: index, at: point) }
            cards.append(card)
        }
        for index in displayed.indices {
            let card = cards[index]
            card.tag = index; card.record = displayed[index].flatMap { byID[$0] }
            card.isVacancyPinned = mode == .overview && slots.slots[index].isPinned
            if let record = card.record {
                if iconCache[record.appIdentifier] == nil { iconCache[record.appIdentifier] = NSRunningApplication(processIdentifier: record.id.process.pid)?.icon }
                card.icon = iconCache[record.appIdentifier]
            } else { card.icon = nil }
            let retain = mode != .tiling && card.record?.id == retainedIdentity && retainedIdentity == selectedID
            card.preview = retain ? retainedImage : nil
            card.previewLabel = retain ? retainedLabel : "Icon preview"
            card.dragEnabled = mode == .overview
        }
        if displayed.isEmpty {
            let message: String
            if !search.stringValue.isEmpty { message = "No windows match this search." }
            else { message = service.hasAccessibility ? "No eligible windows found. Open a normal application window, then refresh." : "Your windows will appear here after Accessibility access is enabled." }
            let empty = NSTextField(wrappingLabelWithString: message)
            empty.textColor = .secondaryLabelColor
            grid.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
            empty.heightAnchor.constraint(equalToConstant: 100).isActive = true
        } else {
            for start in stride(from: 0, to: displayed.count, by: 3) {
                let row = NSStackView(); row.orientation = .horizontal; row.distribution = .fillEqually; row.spacing = 10
                for index in start..<min(start + 3, displayed.count) { row.addArrangedSubview(cards[index]) }
                for _ in min(start + 3, displayed.count)..<(start + 3) { row.addArrangedSubview(NSView()) }
                grid.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
                row.heightAnchor.constraint(equalToConstant: 168).isActive = true
            }
        }
        summary.stringValue = "\(records.count) real windows · " + (mode == .overview ? "Your slot order stays independent of recent use" : mode == .tiling ? "Select a window and choose its destination" : "Individual windows · frozen order for this session")
        refreshSelection()
    }

    private func refreshSelection() {
        let matches = mode == .overview ? slots.matches(query: search.stringValue, records: service.snapshot.records) : Set<UUID>()
        let switchMatches = Set(session.filteredIDs)
        for index in displayed.indices {
            let card = cards[index]
            card.selected = card.record?.id == selectedID && card.record != nil
            if !card.selected { card.preview = nil; card.previewLabel = "Icon preview" }
            if mode == .overview { card.matches = matches.contains(slots.slots[index].id) }
            else if mode == .switcher { card.matches = card.record.map { switchMatches.contains($0.id) } ?? false }
            else { card.matches = search.stringValue.isEmpty || card.record.map { ($0.appName + " " + $0.title).localizedCaseInsensitiveContains(search.stringValue) } ?? false }
            card.isEnabled = card.matches || (card.record == nil && search.stringValue.isEmpty)
            card.setAccessibilityValue(card.selected ? "Selected" : "Not selected")
        }
        if let slot = slots.slots.first(where: { $0.id == selectedSlot }) { pinButton.title = slot.isPinned ? "Unpin slot" : "Pin slot" }
        activateButton.isEnabled = selectedID.map { eligibleSelectionIDs().contains($0) } ?? false
        if let selectedID,
           let selectedCard = cards.prefix(displayed.count).first(where: { $0.record?.id == selectedID }) {
            grid.layoutSubtreeIfNeeded()
            _ = selectedCard.scrollToVisible(selectedCard.bounds)
        }
        updatePreviewSelection()
    }

    private func eligibleSelectionIDs() -> [WindowIdentity] {
        if mode == .overview { return slots.matchingWindowIDs(query: search.stringValue, records: service.snapshot.records) }
        if mode == .switcher { return session.filteredIDs }
        return displayed.compactMap { $0 }.filter { id in
            guard !search.stringValue.isEmpty else { return true }
            guard let record = service.snapshot.records.first(where: { $0.id == id }) else { return false }
            return (record.appName + " " + record.title).localizedCaseInsensitiveContains(search.stringValue)
        }
    }

    private func reconcileSelectionWithSearch() {
        let eligible = eligibleSelectionIDs()
        if selectedID.map({ eligible.contains($0) }) != true {
            selectedID = eligible.first
            selectedSlot = slots.slots.first(where: { $0.binding == selectedID && $0.binding != nil })?.id
        }
    }

    private func fitToVisibleScreen() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let usable = screen.visibleFrame
        panel.minSize = NSSize(width: min(860, usable.width), height: min(620, usable.height))
        var frame = panel.frame
        frame.size.width = min(frame.width, usable.width)
        frame.size.height = min(frame.height, usable.height)
        frame.origin.x = min(max(frame.minX, usable.minX), usable.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, usable.minY), usable.maxY - frame.height)
        panel.setFrame(frame, display: false)
    }

    private func updatePreviewSelection() {
        onPreviewSelection?(selectedID.flatMap { service.captureWindowNumber(for: $0) }, panel.isVisible && mode != .tiling, selectedID?.process.pid)
    }

    func controlTextDidChange(_ notification: Notification) {
        if mode == .switcher {
            session.setSearchQuery(search.stringValue)
            selectedID = session.selectedID
            rebuildCards()
        } else {
            reconcileSelectionWithSearch()
            refreshSelection()
        }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch NSStringFromSelector(selector) {
        case "moveUp:": navigate(.backward); return true
        case "moveDown:": navigate(.forward); return true
        case "insertNewline:": activateSelected(); return true
        case "cancelOperation:": dismiss(); return true
        default: return false
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }

    private func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { dismiss(); return true }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 123, 126: navigate(.backward); return true
        case 124, 125, 48: navigate(.forward); return true
        case 36, 76: activateSelected(); return true
        default: return false
        }
    }
    private func activateSelected() {
        guard let selectedID, eligibleSelectionIDs().contains(selectedID) else { if shortcutSession { dismiss() }; return }
        if mode == .switcher { _ = session.commit() }
        dismiss(); service.focus(selectedID)
    }
    private func saveSlots() { if let metadata = try? slots.encodedMetadata(), metadata != lastSavedMetadata { defaults.set(metadata, forKey: "overview.slots.v1"); lastSavedMetadata = metadata } }
    private func moveSlot(by delta: Int) {
        guard let selectedSlot, let index = slots.slots.firstIndex(where: { $0.id == selectedSlot }) else { return }
        slots.move(slotID: selectedSlot, to: index + delta); saveSlots(); rebuildCards()
    }
    private func moveDraggedSlot(from index: Int, at point: NSPoint) {
        guard mode == .overview, slots.slots.indices.contains(index), !displayed.isEmpty else { return }
        let target = displayed.indices.min { a, b in
            let ar = cards[a].convert(cards[a].bounds, to: nil); let br = cards[b].convert(cards[b].bounds, to: nil)
            return hypot(ar.midX - point.x, ar.midY - point.y) < hypot(br.midX - point.x, br.midY - point.y)
        }!
        let id = slots.slots[index].id; selectedSlot = id; selectedID = slots.slots[index].binding
        slots.move(slotID: id, to: target); saveSlots(); rebuildCards()
    }
    @objc private func changeMode() { present(mode: DesktopMode(rawValue: modes.selectedSegment) ?? .switcher) }
    @objc private func grantAccessibility() { service.requestAccessibility() }
    @objc private func openAccessibility() { service.openAccessibilitySettings() }
    @objc private func refreshWindows() { service.refresh() }
    @objc private func toggleShortcuts() { onToggleShortcuts?(shortcutButton.state == .on) }
    @objc private func togglePreviews() { onTogglePreviews?(previewButton.state == .on) }
    @objc private func selectCard(_ card: DesktopCard) {
        selectedID = card.record?.id
        if mode == .overview { selectedSlot = slots.slots[card.tag].id }
        else if mode == .switcher, let selectedID { _ = session.select(selectedID) }
        refreshSelection()
    }
    @objc private func previous() { navigate(.backward) }
    @objc private func next() { navigate(.forward) }
    @objc private func activate() { activateSelected() }
    @objc private func minimize() { if let selectedID, eligibleSelectionIDs().contains(selectedID) { service.minimize(selectedID) } }
    @objc private func closePanel() { dismiss() }
    @objc private func applyLayout() { if let selectedID, eligibleSelectionIDs().contains(selectedID) { service.tile(selectedID, zone: zones[zone.indexOfSelectedItem].1, screenIndex: display.indexOfSelectedItem == 0 ? nil : display.indexOfSelectedItem - 1) } }
    @objc private func undoLayout() { service.undo() }
    @objc private func moveLeft() { moveSlot(by: -1) }
    @objc private func moveRight() { moveSlot(by: 1) }
    @objc private func togglePin() {
        guard let slot = slots.slots.first(where: { $0.id == selectedSlot }) else { return }
        if slot.isPinned { slots.unpin(slotID: slot.id) }
        else {
            let record = service.snapshot.records.first { $0.id == slot.binding }
            slots.pin(slotID: slot.id, matchingRule: record.map { SlotMatchingRule(appIdentifier: $0.appIdentifier) })
        }
        saveSlots(); rebuildCards()
    }
}

@MainActor
private final class DesktopCard: NSButton {
    var record: WindowRecord? { didSet { needsDisplay = true; setAccessibilityLabel(record.map { "\($0.appName), \($0.title)" } ?? "Vacant overview slot") } }
    var icon: NSImage? { didSet { needsDisplay = true } }
    var preview: CGImage? { didSet { needsDisplay = true } }
    var previewLabel = "Icon preview" { didSet { needsDisplay = true } }
    var selected = false { didSet { needsDisplay = true } }
    var matches = true { didSet { needsDisplay = true } }
    var isVacancyPinned = false { didSet { needsDisplay = true } }
    var dragEnabled = false
    var onDoubleClick: ((WindowIdentity) -> Void)?
    var onDragEnd: ((Int, NSPoint) -> Void)?
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 260, height: 168) }
    override init(frame: NSRect) { super.init(frame: frame); isBordered = false; title = ""; setButtonType(.momentaryChange) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.clickCount == 2, let record { onDoubleClick?(record.id); return }
        guard dragEnabled, let window else { super.mouseDown(with: event); return }
        let start = event.locationInWindow
        var dragged = false
        isHighlighted = true
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 5 { dragged = true }
            if next.type == .leftMouseUp {
                isHighlighted = false
                if dragged { onDragEnd?(tag, next.locationInWindow) }
                else { _ = sendAction(action, to: target) }
                break
            }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        (selected ? NSColor.controlAccentColor.withAlphaComponent(0.12) : .controlBackgroundColor).setFill(); path.fill()
        (selected ? NSColor.controlAccentColor : .separatorColor).setStroke(); path.lineWidth = selected ? 2 : 1; path.stroke()
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current?.cgContext.setAlpha(matches ? 1 : 0.24)
        guard let record else {
            drawText(isVacancyPinned ? "Pinned vacancy" : "Vacant slot", in: NSRect(x: 18, y: 68, width: bounds.width - 36, height: 24), font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
            NSGraphicsContext.restoreGraphicsState(); return
        }
        let target = NSRect(x: 14, y: 13, width: bounds.width - 28, height: bounds.height - 66)
        if let preview {
            let scale = min(target.width / CGFloat(preview.width), target.height / CGFloat(preview.height))
            let area = NSRect(x: target.midX - CGFloat(preview.width) * scale / 2, y: target.midY - CGFloat(preview.height) * scale / 2, width: CGFloat(preview.width) * scale, height: CGFloat(preview.height) * scale)
            NSImage(cgImage: preview, size: NSSize(width: preview.width, height: preview.height)).draw(in: area)
        } else { icon?.draw(in: NSRect(x: target.midX - 30, y: target.midY - 30, width: 60, height: 60)) }
        drawText(record.appName + (isVacancyPinned ? "  • pinned" : ""), in: NSRect(x: 15, y: bounds.height - 53, width: bounds.width - 30, height: 18), font: .systemFont(ofSize: 12, weight: .semibold), color: .labelColor)
        drawText(record.title, in: NSRect(x: 15, y: bounds.height - 34, width: bounds.width - 30, height: 17), font: .systemFont(ofSize: 11), color: .labelColor)
        drawText(record.isMinimized ? "Minimized · cached/icon only" : previewLabel, in: NSRect(x: 15, y: bounds.height - 18, width: bounds.width - 30, height: 13), font: .systemFont(ofSize: 9), color: .secondaryLabelColor)
        NSGraphicsContext.restoreGraphicsState()
    }
}
