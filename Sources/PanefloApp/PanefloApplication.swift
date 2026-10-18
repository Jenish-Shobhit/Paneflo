import AppKit
import PanefloCore
import ServiceManagement

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
    private let windows = WindowService()
    private let shortcuts = GlobalShortcutService()
    private let capture = CaptureController()
    private let gestures = TrackpadGestureService.shared
    /// Show Desktop for the switcher's Desktop card and the Overview home tile.
    private let desktopService = DesktopService()
    private var desktopEntry: DesktopEntryController?
    private let preferences = UserDefaults.standard
    private let setupPreferences = SetupPreferences()
    private let setup = SetupWindowController()
    private lazy var statusMenu = StatusMenuController(preferences: setupPreferences)
    /// The user's previews choice combined with Screen Recording. Capture runs only while this is on.
    private var previewsEnabled = false
    /// The user asked for previews in this process, so re-probing Screen Recording is expected.
    private var previewPermissionRequested = false
    private var desktop: DesktopController?
    private var sample: PreviewController?

    // Setup state for this process (see `SetupModel`).
    private var requestedPermissions: Set<SetupPermission> = []
    private var serviceNeedsRestart: Set<SetupPermission> = []
    private var missingBeforeRelaunch: Set<SetupPermission> = []
    private var awaitingReturnFromSettings = false
    private var returnedFromSettings = false
    private var lastPermissions: PermissionState?
    /// One automatic start attempt per permission reading; a change in permissions allows another.
    private var shortcutAutoStartBlocked = false
    private var gestureAutoStartBlocked = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        RuntimeDiagnostics.mark("delegate launched")
        StartupRecovery.launch(defaults: preferences)
        missingBeforeRelaunch = setupPreferences.takeMissingBeforeRelaunch()
        let controller = DesktopController(service: windows)
        desktop = controller
        let entry = DesktopEntryController(service: desktopService, settings: DesktopSettings())
        desktopEntry = entry
        controller.desktopEntry = entry
        desktopService.onChange = { [weak controller] in controller?.desktopStateChanged() }
        desktopService.start()
        controller.setDesktopSettings(showsEntry: entry.showsDesktopEntry, usesSystemShowDesktop: entry.usesSystemShowDesktop)
        controller.onToggleDesktopEntry = { [weak entry, weak controller] enabled in
            entry?.showsDesktopEntry = enabled
            controller?.desktopStateChanged()
        }
        controller.onToggleSystemShowDesktop = { [weak entry] enabled in entry?.usesSystemShowDesktop = enabled }
        // Lock, display sleep and fast user switching: no window snapshot stays cached (the surface is closed and
        // the live stream stopped by the dismissal itself).
        controller.onPrivacyPurge = { [weak self] in self?.capture.purge(reason: "sessionSuspended") }
        windows.onChange = { [weak self, weak controller] in
            if let self, self.previewsEnabled { self.capture.windowsChanged(alive: Set(self.windows.snapshot.records.map(\.id))) }
            controller?.updateSnapshot()
            self?.startFeaturesAfterRegistryChange()
        }
        windows.onStatus = { [weak controller] in controller?.setStatus($0) }
        controller.enablePreviewControl()
        controller.onTogglePreviews = { [weak self] enabled in self?.setPreviews(enabled) }
        capture.onScreenRecordingStatusChange = { [weak self] status in
            guard let self else { return }
            RuntimeDiagnostics.mark("previews screenRecording=\(status) enabled=\(self.previewsEnabled)")
            self.reconcile()
            if status == .granted, self.previewsEnabled { self.capture.prewarm() }
        }
        controller.onRefreshScreenRecording = { [weak self] in
            guard let self else { return }
            if self.previewPermissionRequested, self.setupPreferences.previewsEnabled,
               self.capture.screenRecordingStatus != .granted { self.capture.refreshScreenRecordingStatus() }
            self.reconcile()
        }
        controller.onCompositionChanged = { [weak self] in self?.shortcuts.compositionActive = $0 }
        controller.onVisibilityChanged = { [weak self] in self?.shortcuts.selectionContextActive = $0 }
        controller.onSurfaceVisibilityChanged = { [weak self] in self?.shortcuts.surfaceVisible = $0 }
        controller.onToggleGesture = { [weak self] in self?.setGestures($0) }
        controller.onToggleShortcuts = { [weak self] in self?.setShortcuts($0) }
        configureSettings(controller.settingsController)
        configureSetup()
        shortcuts.onAction = { [weak self] in self?.handle($0) }
        shortcuts.onWindowCommand = { [weak self] command in
            guard let self, let id = self.desktop?.switcherSelection else { return }
            self.windows.perform(command, on: id)
        }
        shortcuts.onStateChange = { [weak self] state in self?.shortcutStateChanged(state) }
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
        installStatusMenu()
        let permissions = readPermissions()
        RuntimeDiagnostics.mark("permissions accessibility=\(permissions.accessibility) inputMonitoring=\(permissions.inputMonitoring) screenRecording=\(permissions.screenRecording)")
        previewsEnabled = setupPreferences.previewsEnabled && permissions.screenRecording
        updatePreviewState()
        if !setupPreferences.gestureEnabled { desktop?.setGestureState(enabled: false, description: "Off") }
        windows.start()
        let model = reconcile(permissions)
        // Never Settings at launch. Setup only while something required is missing, and once per launch.
        let showsSetup = !RuntimeDiagnostics.benchNoInput && model.showsAtLaunch(alreadyShownThisLaunch: false)
        if showsSetup {
            let step = SetupFlow.openingStep(for: model, welcomeSeen: setupPreferences.welcomeSeen)
            setupPreferences.welcomeSeen = true
            showSetup(step: step)
        }
        // Pay both panels' first-display cost now, so the first ⌘Tab and Overview are warm.
        DispatchQueue.main.async { [weak controller] in controller?.prewarm() }
        // Warm ScreenCaptureKit (first request ~1 s) after startup, off the launch and input paths.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.previewsEnabled else { return }
            self.capture.prewarm()
        }
        // updates hook: isBusy defers automatic checks and offers while a switcher or overview session is showing.
        if !RuntimeDiagnostics.benchNoInput { UpdateController.shared.start(isBusy: { [weak self] in self?.desktop?.isVisible == true },
                                      report: { [weak self] in self?.desktop?.setStatus($0) }) }
        RuntimeDiagnostics.mark("startup menuReady=true settingsShown=false setupShown=\(showsSetup) staleHint=\(model.showsStaleHint)")
    }

    // MARK: Setup and permissions

    private func readPermissions() -> PermissionState {
        PermissionState(accessibility: windows.hasAccessibility, inputMonitoring: CGPreflightListenEventAccess(),
                        screenRecording: capture.hasPermission)
    }

    private func setupModel(_ permissions: PermissionState) -> SetupModel {
        SetupModel(permissions: permissions, intent: setupPreferences.intent, requested: requestedPermissions,
                   serviceNeedsRestart: serviceNeedsRestart, missingBeforeRelaunch: missingBeforeRelaunch,
                   returnedFromSettings: returnedFromSettings)
    }

    /// Reads permissions, starts whatever the saved choices and permissions now allow, and refreshes the setup window,
    /// the Settings permission lines and the menu badge. Called at launch, once a second while setup is visible, when
    /// Paneflo or Settings becomes active, and after any permission action. Never on the input path.
    @discardableResult
    private func reconcile(_ reading: PermissionState? = nil) -> SetupModel {
        let permissions = reading ?? readPermissions()
        if permissions != lastPermissions {
            shortcutAutoStartBlocked = false
            gestureAutoStartBlocked = false
            if let lastPermissions {
                RuntimeDiagnostics.mark("permissions changed accessibility=\(permissions.accessibility) inputMonitoring=\(permissions.inputMonitoring) screenRecording=\(permissions.screenRecording)")
                if permissions.accessibility, !lastPermissions.accessibility { windows.refresh() }
                if permissions.inputMonitoring { serviceNeedsRestart.remove(.inputMonitoring) }
            }
            lastPermissions = permissions
        }
        if setupPreferences.noteSetup(setupModel(permissions)) { RuntimeDiagnostics.mark("setup complete shortcuts=on") }
        startShortcutsIfReady(setupModel(permissions))
        startGestureIfReady(setupModel(permissions))
        startPreviewsIfReady(permissions)
        return publishSetup(permissions)
    }

    /// Pushes the current model to the setup window, Settings and the menu, without reading permissions again.
    @discardableResult
    private func publishSetup(_ permissions: PermissionState? = nil) -> SetupModel {
        let model = setupModel(permissions ?? lastPermissions ?? readPermissions())
        setup.update(model)
        desktop?.settingsController.setSetupModel(model)
        let wanted = setupPreferences.shortcutsEnabled
        let status = PanefloStatus(setupComplete: model.isComplete, shortcutsWanted: wanted, shortcutsActive: shortcuts.state == .active)
        statusMenu.update(status: status, shortcutsWanted: wanted)
        desktop?.settingsController.setShortcutState(wanted: wanted, status: status)
        return model
    }

    /// Without a step, a setup window already on screen keeps its step and a hidden one opens on Permissions.
    private func showSetup(step: SetupStep? = nil) {
        reconcile()
        setup.show(step: step)
    }

    private func configureSetup() {
        setup.onPoll = { [weak self] in self?.reconcile() }
        setup.onGrant = { [weak self] in self?.grant($0) }
        setup.onRestart = { [weak self] in self?.restartForPermissions() }
        setup.onReset = { [weak self] in self?.resetPermissions() }
        setup.onToggleGesture = { [weak self] in self?.setGestures($0) }
        setup.onOpenSettings = { [weak self] in self?.showSettings(pane: $0) }
    }

    /// Grant…: the system request, plus the exact System Settings pane, for one permission.
    private func grant(_ permission: SetupPermission) {
        requestedPermissions.insert(permission)
        awaitingReturnFromSettings = true
        RuntimeDiagnostics.mark("setup grant \(permission.rawValue)")
        switch permission {
        case .accessibility:
            windows.requestAccessibility()
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        case .screenRecording:
            previewPermissionRequested = true
            setupPreferences.previewsEnabled = true
            previewsEnabled = true
            _ = capture.requestPermission()
        }
        if let url = URL(string: permission.settingsURL) { NSWorkspace.shared.open(url) }
        reconcile()
    }

    /// Restart Paneflo: records what is still off (so the next launch can spot a stuck permission), starts a helper
    /// that reopens Paneflo once this process has exited, and quits.
    private func restartForPermissions() {
        let model = setupModel(readPermissions())
        setupPreferences.missingBeforeRelaunch = model.missingForRelaunch
        RuntimeDiagnostics.mark("setup restart missing=\(model.missingForRelaunch.map(\.rawValue).sorted())")
        guard let arguments = RelaunchHelper.arguments(bundlePath: Bundle.main.bundlePath,
                                                       pid: ProcessInfo.processInfo.processIdentifier) else {
            showAlert("Quit and open Paneflo again", "This copy of Paneflo is not running from an app bundle, so it can’t reopen itself.")
            return
        }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = arguments
        do {
            try helper.run()
        } catch {
            showAlert("Couldn’t restart Paneflo", "Quit Paneflo from its menu and open it again.")
            return
        }
        quit()
    }

    /// "Permissions stuck? Reset and grant again": clears Paneflo's own TCC entries (never another app's), then starts
    /// the Grant flow again from the first permission.
    private func resetPermissions() {
        let invocations = PermissionReset.invocations(bundleID: Bundle.main.bundleIdentifier)
        guard !invocations.isEmpty else {
            showAlert("Can’t reset permissions", "This copy of Paneflo has no bundle identifier. Run the app from /Applications.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Reset Paneflo’s permissions?"
        alert.informativeText = PermissionReset.explanation + " You’ll switch Paneflo on again in each pane, and restart it when asked."
        alert.addButton(withTitle: "Reset and Grant Again")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        RuntimeDiagnostics.mark("setup reset services=\(invocations.count)")
        let tool = PermissionReset.tool
        Task.detached(priority: .userInitiated) {
            var failures = 0
            for arguments in invocations {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do { try process.run(); process.waitUntilExit(); if process.terminationStatus != 0 { failures += 1 } }
                catch { failures += 1 }
            }
            let failed = failures
            await MainActor.run { [weak self] in self?.permissionsReset(failures: failed) }
        }
    }

    private func permissionsReset(failures: Int) {
        RuntimeDiagnostics.mark("setup reset failures=\(failures)")
        requestedPermissions = []
        serviceNeedsRestart = []
        missingBeforeRelaunch = []
        returnedFromSettings = false
        awaitingReturnFromSettings = false
        if failures > 0 {
            showAlert("Some permissions couldn’t be reset", "Remove Paneflo from the lists in System Settings › Privacy & Security with the minus button, then grant it again.")
        }
        let model = reconcile()
        let next = model.missingRequired.first ?? .accessibility
        grant(next)
        if !setup.isVisible { setup.show(step: .permissions) }
    }

    private func showAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Registry changes are frequent: they read no permissions and only retry a start the last reading allowed (the
    /// shortcuts wait for the first window list).
    private func startFeaturesAfterRegistryChange() {
        guard let permissions = lastPermissions else { return }
        let model = setupModel(permissions)
        if model.startsShortcuts, !shortcutAutoStartBlocked, shortcuts.state == .disabled { startShortcutsIfReady(model) }
    }

    private func startShortcutsIfReady(_ model: SetupModel) {
        guard model.startsShortcuts, !shortcutAutoStartBlocked else { return }
        switch shortcuts.state {
        case .disabled, .failed: break
        case .arming, .active, .releasing, .interrupted: return
        }
        guard !windows.snapshot.records.isEmpty else { return } // the first window list retries this
        setShortcuts(true, automatic: true)
        if case .failed = shortcuts.state { shortcutAutoStartBlocked = true }
    }

    private func startGestureIfReady(_ model: SetupModel) {
        if model.intent.gesture, !model.startsGesture, !gestures.isEnabled {
            desktop?.setGestureState(enabled: false, description: "Starts once Accessibility and Input Monitoring are on. Finish setup to grant them.")
            return
        }
        guard model.startsGesture, !gestureAutoStartBlocked, !gestures.isEnabled else { return }
        gestureAutoStartBlocked = true
        _ = gestures.start()
        showGestureState(gestures.state)
    }

    private func startPreviewsIfReady(_ permissions: PermissionState) {
        let wanted = setupPreferences.previewsEnabled
        if wanted, permissions.screenRecording, !previewsEnabled {
            previewsEnabled = true
            capture.prewarm()
        }
        if wanted, capture.screenRecordingStatus == .restartRequired { serviceNeedsRestart.insert(.screenRecording) }
        else { serviceNeedsRestart.remove(.screenRecording) }
        updatePreviewState()
    }

    private func configureSettings(_ settings: SettingsWindowController) {
        settings.onOpenSetup = { [weak self] in self?.showSetup(step: .permissions) }
        settings.onGrant = { [weak self] in self?.grant($0) }
        settings.onRestart = { [weak self] in self?.restartForPermissions() }
        settings.onReset = { [weak self] in self?.resetPermissions() }
        settings.setAutomaticUpdates(UpdateController.shared.checksAutomatically)
        settings.onToggleAutomaticUpdates = { UpdateController.shared.checksAutomatically = $0 }
        settings.onCheckForUpdates = { UpdateController.shared.checkForUpdates() }
        settings.lastUpdateCheck = { UpdateSettings().lastCheck }
        settings.setMenuBarIconVisible(statusMenu.isIconVisible)
        // Settings asks before hiding (a sheet); showing never asks.
        settings.onToggleMenuBarIcon = { [weak self] visible in self?.statusMenu.setIconVisible(visible) }
        settings.onToggleLaunchAtLogin = { [weak self] in self?.setLaunchAtLogin($0) }
        settings.onOpenLoginItems = { SMAppService.openSystemSettingsLoginItems() }
        showLaunchAtLoginState()
    }

    // MARK: Launch at login

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled { if service.status != .enabled { try service.register() } }
            else if service.status == .enabled || service.status == .requiresApproval { try service.unregister() }
            showLaunchAtLoginState()
        } catch {
            showLaunchAtLoginState(error: "Couldn’t change it: \(error.localizedDescription)")
        }
    }

    private func showLaunchAtLoginState(error: String? = nil) {
        guard let settings = desktop?.settingsController else { return }
        let status = SMAppService.mainApp.status
        settings.setLaunchAtLogin(enabled: status == .enabled || status == .requiresApproval, note: error,
                                  needsApproval: error == nil && status == .requiresApproval)
    }

    private func installApplicationMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu(title: "Paneflo")
        // About has one home: Settings › About.
        let about = NSMenuItem(title: "About Paneflo", action: #selector(showAbout), keyEquivalent: "")
        about.target = self; app.addItem(about); app.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
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

    private func installStatusMenu() {
        let menu = statusMenu
        menu.showsDeveloperFixtures = RuntimeDiagnostics.isEnabled
        menu.onCheckForUpdates = { UpdateController.shared.checkForUpdates() } // updates hook
        menu.onOpen = { [weak self] in self?.desktop?.present(mode: $0) }
        menu.onSettings = { [weak self] in self?.showSettings(pane: nil) }
        menu.onAbout = { [weak self] in self?.showSettings(pane: .about) }
        menu.onFinishSetup = { [weak self] in self?.showSetup(step: .permissions) }
        menu.onToggleShortcuts = { [weak self] in self?.setShortcuts($0) }
        menu.onRefreshWindows = { [weak self] in self?.windows.refresh() }
        menu.onDeveloperFixtures = { [weak self] in self?.showSample() }
        menu.onQuit = { [weak self] in self?.quit() }
        menu.onIconVisibilityChanged = { [weak self] visible in
            self?.desktop?.settingsController.setMenuBarIconVisible(visible)
        }
        menu.install()
    }

    /// Previews toggle. Turning it on without Screen Recording runs the Grant flow (system request and the
    /// Screen Recording pane); previews start once access is confirmed, or setup offers a restart.
    private func setPreviews(_ enabled: Bool) {
        setupPreferences.previewsEnabled = enabled
        previewsEnabled = enabled
        if enabled {
            if !capture.hasPermission { grant(.screenRecording); return }
            capture.prewarm()
        } else {
            capture.stop()
        }
        updatePreviewState()
    }

    /// Attaches the engine to the surfaces only while previews are on and Screen Recording is usable.
    private func updatePreviewState() {
        guard let desktop else { return }
        let status = capture.screenRecordingStatus
        let ready = capture.hasPermission && status != .restartRequired
        desktop.previews = previewsEnabled && ready ? capture : nil
        desktop.setPreviewsEnabled(previewsEnabled)
        let message: String?
        if ready { message = nil }
        else if previewsEnabled || status == .restartRequired { message = status.settingsMessage ?? ScreenRecordingStatus.unknown.settingsMessage }
        else { message = "Previews need Screen Recording (optional). Without it the switcher works without window pictures." }
        desktop.setPreviewPermissionMessage(message)
    }

    private func setGestures(_ enabled: Bool) {
        setupPreferences.gestureEnabled = enabled
        gestureAutoStartBlocked = false
        if !enabled { gestures.stop(); publishSetup(); return }
        let model = reconcile()
        guard model.startsGesture else { showSetup(); return }
        if !gestures.isEnabled, !gestures.start() { setupPreferences.gestureEnabled = false }
        showGestureState(gestures.state)
    }

    private func showGestureState(_ state: TrackpadGestureService.State) {
        let message: String
        let diagnostic: String
        switch state {
        case .disabled: message = "Off"; diagnostic = "disabled"
        case .starting: message = "Starting…"; diagnostic = "starting"
        case .active:
            // Also after an automatic retry of a transient failure, which had cleared the saved intent.
            setupPreferences.gestureEnabled = true
            message = "Ready · swipe up for Overview, down to close it."; diagnostic = "active"
        case .stopping: message = "Stopping…"; diagnostic = "stopping"
        case .paused: message = "Paused while the display or session is inactive."; diagnostic = "paused"
        case .unavailable(let reason):
            setupPreferences.gestureEnabled = false
            message = reason; diagnostic = "unavailable"
        case .failed(let reason):
            setupPreferences.gestureEnabled = false
            message = reason; diagnostic = "failed"
        }
        desktop?.setGestureState(enabled: gestures.isEnabled, description: message)
        RuntimeDiagnostics.mark("gesture state=\(diagnostic) enabled=\(gestures.isEnabled)")
    }

    /// `automatic`: started by `reconcile` from the saved choice, so the choice is not rewritten and nothing prompts.
    private func setShortcuts(_ enabled: Bool, automatic: Bool = false) {
        guard enabled else {
            setupPreferences.shortcutsEnabled = false
            shortcuts.stop()
            publishSetup()
            return
        }
        if !automatic {
            setupPreferences.shortcutsEnabled = true
            shortcutAutoStartBlocked = false
            publishSetup()
        }
        guard windows.hasAccessibility, CGPreflightListenEventAccess() else {
            desktop?.setShortcutsEnabled(false)
            desktop?.setStatus("Shortcuts start as soon as Accessibility and Input Monitoring are on.")
            if !automatic { showSetup() }
            return
        }
        guard !windows.snapshot.records.isEmpty else {
            desktop?.setShortcutsEnabled(false)
            desktop?.setStatus("Paneflo is still reading your windows. Shortcuts start as soon as it finishes.")
            return
        }
        var tiling: [ShortcutChord: ShortcutAction] = [:]
        let modifiers: ShortcutModifiers = [.control, .option]
        for (key, zone) in [(UInt16(123), LayoutZone.leftHalf), (124, .rightHalf), (126, .topHalf), (125, .bottomHalf), (36, .maximize)] {
            tiling[ShortcutChord(keyCode: key, modifiers: modifiers)] = .tile(zone)
        }
        tiling[ShortcutChord(keyCode: 6, modifiers: modifiers)] = .restore
        _ = shortcuts.start(configuration: .init(switcherEnabled: true, overview: ShortcutChord(keyCode: 49, modifiers: modifiers), tiling: tiling))
    }

    private func shortcutStateChanged(_ state: GlobalShortcutService.State) {
        desktop?.setShortcutsEnabled(state == .active)
        RuntimeDiagnostics.mark("shortcuts state=\(state == .active ? "active" : state == .disabled ? "disabled" : "other")")
        switch state {
        case .active:
            serviceNeedsRestart.remove(.inputMonitoring)
            if let description = shortcuts.installedTapDescription {
                desktop?.setStatus("Shortcuts installed: \(description). ⌘Tab and ⌃⌥ controls are enabled.")
            }
            publishSetup()
        case .failed(let message):
            // The saved choice stays on: a failed start is retried when permissions change or at the next launch.
            // With Input Monitoring reading on, the tap usually needs a relaunch to apply it.
            if CGPreflightListenEventAccess() {
                serviceNeedsRestart.insert(.inputMonitoring)
                desktop?.setStatus(message + " Restart Paneflo to finish enabling Input Monitoring.")
            } else {
                desktop?.setStatus(message)
            }
            publishSetup()
        case .interrupted(let message):
            // An interrupted tap keeps the saved intent; the service retries on its own.
            desktop?.setStatus(message)
            publishSetup()
        case .disabled:
            publishSetup()
        case .arming, .releasing:
            break
        }
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
        case .restore: desktop?.restoreRequested(); windows.undo()
        case .openPair: desktop?.openPairSelected()
        case .openAlone: desktop?.openAloneSelected()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        desktop?.updateKeyboardOwnership()
        // Coming back from System Settings after a Grant button: read permissions again.
        if awaitingReturnFromSettings { returnedFromSettings = true }
        reconcile()
    }
    func applicationDidResignActive(_ notification: Notification) { desktop?.updateKeyboardOwnership() }

    /// Opening Paneflo again (Finder, Spotlight, Launchpad, the Dock) shows setup while something required is missing,
    /// otherwise Settings — on General while the menu bar icon is hidden, where "Show menu bar icon" brings it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let model = reconcile()
        if model.isComplete { showSettings(pane: statusMenu.isIconVisible ? nil : .general) }
        else { setup.show(step: .permissions) }
        return false
    }

    @objc private func openSettings() { showSettings(pane: nil) }
    @objc private func showAbout() { showSettings(pane: .about) }
    private func showSettings(pane: SettingsPane?) { reconcile(); desktop?.showPreferences(pane: pane) }
    private func showSample() { if sample == nil { sample = PreviewController() }; sample?.present(mode: 0) }
    @objc private func quit() { gestures.stop(); shortcuts.stop(); capture.stop(); desktop?.dismiss(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        gestures.stop(); shortcuts.stop(); capture.stop()
        // Never leave apps hidden by a Desktop session behind when Paneflo quits. One restore path: the persisted
        // journal, which the next launch also reads after a crash.
        StartupRecovery.terminate(desktop: desktopService, defaults: preferences)
    }
}
