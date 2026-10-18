import AppKit
@preconcurrency import ApplicationServices
import Darwin
import PanefloCore

private struct AppDescriptor: Sendable {
    let process: ProcessIdentity
    let identifier: String
    let name: String
}

/// Immutable remote handles may cross queues; each operation has a finite AX timeout.
private final class AXWindowTarget: @unchecked Sendable {
    let element: AXUIElement
    let app: AXUIElement
    let id: WindowIdentity
    /// Window server number, resolved once and kept for the window's lifetime.
    let captureNumber: UInt32?

    init(element: AXUIElement, app: AXUIElement, id: WindowIdentity, captureNumber: UInt32?) {
        self.element = element; self.app = app; self.id = id; self.captureNumber = captureNumber
    }
}

/// Hashable identity for a remote AX element. CFEqual/CFHash are local and perform no IPC.
private struct ElementKey: Hashable, @unchecked Sendable {
    let element: AXUIElement
    static func == (lhs: ElementKey, rhs: ElementKey) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

private struct DiscoveryResult: Sendable {
    var records: [WindowRecord] = []
    var targets: [WindowIdentity: AXWindowTarget] = [:]
    var completed: Set<ProcessIdentity> = []
    /// The process's own focused window, whether or not it is frontmost.
    var focus: WindowIdentity?
    /// Latest focus-request sequence when the scan began; stale focus is ignored by the registry.
    var epoch: UInt64 = 0
    /// On-screen, layer-0 window numbers front to back, taken with the scan's window list.
    var stacking: [UInt32] = []
}

private enum PlacementRequest: Sendable {
    case tile(zone: LayoutZone, displays: [DisplayArea], explicitDisplay: Int?, gap: Double)
    case restore(WindowRect, displays: [DisplayArea])
}

/// Outcome of one placement. `after` is nil when nothing was applied; otherwise it is the frame
/// believed final, used for undo bookkeeping only.
private struct PlacementReport: Sendable {
    var before: WindowRect?
    var after: WindowRect?
    var message: String
    /// The display index a tile landed on (nil for restores and failures).
    var display: Int? = nil
    /// The rectangle the placement asked for.
    var requested: WindowRect? = nil
}

/// A finished placement: where it landed (display index in `WindowService.displayAreas()` order) and its frame.
struct TileOutcome: Sendable {
    let display: Int?
    let frame: WindowRect
    /// The window's frame read just before the placement.
    var before: WindowRect? = nil
    /// What Paneflo asked for; a different `frame` means the window limits its own size.
    var requested: WindowRect? = nil
    /// A newer placement of the same window was requested meanwhile: the frame is real, but nothing should be
    /// decided from it (the newer request owns the window).
    var superseded = false
}

/// The window a ⌃⌥ arrangement acts on, resolved fresh at keypress time.
enum FrontWindowTarget: Sendable {
    /// `resizable` false: the window can only be moved.
    case window(WindowIdentity, resizable: Bool)
    case failure(FrontWindowResolution.Failure)
}

/// The worker's fresh read of the frontmost app. `target`/`record` are set when it arranged a window; `adopted` when
/// that window was not in the registry yet.
private struct FrontResolution: Sendable {
    var decision: FrontWindowResolution.Decision
    var target: AXWindowTarget?
    var record: WindowRecord?
    var adopted = false
    var path = ""
}

private enum WindowEvent: Sendable {
    case focused(WindowIdentity, epoch: UInt64)
    case updated([WindowRecord])
    case removed([WindowIdentity])
    case needsRescan
}

/// Private `_AXUIElementGetWindow`, resolved at runtime without a link-time dependency.
/// Capability-checked (symbol present, call succeeds, number owned by the PID in the window
/// list); any failure falls back to public matching. `PANEFLO_DISABLE_AX_WINDOW_ID=1` forces
/// the public path.
private enum AXWindowNumber {
    typealias Function = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    static let function: Function? = {
        guard ProcessInfo.processInfo.environment["PANEFLO_DISABLE_AX_WINDOW_ID"] != "1",
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }()
    static var isAvailable: Bool { function != nil }

    static func number(for element: AXUIElement) -> UInt32? {
        guard let function else { return nil }
        var number: CGWindowID = 0
        guard function(element, &number) == .success, number != 0 else { return nil }
        return number
    }
}

/// Main-thread state publication; all remote Accessibility IPC is performed by WindowWorker.
@MainActor
final class WindowService {
    private let worker = WindowWorker()
    private var registry = WindowRegistry()
    private var targets: [WindowIdentity: AXWindowTarget] = [:]
    private var recordIndex: [WindowIdentity: WindowRecord] = [:]
    private var captureNumbers: [WindowIdentity: UInt32] = [:]
    private var identityByNumber: [UInt32: WindowIdentity] = [:]
    private var lastStacking: [UInt32] = []
    private var hiddenPIDs = Set<pid_t>()
    private var lastFocusedByPID: [pid_t: WindowIdentity] = [:]
    private var scannedProcesses = Set<ProcessIdentity>()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pendingRefresh: DispatchWorkItem?
    private var scanInFlight = false
    private var needsRescan = false
    private var undoHistory = GeometryUndoHistory()
    private var nextOperation: UInt64 = 0
    /// The latest placement token per window while its placement runs.
    private var placementsInFlight: [WindowIdentity: UInt64] = [:]
    private var processTokens: [pid_t: (Date?, UInt64)] = [:]
    private var nextToken: UInt64 = 0
    private var latestFocusIntent: UInt64 = 0
    private var pendingActivations: [UInt64: NSRunningApplication] = [:]
    private(set) var snapshot = WindowSnapshot(records: [])
    private(set) var focusedID: WindowIdentity?
    var onChange: (() -> Void)?
    var onStatus: ((String) -> Void)?
    /// A placement could not be made (window gone, refused, full screen, Accessibility off): the reason, for visible
    /// feedback. Superseded placements are not failures.
    var onPlacementFailed: ((WindowIdentity?, String) -> Void)?
    var hasAccessibility: Bool { AXIsProcessTrusted() }

    #if PANEFLO_NATIVE_CHECK
    /// Drops focus observations so a bench can keep `focusedID` deliberately stale.
    var nativeCheckDropFocusEvents = false
    /// Restricts discovery to the given processes so checks never read unrelated apps.
    var nativeCheckProcessFilter: ((pid_t) -> Bool)?
    private(set) var nativeCheckScanCount = 0

    func nativeCheckInstall(_ records: [WindowRecord]) {
        snapshot = WindowSnapshot(records: records)
        recordIndex = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        focusedID = records.first?.id
        onChange?()
    }
    #endif

    func start() {
        guard workspaceObservers.isEmpty else { refresh(); return }
        worker.setEventHandler { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
        }
        RuntimeDiagnostics.mark("AX window-id mapping=\(AXWindowNumber.isAvailable ? "private-with-public-fallback" : "public")")
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let pid = app?.processIdentifier
                let launch = app?.launchDate
                MainActor.assumeIsolated { self?.workspaceEvent(name, pid: pid, launch: launch) }
            })
        }
        refresh()
    }

    private func workspaceEvent(_ name: Notification.Name, pid: pid_t?, launch: Date?) {
        switch name {
        case NSWorkspace.didActivateApplicationNotification:
            guard let pid, pid != ProcessInfo.processInfo.processIdentifier else { return }
            applicationActivated(pid)
        case NSWorkspace.didTerminateApplicationNotification:
            if let pid, let token = processTokens[pid], token.0 == launch {
                processTokens.removeValue(forKey: pid)
                let ended = ProcessIdentity(pid: pid, launchToken: token.1)
                registry.processEnded(ended)
                targets = targets.filter { $0.key.process != ended }
                scannedProcesses.remove(ended)
                lastFocusedByPID.removeValue(forKey: pid)
                hiddenPIDs.remove(pid)
                publish(force: true)
            }
            scheduleRefresh()
        case NSWorkspace.didHideApplicationNotification:
            if let pid { hiddenPIDs.insert(pid) }
            scheduleRefresh()
        case NSWorkspace.didUnhideApplicationNotification:
            if let pid { hiddenPIDs.remove(pid) }
            scheduleRefresh()
        default:
            scheduleRefresh()
        }
    }

    /// Activation updates MRU directly from the cached focused window, then confirms with a
    /// single focused-window query instead of a full rescan.
    private func applicationActivated(_ pid: pid_t) {
        guard let token = processTokens[pid] else { scheduleRefresh(); return }
        let process = ProcessIdentity(pid: pid, launchToken: token.1)
        guard scannedProcesses.contains(process) else { scheduleRefresh(); return }
        if let cached = lastFocusedByPID[pid] { noteFocus(cached, epoch: worker.currentEpoch()) }
        worker.queryFocus(process)
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        onStatus?("Switch Paneflo on in Privacy & Security › Accessibility. Paneflo picks it up by itself.")
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }

    /// O(1): dictionary lookups only, no window-server or process queries.
    func captureWindowNumber(for id: WindowIdentity) -> UInt32? {
        guard let record = recordIndex[id], !record.isMinimized, !hiddenPIDs.contains(id.process.pid) else { return nil }
        return captureNumbers[id]
    }

    func refresh() {
        pendingRefresh?.cancel(); pendingRefresh = nil
        guard hasAccessibility else {
            onStatus?("Accessibility access is required to discover and control your windows.")
            onChange?()
            return
        }
        guard !scanInFlight else { needsRescan = true; return }
        var hidden = Set<pid_t>()
        #if PANEFLO_NATIVE_CHECK
        nativeCheckScanCount += 1
        let running = NSWorkspace.shared.runningApplications.filter { nativeCheckProcessFilter?($0.processIdentifier) ?? true }
        #else
        let running = NSWorkspace.shared.runningApplications
        #endif
        let apps = running.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
        }.map { app -> AppDescriptor in
            let pid = app.processIdentifier
            if app.isHidden { hidden.insert(pid) }
            let token: UInt64
            if let current = processTokens[pid], current.0 == app.launchDate { token = current.1 }
            else { nextToken += 1; token = nextToken; processTokens[pid] = (app.launchDate, token) }
            return AppDescriptor(process: ProcessIdentity(pid: pid, launchToken: token), identifier: app.bundleIdentifier ?? "pid.\(pid)", name: app.localizedName ?? "Application")
        }
        hiddenPIDs = hidden
        let live = Set(apps.map(\.process))
        let livePIDs = Set(apps.map { $0.process.pid })
        processTokens = processTokens.filter { livePIDs.contains($0.key) }
        for process in Set(snapshot.records.map { $0.id.process }) where !live.contains(process) { registry.processEnded(process) }
        targets = targets.filter { live.contains($0.key.process) }
        scannedProcesses = scannedProcesses.filter { live.contains($0) }
        lastFocusedByPID = lastFocusedByPID.filter { livePIDs.contains($0.key) }
        scanInFlight = true
        worker.discover(apps: apps) { [weak self] result, finished in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(result, finished: finished) } }
        }
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func apply(_ discovered: DiscoveryResult, finished: Bool) {
        // A terminated process cannot repopulate targets from a late in-flight scan.
        let records = discovered.records.filter { isCurrent($0.id.process) }
        let admitted = Set(records.map(\.id))
        for record in snapshot.records where discovered.completed.contains(record.id.process) && !admitted.contains(record.id) {
            registry.remove(record.id)
            targets.removeValue(forKey: record.id)
        }
        for record in records { registry.upsert(record) }
        targets.merge(discovered.targets.filter { admitted.contains($0.key) }) { _, new in new }
        for process in discovered.completed where isCurrent(process) { scannedProcesses.insert(process) }
        if !discovered.stacking.isEmpty { lastStacking = discovered.stacking }
        rebuildIndexes()
        registry.updateStacking(frontToBack: lastStacking.compactMap { identityByNumber[$0] })
        var dropFocus = false
        #if PANEFLO_NATIVE_CHECK
        dropFocus = nativeCheckDropFocusEvents
        #endif
        if !dropFocus, let focus = discovered.focus, admitted.contains(focus) {
            lastFocusedByPID[focus.process.pid] = focus
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.process.pid,
               registry.observeFocus(focus, sequence: discovered.epoch) { focusedID = focus }
        }
        publish(force: finished)
        if finished {
            scanInFlight = false
            if needsRescan { needsRescan = false; scheduleRefresh() }
        }
    }

    private func handle(_ event: WindowEvent) {
        switch event {
        case let .focused(id, epoch):
            noteFocus(id, epoch: epoch)
        case let .updated(records):
            for record in records where isCurrent(record.id.process) && targets[record.id] != nil { registry.upsert(record) }
            publish(force: false)
        case let .removed(ids):
            for id in ids { registry.remove(id); targets.removeValue(forKey: id) }
            rebuildIndexes()
            publish(force: false)
        case .needsRescan:
            scheduleRefresh()
        }
    }

    /// Records the app's focused window and moves it to the MRU front when its app is frontmost.
    private func noteFocus(_ id: WindowIdentity, epoch: UInt64) {
        #if PANEFLO_NATIVE_CHECK
        if nativeCheckDropFocusEvents { return }
        #endif
        guard isCurrent(id.process), targets[id] != nil else { return }
        lastFocusedByPID[id.process.pid] = id
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == id.process.pid else { return }
        if registry.observeFocus(id, sequence: epoch) {
            focusedID = id
            publish(force: false)
        }
    }

    private func rebuildIndexes() {
        captureNumbers = targets.compactMapValues(\.captureNumber)
        identityByNumber = Dictionary(captureNumbers.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
    }

    private func publish(force: Bool) {
        let next = registry.snapshot
        guard force || next != snapshot else { return }
        if next.records != snapshot.records {
            recordIndex = Dictionary(next.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        snapshot = next
        onChange?()
    }

    func focus(_ id: WindowIdentity) {
        guard hasAccessibility, let target = targets[id], recordIndex[id] != nil, let app = currentApplication(for: id) else {
            onStatus?("That window is no longer available."); return
        }
        let intent = worker.beginIntent()
        latestFocusIntent = intent
        // The app is unhidden first so the window can be raised; activation follows the AX
        // raise/main so the app's previous main window does not surface first.
        if app.isHidden { app.unhide() }
        pendingActivations[intent] = app
        worker.focus(target, intent: intent, raised: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.activate(intent, reason: "raised") } }
        }, completion: { [weak self] success in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.focusFinished(id, intent: intent, success: success) } }
        })
        // A slow or unresponsive app must not delay activation indefinitely.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.activate(intent, reason: "deadline") }
        // Optimistic MRU: a quick second Command-Tab sees this window at the front.
        if registry.requestFocus(id, sequence: intent) {
            focusedID = id
            publish(force: false)
        }
    }

    /// Brings a tile partner in front of other apps' windows, just before its pair's target is focused.
    ///
    /// An Accessibility raise alone only reorders a window among its own app's windows: with fixture windows on
    /// macOS 26 a raised background window stayed behind the frontmost app's window. So the partner becomes its
    /// app's focused, main and raised window and its app is activated; `completion` waits (on the worker, never the
    /// main thread) until that app reports itself frontmost, because macOS drops an activation that a newer one
    /// overtakes. The target's focus and activation follow and end on top. Nothing is activated once any focus
    /// request started after this call (including the target's, after the caller's deadline), so a late partner
    /// can never end up in front of the target. `completion` runs on the main actor, at once when the window is
    /// unavailable.
    func bringForward(_ id: WindowIdentity, completion: @escaping @MainActor () -> Void) {
        guard hasAccessibility, let target = targets[id], recordIndex[id]?.isMinimized == false,
              let app = currentApplication(for: id) else { completion(); return }
        if app.isHidden { app.unhide() }
        let epoch = worker.currentEpoch()
        let pid = app.processIdentifier
        worker.raise(target, allowedEpoch: epoch, activate: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.worker.currentEpoch() == epoch,
                          let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated else { return }
                    RuntimeDiagnostics.mark("tilePairs partner activate")
                    running.activate(options: [])
                }
            }
        }, completion: { frontmost in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    RuntimeDiagnostics.mark("tilePairs partner frontmost=\(frontmost ? 1 : 0)")
                    completion()
                }
            }
        })
    }

    private func activate(_ intent: UInt64, reason: String) {
        guard let app = pendingActivations.removeValue(forKey: intent) else { return }
        // A newer focus request owns activation; a stale one must not steal the front.
        guard intent == latestFocusIntent, !app.isTerminated else { return }
        RuntimeDiagnostics.mark("AX focus activate reason=\(reason)")
        app.activate(options: [])
    }

    private func focusFinished(_ id: WindowIdentity, intent: UInt64, success: Bool) {
        activate(intent, reason: "completion")
        let frontMatches = NSWorkspace.shared.frontmostApplication?.processIdentifier == id.process.pid
        let verified = success && validLifetime(id)
        RuntimeDiagnostics.mark("AX focus targetFocused=\(verified ? 1 : 0) frontmostAtCompletion=\(frontMatches ? 1 : 0)")
        onStatus?(verified ? "Window activated." : "The application could not focus that window.")
        guard verified else {
            registry.finishFocusRequest(sequence: intent)
            scheduleRefresh()
            return
        }
        // Notifications generated before the focus landed can arrive slightly after
        // completion; hold the intent briefly, then resync with one focused-window query.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.registry.finishFocusRequest(sequence: intent)
            if intent == self.latestFocusIntent, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
               let token = self.processTokens[pid] {
                self.worker.queryFocus(ProcessIdentity(pid: pid, launchToken: token.1))
            }
        }
    }

    /// One user action's undo step. Pass it to every placement the action issues (the tile and its pair
    /// follow-ups) so a single undo puts all of them back.
    func beginOperation() -> UInt64 { nextOperation &+= 1; return nextOperation }

    /// Pairs an operation ended, re-formed when it is undone.
    func attachUndoPairs(_ pairs: [TilePairMembers], to operation: UInt64) { undoHistory.attach(pairs: pairs, to: operation) }

    /// A pair follow-up is about to move `id` to `planned`: it joins `operation` now (from the window's last known
    /// frame), so an undo issued before it lands still restores it, superseding the move.
    func recordPlanned(_ id: WindowIdentity, to planned: WindowRect, operation: UInt64) {
        guard let current = recordIndex[id]?.frame else { return }
        undoHistory.record([GeometryChange(id: id, before: current, after: planned)], operation: operation)
    }

    /// Windows with a placement still running. O(1) per window; no Accessibility call.
    var busyWindows: Set<WindowIdentity> { Set(placementsInFlight.keys) }

    /// The window a ⌃⌥ arrangement acts on, read fresh on the interactive lane: the frontmost app's focused window,
    /// else its main window, else its first standard window (never for Finder's desktop); a sheet or dialog stands for
    /// its parent. Never decided from the cached `focusedID`, which a missed notification, a click or a window not
    /// scanned yet can leave stale. A window not in the registry yet is adopted at once (a full scan follows).
    func resolveFrontmostWindow(_ completion: @escaping @MainActor (FrontWindowTarget) -> Void) {
        let started = ProcessInfo.processInfo.systemUptime
        guard let app = NSWorkspace.shared.frontmostApplication else { completion(.failure(.noWindow)); return }
        let own = app.processIdentifier == ProcessInfo.processInfo.processIdentifier
        if case .fail(let failure) = FrontWindowResolution.decide(accessibilityTrusted: hasAccessibility, frontmostIsPaneflo: own,
                                                                  frontmostIsFinder: false, candidates: [.init(source: .focused, role: "AXWindow", subrole: nil)]) {
            RuntimeDiagnostics.mark("tile front resolve failure=\(failure)")
            completion(.failure(failure)); return
        }
        let process = processIdentity(for: app)
        let descriptor = AppDescriptor(process: process, identifier: app.bundleIdentifier ?? "pid.\(app.processIdentifier)",
                                       name: app.localizedName ?? "Application")
        worker.resolveFront(descriptor, isFinder: app.bundleIdentifier == "com.apple.finder") { [weak self] resolution in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
                    RuntimeDiagnostics.mark("tile front resolve path=\(resolution.path) decision=\(resolution.decision) adopted=\(resolution.adopted) milliseconds=\(elapsed)")
                    switch resolution.decision {
                    case .fail(let failure): completion(.failure(failure))
                    case .arrange(_, _, let resizable):
                        guard let target = resolution.target, let record = resolution.record, self.isCurrent(record.id.process) else {
                            completion(.failure(.noWindow)); return
                        }
                        let id = record.id
                        if self.targets[id] == nil || self.recordIndex[id] == nil {
                            self.registry.upsert(record)
                            self.targets[id] = target
                            self.scannedProcesses.insert(id.process)
                            self.rebuildIndexes()
                            self.publish(force: true)
                            self.scheduleRefresh()
                        }
                        // The fresh read is the truth: the cached focus catches up.
                        self.lastFocusedByPID[id.process.pid] = id
                        if self.registry.observeFocus(id, sequence: self.worker.currentEpoch()) { self.focusedID = id; self.publish(force: false) }
                        completion(.window(id, resizable: resizable))
                    }
                }
            }
        }
    }

    /// The launch-token identity for a running app, assigned now when no scan has seen it yet (same rule as `refresh`).
    private func processIdentity(for app: NSRunningApplication) -> ProcessIdentity {
        let pid = app.processIdentifier
        if let current = processTokens[pid], current.0 == app.launchDate { return ProcessIdentity(pid: pid, launchToken: current.1) }
        nextToken += 1
        processTokens[pid] = (app.launchDate, nextToken)
        return ProcessIdentity(pid: pid, launchToken: nextToken)
    }

    /// Tiles a window on its own display. The display is chosen from a fresh Accessibility
    /// frame read on the placement lane, never from the snapshot's record. Placement never blocks
    /// or is blocked by focus: both run on their own lanes with independent supersession.
    /// A hidden app is unhidden first and a minimized window is restored by the worker, so the tile is visible.
    func tile(_ id: WindowIdentity? = nil, zone: LayoutZone, screenIndex: Int? = nil, gap: Double = 8, operation: UInt64? = nil,
              completion: (@MainActor @Sendable (TileOutcome?) -> Void)? = nil) {
        if id == nil, focusedID?.process.pid != NSWorkspace.shared.frontmostApplication?.processIdentifier {
            onStatus?("The frontmost window changed. Try again after its focus is confirmed.")
            scheduleRefresh(); completion?(nil); return
        }
        guard hasAccessibility else {
            onPlacementFailed?(id, FrontWindowResolution.Failure.accessibilityOff.message); completion?(nil); return
        }
        guard let id = id ?? focusedID, validLifetime(id), recordIndex[id] != nil, let target = targets[id] else {
            onStatus?("Select a window before arranging it.")
            onPlacementFailed?(id, "That window is no longer available"); completion?(nil); return
        }
        let displays = Self.displayAreas()
        guard !displays.isEmpty else { completion?(nil); return }
        if let app = currentApplication(for: id), app.isHidden { app.unhide() }
        RuntimeDiagnostics.mark("tile request zone=\(zone.rawValue) explicitDisplay=\(screenIndex.map(String.init) ?? "none")")
        run(.tile(zone: zone, displays: displays, explicitDisplay: screenIndex, gap: gap), for: id, target: target,
            operation: operation, completion: completion)
    }

    /// Moves a window to an exact frame (a pair follow-up: a displaced member's home, the rest of the display beside
    /// a size-limited partner). A frame that left every display is clamped into the nearest one.
    func place(_ id: WindowIdentity, frame: WindowRect, operation: UInt64? = nil,
               completion: (@MainActor @Sendable (TileOutcome?) -> Void)? = nil) {
        guard hasAccessibility, validLifetime(id), recordIndex[id] != nil, let target = targets[id] else { completion?(nil); return }
        let displays = Self.displayAreas()
        guard !displays.isEmpty else { completion?(nil); return }
        run(.restore(frame, displays: displays), for: id, target: target, operation: operation, completion: completion)
    }

    private func run(_ request: PlacementRequest, for id: WindowIdentity, target: AXWindowTarget, operation: UInt64?,
                     completion: (@MainActor @Sendable (TileOutcome?) -> Void)?) {
        let token = worker.beginPlacement(for: id)
        placementsInFlight[id] = token
        worker.place(target, request: request, token: token) { [weak self] report in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { completion?(nil); return }
                    let superseded = !self.worker.isCurrentPlacement(token, for: id)
                    if self.placementsInFlight[id] == token { self.placementsInFlight.removeValue(forKey: id) }
                    if let before = report.before, let after = report.after {
                        self.undoHistory.record([GeometryChange(id: id, before: before, after: after)], operation: operation)
                    }
                    if !superseded { self.onStatus?(report.message) }
                    if report.after == nil, !superseded, !report.message.hasPrefix("Layout superseded") {
                        RuntimeDiagnostics.mark("tile placement failed")
                        self.onPlacementFailed?(id, report.message)
                    }
                    self.worker.markDirty(target)
                    completion?(report.after.map {
                        TileOutcome(display: report.display, frame: $0, before: report.before, requested: report.requested,
                                    superseded: superseded)
                    })
                }
            }
        }
    }

    /// Undoes the preferred window's most recent operation (the switcher selection, else the focused window): every
    /// window that operation moved goes back to its exact frame from before (clamped into the nearest display when
    /// that position left every display). Returns the plan with the frames being restored, so pairs it ended can be
    /// formed again at once; nil when there is nothing to undo.
    @discardableResult
    func undo(preferring preferred: WindowIdentity? = nil, fallback: Bool = false) -> (plan: GeometryUndoPlan, restored: [WindowIdentity: WindowRect])? {
        let alive = Set(targets.keys.filter { validLifetime($0) })
        let candidate = preferred ?? focusedID
        let plan: GeometryUndoPlan?
        if let candidate, undoHistory.hasHistory(for: candidate) { plan = undoHistory.undo(window: candidate, surviving: alive) }
        else if preferred == nil || fallback { plan = undoHistory.undo(surviving: alive) }
        else { plan = nil }
        guard let plan, !plan.changes.isEmpty else { onStatus?("Nothing to undo."); return nil }
        let displays = Self.displayAreas()
        guard !displays.isEmpty else { return nil }
        var restored: [WindowIdentity: WindowRect] = [:]
        for change in plan.changes {
            guard let target = targets[change.id] else { continue }
            restored[change.id] = DisplayPlacement.restoredFrame(change.before, displays: displays)
            let token = worker.beginPlacement(for: change.id)
            placementsInFlight[change.id] = token
            worker.place(target, request: .restore(change.before, displays: displays), token: token) { [weak self] report in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if self.placementsInFlight[change.id] == token { self.placementsInFlight.removeValue(forKey: change.id) }
                        self.onStatus?(report.message); self.worker.markDirty(target)
                    }
                }
            }
        }
        return (plan, restored)
    }

    /// Screens in AppKit order converted to Accessibility coordinates. Index 0 owns the global origin.
    static func displayAreas() -> [DisplayArea] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let height = primary.frame.height
        func rect(_ r: NSRect) -> WindowRect { WindowRect(x: r.minX, y: r.minY, width: r.width, height: r.height) }
        return screens.map {
            DisplayArea(appKitFrame: rect($0.frame), appKitVisibleFrame: rect($0.visibleFrame),
                        backingScale: $0.backingScaleFactor, primaryHeight: height)
        }
    }

    /// A held-switcher window command (Command-W/M/H/Q) for `id`. Quit and hide go through
    /// NSRunningApplication (no AX); close presses the window's AX close button on the worker. The
    /// registry update that follows (destroyed window, terminated or hidden app, minimized flag)
    /// refreshes the open switcher, which keeps its order and moves the selection to a neighbour.
    func perform(_ command: SwitcherWindowCommand, on id: WindowIdentity) {
        guard let app = currentApplication(for: id) else { onStatus?("That window is no longer available."); return }
        guard command.isPermitted(bundleIdentifier: app.bundleIdentifier,
                                  isPaneflo: app.processIdentifier == ProcessInfo.processInfo.processIdentifier) else { return }
        RuntimeDiagnostics.mark("switcher windowCommand=\(command)")
        switch command {
        case .quitApplication:
            if !app.terminate() { onStatus?("The application did not accept the request to quit.") }
        case .hideApplication:
            if !app.hide() { onStatus?("The application could not be hidden.") }
        case .minimize:
            minimize(id)
        case .close:
            guard hasAccessibility, let target = targets[id] else { return }
            worker.close(target) { [weak self] closed in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if !closed { self?.onStatus?("That window has no close button Paneflo can press.") }
                        self?.worker.markDirty(target)
                    }
                }
            }
        }
    }

    func minimize(_ id: WindowIdentity) {
        guard hasAccessibility, validLifetime(id), let target = targets[id] else { return }
        worker.setMinimized(target, value: true) { [weak self] in Task { @MainActor in self?.worker.markDirty(target) } }
    }

    /// Cheap lifetime check from cached launch tokens (no process lookup).
    private func isCurrent(_ process: ProcessIdentity) -> Bool {
        processTokens[process.pid]?.1 == process.launchToken
    }

    private func validLifetime(_ id: WindowIdentity) -> Bool {
        currentApplication(for: id) != nil
    }

    private func currentApplication(for id: WindowIdentity) -> NSRunningApplication? {
        // Processes started outside LaunchServices have no launch date; both sides then compare
        // as nil, matching how the token was assigned in `refresh`.
        guard let token = processTokens[id.process.pid], token.1 == id.process.launchToken,
              let running = NSRunningApplication(processIdentifier: id.process.pid), !running.isTerminated,
              running.launchDate == token.0 else { return nil }
        return running
    }
}

/// Runs AX observer sources off the main thread. AX observer run-loop sources are ordinary
/// mach-port sources and may be scheduled on any run loop; callbacks then arrive on this
/// thread and only hop to the coordinator queue (no AX IPC, no main-thread work).
private final class AXObserverThread: @unchecked Sendable {
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    init() {
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            // A distant timer keeps the run loop alive while no observer source is scheduled.
            let keepAlive = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 1e10, 1e10, 0, 0) { _ in }
            CFRunLoopAddTimer(loop, keepAlive, .defaultMode)
            runLoop = loop
            ready.signal()
            while true {
                CFRunLoopRun()
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        thread.name = "dev.paneflo.ax-observer"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    func add(_ source: CFRunLoopSource) {
        guard let runLoop else { return }
        CFRunLoopAddSource(runLoop, source, .defaultMode)
        CFRunLoopWakeUp(runLoop)
    }

    func remove(_ source: CFRunLoopSource) {
        guard let runLoop else { return }
        CFRunLoopRemoveSource(runLoop, source, .defaultMode)
    }
}

private final class WindowWorker: @unchecked Sendable {
    /// Per-process scan state. Fields under `lock` are shared between the serialized scan/update
    /// worker for the PID and the coordinator; `cursor` is scan-only; flush fields are
    /// coordinator-only.
    private final class ScanState: @unchecked Sendable {
        let process: ProcessIdentity
        let app: AXUIElement
        let lock = NSLock()
        var targets: [ElementKey: AXWindowTarget] = [:]
        var records: [WindowIdentity: WindowRecord] = [:]
        /// Window elements that already carry per-window notifications.
        var registered = Set<ElementKey>()
        var observer: AXObserver?
        var cursor = 0
        // Coordinator-only.
        var dirty = Set<ElementKey>()
        var needsFocusQuery = false
        var flushGeneration = 0
        var firstDirty: TimeInterval?

        init(process: ProcessIdentity) {
            self.process = process
            app = AXUIElementCreateApplication(process.pid)
            AXUIElementSetMessagingTimeout(app, 0.12)
        }

        func target(_ key: ElementKey) -> AXWindowTarget? { lock.withLock { targets[key] } }
    }
    private final class Batch: @unchecked Sendable {
        var remaining: Int
        init(_ count: Int) { remaining = count }
    }
    private struct Job: Sendable {
        let work: @Sendable () -> Void
        let cancelled: @Sendable () -> Void
    }
    private final class CGSnapshot: @unchecked Sendable {
        let entries: [Int32: [WindowServerEntry]]
        let owners: [UInt32: Int32]
        let stacking: [UInt32]

        init() {
            let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            // `.optionOnScreenOnly` is ordered front to back.
            let order = onScreen.compactMap { info -> UInt32? in
                guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
                return (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            }
            var rank: [UInt32: Int] = [:]
            for (index, number) in order.enumerated() where rank[number] == nil { rank[number] = index }
            var entries: [Int32: [WindowServerEntry]] = [:]
            var owners: [UInt32: Int32] = [:]
            for (index, info) in all.enumerated() {
                guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                      let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
                owners[number] = pid
                guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
                let entry = WindowServerEntry(number: number, ownerPID: pid,
                                              layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                                              frame: WindowRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height),
                                              title: info[kCGWindowName as String] as? String,
                                              stackIndex: rank[number] ?? 1_000_000 + index)
                entries[pid, default: []].append(entry)
            }
            self.entries = entries; self.owners = owners; self.stacking = order
        }
    }
    private let coordinator = DispatchQueue(label: "dev.paneflo.ax-admission")
    private let metadataQueue = DispatchQueue(label: "dev.paneflo.cg-metadata", qos: .utility)
    private let workers = DispatchQueue(label: "dev.paneflo.ax-workers", qos: .userInitiated, attributes: .concurrent)
    private let interactiveWorkers = DispatchQueue(label: "dev.paneflo.ax-interactive", qos: .userInteractive, attributes: .concurrent)
    private let observerThread = AXObserverThread()
    private var admission = AXWorkAdmission()
    private var jobs: [UInt64: Job] = [:]
    private var nextJob: UInt64 = 0
    private var states: [ProcessIdentity: ScanState] = [:]
    private var nextNumber: UInt32 = 0
    private let numberLock = NSLock()
    private let intentLock = NSLock()
    private var intents = ActionIntents()
    fileprivate static let focusLane: UInt8 = 0
    fileprivate static let placementLane: UInt8 = 1
    fileprivate static let raiseLane: UInt8 = 2
    fileprivate static let resolveLane: UInt8 = 3
    /// Coordinator-only.
    private var onEvent: (@Sendable (WindowEvent) -> Void)?

    func setEventHandler(_ handler: @escaping @Sendable (WindowEvent) -> Void) {
        coordinator.sync { onEvent = handler }
    }

    func beginIntent() -> UInt64 { intentLock.withLock { intents.beginFocus() } }
    func currentEpoch() -> UInt64 { intentLock.withLock { intents.currentFocus } }
    private func isCurrent(_ intent: UInt64) -> Bool { intentLock.withLock { intents.isCurrentFocus(intent) } }
    func beginPlacement(for id: WindowIdentity) -> UInt64 { intentLock.withLock { intents.beginPlacement(for: id) } }
    func isCurrentPlacement(_ token: UInt64, for id: WindowIdentity) -> Bool {
        intentLock.withLock { intents.isCurrentPlacement(token, for: id) }
    }

    private func submit(pid: pid_t, priority: AXWorkAdmission.Priority, lane: UInt8 = 0,
                        cancelled: @escaping @Sendable () -> Void,
                        work: @escaping @Sendable () -> Void) {
        coordinator.async { [self] in enqueue(pid: pid, priority: priority, lane: lane, cancelled: cancelled, work: work) }
    }

    /// Coordinator-only. No AX IPC is allowed here, including cancellation callbacks.
    private func enqueue(pid: pid_t, priority: AXWorkAdmission.Priority, lane: UInt8 = 0,
                         cancelled: @escaping @Sendable () -> Void,
                         work: @escaping @Sendable () -> Void) {
        nextJob &+= 1
        let ticket = AXWorkAdmission.Ticket(id: nextJob, pid: pid, priority: priority, lane: lane)
        jobs[ticket.id] = Job(work: work, cancelled: cancelled)
        for id in admission.enqueue(ticket) { jobs.removeValue(forKey: id)?.cancelled() }
        drain()
    }

    private func drain() {
        for ticket in admission.takeReady() {
            guard let job = jobs[ticket.id] else { admission.finish(ticket.id); continue }
            let queue = ticket.priority == .interactive ? interactiveWorkers : workers
            queue.async { [self] in
                job.work()
                coordinator.async { [self] in
                    jobs.removeValue(forKey: ticket.id)
                    admission.finish(ticket.id)
                    drain()
                }
            }
        }
    }

    private func emit(_ event: WindowEvent) { onEvent?(event) }

    // MARK: Discovery

    func discover(apps: [AppDescriptor], completion: @escaping @Sendable (DiscoveryResult, Bool) -> Void) {
        metadataQueue.async { [self] in
            let cg = CGSnapshot()
            coordinator.async { [self] in
                let live = Set(apps.map(\.process))
                for (identity, state) in states where !live.contains(identity) {
                    if let observer = state.lock.withLock({ state.observer }) {
                        observerThread.remove(AXObserverGetRunLoopSource(observer))
                    }
                    states.removeValue(forKey: identity)
                }
                guard !apps.isEmpty else {
                    completion(DiscoveryResult(stacking: cg.stacking), true)
                    return
                }
                let batch = Batch(apps.count)
                for descriptor in apps {
                    let state = states[descriptor.process] ?? ScanState(process: descriptor.process)
                    states[descriptor.process] = state
                    enqueue(pid: descriptor.process.pid, priority: .background, cancelled: {
                        // Cancellation executes on the coordinator, never releases an active call.
                        batch.remaining -= 1
                        completion(DiscoveryResult(stacking: cg.stacking), batch.remaining == 0)
                    }, work: { [self] in
                        let result = scan(descriptor, state: state, cgWindows: cg)
                        coordinator.async {
                            batch.remaining -= 1
                            // Publish each responsive PID immediately; a slow app cannot hold all results.
                            completion(result, batch.remaining == 0)
                        }
                    })
                }
            }
        }
    }

    private struct FreshWindow {
        let key: ElementKey
        let id: WindowIdentity
        let title: String
        let rect: WindowRect
        let minimized: Bool
        let known: UInt32?
        let axIndex: Int
    }

    private func scan(_ descriptor: AppDescriptor, state: ScanState, cgWindows: CGSnapshot) -> DiscoveryResult {
        let pid = descriptor.process.pid
        var result = DiscoveryResult(epoch: currentEpoch(), stacking: cgWindows.stacking)
        let app = state.app
        guard let elements = Self.attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return result }
        result.completed.insert(descriptor.process)
        let observer = ensureObserver(state: state, pid: pid)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        let focused = Self.element(Self.attribute(app, kAXFocusedWindowAttribute, deadline: deadline)).map(ElementKey.init)
        let (previous, oldRecords, wasRegistered) = state.lock.withLock { (state.targets, state.records, state.registered) }
        var current: [ElementKey: AXWindowTarget] = [:]
        var registered = Set<ElementKey>()
        var fresh: [FreshWindow] = []
        func retain(_ key: ElementKey) {
            guard let old = previous[key], let record = oldRecords[old.id] else { return }
            current[key] = old; result.targets[old.id] = old; result.records.append(record)
            if wasRegistered.contains(key) { registered.insert(key) }
        }
        let candidates = Array(elements.prefix(256))
        let start = state.cursor % max(1, candidates.count)
        for offset in candidates.indices {
            let index = (start + offset) % candidates.count
            let element = candidates[index]
            let key = ElementKey(element: element)
            if ProcessInfo.processInfo.systemUptime >= deadline { retain(key); continue }
            state.cursor = (index + 1) % candidates.count
            AXUIElementSetMessagingTimeout(element, 0.12)
            // An AX timeout is not a close; retain the previous identity and metadata.
            guard let rect = Self.frame(element, deadline: deadline) else { retain(key); continue }
            guard rect.width >= 40, rect.height >= 30 else { continue }
            guard let role = Self.attribute(element, kAXRoleAttribute, deadline: deadline) as? String else { retain(key); continue }
            guard role == kAXWindowRole else { continue }
            let subrole = Self.attribute(element, kAXSubroleAttribute, deadline: deadline) as? String
            guard subrole != kAXSystemDialogSubrole else { continue }
            let old = previous[key]
            let oldRecord = old.flatMap { oldRecords[$0.id] }
            let title = Self.attribute(element, kAXTitleAttribute, deadline: deadline) as? String ?? oldRecord?.title ?? "Untitled window"
            let id: WindowIdentity
            if let old { id = old.id }
            else {
                let number = numberLock.withLock { nextNumber &+= 1; return nextNumber }
                id = WindowIdentity(process: descriptor.process, number: number, incarnation: 1)
            }
            // The window server number never changes for a window: reuse it while still owned
            // by this process, otherwise ask the direct mapping, validated against the list.
            var known: UInt32?
            if let number = old?.captureNumber, cgWindows.owners[number] == pid { known = number }
            else if let number = AXWindowNumber.number(for: element), cgWindows.owners[number] == pid { known = number }
            let minimized = Self.attribute(element, kAXMinimizedAttribute, deadline: deadline) as? Bool ?? oldRecord?.isMinimized ?? false
            fresh.append(FreshWindow(key: key, id: id, title: title, rect: rect, minimized: minimized, known: known, axIndex: index))
            // Per-window notifications are registered once per element, not on every scan.
            if wasRegistered.contains(key) { registered.insert(key) }
            else if let observer, ProcessInfo.processInfo.systemUptime < deadline, register(observer, element: element) {
                registered.insert(key)
            }
        }
        fresh.sort { $0.axIndex < $1.axIndex }
        let probes = fresh.map { AccessibilityWindowProbe(frame: $0.rect, title: $0.title, known: $0.known) }
        let numbers = WindowNumberMatcher.match(pid: pid, probes: probes, entries: cgWindows.entries[pid] ?? [],
                                                claimed: Set(current.values.compactMap(\.captureNumber)))
        for (window, number) in zip(fresh, numbers) {
            let target = AXWindowTarget(element: window.key.element, app: app, id: window.id, captureNumber: number)
            current[window.key] = target; result.targets[window.id] = target
            result.records.append(WindowRecord(id: window.id, appIdentifier: descriptor.identifier, appName: descriptor.name,
                                               title: window.title, frame: window.rect, isMinimized: window.minimized))
        }
        if let focused, let target = current[focused] { result.focus = target.id }
        let records = Dictionary(result.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        state.lock.withLock {
            state.targets = current
            state.records = records
            state.registered = registered
        }
        return result
    }

    private static let windowNotifications = [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification,
                                              kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification]

    private func register(_ observer: AXObserver, element: AXUIElement) -> Bool {
        var complete = true
        for name in Self.windowNotifications {
            let status = AXObserverAddNotification(observer, element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
            if status != .success && status != .notificationAlreadyRegistered { complete = false }
        }
        return complete
    }

    private func ensureObserver(state: ScanState, pid: pid_t) -> AXObserver? {
        if let observer = state.lock.withLock({ state.observer }) { return observer }
        var created: AXObserver?
        let status = AXObserverCreate(pid, { observer, element, notification, context in
            guard let context else { return }
            Unmanaged<WindowWorker>.fromOpaque(context).takeUnretainedValue()
                .receive(observer: observer, element: element, notification: notification as String)
        }, &created)
        guard status == .success, let observer = created else { return nil }
        for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(observer, state.app, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        state.lock.withLock { state.observer = observer }
        observerThread.add(AXObserverGetRunLoopSource(observer))
        return observer
    }

    // MARK: Notifications

    /// Observer thread. Captures the focus epoch at delivery, then hops to the coordinator.
    private func receive(observer: AXObserver, element: AXUIElement, notification: String) {
        let epoch = currentEpoch()
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success else { return }
        let pid = owner
        let key = ElementKey(element: element)
        coordinator.async { [self] in
            guard let state = self.state(pid: pid, observer: observer) else { return }
            switch notification {
            case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
                if let target = state.target(key) { emit(.focused(target.id, epoch: epoch)) }
                else { state.needsFocusQuery = true; scheduleFlush(state, delay: 0) }
            case kAXWindowCreatedNotification:
                emit(.needsRescan)
            case kAXUIElementDestroyedNotification:
                let removed: WindowIdentity? = state.lock.withLock {
                    guard let target = state.targets.removeValue(forKey: key) else { return nil }
                    state.records.removeValue(forKey: target.id)
                    state.registered.remove(key)
                    return target.id
                }
                state.dirty.remove(key)
                if let removed { emit(.removed([removed])) }
            case kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification:
                guard state.target(key) != nil else { return }
                state.dirty.insert(key); scheduleFlush(state, delay: 0.03)
            default: // moved, resized, title changed: coalesce into one record refresh
                guard state.target(key) != nil else { return }
                state.dirty.insert(key); scheduleFlush(state, delay: 0.15)
            }
        }
    }

    /// Coordinator-only.
    private func state(pid: pid_t, observer: AXObserver) -> ScanState? {
        for (process, state) in states where process.pid == pid {
            if let current = state.lock.withLock({ state.observer }), CFEqual(current, observer) { return state }
        }
        return nil
    }

    /// Coordinator-only. Trailing debounce bounded by a maximum wait so continuous drags or
    /// ticking titles still publish at a low rate.
    private func scheduleFlush(_ state: ScanState, delay: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        let first = state.firstDirty ?? now
        state.firstDirty = first
        state.flushGeneration &+= 1
        let generation = state.flushGeneration
        let wait = now - first >= 0.6 ? 0 : delay
        coordinator.asyncAfter(deadline: .now() + wait) { [self] in
            guard state.flushGeneration == generation, states[state.process] === state else { return }
            state.firstDirty = nil
            submitUpdate(state)
        }
    }

    /// Coordinator-only. The update job takes the dirty set when it runs, so a coalesced
    /// (dropped) pending ticket loses nothing.
    private func submitUpdate(_ state: ScanState) {
        enqueue(pid: state.process.pid, priority: .update, cancelled: {}) { [self] in
            let (dirty, query): (Set<ElementKey>, Bool) = coordinator.sync {
                defer { state.dirty.removeAll(); state.needsFocusQuery = false }
                return (state.dirty, state.needsFocusQuery)
            }
            let epoch = currentEpoch()
            var updated: [WindowRecord] = []
            var removed: [WindowIdentity] = []
            var rescan = false
            let deadline = ProcessInfo.processInfo.systemUptime + 0.5
            for key in dirty {
                guard let pair = state.lock.withLock({ state.targets[key].flatMap { t in state.records[t.id].map { (t, $0) } } }) else { continue }
                let (target, old) = pair
                var value: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(key.element, kAXRoleAttribute as CFString, &value)
                if status == .invalidUIElement { removed.append(target.id); continue }
                let rect = Self.frame(key.element, deadline: deadline) ?? old.frame
                let title = Self.attribute(key.element, kAXTitleAttribute, deadline: deadline) as? String ?? old.title
                let minimized = Self.attribute(key.element, kAXMinimizedAttribute, deadline: deadline) as? Bool ?? old.isMinimized
                let record = WindowRecord(id: old.id, appIdentifier: old.appIdentifier, appName: old.appName, title: title,
                                          frame: rect, isMinimized: minimized, documentKey: old.documentKey)
                if record != old { updated.append(record) }
            }
            var focusedID: WindowIdentity?
            if query, let element = Self.element(Self.attribute(state.app, kAXFocusedWindowAttribute, deadline: deadline)) {
                if let target = state.target(ElementKey(element: element)) { focusedID = target.id }
                else { rescan = true }
            }
            state.lock.withLock {
                for record in updated where state.records[record.id] != nil { state.records[record.id] = record }
                for id in removed {
                    state.records.removeValue(forKey: id)
                    if let key = state.targets.first(where: { $0.value.id == id })?.key {
                        state.targets.removeValue(forKey: key); state.registered.remove(key)
                    }
                }
            }
            let events: [WindowEvent] = (removed.isEmpty ? [] : [.removed(removed)])
                + (updated.isEmpty ? [] : [.updated(updated)])
                + (focusedID.map { [.focused($0, epoch: epoch)] } ?? [])
                + (rescan ? [.needsRescan] : [])
            coordinator.async { [self] in
                for event in events { emit(event) }
            }
        }
    }

    /// One focused-window read for a process in the update lane (never behind a full scan).
    func queryFocus(_ process: ProcessIdentity) {
        coordinator.async { [self] in
            guard let state = states[process] else { emit(.needsRescan); return }
            state.needsFocusQuery = true
            scheduleFlush(state, delay: 0)
        }
    }

    /// Reads the frontmost app's focused, main and first standard windows now, decides which one a ⌃⌥ arrangement acts
    /// on (`FrontWindowResolution`), and maps it to its registry identity, adopting a window no scan has seen yet.
    func resolveFront(_ descriptor: AppDescriptor, isFinder: Bool, completion: @escaping @Sendable (FrontResolution) -> Void) {
        coordinator.async { [self] in
            let state: ScanState
            if let existing = states[descriptor.process] { state = existing } else {
                state = ScanState(process: descriptor.process)
                states[descriptor.process] = state
            }
            enqueue(pid: descriptor.process.pid, priority: .interactive, lane: Self.resolveLane,
                    cancelled: { completion(FrontResolution(decision: .fail(.unresponsive), path: "cancelled")) }) { [self] in
                completion(resolveFront(descriptor, state: state, isFinder: isFinder))
            }
        }
    }

    private func resolveFront(_ descriptor: AppDescriptor, state: ScanState, isFinder: Bool) -> FrontResolution {
        typealias Candidate = FrontWindowResolution.Candidate
        let app = state.app
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        func settable(_ element: AXUIElement, _ name: String) -> Bool {
            var value = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(element, name as CFString, &value) == .success && value.boolValue
        }
        /// The candidate and the element to arrange (the parent window for a sheet or attached dialog).
        func describe(_ element: AXUIElement, _ source: Candidate.Source) -> (Candidate, AXUIElement) {
            AXUIElementSetMessagingTimeout(element, 0.12)
            let role = Self.attribute(element, kAXRoleAttribute, deadline: deadline) as? String
            let subrole = Self.attribute(element, kAXSubroleAttribute, deadline: deadline) as? String
            var arranged = element
            var parent: AXUIElement?
            if role == "AXSheet" || subrole == kAXDialogSubrole as String || subrole == kAXSystemDialogSubrole as String {
                var cursor = Self.element(Self.attribute(element, kAXParentAttribute, deadline: deadline))
                for _ in 0..<4 {
                    guard let current = cursor else { break }
                    if Self.attribute(current, kAXRoleAttribute, deadline: deadline) as? String == kAXWindowRole as String { parent = current; break }
                    cursor = Self.element(Self.attribute(current, kAXParentAttribute, deadline: deadline))
                }
                if let parent { arranged = parent }
            }
            let candidate = Candidate(source: source, role: role, subrole: subrole,
                                      fullScreen: Self.attribute(arranged, "AXFullScreen", deadline: deadline) as? Bool ?? false,
                                      minimized: Self.attribute(arranged, kAXMinimizedAttribute, deadline: deadline) as? Bool ?? false,
                                      sizeSettable: settable(arranged, kAXSizeAttribute), positionSettable: settable(arranged, kAXPositionAttribute),
                                      hasParentWindow: parent != nil)
            return (candidate, arranged)
        }
        var described: [Candidate.Source: (Candidate, AXUIElement)] = [:]
        var path: [String] = []
        var focusedValue: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedValue)
        path.append("focused=\(focusedError.rawValue)")
        if let focused = Self.element(focusedValue) { described[.focused] = describe(focused, .focused) }
        if described[.focused] == nil, let main = Self.element(Self.attribute(app, kAXMainWindowAttribute, deadline: deadline)) {
            described[.main] = describe(main, .main); path.append("main")
        }
        if described[.focused] == nil && described[.main] == nil, !isFinder,
           let windows = Self.attribute(app, kAXWindowsAttribute, deadline: deadline) as? [AXUIElement] {
            for window in windows.prefix(32) {
                let (candidate, element) = describe(window, .firstStandard)
                if candidate.subrole == kAXStandardWindowSubrole as String && !candidate.minimized {
                    described[.firstStandard] = (candidate, element); path.append("firstStandard"); break
                }
            }
        }
        if described.isEmpty, focusedError == .cannotComplete {
            return FrontResolution(decision: .fail(.unresponsive), path: path.joined(separator: ","))
        }
        let decision = FrontWindowResolution.decide(accessibilityTrusted: true, frontmostIsPaneflo: false, frontmostIsFinder: isFinder,
                                                    candidates: described.values.map(\.0))
        var result = FrontResolution(decision: decision, path: path.joined(separator: ","))
        guard case .arrange(let source, _, _) = decision, let element = described[source]?.1 else { return result }
        let key = ElementKey(element: element)
        if let target = state.target(key), let record = state.lock.withLock({ state.records[target.id] }) {
            result.target = target; result.record = record
            return result
        }
        // Not seen by a scan yet (just opened, or its app was never scanned): adopt it now.
        guard let frame = Self.frame(element, deadline: deadline) else {
            result.decision = .fail(.unresponsive); return result
        }
        let number = numberLock.withLock { nextNumber &+= 1; return nextNumber }
        let id = WindowIdentity(process: descriptor.process, number: number, incarnation: 1)
        let target = AXWindowTarget(element: element, app: app, id: id, captureNumber: AXWindowNumber.number(for: element))
        let title = Self.attribute(element, kAXTitleAttribute, deadline: deadline) as? String ?? "Untitled window"
        let record = WindowRecord(id: id, appIdentifier: descriptor.identifier, appName: descriptor.name, title: title, frame: frame,
                                  isMinimized: false)
        let observer = ensureObserver(state: state, pid: descriptor.process.pid)
        let registered = observer.map { register($0, element: element) } ?? false
        state.lock.withLock {
            state.targets[key] = target
            state.records[id] = record
            if registered { state.registered.insert(key) }
        }
        result.target = target; result.record = record; result.adopted = true
        return result
    }

    /// Refresh one window's record after Paneflo changed it (placement, minimize).
    fileprivate func markDirty(_ target: AXWindowTarget) {
        coordinator.async { [self] in
            guard let state = states[target.id.process], state.target(ElementKey(element: target.element)) != nil else { return }
            state.dirty.insert(ElementKey(element: target.element))
            scheduleFlush(state, delay: 0.05)
        }
    }

    // MARK: Interactive actions

    /// Raise order: unminimize, application focused window, window main, raise; `raised` then
    /// lets the caller activate the app so its previous main window never surfaces first.
    /// Verification follows on the same worker.
    func focus(_ target: AXWindowTarget, intent: UInt64, raised: @escaping @Sendable () -> Void,
               completion: @escaping @Sendable (Bool) -> Void) {
        submit(pid: target.id.process.pid, priority: .interactive, cancelled: { completion(false) }) { [self] in
            guard isCurrent(intent), Self.valid(target) else { completion(false); return }
            if Self.attribute(target.element, kAXMinimizedAttribute) as? Bool == true {
                guard isCurrent(intent) else { completion(false); return }
                let result = AXUIElementSetAttributeValue(target.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                RuntimeDiagnostics.mark("AX focus stage=unminimize result=\(result.rawValue)")
            }
            guard isCurrent(intent) else { completion(false); return }
            let appResult = AXUIElementSetAttributeValue(target.app, kAXFocusedWindowAttribute as CFString, target.element)
            RuntimeDiagnostics.mark("AX focus stage=application-focused result=\(appResult.rawValue)")
            guard isCurrent(intent) else { completion(false); return }
            let mainResult = AXUIElementSetAttributeValue(target.element, kAXMainAttribute as CFString, kCFBooleanTrue)
            RuntimeDiagnostics.mark("AX focus stage=window-main result=\(mainResult.rawValue)")
            guard isCurrent(intent) else { completion(false); return }
            let raisedResult = AXUIElementPerformAction(target.element, kAXRaiseAction as CFString)
            RuntimeDiagnostics.mark("AX focus stage=raise result=\(raisedResult.rawValue)")
            raised()
            // Raise support is not focus proof. Always verify the exact requested AX element,
            // including apps which focus successfully while rejecting a redundant Raise.
            let deadline = ProcessInfo.processInfo.systemUptime + 0.45
            for attempt in 1...5 {
                guard isCurrent(intent), ProcessInfo.processInfo.systemUptime < deadline else { completion(false); return }
                var focused: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(target.app, kAXFocusedWindowAttribute as CFString, &focused)
                let matches = result == .success && focused.map { CFEqual($0, target.element) } == true
                RuntimeDiagnostics.mark("AX focus attempt=\(attempt) result=\(result.rawValue) targetMatched=\(matches ? 1 : 0)")
                if matches { completion(true); return }
                if attempt < 5 { Thread.sleep(forTimeInterval: 0.035) }
            }
            completion(false)
        }
    }

    /// A tile partner's raise: its app's focused window, main and raise, then `activate` (the caller activates the
    /// app on the main thread) and a wait of at most `PairActivation.raiseDeadline` until the app reports itself
    /// frontmost. `completion(true)` once it does. Stops as soon as a focus request newer than `allowedEpoch` exists.
    func raise(_ target: AXWindowTarget, allowedEpoch: UInt64, activate: @escaping @Sendable () -> Void,
               completion: @escaping @Sendable (Bool) -> Void) {
        submit(pid: target.id.process.pid, priority: .interactive, lane: Self.raiseLane, cancelled: { completion(false) }) { [self] in
            guard currentEpoch() <= allowedEpoch, Self.valid(target) else { completion(false); return }
            let deadline = ProcessInfo.processInfo.systemUptime + PairActivation.raiseDeadline
            AXUIElementSetAttributeValue(target.app, kAXFocusedWindowAttribute as CFString, target.element)
            AXUIElementSetAttributeValue(target.element, kAXMainAttribute as CFString, kCFBooleanTrue)
            guard currentEpoch() <= allowedEpoch else { completion(false); return }
            let result = AXUIElementPerformAction(target.element, kAXRaiseAction as CFString)
            RuntimeDiagnostics.mark("AX pair stage=raise result=\(result.rawValue)")
            activate()
            while currentEpoch() <= allowedEpoch, ProcessInfo.processInfo.systemUptime < deadline {
                if Self.attribute(target.app, kAXFrontmostAttribute) as? Bool == true { completion(true); return }
                Thread.sleep(forTimeInterval: 0.004)
            }
            completion(false)
        }
    }

    /// Rectangle-style size, position, size: the first size write lets a window that is larger than
    /// the destination fit, the position write moves it, and the last size write corrects any size
    /// the move changed. One readback follows for undo bookkeeping and failure reporting. Only when
    /// the application reports a size different from the request (its own minimum or maximum) does
    /// it confirm once more and settle the window inside the zone.
    func place(_ target: AXWindowTarget, request: PlacementRequest, token: UInt64,
               completion: @escaping @Sendable (PlacementReport) -> Void) {
        let id = target.id
        submit(pid: id.process.pid, priority: .interactive, lane: Self.placementLane,
               cancelled: { completion(PlacementReport(message: "Layout superseded before execution.")) }) { [self] in
            guard isCurrentPlacement(token, for: id), Self.valid(target), let initial = Self.frame(target.element) else {
                completion(PlacementReport(message: "The window is no longer available.")); return
            }
            let requested: WindowRect
            let bounds: WindowRect?
            var display: Int?
            var before = initial
            if case .tile = request {
                // A native full-screen window lives in its own Space and refuses geometry writes.
                if Self.attribute(target.element, "AXFullScreen") as? Bool == true {
                    completion(PlacementReport(before: before, message: "Exit full screen to tile this window.")); return
                }
                // A minimized window is restored first, so the tile (and any pair it completes) is visible.
                if Self.attribute(target.element, kAXMinimizedAttribute) as? Bool == true {
                    AXUIElementSetAttributeValue(target.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    let deadline = ProcessInfo.processInfo.systemUptime + 0.6
                    while Self.attribute(target.element, kAXMinimizedAttribute) as? Bool == true,
                          ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
                    guard Self.attribute(target.element, kAXMinimizedAttribute) as? Bool != true else {
                        completion(PlacementReport(before: before, message: "This window is minimized and could not be restored.")); return
                    }
                    if let restored = Self.frame(target.element) { before = restored }
                }
            }
            switch request {
            case let .tile(zone, displays, explicitDisplay, gap):
                // The display comes from the window's frame as read now, not from the last scan.
                guard let plan = DisplayPlacement.planTile(zone: zone, window: before, displays: displays,
                                                           explicitDisplay: explicitDisplay, gap: gap) else {
                    completion(PlacementReport(before: before, message: "The layout does not fit this display.")); return
                }
                requested = plan.rect
                bounds = displays[plan.displayIndex].visibleFrame
                display = plan.displayIndex
            case let .restore(frame, displays):
                guard let restored = DisplayPlacement.restoredFrame(frame, displays: displays) else {
                    completion(PlacementReport(before: before, message: "The saved position is no longer available.")); return
                }
                requested = restored
                bounds = nil
            }
            guard isCurrentPlacement(token, for: id) else { completion(PlacementReport(before: before, message: "Layout superseded.")); return }
            var failures: [AXError] = []
            func write(_ name: String, _ rect: WindowRect, position: Bool) {
                var point = CGPoint(x: rect.x, y: rect.y)
                var size = CGSize(width: rect.width, height: rect.height)
                let value = position ? AXValueCreate(.cgPoint, &point) : AXValueCreate(.cgSize, &size)
                guard let value else { return }
                let error = AXUIElementSetAttributeValue(target.element, name as CFString, value)
                if error != .success { failures.append(error) }
            }
            write(kAXSizeAttribute, requested, position: false)
            write(kAXPositionAttribute, requested, position: true)
            write(kAXSizeAttribute, requested, position: false)
            guard var actual = Self.frame(target.element) else {
                completion(PlacementReport(before: before, after: requested,
                                           message: "Layout sent. The application did not report its new geometry.", display: display,
                                           requested: requested)); return
            }
            RuntimeDiagnostics.mark("AX placement requested=\(Self.geometryText(requested)) before=\(Self.geometryText(before)) actual=\(Self.geometryText(actual))")
            var note = "Layout applied. Undo is available."
            if let bounds, !Self.sameSize(actual, requested) {
                // The application keeps its own size limits. Confirm once, then place the size it
                // accepts at the requested origin, centered inside the zone when it is smaller.
                Thread.sleep(forTimeInterval: 0.02)
                if let again = Self.frame(target.element) { actual = again }
                if !Self.sameSize(actual, requested) {
                    let settled = DisplayPlacement.settledFrame(requested: requested, accepted: actual.size, within: bounds)
                    if abs(settled.x - actual.x) > 1 || abs(settled.y - actual.y) > 1 {
                        guard isCurrentPlacement(token, for: id) else { completion(PlacementReport(before: before, after: actual, message: "Layout superseded.")); return }
                        write(kAXPositionAttribute, settled, position: true)
                        actual = WindowRect(x: settled.x, y: settled.y, width: actual.width, height: actual.height)
                    }
                    note = "This window limits its own size, so it was placed at the size it allows. Undo is available."
                }
            }
            if actual.isClose(to: before, tolerance: 0.5), !failures.isEmpty {
                let reason: String
                switch failures.last! {
                case .apiDisabled: reason = "Accessibility access is disabled."
                case .cannotComplete: reason = "The application did not complete a geometry write."
                case .attributeUnsupported, .notImplemented: reason = "This window does not support moving and resizing."
                case .invalidUIElement: reason = "The window closed during placement."
                default: reason = "The application rejected the layout."
                }
                completion(PlacementReport(before: before, message: reason)); return
            }
            completion(PlacementReport(before: before, after: actual,
                                       message: failures.isEmpty ? note : "The application accepted part of the layout. Undo is available.",
                                       display: display, requested: requested))
        }
    }

    /// Presses the window's close button, as a click would; the app may still ask to save first.
    func close(_ target: AXWindowTarget, completion: @escaping @Sendable (Bool) -> Void) {
        submit(pid: target.id.process.pid, priority: .interactive, cancelled: { completion(false) }) {
            guard Self.valid(target), let button = Self.element(Self.attribute(target.element, kAXCloseButtonAttribute)) else {
                completion(false); return
            }
            completion(AXUIElementPerformAction(button, kAXPressAction as CFString) == .success)
        }
    }

    func setMinimized(_ target: AXWindowTarget, value: Bool, completion: @escaping @Sendable () -> Void) {
        submit(pid: target.id.process.pid, priority: .interactive, cancelled: completion) {
            if Self.valid(target) { AXUIElementSetAttributeValue(target.element, kAXMinimizedAttribute as CFString, value ? kCFBooleanTrue : kCFBooleanFalse) }
            completion()
        }
    }

    private static func geometryText(_ rect: WindowRect) -> String {
        "x:\(rect.x),y:\(rect.y),w:\(rect.width),h:\(rect.height)"
    }

    private static func sameSize(_ actual: WindowRect, _ requested: WindowRect) -> Bool {
        abs(actual.width - requested.width) < 2 && abs(actual.height - requested.height) < 2
    }

    private static func valid(_ target: AXWindowTarget) -> Bool {
        var pid: pid_t = 0
        return AXUIElementGetPid(target.element, &pid) == .success && pid == target.id.process.pid
    }

    private static func attribute(_ element: AXUIElement, _ name: String, deadline: TimeInterval = .infinity) -> CFTypeRef? {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func frame(_ element: AXUIElement, deadline: TimeInterval = .infinity) -> WindowRect? {
        guard let p = attribute(element, kAXPositionAttribute, deadline: deadline), let s = attribute(element, kAXSizeAttribute, deadline: deadline), CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return WindowRect(x: point.x, y: point.y, width: size.width, height: size.height)
    }
}

/// Opening a tile pair: raise the partner, then focus the chosen window.
extension WindowService: PairActivationExecutor {}
