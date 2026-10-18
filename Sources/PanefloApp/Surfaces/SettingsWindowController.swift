import AppKit
import PanefloCore

/// The Settings window. Controls keep their state before the window exists; the window
/// itself is built lazily on first open.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let service: WindowService
    private var window: NSWindow?
    let shortcutButton = NSButton(checkboxWithTitle: "Enable Paneflo shortcuts", target: nil, action: nil)
    let gestureButton = NSButton(checkboxWithTitle: GestureGuidance.toggleTitle, target: nil, action: nil)
    let gestureStatus = NSTextField(wrappingLabelWithString: "Off")
    /// Live reading of the system three-finger swipes; refreshed only when Settings opens or becomes key.
    let gestureGuidanceStatus = NSTextField(wrappingLabelWithString: "")
    private let gestureConflictSection = NSStackView()
    private let threeFingerDragNote = NSTextField(wrappingLabelWithString: GestureGuidance.threeFingerDragNote)
    let previewButton = NSButton(checkboxWithTitle: "Live previews", target: nil, action: nil)
    let desktopEntryButton = NSButton(checkboxWithTitle: "Show Desktop in ⌘Tab and Overview", target: nil, action: nil)
    let systemShowDesktopButton = NSButton(checkboxWithTitle: "Use macOS Show Desktop (experimental)", target: nil, action: nil)
    /// Screen Recording guidance next to the previews toggle; hidden when nothing is needed.
    let previewPermissionStatus = NSTextField(wrappingLabelWithString: "")
    private let previewPermissionSection = NSStackView()
    let status = NSTextField(wrappingLabelWithString: "")
    private let permissionBar = NSStackView()
    private let zone = NSPopUpButton(frame: .zero, pullsDown: false)
    private let display = NSPopUpButton(frame: .zero, pullsDown: false)
    var onToggleShortcuts: ((Bool) -> Void)?
    var onToggleGesture: ((Bool) -> Void)?
    var onTogglePreviews: ((Bool) -> Void)?
    var onToggleDesktopEntry: ((Bool) -> Void)?
    var onToggleSystemShowDesktop: ((Bool) -> Void)?
    /// Settings became key: a pending Screen Recording grant may have landed in System Settings.
    var onRefreshScreenRecording: (() -> Void)?
    /// The window the last surface had selected, if it is still eligible.
    var selectedWindow: (() -> WindowIdentity?)?
    private let zones: [(String, LayoutZone)] = [
        ("Left half", .leftHalf), ("Right half", .rightHalf), ("Top half", .topHalf), ("Bottom half", .bottomHalf),
        ("First third", .firstThird), ("Middle third", .middleThird), ("Last third", .lastThird),
        ("Top left", .topLeftQuarter), ("Top right", .topRightQuarter), ("Bottom left", .bottomLeftQuarter), ("Bottom right", .bottomRightQuarter),
        ("Center", .center), ("Maximize", .maximize),
    ]

    init(service: WindowService) {
        self.service = service
        super.init()
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        previewButton.isEnabled = false
        previewPermissionStatus.font = .systemFont(ofSize: 11); previewPermissionStatus.textColor = .secondaryLabelColor
        previewPermissionStatus.setAccessibilityLabel("Screen Recording status for previews")
        previewPermissionSection.isHidden = true
    }

    func setPreviewPermissionMessage(_ message: String?) {
        if previewPermissionStatus.stringValue != (message ?? "") { previewPermissionStatus.stringValue = message ?? "" }
        if previewPermissionSection.isHidden != (message == nil) { previewPermissionSection.isHidden = message == nil }
    }

    var isConstructed: Bool { window != nil }

    func show() {
        if window == nil { configure() }
        permissionBar.isHidden = service.hasAccessibility
        refreshGestureGuidance()
        window?.center(); window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshGestureGuidance()
        onRefreshScreenRecording?()
    }

    /// Reads the system gesture preferences (read-only CFPreferences). Never on the gesture path.
    private func refreshGestureGuidance() {
        let conflict = SystemGestureSettings.current().conflict
        gestureGuidanceStatus.stringValue = GestureGuidance.status(for: conflict)
        gestureConflictSection.isHidden = !conflict.conflictingSystemGesturesEnabled
        threeFingerDragNote.isHidden = !conflict.threeFingerDrag
    }

    /// Registry changes only matter to an existing window (the permission bar).
    func snapshotChanged() {
        guard window != nil else { return }
        let hidden = service.hasAccessibility
        if permissionBar.isHidden != hidden { permissionBar.isHidden = hidden }
    }

    private func configure() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 760),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Paneflo Settings"; window.isReleasedWhenClosed = false
        window.delegate = self
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
        stack.addArrangedSubview(shortcutButton); stack.addArrangedSubview(previewButton)
        previewPermissionSection.orientation = .vertical; previewPermissionSection.alignment = .leading; previewPermissionSection.spacing = 6
        previewPermissionStatus.widthAnchor.constraint(equalToConstant: 572).isActive = true
        previewPermissionSection.addArrangedSubview(previewPermissionStatus)
        button("Open Screen Recording Settings", #selector(openScreenRecordingSettings), previewPermissionSection)
        stack.addArrangedSubview(previewPermissionSection)
        desktopEntryButton.target = self; desktopEntryButton.action = #selector(toggleDesktopEntry)
        desktopEntryButton.setAccessibilityLabel("Show Desktop in Command-Tab and Overview")
        stack.addArrangedSubview(desktopEntryButton)
        systemShowDesktopButton.target = self; systemShowDesktopButton.action = #selector(toggleSystemShowDesktop)
        systemShowDesktopButton.setAccessibilityLabel("Use macOS Show Desktop, experimental")
        stack.addArrangedSubview(systemShowDesktopButton)
        let desktopHint = NSTextField(wrappingLabelWithString: "Desktop hides other apps (Finder stays) and choosing a window brings back only its app. The experimental option sends your macOS Show Desktop shortcut instead; it needs permission to post keys and is untested on most setups.")
        desktopHint.font = .systemFont(ofSize: 11); desktopHint.textColor = .secondaryLabelColor
        desktopHint.widthAnchor.constraint(equalToConstant: 572).isActive = true
        stack.addArrangedSubview(desktopHint)
        gestureButton.target = self; gestureButton.action = #selector(toggleGesture)
        stack.addArrangedSubview(gestureButton)
        let gestureHint = NSTextField(wrappingLabelWithString: GestureGuidance.requirements)
        gestureHint.font = .systemFont(ofSize: 11); gestureHint.textColor = .secondaryLabelColor
        gestureHint.widthAnchor.constraint(equalToConstant: 572).isActive = true
        stack.addArrangedSubview(gestureHint)
        gestureStatus.font = .systemFont(ofSize: 11); gestureStatus.textColor = .secondaryLabelColor
        gestureStatus.widthAnchor.constraint(equalToConstant: 572).isActive = true
        stack.addArrangedSubview(gestureStatus)
        gestureConflictSection.orientation = .vertical; gestureConflictSection.alignment = .leading; gestureConflictSection.spacing = 4
        let conflictTitle = NSTextField(labelWithString: GestureGuidance.conflictTitle)
        conflictTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        gestureConflictSection.addArrangedSubview(conflictTitle)
        for text in [GestureGuidance.conflictExplanation, "• " + GestureGuidance.missionControlStep, "• " + GestureGuidance.appExposeStep] {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
            label.widthAnchor.constraint(equalToConstant: 572).isActive = true
            gestureConflictSection.addArrangedSubview(label)
        }
        stack.addArrangedSubview(gestureConflictSection)
        for label in [threeFingerDragNote, gestureGuidanceStatus] {
            label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
            label.widthAnchor.constraint(equalToConstant: 572).isActive = true
            stack.addArrangedSubview(label)
        }
        gestureGuidanceStatus.setAccessibilityLabel("System three-finger swipe status")
        let trackpad = NSStackView(); trackpad.orientation = .horizontal
        button(GestureGuidance.openSettingsButton, #selector(openTrackpadSettings), trackpad); stack.addArrangedSubview(trackpad)
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
        if status.stringValue.isEmpty {
            status.stringValue = "⌘Tab picks a window. Keep holding ⌘: Tab or the arrow keys choose, ⌥← → ↑ arrange it, ⌥↓ undoes. Release ⌘ to open it. In Overview, ⌘⌥ with the arrows arranges the selected window."
        }
        self.window = window
    }

    private func button(_ title: String, _ selector: Selector, _ stack: NSStackView) {
        let view = NSButton(title: title, target: self, action: selector); view.bezelStyle = .rounded
        stack.addArrangedSubview(view)
    }

    @objc private func grantAccessibility() { service.requestAccessibility() }
    @objc private func openAccessibility() { service.openAccessibilitySettings() }
    @objc private func refreshWindows() { service.refresh() }
    @objc private func toggleShortcuts() { onToggleShortcuts?(shortcutButton.state == .on) }
    @objc private func toggleGesture() { onToggleGesture?(gestureButton.state == .on) }
    @objc private func togglePreviews() { onTogglePreviews?(previewButton.state == .on) }
    @objc private func toggleDesktopEntry() { onToggleDesktopEntry?(desktopEntryButton.state == .on) }
    @objc private func toggleSystemShowDesktop() { onToggleSystemShowDesktop?(systemShowDesktopButton.state == .on) }
    @objc private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
           NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
    @objc private func openTrackpadSettings() {
        if let url = URL(string: GestureGuidance.trackpadSettingsURL), NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
    @objc private func applyLayout() {
        guard let id = selectedWindow?() else { return }
        service.tile(id, zone: zones[zone.indexOfSelectedItem].1, screenIndex: display.indexOfSelectedItem == 0 ? nil : display.indexOfSelectedItem - 1)
    }
    @objc private func undoLayout() { service.undo() }
}
