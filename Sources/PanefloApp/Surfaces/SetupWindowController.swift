import AppKit
import PanefloCore
import SwiftUI

/// "Set up Paneflo": four steps (Welcome, Permissions, Gesture, Done) in an AppKit window hosting SwiftUI (design spec
/// §7). It renders the `SetupModel` the app rebuilds from preflight readings and keeps the step in `SetupFlow`; while
/// the window is visible it asks for a fresh reading once a second (`onPoll`) and stops when hidden.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    var onGrant: ((SetupPermission) -> Void)?
    var onRestart: (() -> Void)?
    var onReset: (() -> Void)?
    /// "Use the three-finger swipe" (the same saved choice as Settings).
    var onToggleGesture: ((Bool) -> Void)?
    /// Open Settings, optionally on a pane (Done's "Open Settings", the previews hint).
    var onOpenSettings: ((SettingsPane?) -> Void)?
    /// Asked once a second while the window is visible, and once when it opens.
    var onPoll: (() -> Void)?
    var pollInterval: TimeInterval {
        get { poller.interval }
        set { poller.interval = newValue }
    }

    private let view = SetupViewModel()
    private var window: NSWindow?
    private lazy var poller: WindowPoller = {
        let poller = WindowPoller { [weak self] in self?.isVisible == true }
        poller.onTick = { [weak self] in self?.tick() }
        return poller
    }()

    var model: SetupModel? { view.setup }
    var step: SetupStep { view.step }
    var isVisible: Bool { window?.isVisible == true }
    var isPolling: Bool { poller.isRunning }

    override init() {
        super.init()
        view.perform = { [weak self] in self?.handle($0) }
    }

    /// Shows the window on `step`. Without one, a window already on screen keeps its step and a hidden one opens on
    /// Permissions (setup opens because something is missing).
    func show(step: SetupStep? = nil) {
        if let step { view.flow.go(to: step) } else if !isVisible { view.flow.go(to: .permissions) }
        let window = self.window ?? makeWindow()
        self.window = window
        refreshGestureGuidance()
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // An accessory app launched in the background can be refused activation; keep the window in front anyway.
        window.orderFrontRegardless()
        poller.start()
        onPoll?()
    }

    func close() { window?.close() }

    func update(_ model: SetupModel) {
        guard model != view.setup else { return }
        view.setup = model
    }

    func windowWillClose(_ notification: Notification) { poller.stop() }

    private func tick() {
        onPoll?()
        if view.step == .gesture { refreshGestureGuidance() }
    }

    /// Read-only CFPreferences; only while the window is open.
    private func refreshGestureGuidance() {
        let conflict = SystemGestureSettings.current().conflict
        if view.gestureConflict != conflict { view.gestureConflict = conflict }
    }

    private func handle(_ action: SetupUIAction) {
        switch action {
        case .footer(let footer):
            switch view.flow.perform(footer, model: view.current) {
            case .none: if view.step == .gesture { refreshGestureGuidance() }
            case .close: close()
            case .restart: onRestart?()
            case .openSettings: close(); onOpenSettings?(nil)
            }
        case .back: view.flow.back()
        case .grant(let permission): onGrant?(permission)
        case .reset: onReset?()
        case .toggleGesture(let on): onToggleGesture?(on)
        case .openTrackpadSettings:
            if let url = URL(string: GestureGuidance.trackpadSettingsURL), NSWorkspace.shared.open(url) { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        case .openPreviewSettings: close(); onOpenSettings?(.previews)
        }
    }

    private func makeWindow() -> NSWindow {
        let size = PanefloWindowStyle.setupSize
        let window = SetupWindow(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Set up Paneflo"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        let hosting = NSHostingController(rootView: SetupView(model: view))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(size)
        window.delegate = self
        return window
    }

    #if PANEFLO_NATIVE_CHECK
    struct NativeCheckRow: Equatable { let title: String; let tag: String; let status: String; let grantVisible: Bool }
    var nativeCheckRows: [NativeCheckRow] {
        view.current.rows.map { NativeCheckRow(title: $0.permission.title, tag: $0.tag, status: $0.statusText, grantVisible: $0.showsGrant) }
    }
    var nativeCheckRestartVisible: Bool { view.showsRestartCallout && view.primary == .restart }
    var nativeCheckStaleHintVisible: Bool { view.staleHint != nil }
    /// How far the permissions step's natural height exceeds the space above the footer at the default size.
    var nativeCheckPermissionsOverflow: CGFloat {
        let host = NSHostingController(rootView: PermissionsStepContent(model: view))
        let height = host.sizeThatFits(in: CGSize(width: PanefloWindowStyle.setupSize.width, height: 10_000)).height
        return height - (PanefloWindowStyle.setupSize.height - 52)
    }
    var nativeCheckHeadline: String { view.title }
    var nativeCheckPrimaryTitle: String { view.primary.title }
    var nativeCheckPrimaryEnabled: Bool { view.primaryEnabled }
    var nativeCheckSecondaryTitle: String? { view.secondary?.title }
    var nativeCheckShowsBack: Bool { view.flow.showsBack }
    var nativeCheckChecklist: [String] { view.current.checklist.map(\.title) }
    var nativeCheckWindow: NSWindow? { window }
    func nativeCheckPressGrant(_ permission: SetupPermission) { handle(.grant(permission)) }
    /// Return: only when the primary button is enabled, as the disabled button would refuse it.
    func nativeCheckPressPrimary() { if view.primaryEnabled { handle(.footer(view.primary)) } }
    func nativeCheckPressSecondary() { if let secondary = view.secondary { handle(.footer(secondary)) } }
    func nativeCheckPressBack() { handle(.back) }
    func nativeCheckPressRestart() { if view.primary == .restart { handle(.footer(.restart)) } }
    func nativeCheckPressReset() { handle(.reset) }
    func nativeCheckToggleGesture(_ on: Bool) { handle(.toggleGesture(on)) }
    #endif
}

/// Escape closes the setup window ("Later").
private final class SetupWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
}
