import AppKit
import PanefloCore
import SwiftUI

/// Paneflo Settings: an AppKit window hosting the SwiftUI sidebar and panes (design spec §6). The app talks to this
/// façade only; it writes `SettingsModel`, which exists from launch, while the window and its views are built on first
/// open. While the window is visible it asks for a fresh permission reading once a second (`onRefreshScreenRecording`);
/// nothing runs while it is closed.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let model = SettingsModel()
    private var window: NSWindow?
    private lazy var poller: WindowPoller = {
        let poller = WindowPoller { [weak self] in self?.isVisible == true }
        poller.onTick = { [weak self] in self?.tick() }
        return poller
    }()
    private let defaults: UserDefaults
    static let lastPaneKey = "settings.lastPane"

    var onToggleShortcuts: ((Bool) -> Void)?
    var onToggleGesture: ((Bool) -> Void)?
    var onTogglePreviews: ((Bool) -> Void)?
    var onToggleDesktopEntry: ((Bool) -> Void)?
    var onToggleSystemShowDesktop: ((Bool) -> Void)?
    var onToggleAutomaticUpdates: ((Bool) -> Void)?
    var onCheckForUpdates: (() -> Void)?
    /// Show menu bar icon turned on (showing never asks).
    var onToggleMenuBarIcon: ((Bool) -> Void)?
    /// Show menu bar icon turned off: the app runs Hide from Menu Bar (confirmation, attention rule).
    var onRequestHideMenuBarIcon: (() -> Void)?
    var onToggleLaunchAtLogin: ((Bool) -> Void)?
    var onOpenLoginItems: (() -> Void)?
    var onOpenSetup: (() -> Void)?
    /// Removes the Overview's free slots and returns how many there were.
    var onRemoveFreeSlots: (() -> Int)?
    /// Clears Overview slots and pins and places the current windows in order (after the confirmation).
    var onResetSlots: (() -> Void)?
    /// The keymap changed (after validation); the app saves it and applies it to the running tap and the menu.
    var onTilingKeymapChanged: ((TilingKeymap) -> Void)?
    /// A shortcut recorder started or stopped capturing keys.
    var onShortcutRecordingChanged: ((Bool) -> Void)?
    var onGrant: ((SetupPermission) -> Void)?
    var onRestart: (() -> Void)?
    var onReset: (() -> Void)?
    /// Settings became key, or a second passed while it is visible: permissions may have changed in System Settings.
    var onRefreshScreenRecording: (() -> Void)?
    /// Read when Settings opens: the date of the last update check.
    var lastUpdateCheck: () -> Date? = { nil }
    /// Asks before hiding the menu bar icon and answers (confirmed, don't show again) through the callback. Default: a
    /// sheet on Settings when it is open, otherwise an alert. Replaceable in own-window checks.
    lazy var confirmHideIcon: (@escaping @MainActor (Bool, Bool) -> Void) -> Void = { [weak self] answer in
        self?.presentHideConfirmation(answer)
    }
    /// Asks before resetting the Overview's slots. Default: a sheet on the Settings window. Replaceable in own-window
    /// checks.
    lazy var confirmResetSlots: (@escaping @MainActor (Bool) -> Void) -> Void = { [weak self] answer in
        self?.presentConfirmation(message: "Reset the Overview?",
                                  detail: "Slots and pins are cleared and your windows are placed in their current order.",
                                  confirm: "Reset", answer)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        if let raw = defaults.string(forKey: Self.lastPaneKey), let pane = SettingsPane(rawValue: raw) { model.pane = pane }
        model.surface = SurfacePreferences(defaults: defaults)
        model.perform = { [weak self] in self?.handle($0) }
    }

    var isConstructed: Bool { window != nil }
    var isVisible: Bool { window?.isVisible == true }

    // MARK: State from the app

    func setStatus(_ text: String) { if model.status != text { model.status = text } }
    /// The event tap is running.
    func setShortcutsEnabled(_ active: Bool) { if model.shortcutsActive != active { model.shortcutsActive = active } }
    func setShortcutState(wanted: Bool, status: PanefloStatus) {
        if model.shortcutsWanted != wanted { model.shortcutsWanted = wanted }
        if model.appStatus != status { model.appStatus = status }
    }
    func setGestureState(enabled: Bool, description: String) {
        if model.gestureEnabled != enabled { model.gestureEnabled = enabled }
        if model.gestureStatus != description { model.gestureStatus = description }
    }
    func enablePreviewControl() { model.previewControlEnabled = true }
    func setPreviewsEnabled(_ enabled: Bool) { if model.previewsEnabled != enabled { model.previewsEnabled = enabled } }
    func setDesktopSettings(showsEntry: Bool, usesSystemShowDesktop: Bool) {
        model.desktopEntry = showsEntry
        model.systemShowDesktop = usesSystemShowDesktop
    }
    /// Screen Recording guidance next to the previews toggle; nil when nothing is needed.
    func setPreviewPermissionMessage(_ message: String?) {
        if model.previewPermissionMessage != message { model.previewPermissionMessage = message }
    }
    /// Inline permission rows, the restart and stuck-permission offers, and the sidebar badge.
    func setSetupModel(_ setup: SetupModel) { if model.setup != setup { model.setup = setup } }
    func setLaunchAtLogin(enabled: Bool, note: String?, needsApproval: Bool) {
        model.launchAtLogin = enabled
        model.launchAtLoginNote = note
        model.launchAtLoginNeedsApproval = needsApproval
    }
    func setMenuBarIconVisible(_ visible: Bool) { if model.menuBarIconVisible != visible { model.menuBarIconVisible = visible } }
    /// A one-line note under Settings › General › Menu Bar ("Menu bar icon restored"); nil clears it.
    func showMenuBarNote(_ note: String?) { model.menuBarNote = note }
    func setAutomaticUpdates(_ enabled: Bool) { model.automaticUpdates = enabled }
    func setTilingKeymap(_ keymap: TilingKeymap) { if model.tilingKeymap != keymap { model.tilingKeymap = keymap } }

    // MARK: Window

    /// Opens Settings, on `pane` when given (the menu's About, Setup's links), else on the last pane used.
    func show(pane: SettingsPane? = nil) {
        if let pane { select(pane) }
        let window = self.window ?? makeWindow()
        self.window = window
        refreshOnOpen()
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // An accessory app can be refused activation; keep the window in front anyway.
        window.orderFrontRegardless()
        poller.start()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshGestureGuidance()
        refreshSystemEdgeTiling()
        onRefreshScreenRecording?()
    }

    func windowWillClose(_ notification: Notification) {
        poller.stop()
        endShortcutRecording()
    }

    /// A recorder can only hear keys while Settings is key, so losing key status ends it too.
    func windowDidResignKey(_ notification: Notification) { endShortcutRecording() }

    /// Always lets the global tiling chords through again, whichever way the recording ended.
    private func endShortcutRecording() {
        if model.recordingAction != nil { model.recordingAction = nil }
        onShortcutRecordingChanged?(false)
    }

    private func tick() {
        onRefreshScreenRecording?()
        if model.pane == .overviewGesture { refreshGestureGuidance() }
    }

    /// Reads macOS's own drag-to-edge tiling options (read only).
    private func refreshSystemEdgeTiling() {
        let enabled = SystemEdgeTiling.isEnabled(UserDefaults(suiteName: SystemEdgeTiling.domain))
        if model.systemEdgeTiling != enabled { model.systemEdgeTiling = enabled }
    }

    private func refreshOnOpen() {
        refreshGestureGuidance()
        refreshSystemEdgeTiling()
        let surface = SurfacePreferences(defaults: defaults)
        if model.surface != surface { model.surface = surface }
        model.slotNote = nil
        model.lastUpdateCheck = lastUpdateCheck()
    }

    /// Reads the system gesture preferences (read-only CFPreferences). Never on the gesture path.
    private func refreshGestureGuidance() {
        let conflict = SystemGestureSettings.current().conflict
        if model.gestureConflict != conflict { model.gestureConflict = conflict }
    }

    private func select(_ pane: SettingsPane) {
        model.pane = pane
        defaults.set(pane.rawValue, forKey: Self.lastPaneKey)
        if pane == .overviewGesture { refreshGestureGuidance() }
        if pane == .updates { model.lastUpdateCheck = lastUpdateCheck() }
    }

    private func makeWindow() -> NSWindow {
        let size = PanefloWindowStyle.settingsSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Paneflo Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(size)
        window.contentMinSize = PanefloWindowStyle.settingsMinSize
        window.contentMaxSize = NSSize(width: 960, height: 1600)
        window.delegate = self
        return window
    }

    // MARK: Actions

    private func handle(_ action: SettingsAction) {
        switch action {
        case .selectPane(let pane): select(pane)
        case .toggleShortcuts(let on): model.shortcutsWanted = on; onToggleShortcuts?(on)
        case .toggleLaunchAtLogin(let on): model.launchAtLogin = on; onToggleLaunchAtLogin?(on)
        case .openLoginItems: onOpenLoginItems?()
        case .setMenuBarIcon(true):
            model.menuBarIconVisible = true
            model.menuBarNote = nil
            onToggleMenuBarIcon?(true)
        case .setMenuBarIcon(false):
            // The switch follows the icon (`setMenuBarIconVisible`); a cancelled or refused hide leaves it on.
            guard model.menuBarIconVisible else { return }
            onRequestHideMenuBarIcon?()
        case .toggleGesture(let on): model.gestureEnabled = on; onToggleGesture?(on)
        case .openTrackpadSettings:
            if let url = URL(string: GestureGuidance.trackpadSettingsURL), NSWorkspace.shared.open(url) { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        case .togglePreviews(let on): model.previewsEnabled = on; onTogglePreviews?(on)
        case .toggleDesktopEntry(let on): model.desktopEntry = on; onToggleDesktopEntry?(on)
        case .toggleSystemShowDesktop(let on): model.systemShowDesktop = on; onToggleSystemShowDesktop?(on)
        case .grant(let permission): onGrant?(permission)
        case .openPermissionSettings(let permission):
            if let url = URL(string: permission.settingsURL) { NSWorkspace.shared.open(url) }
        case .restart: onRestart?()
        case .resetPermissions: onReset?()
        case .openSetup: onOpenSetup?()
        case .toggleAutomaticUpdates(let on): model.automaticUpdates = on; onToggleAutomaticUpdates?(on)
        case .checkForUpdates: onCheckForUpdates?()
        case .openURL(let url): NSWorkspace.shared.open(url)
        case .setCardSize(let size):
            model.surface.cardSize = size
            SurfacePreferences.write(cardSize: size, to: defaults)
        case .setFreeSlots(let retention):
            model.surface.freeSlots = retention
            SurfacePreferences.write(freeSlots: retention, to: defaults)
        case .setSurfaceOption(let option, let on):
            model.surface[option] = on
            SurfacePreferences.write(option, on, to: defaults)
        case .removeFreeSlots:
            model.slotNote = SettingsModel.removedNote(onRemoveFreeSlots?() ?? 0)
        case .resetSlots:
            confirmResetSlots { [weak self] confirmed in
                guard let self, confirmed else { return }
                self.onResetSlots?()
                self.model.slotNote = "Slots reset to your windows’ current order."
            }
        case .setTilingShortcut(let action, let chord):
            guard let chord else {
                model.recordingAction = nil
                onShortcutRecordingChanged?(false)
                model.tilingNote = nil; model.tilingNoteIsProblem = false
                applyTilingKeymap(model.tilingKeymap.clearing(action))
                return
            }
            switch model.tilingKeymap.assigning(chord, to: action) {
            case .rejected(let rejection):
                // The recorder keeps listening so another chord can be tried.
                model.tilingNote = "\(rejection.message) Try another shortcut."
                model.tilingNoteIsProblem = true
            case .assigned(let assignment):
                model.recordingAction = nil
                onShortcutRecordingChanged?(false)
                model.tilingNote = assignment.note(for: action)
                model.tilingNoteIsProblem = false
                applyTilingKeymap(assignment.keymap)
            }
        case .resetTilingShortcuts:
            model.recordingAction = nil
            onShortcutRecordingChanged?(false)
            model.tilingNote = nil; model.tilingNoteIsProblem = false
            applyTilingKeymap(.defaults)
        case .setShortcutRecording(let action):
            if action != nil { model.tilingNote = nil; model.tilingNoteIsProblem = false }
            model.recordingAction = action
            onShortcutRecordingChanged?(action != nil)
        }
    }

    private func applyTilingKeymap(_ keymap: TilingKeymap) {
        guard model.tilingKeymap != keymap else { return }
        model.tilingKeymap = keymap
        onTilingKeymapChanged?(keymap)
    }

    static let hideMessage = "Hide Paneflo from the menu bar?"
    static let hideDetail = "Paneflo keeps running and your shortcuts and gesture keep working. To bring the icon back, open Paneflo again from Spotlight, Launchpad or Applications."

    /// Hide from Menu Bar's confirmation (with the app icon): a sheet on Settings when it is open, otherwise an alert.
    private func presentHideConfirmation(_ answer: @escaping @MainActor (Bool, Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = Self.hideMessage
        alert.informativeText = Self.hideDetail
        alert.addButton(withTitle: "Hide")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t show this again"
        let reply: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            answer(response == .alertFirstButtonReturn, alert.suppressionButton?.state == .on)
        }
        guard let window, window.isVisible else {
            NSApp.activate(ignoringOtherApps: true)
            reply(alert.runModal())
            return
        }
        alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { reply(response) } }
    }

    /// A two-button confirmation as a sheet on Settings (app-modal only if Settings is somehow not open).
    private func presentConfirmation(message: String, detail: String, confirm: String,
                                     _ answer: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        guard let window, window.isVisible else {
            NSApp.activate(ignoringOtherApps: true)
            answer(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { answer(response == .alertFirstButtonReturn) }
        }
    }

    #if PANEFLO_NATIVE_CHECK
    var nativeCheckWindow: NSWindow? { window }
    var nativeCheckIsPolling: Bool { poller.isRunning }
    /// Sends an action down the same path a control uses.
    func nativeCheckPerform(_ action: SettingsAction) { handle(action) }
    var nativeCheckGestureGuidanceStatus: String { GestureGuidance.status(for: model.gestureConflict) }
    func nativeCheckPermissionStatus(_ permission: SetupPermission) -> String { model.row(permission)?.statusText ?? "" }
    #endif
}
