import AppKit
import PanefloCore

@MainActor
private final class PreviewWindow: NSPanel {
    var handleKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {
        if handleKey?(event) != true { super.keyDown(with: event) }
    }
}

@MainActor
final class PreviewController: NSObject, NSSearchFieldDelegate {
    private enum Mode: Int { case switcher, tiling, overview }
    private let window = PreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    private let records: [WindowRecord]
    private var focusHistory: [WindowIdentity]
    private var session: SwitcherSession
    private var overview = OverviewSlotStore()
    private var selectedSlotID: UUID?
    private var mode: Mode = .switcher
    private let modeControl = NSSegmentedControl(labels: ["01  Switch", "02  Arrange", "03  Overview"], trackingMode: .selectOne, target: nil, action: nil)
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let search = NSSearchField()
    private let cards = (0..<6).map { _ in SampleCard() }
    private let grid = NSStackView()
    private let layoutPreview = LayoutPreviewView()
    private let switcherTools = NSStackView()
    private let tilingTools = NSStackView()
    private let overviewTools = NSStackView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let zonePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let displayPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let gap = NSSlider(value: 12, minValue: 0, maxValue: 32, target: nil, action: nil)
    private let pinButton = NSButton(title: "Pin sample", target: nil, action: nil)
    private var layoutHistory = GeometryUndoHistory()
    private let zones: [(String, LayoutZone)] = [
        ("Left half", .leftHalf), ("Right half", .rightHalf),
        ("First third", .firstThird), ("Middle third", .middleThird), ("Last third", .lastThird),
        ("Top left quarter", .topLeftQuarter), ("Bottom right quarter", .bottomRightQuarter),
        ("Center", .center), ("Maximize", .maximize),
    ]

    override init() {
        let sampleRecords = Self.makeRecords()
        records = sampleRecords
        focusHistory = sampleRecords.map(\.id)
        session = SwitcherSession(snapshot: WindowSnapshot(records: sampleRecords, mostRecent: sampleRecords.map(\.id)))
        super.init()
        overview.reconcile(sampleRecords)
        selectedSlotID = overview.slots.first?.id
        configureWindow()
        configureContent()
        refresh()
    }

    func present(mode rawValue: Int) {
        mode = Mode(rawValue: rawValue) ?? .switcher
        if mode == .switcher { restartSession() }
        refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(search)
    }

    private func configureWindow() {
        window.title = "Paneflo — Native developer preview"
        window.minSize = NSSize(width: 1000, height: 790)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.center()
        window.handleKey = { [weak self] event in self?.handleKey(event) ?? false }
    }

    private func configureContent() {
        let root = NSView()
        window.contentView = root
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 11
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            content.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
        ])

        let title = NSTextField(labelWithString: "Paneflo")
        title.font = .systemFont(ofSize: 28, weight: .semibold)
        content.addArrangedSubview(title)
        let subtitle = NSTextField(labelWithString: "NATIVE DEVELOPER PREVIEW  ·  Synthetic sample windows only")
        subtitle.font = .systemFont(ofSize: 11, weight: .medium)
        subtitle.textColor = .secondaryLabelColor
        content.addArrangedSubview(subtitle)

        modeControl.target = self
        modeControl.action = #selector(changeMode)
        modeControl.setAccessibilityLabel("Preview function")
        content.addArrangedSubview(modeControl)

        descriptionLabel.font = .systemFont(ofSize: 13)
        descriptionLabel.textColor = .secondaryLabelColor
        content.addArrangedSubview(descriptionLabel)
        descriptionLabel.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        descriptionLabel.heightAnchor.constraint(equalToConstant: 36).isActive = true

        search.placeholderString = "Search sample app names or window titles"
        search.delegate = self
        search.setAccessibilityLabel("Search synthetic windows")
        content.addArrangedSubview(search)
        search.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        grid.orientation = .vertical
        grid.spacing = 10
        grid.distribution = .fillEqually
        for row in 0..<2 {
            let rowView = NSStackView(views: Array(cards[(row * 3)..<(row * 3 + 3)]))
            rowView.orientation = .horizontal
            rowView.distribution = .fillEqually
            rowView.spacing = 10
            grid.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
        for (index, card) in cards.enumerated() {
            card.tag = index
            card.target = self
            card.action = #selector(selectCard(_:))
            card.handleKey = { [weak self] event in self?.handleKey(event) ?? false }
        }
        content.addArrangedSubview(grid)
        grid.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        grid.heightAnchor.constraint(equalToConstant: 334).isActive = true

        content.addArrangedSubview(layoutPreview)
        layoutPreview.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        layoutPreview.heightAnchor.constraint(equalToConstant: 334).isActive = true

        configureTools()
        for tools in [switcherTools, tilingTools, overviewTools] {
            tools.orientation = .horizontal
            tools.spacing = 8
            tools.alignment = .centerY
            content.addArrangedSubview(tools)
        }

        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.setAccessibilityLabel("Preview status")
        content.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        status.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true

        let boundary = NSTextField(wrappingLabelWithString: "Real windows, ⌘Tab replacement, capture, permissions, and native desktop control are not connected. No background animation or timers.")
        boundary.font = .systemFont(ofSize: 11)
        boundary.textColor = .tertiaryLabelColor
        content.addArrangedSubview(boundary)
        boundary.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }

    private func configureTools() {
        addButton("Previous", action: #selector(previousSample), to: switcherTools)
        addButton("Next", action: #selector(nextSample), to: switcherTools)
        addButton("Choose sample", action: #selector(chooseSample), to: switcherTools)
        addButton("Restart session", action: #selector(restartSampleSession), to: switcherTools)

        zonePicker.addItems(withTitles: zones.map(\.0))
        zonePicker.target = self
        zonePicker.action = #selector(updateLayout)
        zonePicker.setAccessibilityLabel("Sample layout zone")
        tilingTools.addArrangedSubview(zonePicker)
        displayPicker.addItems(withTitles: ["Laptop", "Wide display", "Portrait display"])
        displayPicker.target = self
        displayPicker.action = #selector(changeDisplay)
        displayPicker.setAccessibilityLabel("Synthetic display dimensions")
        tilingTools.addArrangedSubview(displayPicker)
        let gapLabel = NSTextField(labelWithString: "Gap")
        tilingTools.addArrangedSubview(gapLabel)
        gap.target = self
        gap.action = #selector(updateLayout)
        gap.setAccessibilityLabel("Sample gap in points")
        gap.widthAnchor.constraint(equalToConstant: 90).isActive = true
        tilingTools.addArrangedSubview(gap)
        addButton("Apply to sample", action: #selector(applyLayout), to: tilingTools)
        addButton("Undo sample", action: #selector(undoLayout), to: tilingTools)

        addButton("Move left", action: #selector(moveSlotLeft), to: overviewTools)
        addButton("Move right", action: #selector(moveSlotRight), to: overviewTools)
        pinButton.target = self
        pinButton.action = #selector(togglePin)
        overviewTools.addArrangedSubview(pinButton)
        addButton("Change focus history", action: #selector(changeFocusHistory), to: overviewTools)
        addButton("Reopen overview", action: #selector(reopenOverview), to: overviewTools)
    }

    private func addButton(_ title: String, action: Selector, to stack: NSStackView) {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        stack.addArrangedSubview(button)
    }

    @objc private func changeMode() {
        mode = Mode(rawValue: modeControl.selectedSegment) ?? .switcher
        if mode == .switcher { restartSession() }
        refresh()
    }

    func controlTextDidChange(_ notification: Notification) {
        if mode == .switcher { session.setSearchQuery(search.stringValue) }
        refreshCards()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Keep Left/Right as normal text editing; Up/Down and Return operate on results.
        switch NSStringFromSelector(commandSelector) {
        case "moveUp:":
            navigateSelection(backward: true)
            return true
        case "moveDown:":
            navigateSelection(backward: false)
            return true
        case "insertNewline:":
            activateSelection()
            return true
        case "cancelOperation:":
            window.close()
            return true
        default: return false
        }
    }

    private func refresh() {
        modeControl.selectedSegment = mode.rawValue
        grid.isHidden = mode == .tiling
        layoutPreview.isHidden = mode != .tiling
        switcherTools.isHidden = mode != .switcher
        tilingTools.isHidden = mode != .tiling
        overviewTools.isHidden = mode != .overview
        search.isEnabled = mode != .tiling
        switch mode {
        case .switcher:
            descriptionLabel.stringValue = "Select sample windows in a frozen core session. In search, Up/Down navigate and Return chooses; Left/Right edit text. Escape closes. Choosing updates simulated focus only."
            status.stringValue = "Synthetic switcher ready. The real Command–Tab shortcut remains unchanged."
        case .tiling:
            descriptionLabel.stringValue = "Preview pure layout geometry in a synthetic display. The outlined destination can be applied to the sample rectangle and undone; no desktop window moves."
            updateLayout()
        case .overview:
            descriptionLabel.stringValue = "Move or pin sample cards, then change focus history and reopen. Persistent logical slot order stays separate from recent-use switching order. Search dims in place."
            status.stringValue = "Synthetic overview ready. Reopening keeps chosen slots; these fixtures are not real windows."
        }
        refreshCards()
    }

    private func refreshCards() {
        let matchIDs = Set(session.filteredIDs)
        let overviewMatches = overview.matches(query: search.stringValue, records: records)
        for (index, card) in cards.enumerated() {
            if mode == .overview {
                let slot = overview.slots[index]
                card.record = records.first { $0.id == slot.binding }
                card.isSelectedCard = selectedSlotID == slot.id
                card.isPinned = slot.isPinned
                card.isMatching = overviewMatches.contains(slot.id)
                card.isEnabled = true
            } else {
                let id = session.orderedIDs[index]
                card.record = records.first { $0.id == id }
                card.isSelectedCard = session.selectedID == id
                card.isPinned = false
                card.isMatching = matchIDs.contains(id)
                card.isEnabled = card.isMatching
            }
        }
        if let slot = overview.slots.first(where: { $0.id == selectedSlotID }) {
            pinButton.title = slot.isPinned ? "Unpin sample" : "Pin sample"
        }
    }

    @objc private func selectCard(_ sender: SampleCard) {
        if mode == .overview { selectedSlotID = overview.slots[sender.tag].id }
        else if let id = sender.record?.id { _ = session.select(id) }
        refreshCards()
    }

    @objc private func previousSample() { session.advance(.backward); refreshCards() }
    @objc private func nextSample() { session.advance(.forward); refreshCards() }

    @objc private func chooseSample() {
        guard let id = session.commit(), let record = records.first(where: { $0.id == id }) else { return }
        focusHistory.removeAll { $0 == id }
        focusHistory.insert(id, at: 0)
        restartSession()
        _ = session.select(id)
        refreshCards()
        status.stringValue = "Simulated choice: \(record.appName) · \(record.title). No real application was activated."
    }

    private func restartSession() {
        session = SwitcherSession(snapshot: WindowSnapshot(records: records, mostRecent: focusHistory))
        session.setSearchQuery(search.stringValue)
    }

    @objc private func restartSampleSession() {
        restartSession()
        refreshCards()
        status.stringValue = "A new synthetic session uses the latest simulated focus order, then freezes it."
    }

    @objc private func moveSlotLeft() { moveSlot(by: -1) }
    @objc private func moveSlotRight() { moveSlot(by: 1) }
    private func moveSlot(by offset: Int) {
        guard let id = selectedSlotID, let index = overview.slots.firstIndex(where: { $0.id == id }) else { return }
        overview.move(slotID: id, to: index + offset)
        refreshCards()
        status.stringValue = "Sample slot moved explicitly. Focus history did not change."
    }

    @objc private func togglePin() {
        guard let slot = overview.slots.first(where: { $0.id == selectedSlotID }) else { return }
        if slot.isPinned { overview.unpin(slotID: slot.id) }
        else if let record = records.first(where: { $0.id == slot.binding }) {
            overview.pin(slotID: slot.id, matchingRule: SlotMatchingRule(appIdentifier: record.appIdentifier, documentKey: record.documentKey))
        }
        refreshCards()
        status.stringValue = "Sample pin updated. No desktop or native Space assignment changed."
    }

    @objc private func changeFocusHistory() {
        let previous = focusHistory.removeFirst()
        focusHistory.append(previous)
        status.stringValue = "Simulated recent-use order changed. Overview slot positions stayed put."
    }

    @objc private func reopenOverview() {
        overview.reconcile(records)
        refreshCards()
        status.stringValue = "Overview reopened from the same logical slots. Synthetic focus history has no effect on their order."
    }

    @objc private func changeDisplay() {
        let sizes = [(1440.0, 900.0), (2560.0, 1440.0), (900.0, 1440.0)]
        let size = sizes[displayPicker.indexOfSelectedItem]
        layoutPreview.usable = WindowRect(x: 0, y: 0, width: size.0, height: size.1)
        layoutPreview.applied = WindowRect(x: size.0 * 0.13, y: size.1 * 0.15, width: size.0 * 0.55, height: size.1 * 0.6)
        layoutHistory = GeometryUndoHistory()
        updateLayout()
    }

    @objc private func updateLayout() {
        let result = LayoutEngine.plan(zone: zones[zonePicker.indexOfSelectedItem].1, in: layoutPreview.usable, gap: gap.doubleValue, backingScale: 2, minimumSize: WindowSize(width: 180, height: 120), currentSize: WindowSize(width: layoutPreview.applied.width, height: layoutPreview.applied.height))
        switch result {
        case .success(let rect):
            layoutPreview.proposed = rect
            let description = "Sample target: x \(Int(rect.x)), y \(Int(rect.y)), \(Int(rect.width)) × \(Int(rect.height)) points; gap \(Int(gap.doubleValue)). No actual AX constraints/readback."
            status.stringValue = description
            layoutPreview.setAccessibilityValue(description)
        case .rejected(let reason):
            layoutPreview.proposed = nil
            status.stringValue = "Sample layout rejected: \(reason). No window moved."
        }
    }

    @objc private func applyLayout() {
        guard let proposed = layoutPreview.proposed else { return }
        layoutHistory.record([GeometryChange(id: records[0].id, before: layoutPreview.applied, after: proposed)])
        layoutPreview.applied = proposed
        status.stringValue = "Applied to the synthetic rectangle only. Undo history: \(layoutHistory.count) / 20."
    }

    @objc private func undoLayout() {
        guard let plan = layoutHistory.undo(surviving: Set(records.map(\.id))), let change = plan.changes.first else {
            status.stringValue = "No synthetic layout operation to undo."
            return
        }
        layoutPreview.applied = change.before
        updateLayout()
        status.stringValue = "Restored the sample rectangle. Undo history: \(layoutHistory.count) / 20."
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) else { return false }
        if event.keyCode == 53 { window.close(); return true }
        guard mode != .tiling else { return false }
        switch event.keyCode {
        case 123, 124, 125, 126:
            navigateSelection(backward: event.keyCode == 123 || event.keyCode == 126)
            return true
        case 36, 76:
            activateSelection()
            return true
        default: return false
        }
    }

    private func navigateSelection(backward: Bool) {
        guard mode != .tiling else { return }
        if mode == .switcher { session.advance(backward ? .backward : .forward) }
        else if let id = selectedSlotID, let index = overview.slots.firstIndex(where: { $0.id == id }) {
            let count = overview.slots.count
            let matches = overview.matches(query: search.stringValue, records: records)
            for step in 1...count {
                let candidate = overview.slots[(index + (backward ? -step : step) + count) % count]
                if matches.contains(candidate.id) {
                    selectedSlotID = candidate.id
                    break
                }
            }
        }
        refreshCards()
    }

    private func activateSelection() {
        if mode == .switcher { chooseSample() }
        else if mode == .overview { status.stringValue = "Selected sample overview card. No real application was activated." }
    }

    private static func makeRecords() -> [WindowRecord] {
        let samples = [
            ("sample.editor", "Editor", "Paneflo.swift", "paneflo-swift"),
            ("sample.browser", "Browser", "Architecture notes", "architecture"),
            ("sample.terminal", "Terminal", "swift test", "test-session"),
            ("sample.browser", "Browser", "Display research", "displays"),
            ("sample.messages", "Messages", "Project chat", "project-chat"),
            ("sample.files", "Files", "Working folder", "working-folder"),
        ]
        return samples.enumerated().map { index, sample in
            let pid: Int32 = sample.0 == "sample.browser" ? 102 : Int32(101 + index)
            return WindowRecord(id: WindowIdentity(process: ProcessIdentity(pid: pid, launchToken: 1), number: UInt32(index + 1), incarnation: 1), appIdentifier: sample.0, appName: sample.1, title: sample.2, frame: WindowRect(x: 40 + Double(index) * 20, y: 40, width: 800, height: 600), isMinimized: index == 5, documentKey: sample.3)
        }
    }
}
