import AppKit
import PanefloCore

/// Coordinates the two pre-created surfaces (⌘Tab switcher and Overview) and Settings.
/// Native presentation reads prepared snapshots. It never makes remote AX or capture calls.
@MainActor
final class DesktopController: NSObject, SurfaceHost {
    let service: WindowService
    private let switcher = SwitcherPanelController()
    private let overview = OverviewPanelController()
    private let settings: SettingsWindowController
    private var latestPlacement: UInt64 = 0
    private var presentationGeneration: UInt64 = 0
    private var overviewReturnApplication: NSRunningApplication?
    private var iconCache: [String: NSImage] = [:]
    private var lastKeyboardDiagnostic: String?
    private var firstPreviewStarted: Double?
    private var pendingGestureRecognizedAt: UInt64?
    private weak var lastSurface: SurfacePanelController?
    private var observers: [NSObjectProtocol] = []
    /// Present only while the Overview is on screen; never installed while hidden.
    private var outsideClickMonitor: Any?
    private var installOutsideClickMonitor: (@escaping @MainActor (NSPoint) -> Void) -> Any? = { handler in
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in
            // Global monitors see only events bound for other apps' windows, on the main thread.
            let point = NSEvent.mouseLocation
            MainActor.assumeIsolated { handler(point) }
        }
    }
    private var removeOutsideClickMonitor: (Any) -> Void = { NSEvent.removeMonitor($0) }
    private var workspaceObservers: [NSObjectProtocol] = []
    /// The preview engine, or nil while previews are off. Cards render its updates; the visible
    /// surface reports its visible cards and selection on open, Tab, scroll and search.
    var previews: PreviewProvider? {
        didSet {
            guard previews !== oldValue else { return }
            oldValue?.onPreview = nil
            oldValue?.updateSurface(visible: false, cards: [], selected: nil, previewPixelSize: nil)
            previewSessionOpen = false
            for surface in [switcher, overview] as [SurfacePanelController] {
                for card in surface.grid.cards where !card.isDesktopEntry { card.clearPreview() }
            }
            previews?.onPreview = { [weak self] update in self?.showPreview(update) }
            if let surface = visibleSurface { surfaceSelectionChanged(surface) }
        }
    }
    /// True between the first visible `updateSurface` of a presentation and its dismissal.
    private var previewSessionOpen = false
    /// The Desktop entry (switcher card, Overview home tile). Nil: no entry anywhere.
    var desktopEntry: DesktopEntryProvider? {
        didSet { if desktopEntry !== oldValue { desktopStateChanged() } }
    }
    /// Why surfaces may not open right now (screen locked, displays asleep, another login session active).
    enum Suspension: String, Hashable { case screenLocked, displaysAsleep, sessionInactive }
    private(set) var suspensions: Set<Suspension> = []
    /// Called when the screen locks, the displays sleep or the login session resigns: purge cached window
    /// snapshots (the app calls the capture engine's purge; the engine already stops live work on dismissal).
    var onPrivacyPurge: (() -> Void)?
    /// Reads the login session's lock and console state. Consulted only while a suspension is recorded, so a
    /// missed unlock or wake notification can never keep the surfaces closed. Replaceable in own-window checks.
    private var sessionState: () -> (locked: Bool, onConsole: Bool) = {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return (false, true) }
        return ((info["CGSSessionScreenIsLocked"] as? Bool) ?? false, (info[kCGSessionOnConsoleKey as String] as? Bool) ?? true)
    }
    private var distributedObservers: [NSObjectProtocol] = []
    private var screenChangeScheduled = false
    var onVisibilityChanged: ((Bool) -> Void)?
    var onCompositionChanged: ((Bool) -> Void)?
    /// Any Paneflo surface on screen, regardless of key or active state. Escape ownership follows this.
    var onSurfaceVisibilityChanged: ((Bool) -> Void)?
    var onDismiss: (() -> Void)?
    var onToggleShortcuts: ((Bool) -> Void)? { get { settings.onToggleShortcuts } set { settings.onToggleShortcuts = newValue } }
    var onToggleGesture: ((Bool) -> Void)? { get { settings.onToggleGesture } set { settings.onToggleGesture = newValue } }
    var onTogglePreviews: ((Bool) -> Void)? { get { settings.onTogglePreviews } set { settings.onTogglePreviews = newValue } }
    var onToggleDesktopEntry: ((Bool) -> Void)? { get { settings.onToggleDesktopEntry } set { settings.onToggleDesktopEntry = newValue } }
    var onToggleSystemShowDesktop: ((Bool) -> Void)? {
        get { settings.onToggleSystemShowDesktop } set { settings.onToggleSystemShowDesktop = newValue }
    }
    var isVisible: Bool { switcher.isShown || overview.isShown }
    var isOverviewVisible: Bool { overview.isShown }
    private var visibleSurface: SurfacePanelController? { overview.isShown ? overview : switcher.isShown ? switcher : nil }

    init(service: WindowService) {
        self.service = service
        settings = SettingsWindowController(service: service)
        super.init()
        switcher.host = self
        overview.host = self
        overview.onFirstCards = { [weak self] in self?.switcher.prepareHidden() }
        settings.selectedWindow = { [weak self] in
            guard let surface = self?.lastSurface, let id = surface.selectedID, surface.isEligible(id) else { return nil }
            return id
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didHideNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(restorePreviousApplication: false) }
        })
        for name in [NSText.didChangeNotification, NSTextView.didChangeSelectionNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let editor = notification.object as? NSTextView
                MainActor.assumeIsolated {
                    guard let self, let editor, let surface = self.visibleSurface,
                          editor === surface.panel.firstResponder else { return }
                    self.updateKeyboardOwnership()
                }
            })
        }
        // The Overview never activates Paneflo, so another app's activation is the unambiguous
        // signal that the user moved on (Dock click, ⌘Tab in another switcher, a click elsewhere).
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { self?.otherApplicationActivated(pid) }
        })
        installLifecycleObservers()
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    // MARK: Display, lock and session lifecycle

    private func installLifecycleObservers() {
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersChanged() }
        })
        // Lock and unlock are only published as distributed notifications.
        let distributed = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            distributedObservers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { locked ? self?.suspend(.screenLocked) : self?.resume(.screenLocked) }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let signals: [(Notification.Name, Suspension, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, .displaysAsleep, true),
            (NSWorkspace.screensDidWakeNotification, .displaysAsleep, false),
            // Fast user switching: another login session takes the console. Treated like a lock.
            (NSWorkspace.sessionDidResignActiveNotification, .sessionInactive, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive, false),
        ]
        for (name, reason, begins) in signals {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { begins ? self?.suspend(reason) : self?.resume(reason) }
            })
        }
    }

    /// Lock, display sleep or session switch: close any surface (which ends the preview session and its live
    /// stream), purge cached snapshots, and refuse new presentations until the session is back.
    func suspend(_ reason: Suspension) {
        suspensions.insert(reason)
        RuntimeDiagnostics.mark("desktop suspended reason=\(reason.rawValue) visible=\(isVisible)")
        if isVisible { dismiss(restorePreviousApplication: false) }
        onPrivacyPurge?()
    }

    func resume(_ reason: Suspension) {
        guard suspensions.remove(reason) != nil else { return }
        RuntimeDiagnostics.mark("desktop resumed reason=\(reason.rawValue) remaining=\(suspensions.count)")
    }

    /// True while a recorded suspension is confirmed by the session itself. Costs nothing when none is recorded.
    private var presentationSuspended: Bool {
        guard !suspensions.isEmpty else { return false }
        let state = sessionState()
        // Keys reach Paneflo only from an awake console; an unlocked console session means a resume was missed.
        if !state.locked, state.onConsole {
            RuntimeDiagnostics.mark("desktop resumed reason=sessionStateCheck cleared=\(suspensions.count)")
            suspensions.removeAll()
            return false
        }
        return true
    }

    /// Display added, removed, rearranged or resized. A visible surface stays on its display (re-fitted to the
    /// new visible frame) or closes when that display is gone. Hidden panels are re-laid out for the pointer's
    /// display and pre-warmed again once the burst of notifications settles.
    func screenParametersChanged() {
        desktopEntry?.screensChanged()
        if let surface = visibleSurface {
            let screens = NSScreen.screens
            if let id = surface.placedDisplayID, let screen = screens.first(where: { $0.displayID == id }) {
                surface.screenParametersChanged(to: screen)
                if surface.isShown { surface.showDesktopWallpaper(); surfaceSelectionChanged(surface) }
            } else {
                RuntimeDiagnostics.mark("desktop dismissed reason=displayRemoved")
                dismiss(restorePreviousApplication: false)
            }
        }
        guard !screenChangeScheduled else { return }
        screenChangeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.screenChangeScheduled = false
            guard let screen = NSScreen.pointerScreen else { return }
            for surface in [self.switcher, self.overview] as [SurfacePanelController] where !surface.isShown {
                surface.screenParametersChanged(to: screen)
            }
        }
    }

    /// Pays both panels' first-display cost at launch, off the input path.
    func prewarm() {
        let started = ProcessInfo.processInfo.systemUptime
        switcher.prewarm()
        overview.prewarm()
        RuntimeDiagnostics.mark("desktop prewarmMilliseconds=\((ProcessInfo.processInfo.systemUptime - started) * 1000)")
    }

    // MARK: Presentation

    func present(mode: DesktopMode, fromShortcut: Bool = false, backwards: Bool = false) {
        if presentationSuspended {
            RuntimeDiagnostics.mark("desktop presentation refused suspended=\(suspensions.map(\.rawValue).sorted())")
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        firstPreviewStarted = started
        presentationGeneration &+= 1
        pruneIconCache()
        let surface: SurfacePanelController
        if mode == .overview {
            if switcher.isShown { switcher.hide() }
            if let previous = NSWorkspace.shared.frontmostApplication,
               previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                overviewReturnApplication = previous
            }
            overview.present()
            startOutsideClickMonitor()
            surface = overview
        } else {
            if overview.isShown { overview.hide(); overviewReturnApplication = nil }
            stopOutsideClickMonitor()
            switcher.present(mode: mode, fromShortcut: fromShortcut, backwards: backwards)
            surface = switcher
        }
        lastSurface = surface
        let shown = ProcessInfo.processInfo.systemUptime
        updateKeyboardOwnership()
        surfaceSelectionChanged(surface)
        if RuntimeDiagnostics.isEnabled {
            let complete = ProcessInfo.processInfo.systemUptime
            RuntimeDiagnostics.mark("desktop mode=\(mode.rawValue) visible=\(surface.isShown) key=\(surface.panel.isKeyWindow) appActive=\(NSApp.isActive) presentMilliseconds=\((shown - started) * 1000) previewSelectionMilliseconds=\((complete - shown) * 1000) presentationMilliseconds=\((complete - started) * 1000)")
        }
    }

    func switchStep(backwards: Bool) {
        if !switcher.isShown || switcher.mode != .switcher || !switcher.shortcutSession {
            present(mode: .switcher, fromShortcut: true, backwards: backwards)
        } else { switcher.step(backwards: backwards) }
    }

    func navigate(_ direction: CycleDirection) { visibleSurface?.navigate(direction) }
    func navigateRow(_ direction: CycleDirection) { visibleSurface?.navigateRows(direction == .forward ? 1 : -1) }
    func commitShortcut() { if switcher.isShown { switcher.commitShortcut() } }

    func focusOverview(recognizedAtUptimeNanoseconds: UInt64? = nil) {
        pendingGestureRecognizedAt = recognizedAtUptimeNanoseconds
        if overview.isShown { overview.reacquireKeyboard(); updateKeyboardOwnership() }
        else { present(mode: .overview, fromShortcut: true) }
    }

    func dismiss(restorePreviousApplication: Bool = true) {
        let previous = overviewReturnApplication
        overviewReturnApplication = nil
        firstPreviewStarted = nil
        pendingGestureRecognizedAt = nil
        switcher.hide()
        overview.hide()
        stopOutsideClickMonitor()
        updateKeyboardOwnership()
        endPreviewSession()
        onDismiss?()
        // A key non-activating panel makes NSApp.isActive true without taking the frontmost
        // position, so restore only when Paneflo itself really became frontmost meanwhile.
        if restorePreviousApplication, let previous, !previous.isTerminated,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            previous.activate(options: [])
        }
    }

    private func startOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = installOutsideClickMonitor { [weak self] point in self?.mouseDownElsewhere(at: point) }
    }

    private func stopOutsideClickMonitor() {
        guard let monitor = outsideClickMonitor else { return }
        outsideClickMonitor = nil
        removeOutsideClickMonitor(monitor)
    }

    /// A click in another app's window, including the already-frontmost app (which posts no
    /// activation notification), closes the Overview.
    private func mouseDownElsewhere(at point: NSPoint) {
        guard overview.isShown, !overview.panel.frame.contains(point) else { return }
        RuntimeDiagnostics.mark("desktop overview dismissed reason=mouseDownOutside")
        dismiss(restorePreviousApplication: false)
    }

    private func otherApplicationActivated(_ pid: pid_t?) {
        guard overview.isShown, let pid, pid != ProcessInfo.processInfo.processIdentifier else { return }
        RuntimeDiagnostics.mark("desktop overview dismissed reason=otherApplicationActivated")
        dismiss(restorePreviousApplication: false)
    }

    /// Registry change. Hidden surfaces do no work here: the switcher builds on present and the
    /// Overview coalesces into at most one diff per second.
    func updateSnapshot() {
        switcher.snapshotChanged()
        overview.snapshotChanged()
        settings.snapshotChanged()
        if let surface = visibleSurface { surfaceSelectionChanged(surface) }
    }

    func tileSelected(_ zone: LayoutZone) {
        guard let surface = visibleSurface, let id = surface.selectedID, surface.isEligible(id) else { return }
        latestPlacement &+= 1
        let generation = latestPlacement
        let presentedGeneration = presentationGeneration
        surface.setLayoutBadge(zone == .leftHalf ? "Left half" : zone == .rightHalf ? "Right half" : "Fill screen", for: id)
        service.tile(id, zone: zone) { [weak self, weak surface] accepted in
            guard let self, self.latestPlacement == generation else { return }
            if !accepted, let surface {
                surface.setLayoutBadge(nil, for: id)
                if surface.isShown, self.presentationGeneration == presentedGeneration {
                    surface.showFailure("Couldn’t arrange this window. Try another window or check Accessibility in Settings.")
                }
            }
        }
    }

    // MARK: Keyboard ownership

    func updateKeyboardOwnership() {
        let surface = visibleSurface
        let owned = surface?.keyboardOwned ?? false
        if owned, surface === overview, let recognizedAt = pendingGestureRecognizedAt {
            pendingGestureRecognizedAt = nil
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= recognizedAt {
                RuntimeDiagnostics.mark("gesture recognitionToKeyReadyMilliseconds=\(Double(now - recognizedAt) / 1_000_000)")
            }
        }
        onVisibilityChanged?(owned)
        onSurfaceVisibilityChanged?(surface != nil)
        // Marked text can exist only in Paneflo's own key field; that is the one Escape exception.
        let composing = surface?.composing ?? false
        onCompositionChanged?(composing)
        if RuntimeDiagnostics.isEnabled {
            let state = "desktop keyboard visible=\(surface != nil) key=\(surface?.panel.isKeyWindow ?? false) appActive=\(NSApp.isActive) selectionOwned=\(owned) composing=\(composing) overview=\(surface === overview)"
            if state != lastKeyboardDiagnostic {
                lastKeyboardDiagnostic = state
                RuntimeDiagnostics.mark(state)
            }
        }
    }

    // MARK: Previews

    func setStatus(_ text: String) { settings.status.stringValue = text }
    func setShortcutsEnabled(_ enabled: Bool) { settings.shortcutButton.state = enabled ? .on : .off }
    func setGestureState(enabled: Bool, description: String) {
        settings.gestureButton.state = enabled ? .on : .off
        settings.gestureStatus.stringValue = description
    }
    func enablePreviewControl() {
        settings.previewButton.isEnabled = true
        settings.previewButton.toolTip = "One live stream for the selected window while this overlay is visible."
    }
    func setPreviewsEnabled(_ enabled: Bool) { settings.previewButton.state = enabled ? .on : .off }
    func setDesktopSettings(showsEntry: Bool, usesSystemShowDesktop: Bool) {
        settings.desktopEntryButton.state = showsEntry ? .on : .off
        settings.systemShowDesktopButton.state = usesSystemShowDesktop ? .on : .off
    }

    /// The Desktop session started, changed or ended, or its setting changed. Hidden surfaces pick it up when they
    /// open (the switcher builds its loop then); visible ones refresh the entry in place. A held switcher keeps its
    /// frozen loop: only the entry's subtitle follows.
    func desktopStateChanged() {
        switcher.desktopStateChanged()
        overview.desktopStateChanged()
    }
    /// Screen Recording guidance shown next to the previews toggle; nil hides it.
    func setPreviewPermissionMessage(_ message: String?) { settings.setPreviewPermissionMessage(message) }
    var onRefreshScreenRecording: (() -> Void)? {
        get { settings.onRefreshScreenRecording } set { settings.onRefreshScreenRecording = newValue }
    }

    /// Renders one engine update on the visible surface's card. Updates for hidden surfaces or
    /// cards no longer displayed are dropped: hidden cards hold no window content.
    private func showPreview(_ update: PreviewUpdate) {
        guard let surface = visibleSurface, surface.showsPreviews, let card = surface.cardsByWindow[update.id] else { return }
        card.showPreview(update)
        if let started = firstPreviewStarted, card.pixels.hasContent {
            firstPreviewStarted = nil
            RuntimeDiagnostics.mark("desktop firstPreviewMilliseconds=\((ProcessInfo.processInfo.systemUptime - started) * 1000)")
        }
    }

    private func endPreviewSession() {
        guard previewSessionOpen else { return }
        previewSessionOpen = false
        previews?.updateSurface(visible: false, cards: [], selected: nil, previewPixelSize: nil)
    }

    func showPreferences() {
        dismiss(restorePreviousApplication: false)
        settings.show()
    }

    // MARK: SurfaceHost

    func icon(for record: WindowRecord) -> NSImage? {
        if let icon = iconCache[record.appIdentifier] { return icon }
        let icon = NSRunningApplication(processIdentifier: record.id.process.pid)?.icon
        iconCache[record.appIdentifier] = icon
        return icon
    }

    private func pruneIconCache() {
        guard iconCache.count > 32 else { return }
        let live = Set(service.snapshot.records.map(\.appIdentifier))
        iconCache = iconCache.filter { live.contains($0.key) }
    }

    func surfaceKeyboardChanged(_ surface: SurfacePanelController) { updateKeyboardOwnership() }

    /// Open, Tab, arrows, scroll, search and registry changes all land here. Reads prepared state
    /// only; the engine call does no capture, AX or window-server work synchronously.
    func surfaceSelectionChanged(_ surface: SurfacePanelController) {
        guard surface === visibleSurface, let previews else { return }
        guard surface.showsPreviews else { endPreviewSession(); return }
        let cards = surface.previewCards()
        if previewSessionOpen {
            // The engine emits each card once per session; a card view reused mid-session asks for
            // the current state instead of waiting for the next change.
            for card in cards {
                if let view = surface.cardsByWindow[card.id], !view.hasPreviewState { view.showPreview(previews.preview(for: card)) }
            }
        }
        previewSessionOpen = true
        previews.updateSurface(visible: true, cards: cards, selected: surface.selectedID,
                               previewPixelSize: surface.previewPixelSize)
    }

    func surfaceDismiss(_ surface: SurfacePanelController) { dismiss() }

    func surfaceActivate(_ id: WindowIdentity) {
        // Focus never waits for a pending tile: placement finishes on its own lane.
        dismiss(restorePreviousApplication: false)
        guard let desktopEntry else { service.focus(id); return }
        // A desktop session may have hidden this app: unhide it first, so the AX raise can land.
        desktopEntry.prepareToFocus(pid: id.process.pid) { [weak self] in self?.service.focus(id) }
    }

    var desktopLoopMode: DesktopLoopMode { desktopEntry?.loopMode ?? .hidden }
    var showsDesktopHomeTile: Bool { desktopEntry?.showsDesktopEntry ?? false }
    var desktopIsCurrent: Bool { desktopEntry?.isDesktopShown ?? false }

    func surfaceActivateDesktop() {
        dismiss(restorePreviousApplication: false)
        desktopEntry?.activateDesktopEntry()
    }

    func surfaceShowWallpaper(_ card: CardView, on surface: SurfacePanelController) {
        guard let desktopEntry, let screen = surface.panel.screen ?? surface.placedScreen else { return }
        if !card.pixels.hasContent, let image = desktopEntry.cachedWallpaper(for: screen) { card.showWallpaper(image) }
        desktopEntry.refreshWallpaper(for: screen) { [weak surface, weak card] image in
            // Only a still-visible Desktop card takes the result: hidden cards hold no pixels.
            guard let surface, let card, surface.isShown, card.isDesktopEntry, surface.desktopCard === card else { return }
            card.showWallpaper(image)
        }
    }

    func surfaceTile(_ zone: LayoutZone) { tileSelected(zone) }
    func surfaceUndo() { service.undo(preferring: visibleSurface?.selectedID) }

    #if PANEFLO_NATIVE_CHECK
    func nativeCheckSuppressExternalRestore() { overviewReturnApplication = nil }
    /// Replaces the global mouse monitor so own-window checks never install one.
    func nativeCheckReplaceOutsideClickMonitor(install: @escaping (@escaping @MainActor (NSPoint) -> Void) -> Any?,
                                               remove: @escaping (Any) -> Void) {
        installOutsideClickMonitor = install
        removeOutsideClickMonitor = remove
    }
    var nativeCheckOutsideClickMonitorInstalled: Bool { outsideClickMonitor != nil }
    var nativeCheckGestureGuidanceStatus: String { settings.gestureGuidanceStatus.stringValue }
    private var nativeCheckSurface: SurfacePanelController { visibleSurface ?? lastSurface ?? overview }
    var nativeCheckWindow: NSWindow { nativeCheckSurface.panel }
    var nativeCheckSwitcherWindow: NSWindow { switcher.panel }
    var nativeCheckOverviewWindow: NSWindow { overview.panel }
    var nativeCheckOverviewApplyCount: Int { overview.applyCount }
    var nativeCheckPreferencesConstructed: Bool { settings.isConstructed }
    var nativeCheckPreviewControlEnabled: Bool { settings.previewButton.isEnabled }
    var nativeCheckShortcutsEnabled: Bool { settings.shortcutButton.state == .on }
    var nativeCheckGestureEnabled: Bool { settings.gestureButton.state == .on }
    var nativeCheckStatus: String { settings.status.stringValue }
    var nativeCheckSearch: NSSearchField { nativeCheckSurface.search }
    var nativeCheckSelected: WindowIdentity? { nativeCheckSurface.selectedID }
    var nativeCheckSwitcherTargets: [SwitchTarget] { switcher.nativeCheckTargets }
    var nativeCheckSelectedTarget: SwitchTarget? { nativeCheckSurface.selectedTarget }
    var nativeCheckDesktopCard: CardView? { nativeCheckSurface.desktopCard }
    var nativeCheckDesktopEntryControl: Bool { settings.desktopEntryButton.state == .on }
    func nativeCheckReplaceSessionState(_ probe: @escaping () -> (locked: Bool, onConsole: Bool)) { sessionState = probe }
    /// Pretends the visible surface was placed on a display that no longer exists.
    func nativeCheckDetachPlacedScreen() { visibleSurface?.nativeCheckForgetPlacedScreen() }
    func nativeCheckSelect(_ target: SwitchTarget) { visibleSurface?.select(target: target) }
    func nativeCheckActivateSelected() { visibleSurface?.activateSelected() }
    var nativeCheckSlots: [WindowIdentity?] {
        nativeCheckSurface === overview ? overview.slotBindings : switcher.displayed.map(Optional.some)
    }
    var nativeCheckPayloadCount: Int {
        (switcher.grid.cards + overview.grid.cards).filter { $0.pixels.hasContent }.count
    }
    var nativeCheckLabelledCount: Int {
        (switcher.grid.cards + overview.grid.cards).filter { $0.previewLabel != nil }.count
    }
    func nativeCheckCard(for id: WindowIdentity) -> CardView? { nativeCheckSurface.cardsByWindow[id] }
    var nativeCheckCards: [CardView] { nativeCheckSurface.grid.cards }
    var nativeCheckViewport: NSRect { nativeCheckSurface.scroll.contentView.documentVisibleRect }
    var nativeCheckCardHeight: CGFloat { nativeCheckSurface.grid.metrics.cardHeight }
    func nativeCheckQuery(_ value: String) {
        let surface = nativeCheckSurface
        surface.search.stringValue = value
        surface.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: surface.search))
    }
    #endif
}
