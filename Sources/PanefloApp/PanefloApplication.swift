import AppKit
import PanefloCore

@main
struct PanefloApplication {
    @MainActor static func main() {
        if RuntimeDiagnostics.handleCommandLine() { return }
        RuntimeDiagnostics.mark("entry")
        let application = NSApplication.shared
        RuntimeDiagnostics.mark("application initialized")
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let windows = WindowService()
    private let shortcuts = GlobalShortcutService()
    private let capture = CaptureController()
    private let gestures = TrackpadGestureService.shared
    private let preferences = UserDefaults.standard
    private var startupShortcutRestorePending = false
    private var startupGestureRestorePending = false
    private var previewsEnabled = false
    private var desktop: DesktopController?
    private var sample: PreviewController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        RuntimeDiagnostics.mark("delegate launched")
        let controller = DesktopController(service: windows)
        desktop = controller
        windows.onChange = { [weak self, weak controller] in
            controller?.updateSnapshot()
            self?.restoreStartupShortcutsIfReady()
            self?.restoreStartupGesturesIfReady()
        }
        windows.onStatus = { [weak controller] in controller?.setStatus($0) }
        controller.enablePreviewControl()
        capture.onThumbnail = { [weak controller] request, image in controller?.showThumbnail(image, for: request.id) }
        capture.onThumbnailsCleared = { [weak controller] in controller?.clearThumbnails() }
        capture.isThumbnailCurrent = { [weak self] request in
            guard let self else { return false }
            return request.id.process.pid == request.ownerPID && self.windows.captureWindowNumber(for: request.id) == request.windowNumber
        }
        controller.onThumbnailViewport = { [weak self] requests, visible, surviving in
            guard let self else { return }
            self.capture.selectVisibleThumbnails(requests, visible: visible && self.previewsEnabled, surviving: surviving)
        }
        capture.onImage = { [weak controller] in controller?.showPreview($0, label: $1) }
        controller.onPreviewSelection = { [weak self] number, visible, ownerPID in
            guard let self else { return }
            if self.previewsEnabled { self.capture.select(windowNumber: number, visible: visible, ownerPID: ownerPID) }
            else { self.capture.stop() }
        }
        controller.onTogglePreviews = { [weak self] enabled in
            guard let self else { return }
            if enabled && !self.capture.hasPermission && !self.capture.requestPermission() {
                controller.setPreviewsEnabled(false)
                controller.setStatus("Enable Screen Recording for Paneflo in Privacy & Security, then enable previews again.")
                return
            }
            self.previewsEnabled = enabled
            self.preferences.set(enabled, forKey: "previews.enabled.v1")
            if enabled { controller.refreshPreviewSelection() } else { self.capture.stop() }
        }
        controller.onCompositionChanged = { [weak self] in self?.shortcuts.compositionActive = $0 }
        controller.onVisibilityChanged = { [weak self] in self?.shortcuts.selectionContextActive = $0 }
        controller.onSurfaceVisibilityChanged = { [weak self] in self?.shortcuts.surfaceVisible = $0 }
        controller.onToggleGesture = { [weak self] in self?.setGestures($0) }
        controller.onToggleShortcuts = { [weak self] in self?.setShortcuts($0) }
        shortcuts.onAction = { [weak self] in self?.handle($0) }
        shortcuts.onStateChange = { [weak self, weak controller] state in
            controller?.setShortcutsEnabled(state == .active)
            if state == .active, let description = self?.shortcuts.installedTapDescription { controller?.setStatus("Shortcuts installed: \(description). ⌘Tab and ⌃⌥ controls are enabled.") }
            if state == .active { self?.preferences.set(true, forKey: "shortcuts.enabled.v1") }
            if case .failed(let message) = state {
                self?.preferences.set(false, forKey: "shortcuts.enabled.v1")
                controller?.setStatus(message)
            }
        }
        gestures.onGestureEvent = { [weak self] event in
            guard let self else { return }
            switch event.direction {
            case .up:
                self.desktop?.focusOverview(recognizedAtUptimeNanoseconds: event.recognizedAtUptimeNanoseconds)
            case .down:
                if self.desktop?.isOverviewVisible == true { self.desktop?.dismiss() }
            }
        }
        gestures.onStateChange = { [weak self] state in self?.showGestureState(state) }
        gestures.diagnosticCountsOnStop = RuntimeDiagnostics.isEnabled
        gestures.onDiagnostics = { counts in
            RuntimeDiagnostics.mark("gesture frames=\(counts.frames) contacts=\(counts.contacts) rejectedFrames=\(counts.rejectedFrames) gestures=\(counts.gestures) up=\(counts.upGestures) down=\(counts.downGestures) palmOrRimContacts=\(counts.palmOrRimContacts)")
        }
        installApplicationMenu()
        installMenu()
        startupShortcutRestorePending = preferences.bool(forKey: "shortcuts.enabled.v1")
        startupGestureRestorePending = preferences.bool(forKey: "gesture.enabled.v1")
        let savedPreviews = preferences.bool(forKey: "previews.enabled.v1")
        let accessibilityReady = windows.hasAccessibility
        let inputMonitoringReady = CGPreflightListenEventAccess()
        let screenRecordingReady = capture.hasPermission
        RuntimeDiagnostics.mark("permissions accessibility=\(accessibilityReady) inputMonitoring=\(inputMonitoringReady) screenRecording=\(screenRecordingReady)")
        previewsEnabled = savedPreviews && screenRecordingReady
        controller.setPreviewsEnabled(previewsEnabled)
        let missingPermission = !accessibilityReady
            || ((startupShortcutRestorePending || startupGestureRestorePending) && !inputMonitoringReady)
            || (savedPreviews && !screenRecordingReady)
        let firstLaunch = !preferences.bool(forKey: "startup.completed.v1")
        preferences.set(true, forKey: "startup.completed.v1")
        windows.start()
        if missingPermission || firstLaunch { controller.showPreferences() }
        // Pay both panels' first-display cost now, so the first ⌘Tab and Overview are warm.
        DispatchQueue.main.async { [weak controller] in controller?.prewarm() }
        // updates hook: isBusy defers automatic checks and offers while a switcher or overview session is showing.
        UpdateController.shared.start(isBusy: { [weak self] in self?.desktop?.isVisible == true },
                                      report: { [weak self] in self?.desktop?.setStatus($0) })
        RuntimeDiagnostics.mark("startup menuReady=true settingsShown=\(missingPermission || firstLaunch)")
    }

    private func installApplicationMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu(title: "Paneflo")
        let about = NSMenuItem(title: "About Paneflo", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        about.target = NSApp; app.addItem(about); app.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; app.addItem(settings); app.addItem(.separator())
        let hide = NSMenuItem(title: "Hide Paneflo", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp; app.addItem(hide)
        app.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Paneflo", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; app.addItem(quit)
        appItem.submenu = app; main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        editItem.submenu = edit; main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func installMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Paneflo")
        item.button?.title = ""; item.button?.toolTip = "Paneflo"
        item.button?.setAccessibilityLabel("Paneflo menu")
        let menu = NSMenu()
        for (index, title) in ["Switch windows", "Arrange windows", "Organized overview"].enumerated() {
            let entry = NSMenuItem(title: title, action: #selector(openDesktop(_:)), keyEquivalent: "")
            entry.target = self; entry.tag = index; menu.addItem(entry)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        UpdateMenu.shared.addItems(to: menu) // updates hook
        let disable = NSMenuItem(title: "Disable global shortcuts", action: #selector(disableShortcuts), keyEquivalent: "")
        disable.target = self; menu.addItem(disable)
        let refresh = NSMenuItem(title: "Refresh windows", action: #selector(refreshWindows), keyEquivalent: "")
        refresh.target = self; menu.addItem(refresh)
        let preview = NSMenuItem(title: "Synthetic developer fixtures", action: #selector(showSample), keyEquivalent: "")
        preview.target = self; menu.addItem(preview)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Paneflo", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        item.menu = menu; statusItem = item
    }

    private func restoreStartupShortcutsIfReady() {
        guard startupShortcutRestorePending, !windows.snapshot.records.isEmpty else { return }
        startupShortcutRestorePending = false
        guard windows.hasAccessibility, CGPreflightListenEventAccess() else {
            desktop?.setStatus("Saved shortcuts need Accessibility and Input Monitoring. Enable them in Settings when ready.")
            return
        }
        setShortcuts(true, allowPermissionRequest: false)
    }

    private func restoreStartupGesturesIfReady() {
        guard startupGestureRestorePending, !windows.snapshot.records.isEmpty else { return }
        startupGestureRestorePending = false
        guard windows.hasAccessibility, CGPreflightListenEventAccess() else {
            desktop?.setGestureState(enabled: false, description: "Saved gesture needs Accessibility and Input Monitoring. Enable it in Settings when ready.")
            return
        }
        if !gestures.start() { preferences.set(false, forKey: "gesture.enabled.v1") }
        showGestureState(gestures.state)
    }

    private func setGestures(_ enabled: Bool) {
        startupGestureRestorePending = false
        preferences.set(enabled, forKey: "gesture.enabled.v1")
        if !enabled { gestures.stop(); return }
        if !CGPreflightListenEventAccess(), !CGRequestListenEventAccess() {
            preferences.set(false, forKey: "gesture.enabled.v1")
            desktop?.setGestureState(enabled: false, description: "Enable Input Monitoring in Privacy & Security, then try again.")
            return
        }
        if !gestures.start() { preferences.set(false, forKey: "gesture.enabled.v1") }
        showGestureState(gestures.state)
    }

    private func showGestureState(_ state: TrackpadGestureService.State) {
        let message: String
        let diagnostic: String
        switch state {
        case .disabled: message = "Off"; diagnostic = "disabled"
        case .starting: message = "Starting…"; diagnostic = "starting"
        case .active: message = "Ready · swipe up for Overview, down to dismiss it."; diagnostic = "active"
        case .stopping: message = "Stopping…"; diagnostic = "stopping"
        case .paused: message = "Paused while the display or session is inactive."; diagnostic = "paused"
        case .unavailable(let reason):
            preferences.set(false, forKey: "gesture.enabled.v1")
            message = reason; diagnostic = "unavailable"
        case .failed(let reason):
            preferences.set(false, forKey: "gesture.enabled.v1")
            message = reason; diagnostic = "failed"
        }
        desktop?.setGestureState(enabled: gestures.isEnabled, description: message)
        RuntimeDiagnostics.mark("gesture state=\(diagnostic) enabled=\(gestures.isEnabled)")
    }

    private func setShortcuts(_ enabled: Bool, allowPermissionRequest: Bool = true) {
        startupShortcutRestorePending = false
        guard enabled else {
            preferences.set(false, forKey: "shortcuts.enabled.v1")
            shortcuts.stop(); return
        }
        guard windows.hasAccessibility else {
            desktop?.setShortcutsEnabled(false); if allowPermissionRequest { windows.requestAccessibility() }; return
        }
        if !CGPreflightListenEventAccess(), (!allowPermissionRequest || !CGRequestListenEventAccess()) {
            desktop?.setShortcutsEnabled(false)
            desktop?.setStatus("Enable Paneflo in Privacy & Security → Input Monitoring, then enable shortcuts again.")
            return
        }
        guard !windows.snapshot.records.isEmpty else {
            desktop?.setShortcutsEnabled(false); desktop?.setStatus("Open a normal window and refresh before enabling shortcuts."); return
        }
        var tiling: [ShortcutChord: ShortcutAction] = [:]
        let modifiers: ShortcutModifiers = [.control, .option]
        for (key, zone) in [(UInt16(123), LayoutZone.leftHalf), (124, .rightHalf), (126, .topHalf), (125, .bottomHalf), (36, .maximize)] {
            tiling[ShortcutChord(keyCode: key, modifiers: modifiers)] = .tile(zone)
        }
        tiling[ShortcutChord(keyCode: 6, modifiers: modifiers)] = .restore
        _ = shortcuts.start(configuration: .init(switcherEnabled: true, overview: ShortcutChord(keyCode: 49, modifiers: modifiers), tiling: tiling))
    }

    /// Queued actions never expire. One is dropped only when the surface it targets is gone;
    /// the controller methods guard their own surface state.
    private func handle(_ action: ShortcutAction) {
        switch action {
        case .switchForward: desktop?.switchStep(backwards: false)
        case .switchBackward: desktop?.switchStep(backwards: true)
        case .commit: desktop?.commitShortcut()
        case .cancel: if desktop?.isVisible == true { desktop?.dismiss() }
        case .navigate(let direction): desktop?.navigate(direction)
        case .navigateRow(let direction): desktop?.navigateRow(direction)
        case .overview:
            if desktop?.isVisible == true { desktop?.dismiss() } else { desktop?.present(mode: .overview, fromShortcut: true) }
        case .tileSelected(let zone): desktop?.tileSelected(zone)
        case .tile(let zone):
            if desktop?.isVisible == true { desktop?.tileSelected(zone) }
            else { windows.tile(zone: zone) }
        case .restore: windows.undo()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) { desktop?.updateKeyboardOwnership() }
    func applicationDidResignActive(_ notification: Notification) { desktop?.updateKeyboardOwnership() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if desktop?.isVisible != true { desktop?.present(mode: .switcher) }
        return true
    }

    @objc private func openDesktop(_ sender: NSMenuItem) { desktop?.present(mode: DesktopMode(rawValue: sender.tag) ?? .switcher) }
    @objc private func showSettings() { desktop?.showPreferences() }
    @objc private func disableShortcuts() { setShortcuts(false) }
    @objc private func refreshWindows() { windows.refresh() }
    @objc private func showSample() { if sample == nil { sample = PreviewController() }; sample?.present(mode: 0) }
    @objc private func quit() { gestures.stop(); shortcuts.stop(); capture.stop(); desktop?.dismiss(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { gestures.stop(); shortcuts.stop(); capture.stop() }
}
