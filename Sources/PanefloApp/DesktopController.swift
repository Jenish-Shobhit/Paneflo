import AppKit
import QuartzCore
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
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), [123, 124, 126].contains(event.keyCode), onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Native presentation reads prepared snapshots. It never makes remote AX or capture calls.
@MainActor
final class DesktopController: NSObject, NSSearchFieldDelegate, NSWindowDelegate {
    private let service: WindowService
    private let panel = DesktopPanel(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 780), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var preferences: NSWindow?
    private let heading = NSTextField(labelWithString: "Switch windows")
    private let keyboardHint = NSTextField(labelWithString: "")
    private let failureFeedback = NSTextField(wrappingLabelWithString: "")
    private var viewportHeight: NSLayoutConstraint?
    private var layoutFeedback: [WindowIdentity: String] = [:]
    private var commitGate = SelectionCommitGate()
    private var latestPlacement: UInt64?
    private var presentationGeneration: UInt64 = 0
    private var columnCount = 4
    private var overviewCardHeight: CGFloat = 220
    private var viewportObserver: NSObjectProtocol?
    private var thumbnailViewportQueued = false
    var onThumbnailViewport: (([WindowThumbnailRequest], Bool, Set<WindowIdentity>) -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?
    private let modes = NSSegmentedControl(labels: ["Switch", "Arrange", "Overview"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    private let grid = NSStackView()
    private let scroll = NSScrollView()
    private let permissionBar = NSStackView()
    private let shortcutButton = NSButton(checkboxWithTitle: "Enable Paneflo shortcuts", target: nil, action: nil)
    private let gestureButton = NSButton(checkboxWithTitle: "Three-finger swipe opens Overview", target: nil, action: nil)
    private let gestureStatus = NSTextField(wrappingLabelWithString: "Off")
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
    var onToggleGesture: ((Bool) -> Void)?
    var onTogglePreviews: ((Bool) -> Void)?
    var onPreviewSelection: ((UInt32?, Bool, pid_t?) -> Void)?
    var onDismiss: (() -> Void)?
    var isVisible: Bool { panel.isVisible }
    var isOverviewVisible: Bool { panel.isVisible && mode == .overview }
    func setGestureState(enabled: Bool, description: String) {
        gestureButton.state = enabled ? .on : .off
        gestureStatus.stringValue = description
    }
    isolated deinit {
        if let viewportObserver { NotificationCenter.default.removeObserver(viewportObserver) }
    }
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
        presentationGeneration &+= 1
        shortcutSession = fromShortcut && mode == .switcher
        layoutFeedback.removeAll()
        failureFeedback.isHidden = true
        commitGate.cancelCommit()
        heading.stringValue = mode == .overview ? "Your overview" : mode == .tiling ? "Arrange a window" : "Switch windows"
        keyboardHint.stringValue = mode == .overview ? "arrows select   ⌘← → tile   ⌘↑ fill   return open   esc close" : "⇥ switch   ⇧⇥ reverse   ⌘← → tile   ⌘↑ fill   esc cancel"
        search.isHidden = shortcutSession
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
        onVisibilityChanged?(panel.isKeyWindow)
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

    private func navigateRows(_ delta: Int) {
        guard mode != .switcher else { navigate(delta > 0 ? .forward : .backward); return }
        let eligible = Set(eligibleSelectionIDs())
        let indices = displayed.indices.filter { displayed[$0].map { eligible.contains($0) } ?? false }
        let current = displayed.firstIndex(where: { $0 != nil && $0 == selectedID })
        if let next = GridNavigation.vertical(from: current, columns: columnCount, count: displayed.count, eligible: indices, direction: delta) {
            selectedID = displayed[next]
            selectedSlot = slots.slots.first(where: { $0.binding == selectedID })?.id
            refreshSelection()
        }
    }

    func commitShortcut() { if shortcutSession { activateSelected() } }
    func dismiss() {
        commitGate.cancelCommit()
        session.cancel(); shortcutSession = false
        panel.orderOut(nil)
        onVisibilityChanged?(false)
        for card in cards { card.preview = nil; card.previewLabel = "Icon preview" }
        for card in cards { card.thumbnail = nil }
        onThumbnailViewport?([], false, Set(service.snapshot.records.map(\.id)))
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

    func showThumbnail(_ image: CGImage, for id: WindowIdentity) {
        for card in cards where card.record?.id == id { card.thumbnail = image }
    }
    func clearThumbnails() { for card in cards { card.thumbnail = nil } }

    private func configure() {
        panel.title = "Paneflo"
        panel.minSize = NSSize(width: 320, height: 210)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = .floating
        panel.delegate = self
        panel.onKey = { [weak self] in self?.handleKey($0) ?? false }
        let root = NSVisualEffectView()
        root.material = .popover; root.blendingMode = .behindWindow; root.state = .active
        root.wantsLayer = true; root.layer?.cornerRadius = 18; root.layer?.masksToBounds = true
        panel.contentView = root
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
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
        search.placeholderString = "Find a window"
        search.delegate = self; search.setAccessibilityLabel("Search windows")
        stack.addArrangedSubview(search)
        search.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        grid.orientation = .vertical; grid.alignment = .leading; grid.spacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView.postsBoundsChangedNotifications = true
        viewportObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateThumbnailViewport() }
        }
        let document = FlippedDesktopDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(grid); scroll.documentView = document
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        viewportHeight = scroll.heightAnchor.constraint(equalToConstant: 142)
        viewportHeight?.isActive = true
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            grid.leadingAnchor.constraint(equalTo: document.leadingAnchor), grid.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            grid.topAnchor.constraint(equalTo: document.topAnchor), grid.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
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
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        overviewBar.isHidden = true
        configurePreferences()
    }

    private func configurePreferences() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 650),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Paneflo Settings"; window.isReleasedWhenClosed = false
        let root = NSView(); window.contentView = root
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24)
        ])
        let title = NSTextField(labelWithString: "Paneflo")
        title.font = .systemFont(ofSize: 22, weight: .semibold); stack.addArrangedSubview(title)
        shortcutButton.target = self; shortcutButton.action = #selector(toggleShortcuts)
        shortcutButton.setAccessibilityLabel("Enable Paneflo shortcuts")
        previewButton.target = self; previewButton.action = #selector(togglePreviews)
        previewButton.setAccessibilityLabel("Enable live window previews")
        previewButton.isEnabled = false
        stack.addArrangedSubview(shortcutButton); stack.addArrangedSubview(previewButton)
        gestureButton.target = self; gestureButton.action = #selector(toggleGesture)
        stack.addArrangedSubview(gestureButton)
        let gestureHint = NSTextField(wrappingLabelWithString: "Experimental · macOS 27 on Apple silicon, built-in trackpad only. Turn off the conflicting Mission Control swipe in Trackpad Settings. Requires Input Monitoring.")
        gestureHint.font = .systemFont(ofSize: 11); gestureHint.textColor = .secondaryLabelColor
        gestureHint.widthAnchor.constraint(equalToConstant: 572).isActive = true
        stack.addArrangedSubview(gestureHint)
        gestureStatus.font = .systemFont(ofSize: 11); gestureStatus.textColor = .secondaryLabelColor
        gestureStatus.widthAnchor.constraint(equalToConstant: 572).isActive = true
        stack.addArrangedSubview(gestureStatus)
        let trackpad = NSStackView(); trackpad.orientation = .horizontal
        button("Trackpad Settings…", #selector(openTrackpadSettings), trackpad); stack.addArrangedSubview(trackpad)
        permissionBar.orientation = .horizontal; permissionBar.spacing = 10
        button("Grant Accessibility", #selector(grantAccessibility), permissionBar)
        button("Privacy Settings", #selector(openAccessibility), permissionBar)
        stack.addArrangedSubview(permissionBar)
        let refresh = NSStackView(); refresh.orientation = .horizontal
        button("Refresh windows", #selector(refreshWindows), refresh); stack.addArrangedSubview(refresh)
        let arrange = NSStackView(); arrange.orientation = .horizontal; arrange.spacing = 8
        zone.addItems(withTitles: zones.map(\.0)); display.addItem(withTitle: "Current display")
        display.addItems(withTitles: NSScreen.screens.enumerated().map { "Display \($0.offset + 1): \($0.element.localizedName)" })
        arrange.addArrangedSubview(zone); arrange.addArrangedSubview(display)
        button("Apply to selection", #selector(applyLayout), arrange); stack.addArrangedSubview(arrange)
        let undo = NSStackView(); undo.orientation = .horizontal
        button("Undo arrangement", #selector(undoLayout), undo); stack.addArrangedSubview(undo)
        stack.addArrangedSubview(status); status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        status.stringValue = "⌘Tab picks a window. Hold ⌘ and use ← → or ↑ to arrange it before releasing."
        preferences = window
    }

    func showPreferences() {
        dismiss()
        preferences?.center(); preferences?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func tileSelected(_ zone: LayoutZone) {
        guard panel.isVisible, let id = selectedID, eligibleSelectionIDs().contains(id) else { return }
        let generation = commitGate.beginPlacement()
        let presentedGeneration = presentationGeneration
        latestPlacement = generation
        layoutFeedback[id] = zone == .leftHalf ? "Left half" : zone == .rightHalf ? "Right half" : "Fill screen"
        for card in cards where card.record?.id == id { card.layoutBadge = layoutFeedback[id] }
        service.tile(id, zone: zone) { [weak self] accepted in
            guard let self, self.latestPlacement == generation else { return }
            self.latestPlacement = nil
            if !accepted {
                self.layoutFeedback.removeValue(forKey: id)
                for card in self.cards where card.record?.id == id { card.layoutBadge = nil }
                if self.panel.isVisible, self.presentationGeneration == presentedGeneration {
                    self.failureFeedback.stringValue = "Couldn’t arrange this window. Try another window or check Accessibility in Settings."
                    self.failureFeedback.isHidden = false
                    self.fitToVisibleScreen()
                }
            }
            if let focus = self.commitGate.finishPlacement(generation) { self.service.focus(focus) }
        }
    }

    private func button(_ title: String, _ selector: Selector, _ stack: NSStackView) {
        let view = NSButton(title: title, target: self, action: selector); view.bezelStyle = .rounded
        stack.addArrangedSubview(view)
    }

    private func rebuildCards() {
        guard !building else { return }; building = true; defer { building = false }
        modes.selectedSegment = mode.rawValue
        overviewBar.isHidden = mode != .overview
        let selectedPreview = cards.first { $0.record?.id == selectedID }
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
                card.thumbnail = nil
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
            if card.record?.id != displayed[index] { card.thumbnail = nil }
            card.tag = index; card.record = displayed[index].flatMap { byID[$0] }
            card.isVacancyPinned = mode == .overview && slots.slots[index].isPinned
            if let record = card.record {
                if service.captureWindowNumber(for: record.id) == nil { card.thumbnail = nil }
                if iconCache[record.appIdentifier] == nil { iconCache[record.appIdentifier] = NSRunningApplication(processIdentifier: record.id.process.pid)?.icon }
                card.icon = iconCache[record.appIdentifier]
            } else { card.icon = nil }
            let retain = mode != .tiling && card.record?.id == retainedIdentity && retainedIdentity == selectedID
            card.preview = retain ? retainedImage : nil
            card.previewLabel = retain ? retainedLabel : "Icon preview"
            card.dragEnabled = mode == .overview
            card.layoutBadge = card.record.flatMap { layoutFeedback[$0.id] }
            card.menu = nil
            if mode == .overview {
                let menu = NSMenu()
                for (title, action) in [("Move slot left", #selector(moveLeft(_:))), ("Move slot right", #selector(moveRight(_:))), (card.isVacancyPinned ? "Unpin slot" : "Pin slot", #selector(togglePin(_:)))] {
                    let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.representedObject = slots.slots[index].id.uuidString
                    menu.addItem(item)
                }
                card.menu = menu
            }
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
            let usableWidth = (panel.screen ?? NSScreen.main)?.visibleFrame.width ?? 1000
            let usableHeight = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
            overviewCardHeight = max(174, min(280, (usableHeight * 0.9 - 160) / 3))
            columnCount = max(1, min(4, Int((usableWidth - 60) / 190)))
            columnCount = min(columnCount, max(1, displayed.count))
            for start in stride(from: 0, to: displayed.count, by: columnCount) {
                let row = NSStackView(); row.orientation = .horizontal; row.distribution = .fillEqually; row.spacing = 10
                for index in start..<min(start + columnCount, displayed.count) { row.addArrangedSubview(cards[index]) }
                for _ in min(start + columnCount, displayed.count)..<(start + columnCount) { row.addArrangedSubview(NSView()) }
                grid.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
                row.heightAnchor.constraint(equalToConstant: mode == .overview ? overviewCardHeight : 142).isActive = true
            }
        }
        summary.stringValue = "\(records.count) real windows · " + (mode == .overview ? "Your slot order stays independent of recent use" : mode == .tiling ? "Select a window and choose its destination" : "Individual windows · frozen order for this session")
        fitToVisibleScreen()
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
        let usable = screen.visibleFrame.insetBy(dx: 16, dy: 16)
        let rows = max(1, (displayed.count + columnCount - 1) / columnCount)
        let cardHeight: CGFloat = mode == .overview ? overviewCardHeight : 142
        let visibleRows = min(rows, mode == .overview ? 3 : 2)
        let desiredViewport = mode == .overview ? usable.height * 0.9 - 128
            : CGFloat(visibleRows) * cardHeight + CGFloat(max(0, visibleRows - 1)) * 10
        viewportHeight?.constant = min(desiredViewport, max(80, usable.height - (search.isHidden ? 110 : 145)))
        panel.minSize = NSSize(width: min(320, usable.width), height: min(180, usable.height))
        panel.setContentSize(NSSize(width: mode == .overview ? usable.width * 0.92 : min(CGFloat(columnCount) * 208 + 36, usable.width),
                                   height: min((viewportHeight?.constant ?? 142) + (search.isHidden ? 94 : 128) + (failureFeedback.isHidden ? 0 : 30), usable.height)))
        var frame = panel.frame
        frame.origin.x = min(max(frame.minX, usable.minX), usable.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, usable.minY), usable.maxY - frame.height)
        panel.setFrame(frame, display: false)
    }

    private func updateThumbnailViewport() {
        if building {
            guard !thumbnailViewportQueued else { return }
            thumbnailViewportQueued = true
            DispatchQueue.main.async { [weak self] in
                self?.thumbnailViewportQueued = false
                self?.updateThumbnailViewport()
            }
            return
        }
        let surviving = Set(service.snapshot.records.map(\.id))
        guard panel.isVisible, mode != .tiling, let document = scroll.documentView else {
            onThumbnailViewport?([], false, surviving); return
        }
        let viewport = scroll.contentView.documentVisibleRect
        let requests = cards.prefix(displayed.count).compactMap { card -> WindowThumbnailRequest? in
            guard card.matches, let record = card.record, record.id != selectedID,
                  card.convert(card.bounds, to: document).intersects(viewport),
                  let number = service.captureWindowNumber(for: record.id) else { return nil }
            return WindowThumbnailRequest(id: record.id, windowNumber: number, ownerPID: record.id.process.pid)
        }
        onThumbnailViewport?(requests, true, surviving)
    }

    private func updatePreviewSelection() {
        onPreviewSelection?(selectedID.flatMap { service.captureWindowNumber(for: $0) }, panel.isVisible && mode != .tiling, selectedID?.process.pid)
        updateThumbnailViewport()
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
        case "moveUp:": navigateRows(-1); return true
        case "moveDown:": navigateRows(1); return true
        case "insertNewline:": activateSelected(); return true
        case "cancelOperation:": dismiss(); return true
        default: return false
        }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        onVisibilityChanged?(panel.isVisible && panel.isKeyWindow)
    }
    func windowDidResignKey(_ notification: Notification) { onVisibilityChanged?(false) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }

    private func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { dismiss(); return true }
        let commandModifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if commandModifiers == .command, [123, 124, 126].contains(event.keyCode) {
            if event.isARepeat { return true }
            if event.keyCode == 123 { tileSelected(.leftHalf); return true }
            if event.keyCode == 124 { tileSelected(.rightHalf); return true }
            if event.keyCode == 126 { tileSelected(.maximize); return true }
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
    private func activateSelected() {
        guard let selectedID, eligibleSelectionIDs().contains(selectedID) else { if shortcutSession { dismiss() }; return }
        if mode == .switcher { _ = session.commit() }
        dismiss()
        if let focus = commitGate.commit(selectedID) { service.focus(focus) }
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
    @objc private func toggleGesture() { onToggleGesture?(gestureButton.state == .on) }
    @objc private func openTrackpadSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") { NSWorkspace.shared.open(url) }
    }
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
    private func selectMenuSlot(_ sender: NSMenuItem?) {
        if let text = sender?.representedObject as? String, let id = UUID(uuidString: text) {
            selectedSlot = id; selectedID = slots.slots.first { $0.id == id }?.binding
        }
    }
    @objc private func moveLeft(_ sender: NSMenuItem?) { selectMenuSlot(sender); moveSlot(by: -1) }
    @objc private func moveRight(_ sender: NSMenuItem?) { selectMenuSlot(sender); moveSlot(by: 1) }
    @objc private func togglePin(_ sender: NSMenuItem?) {
        selectMenuSlot(sender)
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
    var record: WindowRecord? { didSet { toolTip = record?.title; needsDisplay = true; setAccessibilityLabel(record.map { "\($0.appName), \($0.title)" } ?? "Vacant overview slot") } }
    var icon: NSImage? { didSet { needsDisplay = true } }
    var layoutBadge: String? { didSet { if oldValue != layoutBadge { needsDisplay = true } } }
    private let previewLayer = CALayer()
    var thumbnail: CGImage? {
        didSet {
            updatePreviewLayer()
            if preview == nil, (oldValue == nil) != (thumbnail == nil) { needsDisplay = true }
        }
    }
    var preview: CGImage? {
        didSet {
            if PreviewRenderer.usesReferenceRenderer { needsDisplay = true }
            else {
                updatePreviewLayer()
                // Only image/placeholder transitions change the static backing-store drawing.
                if (oldValue == nil) != (preview == nil) { needsDisplay = true }
            }
        }
    }
    var previewLabel = "Icon preview" { didSet { if oldValue != previewLabel { needsDisplay = true } } }
    var selected = false { didSet { needsDisplay = true } }
    var matches = true { didSet { needsDisplay = true; updatePreviewLayer() } }
    var isVacancyPinned = false { didSet { needsDisplay = true } }
    var dragEnabled = false
    var onDoubleClick: ((WindowIdentity) -> Void)?
    var onDragEnd: ((Int, NSPoint) -> Void)?
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 260, height: 168) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false; title = ""; setButtonType(.momentaryChange)
        if !PreviewRenderer.usesReferenceRenderer {
            wantsLayer = true
            previewLayer.contentsGravity = .resizeAspect
            previewLayer.minificationFilter = .trilinear
            previewLayer.magnificationFilter = .linear
            previewLayer.isHidden = true
            layer?.addSublayer(previewLayer)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layout() {
        super.layout()
        if !PreviewRenderer.usesReferenceRenderer { updatePreviewLayer() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if !PreviewRenderer.usesReferenceRenderer { updatePreviewLayer() }
    }

    private func updatePreviewLayer() {
        guard !PreviewRenderer.usesReferenceRenderer else { return }
        let target = NSRect(x: 14, y: 13, width: max(0, bounds.width - 28), height: max(0, bounds.height - 66))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = convertToLayer(target)
        previewLayer.contentsScale = window?.backingScaleFactor ?? 1
        previewLayer.opacity = matches ? 1 : 0.24
        previewLayer.contents = preview ?? thumbnail
        previewLayer.isHidden = preview == nil && thumbnail == nil
        setAccessibilityHelp(preview != nil ? "Live window preview" : thumbnail != nil ? "Static window snapshot" : previewLabel)
        CATransaction.commit()
    }

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
        if let preview = preview ?? thumbnail {
            let scale = min(target.width / CGFloat(preview.width), target.height / CGFloat(preview.height))
            let area = NSRect(x: target.midX - CGFloat(preview.width) * scale / 2, y: target.midY - CGFloat(preview.height) * scale / 2, width: CGFloat(preview.width) * scale, height: CGFloat(preview.height) * scale)
            if PreviewRenderer.usesReferenceRenderer {
                NSImage(cgImage: preview, size: NSSize(width: preview.width, height: preview.height)).draw(in: area)
            }
        } else { icon?.draw(in: NSRect(x: target.midX - 30, y: target.midY - 30, width: 60, height: 60)) }
        drawText(record.appName + (layoutBadge.map { " · " + $0 } ?? "") + (isVacancyPinned ? "  • pinned" : ""), in: NSRect(x: 15, y: bounds.height - 53, width: bounds.width - 30, height: 18), font: .systemFont(ofSize: 12, weight: .semibold), color: .labelColor)
        drawText(record.title, in: NSRect(x: 15, y: bounds.height - 34, width: bounds.width - 30, height: 17), font: .systemFont(ofSize: 11), color: .labelColor)
        drawText(preview != nil ? "● Live" : thumbnail != nil ? "◷ Snapshot" : record.isMinimized ? "Minimized" : "", in: NSRect(x: 15, y: bounds.height - 18, width: bounds.width - 30, height: 13), font: .systemFont(ofSize: 9), color: .secondaryLabelColor)
        NSGraphicsContext.restoreGraphicsState()
    }
}
