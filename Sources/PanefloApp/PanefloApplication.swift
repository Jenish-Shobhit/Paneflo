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
    private var previewsEnabled = false
    private var desktop: DesktopController?
    private var sample: PreviewController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        RuntimeDiagnostics.mark("delegate launched")
        let controller = DesktopController(service: windows)
        desktop = controller
        windows.onChange = { [weak controller] in controller?.updateSnapshot() }
        windows.onStatus = { [weak controller] in controller?.setStatus($0) }
        controller.enablePreviewControl()
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
            if enabled { controller.refreshPreviewSelection() } else { self.capture.stop() }
        }
        controller.onToggleShortcuts = { [weak self] in self?.setShortcuts($0) }
        shortcuts.onAction = { [weak self] in self?.handle($0) }
        shortcuts.onStateChange = { [weak self, weak controller] state in
            controller?.setShortcutsEnabled(state == .active)
            if state == .active, let description = self?.shortcuts.installedTapDescription { controller?.setStatus("Shortcuts installed: \(description). ⌘Tab and ⌃⌥ controls are enabled.") }
            if case .failed(let message) = state { controller?.setStatus(message) }
        }
        installApplicationMenu()
        installMenu()
        windows.start()
        controller.present(mode: .switcher)
        RuntimeDiagnostics.mark("initial surface requested")
    }

    private func installApplicationMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu(title: "Paneflo")
        let about = NSMenuItem(title: "About Paneflo", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        about.target = NSApp; app.addItem(about); app.addItem(.separator())
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
        item.button?.title = " Paneflo"; item.button?.setAccessibilityLabel("Paneflo menu")
        let menu = NSMenu()
        for (index, title) in ["Switch windows", "Arrange windows", "Organized overview"].enumerated() {
            let entry = NSMenuItem(title: title, action: #selector(openDesktop(_:)), keyEquivalent: "")
            entry.target = self; entry.tag = index; menu.addItem(entry)
        }
        menu.addItem(.separator())
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

    private func setShortcuts(_ enabled: Bool) {
        guard enabled else { shortcuts.stop(); return }
        guard windows.hasAccessibility else {
            desktop?.setShortcutsEnabled(false); windows.requestAccessibility(); return
        }
        if !CGPreflightListenEventAccess(), !CGRequestListenEventAccess() {
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

    private func handle(_ action: ShortcutAction) {
        switch action {
        case .switchForward: desktop?.switchStep(backwards: false)
        case .switchBackward: desktop?.switchStep(backwards: true)
        case .commit: desktop?.commitShortcut()
        case .cancel: desktop?.dismiss()
        case .navigate(let direction): desktop?.navigate(direction)
        case .overview:
            if desktop?.isVisible == true { desktop?.dismiss() } else { desktop?.present(mode: .overview, fromShortcut: true) }
        case .tile(let zone): windows.tile(zone: zone)
        case .restore: windows.undo()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if desktop?.isVisible != true { desktop?.present(mode: .switcher) }
        return true
    }

    @objc private func openDesktop(_ sender: NSMenuItem) { desktop?.present(mode: DesktopMode(rawValue: sender.tag) ?? .switcher) }
    @objc private func disableShortcuts() { shortcuts.stop() }
    @objc private func refreshWindows() { windows.refresh() }
    @objc private func showSample() { if sample == nil { sample = PreviewController() }; sample?.present(mode: 0) }
    @objc private func quit() { shortcuts.stop(); capture.stop(); desktop?.dismiss(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { shortcuts.stop(); capture.stop() }
}
