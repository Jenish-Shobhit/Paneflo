import AppKit
import PanefloCore

/// Show Desktop for the switcher loop and the Overview home tile.
///
/// Approach 1 of the design (public API only, no Accessibility): hide every regular app except Finder and Paneflo,
/// then activate Finder so the desktop has focus. The set of apps Paneflo hid is recorded in a `DesktopSession`
/// (decision logic in PanefloCore) so that choosing a window afterwards unhides only that window's app, the way a
/// Dock click does, and "Restore all" returns everything Paneflo hid and nothing else.
///
/// Behaviour notes:
/// - Hiding is per app, so every display is revealed at once; per-display reveal is not offered.
/// - Finder is never hidden, so Finder windows that were already open stay visible (the system Show Desktop would
///   move them away too). Activation uses `activate(options: [])`, so Finder raises only its key window; if Finder
///   did not come forward, a LaunchServices open request activates it instead (Finder may then open a window).
/// - Apps that decline `hide()` (or are visible again shortly after) are recorded as refused and never "restored".
/// - Apps that were already hidden by the user are left alone and are not restored.
/// - An app launched or activated while the desktop is shown ends the "desktop is current" state; the remaining hidden
///   set stays restorable. The session ends when nothing is hidden by it and the desktop is not current.
/// - Stage Manager: hiding works, but apps leave their stage groups and the restored layout is the system's choice.
///   `isStageManagerEnabled` lets the UI warn; behaviour is not changed.
/// - Every change to the hidden set is journaled to UserDefaults (`DesktopRestoreJournal`). Quitting Paneflo
///   restores all; after a crash or kill the next launch does (`restoreJournaledApps`).
@MainActor
final class DesktopService {
    enum ShowOutcome: Equatable {
        /// Approach 1 ran. `hidden` apps were asked to hide; `refused` declined at once.
        case shown(hidden: Int, refused: Int)
        /// The macOS Show Desktop shortcut was posted (the "Use macOS Show Desktop" setting). Restore is native, and
        /// Paneflo cannot observe the result, so `isDesktopShown` stays false.
        case systemShortcutPosted
    }

    /// Called after the session starts, changes or ends. The UI uses it to rebuild the Desktop entry / tile state.
    var onChange: (() -> Void)?

    private(set) var session: DesktopSession? { didSet { if session != oldValue { persist() } } }
    private var generation: UInt64 = 0
    private let settings: DesktopSettings
    private let workspace: NSWorkspace
    private let defaults: UserDefaults
    private var observers: [NSObjectProtocol] = []
    private var terminationObserver: NSObjectProtocol?

    static let journalKey = "desktop.session.v1"

    init(settings: DesktopSettings = DesktopSettings(), workspace: NSWorkspace = .shared, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.workspace = workspace
        self.defaults = defaults
    }

    isolated deinit {
        for observer in observers { workspace.notificationCenter.removeObserver(observer) }
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    // MARK: Journal

    /// Writes the hidden set (with launch dates, so a reused PID is never touched) or clears the journal.
    private func persist() {
        guard let session, !session.hiddenPIDs.isEmpty else {
            defaults.removeObject(forKey: Self.journalKey); return
        }
        let entries = session.hiddenPIDs.map { pid -> DesktopRestoreJournal.Entry in
            let app = NSRunningApplication(processIdentifier: pid)
            return .init(pid: pid, bundleIdentifier: app?.bundleIdentifier, launchDate: app?.launchDate?.timeIntervalSinceReferenceDate)
        }
        guard let data = try? DesktopRestoreJournal(generation: session.generation, entries: entries).encoded() else { return }
        defaults.set(data, forKey: Self.journalKey)
    }

    /// Unhides the apps a previous Show Desktop hid and never restored (Paneflo quit, crashed or was killed), if they
    /// are the same processes and still hidden, then clears the journal. Call at launch and at termination.
    @discardableResult
    static func restoreJournaledApps(defaults: UserDefaults = .standard, workspace: NSWorkspace = .shared) -> Int {
        guard let data = defaults.data(forKey: journalKey) else {
            defaults.removeObject(forKey: journalKey)
            return 0
        }
        defaults.removeObject(forKey: journalKey)
        guard let journal = DesktopRestoreJournal.decode(data) else { return 0 }
        let running = workspace.runningApplications.map {
            DesktopApp(pid: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier, isRegular: $0.activationPolicy == .regular,
                       isHidden: $0.isHidden, isTerminated: $0.isTerminated,
                       launchDate: $0.launchDate?.timeIntervalSinceReferenceDate)
        }
        let pids = journal.appsToUnhide(running: running)
        for pid in pids { NSRunningApplication(processIdentifier: pid)?.unhide() }
        return pids.count
    }

    // MARK: State

    /// True while the desktop is the current state: it was shown and the user has not yet brought an app forward.
    /// Pass this to `DesktopSettings.loopMode(desktopIsCurrent:)` when starting a switcher session.
    var isDesktopShown: Bool { session?.isCurrent == true }

    /// True while Paneflo still holds apps it hid (possibly with the desktop no longer current).
    var hasHiddenApps: Bool { !(session?.hiddenPIDs.isEmpty ?? true) }

    /// `com.apple.WindowManager GloballyEnabled`. Read-only; no permission needed.
    var isStageManagerEnabled: Bool {
        CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString) as? Bool ?? false
    }

    // MARK: Observation

    /// Starts watching the user's own app activity. Idempotent.
    func start() {
        guard observers.isEmpty else { return }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreAll() }
        }
        let center = workspace.notificationCenter
        func observe(_ name: Notification.Name, _ signal: @escaping @Sendable (Int32) -> DesktopSignal) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let value = signal(app.processIdentifier)
                MainActor.assumeIsolated { self?.receive(value) }
            })
        }
        observe(NSWorkspace.didActivateApplicationNotification) { .didActivate(pid: $0) }
        observe(NSWorkspace.didUnhideApplicationNotification) { .didUnhide(pid: $0) }
        observe(NSWorkspace.didTerminateApplicationNotification) { .didTerminate(pid: $0) }
    }

    private func receive(_ signal: DesktopSignal) {
        guard var current = session else { return }
        let before = current
        let ended = current.apply(signal, at: Date())
        session = ended ? nil : current
        if ended || current != before { onChange?() }
    }

    // MARK: Show

    /// Reveals the desktop. Safe to call repeatedly: a second call from a non-current state merges newly visible apps
    /// into the existing hidden set under a new generation.
    @discardableResult
    func showDesktop() -> ShowOutcome {
        if settings.usesSystemShowDesktop, postSystemShowDesktop() {
            return .systemShortcutPosted
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let finders = workspace.runningApplications.filter { $0.bundleIdentifier == DesktopPlan.finderBundleIdentifier }
        let apps = workspace.runningApplications.map {
            DesktopApp(pid: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier,
                       isRegular: $0.activationPolicy == .regular, isHidden: $0.isHidden, isTerminated: $0.isTerminated)
        }
        var protected: Set<Int32> = [ownPID]
        protected.formUnion(finders.map(\.processIdentifier))

        var hidden: Set<Int32> = []
        var refused: Set<Int32> = []
        for pid in DesktopPlan.appsToHide(running: apps, excluding: protected) {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            if app.hide() { hidden.insert(pid) } else { refused.insert(pid) }
        }

        generation += 1
        let now = Date()
        var next: DesktopSession
        if let existing = session {
            next = existing.merging(newlyHidden: hidden, generation: generation, at: now)
        } else {
            next = DesktopSession(generation: generation, startedAt: now, hidden: hidden, protected: protected)
        }
        next.noteRefused(refused)
        session = next

        activateFinder(finders.first)
        verifyHides(generation: generation, candidates: hidden)
        onChange?()
        return .shown(hidden: hidden.count, refused: refused.count)
    }

    /// What the Desktop entry does when chosen: show the desktop, or, if it is already the current state, bring back
    /// everything Paneflo hid.
    @discardableResult
    func activateDesktopEntry() -> ShowOutcome? {
        switch DesktopEntryAction.resolve(for: session) {
        case .show: return showDesktop()
        case .restoreAll: restoreAll(); return nil
        }
    }

    // MARK: Restore

    /// Call before focusing a window while a session exists. Unhides only that window's app if Paneflo hid it, and
    /// leaves the "desktop is current" state. Returns true when an app was asked to unhide; the unhide is asynchronous,
    /// so use `restoreAndWait(for:)` when the next step (an AX raise) needs the app visible.
    @discardableResult
    func restore(for app: NSRunningApplication?) -> Bool {
        guard var current = session else { return false }
        let pids = current.restore(for: app?.processIdentifier)
        session = current.isActive ? current : nil
        for pid in pids { NSRunningApplication(processIdentifier: pid)?.unhide() }
        onChange?()
        return !pids.isEmpty
    }

    /// `restore(for:)`, then waits (at most `timeout`) until the app reports it is no longer hidden.
    func restoreAndWait(for app: NSRunningApplication?, timeout: TimeInterval = 0.3) async {
        guard restore(for: app), let app else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while app.isHidden, !app.isTerminated, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    /// Unhides every app Paneflo hid, and nothing else.
    func restoreAll() {
        guard var current = session else { return }
        let pids = current.restoreAll()
        session = nil
        for pid in pids { NSRunningApplication(processIdentifier: pid)?.unhide() }
        onChange?()
    }

    // MARK: Private

    private func activateFinder(_ finder: NSRunningApplication?) {
        guard let finder else {
            // Finder is not running (it normally relaunches itself within moments): ask LaunchServices for it.
            openFinder()
            return
        }
        finder.activate(options: [])
        // Cooperative activation can decline for a background accessory app; check once and fall back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.session?.isCurrent == true, !finder.isActive, !finder.isTerminated else { return }
                self.openFinder()
            }
        }
    }

    private func openFinder() {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: url, configuration: configuration, completionHandler: nil)
    }

    /// Some apps accept `hide()` and stay visible. After a short settle, anything still visible is dropped from the
    /// hidden set so a later restore never touches an app Paneflo did not hide.
    private func verifyHides(generation: UInt64, candidates: Set<Int32>) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, var current = self.session, current.generation == generation else { return }
                let visible = candidates.filter { pid in
                    guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
                    return !app.isHidden && !app.isTerminated
                }
                guard !visible.isEmpty else { return }
                current.noteRefused(Set(visible))
                self.session = current
                self.onChange?()
            }
        }
    }

    // MARK: System Show Desktop (optional, default off)

    /// Posts the user's own Show Desktop shortcut (symbolic hotkey 36; F11 by default). This needs the
    /// post-event permission and the shortcut to be enabled, so it can fail; the caller then falls back to approach 1.
    /// Unverified on real hardware: the physical Command key of a ⌘Tab chord may still be down while the synthetic
    /// key is posted, and no one can observe whether the system reacted, so the setting stays off by default.
    private func postSystemShowDesktop() -> Bool {
        guard CGPreflightPostEventAccess() else { return false }
        let hotkeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
                                                "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        guard let hotkey = SystemShowDesktopHotkey.resolve(symbolicHotkeys: hotkeys) else { return false }
        let flags = CGEventFlags(rawValue: hotkey.modifierMask)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: hotkey.keyCode, keyDown: keyDown) else { return false }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        return true
    }
}
