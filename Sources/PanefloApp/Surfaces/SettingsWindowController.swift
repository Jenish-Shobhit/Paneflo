import AppKit
import PanefloCore

/// The Settings window, grouped as Permissions, Shortcuts, Gesture, Previews, Desktop, Updates and Menu bar. Controls
/// keep their state before the window exists; the window itself is built lazily on first open.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let shortcutButton = NSButton(checkboxWithTitle: "⌘Tab switcher and ⌃⌥ tiling shortcuts", target: nil, action: nil)
    let gestureButton = NSButton(checkboxWithTitle: GestureGuidance.toggleTitle, target: nil, action: nil)
    let gestureStatus = NSTextField(wrappingLabelWithString: "Off")
    /// Live reading of the system three-finger swipes; refreshed only when Settings opens or becomes key.
    let gestureGuidanceStatus = NSTextField(wrappingLabelWithString: "")
    private let gestureConflictSection = NSStackView()
    private let threeFingerDragNote = NSTextField(wrappingLabelWithString: GestureGuidance.threeFingerDragNote)
    let previewButton = NSButton(checkboxWithTitle: "Live previews", target: nil, action: nil)
    let desktopEntryButton = NSButton(checkboxWithTitle: "Show Desktop in ⌘Tab and Overview", target: nil, action: nil)
    let systemShowDesktopButton = NSButton(checkboxWithTitle: "Use macOS Show Desktop (experimental)", target: nil, action: nil)
    let raiseTogetherButton = NSButton(checkboxWithTitle: "Open tile pairs together", target: nil, action: nil)
    /// Screen Recording guidance next to the previews toggle; hidden when nothing is needed.
    let previewPermissionStatus = NSTextField(wrappingLabelWithString: "")
    private let previewPermissionSection = NSStackView()
    let status = NSTextField(wrappingLabelWithString: "")
    let automaticUpdatesButton = NSButton(checkboxWithTitle: "Check for updates automatically", target: nil, action: nil)
    let menuBarIconButton = NSButton(checkboxWithTitle: "Show menu bar icon", target: nil, action: nil)
    let launchAtLoginButton = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    let launchAtLoginStatus = NSTextField(wrappingLabelWithString: "")
    /// One line per permission ("Accessibility: On").
    private var permissionLabels: [SetupPermission: NSTextField] = [:]
    private let permissionSetupButton = NSButton(title: "Finish Setup…", target: nil, action: nil)
    private(set) var permissionRows: [SetupRow] = []
    var onToggleShortcuts: ((Bool) -> Void)?
    var onToggleGesture: ((Bool) -> Void)?
    var onTogglePreviews: ((Bool) -> Void)?
    var onToggleDesktopEntry: ((Bool) -> Void)?
    var onToggleSystemShowDesktop: ((Bool) -> Void)?
    var onToggleRaiseTogether: ((Bool) -> Void)?
    var onToggleAutomaticUpdates: ((Bool) -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onToggleMenuBarIcon: ((Bool) -> Void)?
    var onToggleLaunchAtLogin: ((Bool) -> Void)?
    var onOpenSetup: (() -> Void)?
    var onGrantScreenRecording: (() -> Void)?
    /// Settings became key: permissions may have changed in System Settings.
    var onRefreshScreenRecording: (() -> Void)?
    private static let width: CGFloat = 520

    override init() {
        super.init()
        for permission in SetupPermission.allCases {
            let label = NSTextField(labelWithString: "\(permission.title): checking…")
            label.font = .systemFont(ofSize: 12)
            permissionLabels[permission] = label
        }
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        previewButton.isEnabled = false
        previewPermissionStatus.font = .systemFont(ofSize: 11); previewPermissionStatus.textColor = .secondaryLabelColor
        previewPermissionStatus.setAccessibilityLabel("Screen Recording status for previews")
        previewPermissionSection.isHidden = true
        menuBarIconButton.state = .on
        launchAtLoginStatus.font = .systemFont(ofSize: 11); launchAtLoginStatus.textColor = .secondaryLabelColor
        launchAtLoginStatus.isHidden = true
    }

    func setPreviewPermissionMessage(_ message: String?) {
        if previewPermissionStatus.stringValue != (message ?? "") { previewPermissionStatus.stringValue = message ?? "" }
        if previewPermissionSection.isHidden != (message == nil) { previewPermissionSection.isHidden = message == nil }
    }

    /// Inline permission status; "Finish Setup…" shows while something required is missing.
    func setPermissionRows(_ rows: [SetupRow]) {
        guard rows != permissionRows else { return }
        permissionRows = rows
        for row in rows {
            let text: String
            switch row.status {
            case .granted: text = "On"
            case .missing: text = row.required ? "Off (required)" : "Off (optional, for previews)"
            case .needsRestart: text = "Restart Paneflo to apply"
            }
            permissionLabels[row.permission]?.stringValue = "\(row.status == .granted ? "✓" : "•") \(row.permission.title): \(text)"
            permissionLabels[row.permission]?.textColor = row.status == .granted ? .labelColor
                : row.required || row.status == .needsRestart ? .systemOrange : .secondaryLabelColor
        }
        permissionSetupButton.title = rows.contains { $0.required && !$0.isGranted } ? "Finish Setup…" : "Permission Setup…"
    }

    func setLaunchAtLoginNote(_ note: String?) {
        launchAtLoginStatus.stringValue = note ?? ""
        launchAtLoginStatus.isHidden = note == nil
    }

    var isConstructed: Bool { window != nil }
    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil { configure() }
        refreshGestureGuidance()
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
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

    // MARK: Construction

    private func configure() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width + 64, height: 680),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Paneflo Settings"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: Self.width + 64, height: 360)
        window.contentMaxSize = NSSize(width: Self.width + 64, height: 4000)
        window.delegate = self
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.autohidesScrollers = true
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        window.contentView = scroll
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
        ])

        header("Permissions", stack, first: true)
        for permission in SetupPermission.allCases { if let label = permissionLabels[permission] { stack.addArrangedSubview(label) } }
        permissionSetupButton.target = self; permissionSetupButton.action = #selector(openSetup)
        permissionSetupButton.bezelStyle = .push
        stack.addArrangedSubview(permissionSetupButton)

        header("Shortcuts", stack)
        shortcutButton.target = self; shortcutButton.action = #selector(toggleShortcuts)
        shortcutButton.setAccessibilityLabel("Enable Paneflo shortcuts")
        stack.addArrangedSubview(shortcutButton)
        stack.addArrangedSubview(note("⌘Tab picks a window. Keep holding ⌘: Tab or the arrow keys choose, ⌥← → ↑ arrange it, ⌥↓ undoes, release ⌘ to open it. ⌃⌥Space opens the Overview; ⌃⌥ with the arrows tiles the focused window."))
        status.preferredMaxLayoutWidth = Self.width
        stack.addArrangedSubview(status)

        header("Trackpad gesture", stack)
        gestureButton.target = self; gestureButton.action = #selector(toggleGesture)
        stack.addArrangedSubview(gestureButton)
        stack.addArrangedSubview(note(GestureGuidance.requirements))
        gestureStatus.font = .systemFont(ofSize: 11); gestureStatus.textColor = .secondaryLabelColor
        gestureStatus.preferredMaxLayoutWidth = Self.width
        stack.addArrangedSubview(gestureStatus)
        gestureConflictSection.orientation = .vertical; gestureConflictSection.alignment = .leading; gestureConflictSection.spacing = 4
        let conflictTitle = NSTextField(labelWithString: GestureGuidance.conflictTitle)
        conflictTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        gestureConflictSection.addArrangedSubview(conflictTitle)
        for text in [GestureGuidance.conflictExplanation, "• " + GestureGuidance.missionControlStep, "• " + GestureGuidance.appExposeStep] {
            gestureConflictSection.addArrangedSubview(note(text))
        }
        stack.addArrangedSubview(gestureConflictSection)
        for label in [threeFingerDragNote, gestureGuidanceStatus] {
            label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = Self.width
            stack.addArrangedSubview(label)
        }
        gestureGuidanceStatus.setAccessibilityLabel("System three-finger swipe status")
        stack.addArrangedSubview(button(GestureGuidance.openSettingsButton, #selector(openTrackpadSettings)))

        header("Previews", stack)
        previewButton.target = self; previewButton.action = #selector(togglePreviews)
        previewButton.setAccessibilityLabel("Enable live window previews")
        stack.addArrangedSubview(previewButton)
        previewPermissionSection.orientation = .vertical; previewPermissionSection.alignment = .leading; previewPermissionSection.spacing = 6
        previewPermissionStatus.preferredMaxLayoutWidth = Self.width
        previewPermissionSection.addArrangedSubview(previewPermissionStatus)
        previewPermissionSection.addArrangedSubview(button("Grant Screen Recording…", #selector(grantScreenRecording)))
        stack.addArrangedSubview(previewPermissionSection)

        header("Desktop", stack)
        desktopEntryButton.target = self; desktopEntryButton.action = #selector(toggleDesktopEntry)
        desktopEntryButton.setAccessibilityLabel("Show Desktop in Command-Tab and Overview")
        stack.addArrangedSubview(desktopEntryButton)
        systemShowDesktopButton.target = self; systemShowDesktopButton.action = #selector(toggleSystemShowDesktop)
        systemShowDesktopButton.setAccessibilityLabel("Use macOS Show Desktop, experimental")
        stack.addArrangedSubview(systemShowDesktopButton)
        stack.addArrangedSubview(note("Desktop hides other apps (Finder stays) and choosing a window brings back only its app. The experimental option sends your macOS Show Desktop shortcut instead; it needs permission to post keys and is untested on most setups."))

        header("Tile pairs", stack)
        raiseTogetherButton.target = self; raiseTogetherButton.action = #selector(toggleRaiseTogether)
        raiseTogetherButton.setAccessibilityLabel("Open tile pairs together")
        stack.addArrangedSubview(raiseTogetherButton)
        stack.addArrangedSubview(note("Two windows in the left and right (or top and bottom) halves of one display form a pair. Opening one from ⌘Tab or the Overview brings its partner forward too. ⌘⌥Return always opens the pair."))

        header("Updates", stack)
        automaticUpdatesButton.target = self; automaticUpdatesButton.action = #selector(toggleAutomaticUpdates)
        stack.addArrangedSubview(automaticUpdatesButton)
        stack.addArrangedSubview(button("Check for Updates…", #selector(checkForUpdates)))

        header("Menu bar", stack)
        menuBarIconButton.target = self; menuBarIconButton.action = #selector(toggleMenuBarIcon)
        stack.addArrangedSubview(menuBarIconButton)
        stack.addArrangedSubview(note("With the icon hidden Paneflo keeps running. Open Paneflo again from Finder, Spotlight or Launchpad to get back here."))
        launchAtLoginButton.target = self; launchAtLoginButton.action = #selector(toggleLaunchAtLogin)
        stack.addArrangedSubview(launchAtLoginButton)
        launchAtLoginStatus.preferredMaxLayoutWidth = Self.width
        stack.addArrangedSubview(launchAtLoginStatus)
        self.window = window
    }

    private func header(_ title: String, _ stack: NSStackView, first: Bool = false) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        if !first {
            // A fixed gap, so the spacing holds even when the section above ends in a hidden view.
            let gap = NSView()
            gap.translatesAutoresizingMaskIntoConstraints = false
            gap.heightAnchor.constraint(equalToConstant: 8).isActive = true
            stack.addArrangedSubview(gap)
        }
        stack.addArrangedSubview(label)
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = Self.width
        return label
    }

    private func button(_ title: String, _ selector: Selector) -> NSButton {
        let view = NSButton(title: title, target: self, action: selector); view.bezelStyle = .push
        return view
    }

    @objc private func openSetup() { onOpenSetup?() }
    @objc private func toggleShortcuts() { onToggleShortcuts?(shortcutButton.state == .on) }
    @objc private func toggleGesture() { onToggleGesture?(gestureButton.state == .on) }
    @objc private func togglePreviews() { onTogglePreviews?(previewButton.state == .on) }
    @objc private func toggleDesktopEntry() { onToggleDesktopEntry?(desktopEntryButton.state == .on) }
    @objc private func toggleSystemShowDesktop() { onToggleSystemShowDesktop?(systemShowDesktopButton.state == .on) }
    @objc private func toggleRaiseTogether() { onToggleRaiseTogether?(raiseTogetherButton.state == .on) }
    @objc private func toggleAutomaticUpdates() { onToggleAutomaticUpdates?(automaticUpdatesButton.state == .on) }
    @objc private func checkForUpdates() { onCheckForUpdates?() }
    @objc private func toggleMenuBarIcon() { onToggleMenuBarIcon?(menuBarIconButton.state == .on) }
    @objc private func toggleLaunchAtLogin() { onToggleLaunchAtLogin?(launchAtLoginButton.state == .on) }
    @objc private func grantScreenRecording() { onGrantScreenRecording?() }
    @objc private func openTrackpadSettings() {
        if let url = URL(string: GestureGuidance.trackpadSettingsURL), NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    #if PANEFLO_NATIVE_CHECK
    func nativeCheckPermissionLine(_ permission: SetupPermission) -> String { permissionLabels[permission]?.stringValue ?? "" }
    var nativeCheckWindow: NSWindow? { window }
    #endif
}

/// Top-left origin, so the Settings content starts at the top of its scroll view.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
