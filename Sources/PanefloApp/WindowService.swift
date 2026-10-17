import AppKit
@preconcurrency import ApplicationServices
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
    let captureNumber: UInt32?

    init(element: AXUIElement, app: AXUIElement, id: WindowIdentity, captureNumber: UInt32?) {
        self.element = element; self.app = app; self.id = id; self.captureNumber = captureNumber
    }
}

private struct DiscoveryResult: Sendable {
    var records: [WindowRecord]
    var targets: [WindowIdentity: AXWindowTarget]
    var completed: Set<ProcessIdentity>
    var focus: WindowIdentity?
}

/// Main-thread state publication; all remote Accessibility IPC is performed by WindowWorker.
@MainActor
final class WindowService {
    private let worker = WindowWorker()
    private var registry = WindowRegistry()
    private var targets: [WindowIdentity: AXWindowTarget] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pendingRefresh: DispatchWorkItem?
    private var scanInFlight = false
    private var needsRescan = false
    private var undoHistory = GeometryUndoHistory()
    private var processTokens: [pid_t: (Date?, UInt64)] = [:]
    private var nextToken: UInt64 = 0
    private(set) var snapshot = WindowSnapshot(records: [])
    private(set) var focusedID: WindowIdentity?
    var onChange: (() -> Void)?
    var onStatus: ((String) -> Void)?
    var hasAccessibility: Bool { AXIsProcessTrusted() }

    #if PANEFLO_NATIVE_CHECK
    func nativeCheckInstall(_ records: [WindowRecord]) {
        snapshot = WindowSnapshot(records: records)
        focusedID = records.first?.id
        onChange?()
    }
    #endif

    func start() {
        guard workspaceObservers.isEmpty else { refresh(); return }
        worker.onEvent = { [weak self] in Task { @MainActor in self?.scheduleRefresh() } }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let endedApp = name == NSWorkspace.didTerminateApplicationNotification
                    ? notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication : nil
                let endedPID = endedApp?.processIdentifier
                let endedLaunch = endedApp?.launchDate
                MainActor.assumeIsolated {
                    if let pid = endedPID, let self, let token = self.processTokens[pid], token.0 == endedLaunch {
                        self.processTokens.removeValue(forKey: pid)
                        let ended = ProcessIdentity(pid: pid, launchToken: token.1)
                        self.registry.processEnded(ended)
                        self.targets = self.targets.filter { $0.key.process != ended }
                        self.snapshot = self.registry.snapshot
                        self.onChange?()
                    }
                    self?.scheduleRefresh()
                }
            })
        }
        refresh()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        onStatus?("Enable Paneflo in Privacy & Security → Accessibility, then click Refresh.")
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }

    func captureWindowNumber(for id: WindowIdentity) -> UInt32? {
        guard let record = snapshot.records.first(where: { $0.id == id }), !record.isMinimized,
              let app = currentApplication(for: id), !app.isHidden else { return nil }
        return targets[id]?.captureNumber
    }

    func refresh() {
        pendingRefresh?.cancel(); pendingRefresh = nil
        guard hasAccessibility else {
            onStatus?("Accessibility access is required to discover and control your windows.")
            onChange?()
            return
        }
        guard !scanInFlight else { needsRescan = true; return }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
        }.map { app -> AppDescriptor in
            let pid = app.processIdentifier
            let token: UInt64
            if let current = processTokens[pid], current.0 == app.launchDate { token = current.1 }
            else { nextToken += 1; token = nextToken; processTokens[pid] = (app.launchDate, token) }
            return AppDescriptor(process: ProcessIdentity(pid: pid, launchToken: token), identifier: app.bundleIdentifier ?? "pid.\(pid)", name: app.localizedName ?? "Application")
        }
        let live = Set(apps.map(\.process))
        let livePIDs = Set(apps.map { $0.process.pid })
        processTokens = processTokens.filter { livePIDs.contains($0.key) }
        for process in Set(snapshot.records.map { $0.id.process }) where !live.contains(process) { registry.processEnded(process) }
        targets = targets.filter { live.contains($0.key.process) }
        scanInFlight = true
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        worker.discover(apps: apps, frontPID: frontPID) { [weak self] result, finished in
            Task { @MainActor in self?.apply(result, finished: finished) }
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
        let records = discovered.records.filter { validLifetime($0.id) }
        let admitted = Set(records.map(\.id))
        let result = DiscoveryResult(records: records, targets: discovered.targets.filter { admitted.contains($0.key) },
                                     completed: discovered.completed, focus: discovered.focus)
        let current = Set(result.records.map(\.id))
        for record in snapshot.records where result.completed.contains(record.id.process) && !current.contains(record.id) {
            registry.remove(record.id)
            targets.removeValue(forKey: record.id)
        }
        for record in result.records { registry.upsert(record) }
        targets.merge(result.targets) { _, new in new }
        if let focus = result.focus, NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.process.pid { focusedID = focus; registry.commitFocus(focus) }
        snapshot = registry.snapshot
        onChange?()
        if finished {
            scanInFlight = false
            if needsRescan { needsRescan = false; scheduleRefresh() }
        }
    }

    func focus(_ id: WindowIdentity) {
        guard hasAccessibility, validLifetime(id), let target = targets[id], snapshot.records.contains(where: { $0.id == id }) else {
            onStatus?("That window is no longer available."); return
        }
        let intent = worker.beginIntent()
        // AppKit application activation belongs to the main thread; remote IPC stays off-main.
        guard let app = currentApplication(for: id) else { return }
        if app.isHidden { app.unhide() }
        app.activate(options: [])
        worker.focus(target, intent: intent) { [weak self] success in
            Task { @MainActor in
                guard let self else { return }
                let frontMatches = NSWorkspace.shared.frontmostApplication?.processIdentifier == id.process.pid
                let verified = success && self.validLifetime(id) && frontMatches
                RuntimeDiagnostics.mark("AX focus frontmostVerified=\(verified ? 1 : 0)")
                self.onStatus?(verified ? "Window activated." : "The application could not focus that window.")
                self.scheduleRefresh()
            }
        }
    }

    func tile(_ id: WindowIdentity? = nil, zone: LayoutZone, screenIndex: Int? = nil, gap: Double = 8, completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        if id == nil, focusedID?.process.pid != NSWorkspace.shared.frontmostApplication?.processIdentifier {
            onStatus?("The frontmost window changed. Try again after its focus is confirmed.")
            scheduleRefresh(); completion?(false); return
        }
        guard hasAccessibility, let id = id ?? focusedID, validLifetime(id), let record = snapshot.records.first(where: { $0.id == id }), let target = targets[id] else {
            onStatus?("Select a window before arranging it."); completion?(false); return
        }
        let screens = NSScreen.screens
        guard let primary = screens.first else { completion?(false); return }
        let usable: [(NSScreen, WindowRect)] = screens.map { screen in
            let f = screen.visibleFrame
            return (screen, DisplayCoordinates.accessibilityFrame(fromAppKit: WindowRect(x: f.minX, y: f.minY, width: f.width, height: f.height), primaryHeight: primary.frame.height))
        }
        let chosen: (NSScreen, WindowRect)
        if let screenIndex, usable.indices.contains(screenIndex) { chosen = usable[screenIndex] }
        else { chosen = usable.max(by: { Self.intersection($0.1, record.frame) < Self.intersection($1.1, record.frame) })! }
        guard let proposed = LayoutEngine.plan(zone: zone, in: chosen.1, gap: gap, backingScale: chosen.0.backingScaleFactor, currentSize: record.frame.size).rect else {
            onStatus?("The layout does not fit this display."); completion?(false); return
        }
        let intent = worker.beginIntent()
        worker.place(target, frame: proposed, intent: intent) { [weak self] actual, before, message in
            Task { @MainActor in
                guard let self else { completion?(false); return }
                if let actual, let before { self.undoHistory.record([GeometryChange(id: id, before: before, after: actual)]) }
                self.onStatus?(message); self.scheduleRefresh()
                completion?(actual != nil)
            }
        }
    }

    func undo() {
        guard let plan = undoHistory.undo(surviving: Set(targets.keys.filter { validLifetime($0) })), let change = plan.changes.first, let target = targets[change.id] else {
            onStatus?("Nothing to undo."); return
        }
        let intent = worker.beginIntent()
        worker.place(target, frame: change.before, intent: intent) { [weak self] _, _, message in
            Task { @MainActor in self?.onStatus?(message); self?.scheduleRefresh() }
        }
    }

    func minimize(_ id: WindowIdentity) {
        guard hasAccessibility, validLifetime(id), let target = targets[id] else { return }
        worker.setMinimized(target, value: true) { [weak self] in Task { @MainActor in self?.scheduleRefresh() } }
    }

    private func validLifetime(_ id: WindowIdentity) -> Bool {
        currentApplication(for: id) != nil
    }

    private func currentApplication(for id: WindowIdentity) -> NSRunningApplication? {
        guard let token = processTokens[id.process.pid], token.1 == id.process.launchToken, let expectedDate = token.0,
              let running = NSRunningApplication(processIdentifier: id.process.pid), !running.isTerminated,
              let actualDate = running.launchDate, expectedDate == actualDate else { return nil }
        return running
    }

    private static func intersection(_ a: WindowRect, _ b: WindowRect) -> Double {
        max(0, min(a.maxX, b.maxX) - max(a.x, b.x)) * max(0, min(a.maxY, b.maxY) - max(a.y, b.y))
    }
}

private final class WindowWorker: @unchecked Sendable {
    private final class ScanState: @unchecked Sendable {
        var previous: [AXWindowTarget] = []
        var records: [WindowIdentity: WindowRecord] = [:]
        var observer: AXObserver?
        var cursor = 0
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
        let windows: [[String: Any]]
        init(_ windows: [[String: Any]]) { self.windows = windows }
    }
    private let coordinator = DispatchQueue(label: "dev.paneflo.ax-admission")
    private let metadataQueue = DispatchQueue(label: "dev.paneflo.cg-metadata", qos: .utility)
    private let workers = DispatchQueue(label: "dev.paneflo.ax-workers", qos: .userInitiated, attributes: .concurrent)
    private var admission = AXWorkAdmission()
    private var jobs: [UInt64: Job] = [:]
    private var nextJob: UInt64 = 0
    private var states: [ProcessIdentity: ScanState] = [:]
    private var nextNumber: UInt32 = 0
    private let numberLock = NSLock()
    private let intentLock = NSLock()
    private var latestIntent: UInt64 = 0
    var onEvent: (@Sendable () -> Void)?

    func beginIntent() -> UInt64 { intentLock.withLock { latestIntent += 1; return latestIntent } }
    private func isCurrent(_ intent: UInt64) -> Bool { intentLock.withLock { latestIntent == intent } }

    private func submit(pid: pid_t, priority: AXWorkAdmission.Priority,
                        cancelled: @escaping @Sendable () -> Void,
                        work: @escaping @Sendable () -> Void) {
        coordinator.async { [self] in enqueue(pid: pid, priority: priority, cancelled: cancelled, work: work) }
    }

    /// Coordinator-only. No AX IPC is allowed here, including cancellation callbacks.
    private func enqueue(pid: pid_t, priority: AXWorkAdmission.Priority,
                         cancelled: @escaping @Sendable () -> Void,
                         work: @escaping @Sendable () -> Void) {
        nextJob &+= 1
        let ticket = AXWorkAdmission.Ticket(id: nextJob, pid: pid, priority: priority)
        jobs[ticket.id] = Job(work: work, cancelled: cancelled)
        for id in admission.enqueue(ticket) { jobs.removeValue(forKey: id)?.cancelled() }
        drain()
    }

    private func drain() {
        for ticket in admission.takeReady() {
            guard let job = jobs[ticket.id] else { admission.finish(ticket.id); continue }
            workers.async { [self] in
                job.work()
                coordinator.async { [self] in
                    jobs.removeValue(forKey: ticket.id)
                    admission.finish(ticket.id)
                    drain()
                }
            }
        }
    }

    func discover(apps: [AppDescriptor], frontPID: pid_t?,
                  completion: @escaping @Sendable (DiscoveryResult, Bool) -> Void) {
        metadataQueue.async { [self] in
            let cg = CGSnapshot(CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            coordinator.async { [self] in
                let live = Set(apps.map(\.process))
                for (identity, state) in states where !live.contains(identity) {
                    if let observer = state.observer {
                        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                    }
                    states.removeValue(forKey: identity)
                }
                guard !apps.isEmpty else {
                    completion(DiscoveryResult(records: [], targets: [:], completed: [], focus: nil), true)
                    return
                }
                let batch = Batch(apps.count)
                for descriptor in apps {
                    let state = states[descriptor.process] ?? ScanState()
                    states[descriptor.process] = state
                    enqueue(pid: descriptor.process.pid, priority: .background, cancelled: {
                        // Cancellation executes on the coordinator, never releases an active call.
                        batch.remaining -= 1
                        completion(DiscoveryResult(records: [], targets: [:], completed: [], focus: nil), batch.remaining == 0)
                    }, work: { [self] in
                        let result = scan(descriptor, state: state, frontPID: frontPID, cgWindows: cg)
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

    private func scan(_ descriptor: AppDescriptor, state: ScanState, frontPID: pid_t?, cgWindows: CGSnapshot) -> DiscoveryResult {
        var result = DiscoveryResult(records: [], targets: [:], completed: [], focus: nil)
        let app = AXUIElementCreateApplication(descriptor.process.pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        guard let elements = Self.attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return result }
        result.completed.insert(descriptor.process)
        let observer = ensureObserver(state: state, pid: descriptor.process.pid, app: app)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        let focused = Self.attribute(app, kAXFocusedWindowAttribute, deadline: deadline)
        var current: [AXWindowTarget] = []
        let candidates = Array(elements.prefix(256))
        let start = state.cursor % max(1, candidates.count)
        for offset in candidates.indices {
            let index = (start + offset) % candidates.count
            let element = candidates[index]
            if ProcessInfo.processInfo.systemUptime >= deadline {
                if let old = state.previous.first(where: { CFEqual($0.element, element) }), let record = state.records[old.id] {
                    current.append(old); result.targets[old.id] = old; result.records.append(record)
                    if descriptor.process.pid == frontPID, let focused, CFEqual(focused, element) { result.focus = old.id }
                }
                continue
            }
            state.cursor = (index + 1) % candidates.count
            AXUIElementSetMessagingTimeout(element, 0.12)
            guard let rect = Self.frame(element, deadline: deadline) else {
                // An AX timeout is not a close; retain the previous identity and metadata.
                if let old = state.previous.first(where: { CFEqual($0.element, element) }), let record = state.records[old.id] {
                    current.append(old); result.targets[old.id] = old; result.records.append(record)
                }
                continue
            }
            guard rect.width >= 40, rect.height >= 30 else { continue }
            let role = Self.attribute(element, kAXRoleAttribute, deadline: deadline) as? String
            if role == nil {
                if let old = state.previous.first(where: { CFEqual($0.element, element) }), let record = state.records[old.id] {
                    current.append(old); result.targets[old.id] = old; result.records.append(record)
                }
                continue
            }
            guard role == kAXWindowRole else { continue }
            let subrole = Self.attribute(element, kAXSubroleAttribute, deadline: deadline) as? String
            guard subrole != kAXSystemDialogSubrole else { continue }
            let oldRecord = state.previous.first(where: { CFEqual($0.element, element) }).flatMap { state.records[$0.id] }
            let title = Self.attribute(element, kAXTitleAttribute, deadline: deadline) as? String ?? oldRecord?.title ?? "Untitled window"
            let id: WindowIdentity
            if let old = state.previous.first(where: { CFEqual($0.element, element) }) { id = old.id }
            else {
                let number = numberLock.withLock { nextNumber &+= 1; return nextNumber }
                id = WindowIdentity(process: descriptor.process, number: number, incarnation: 1)
            }
            let capture = Self.captureNumber(pid: descriptor.process.pid, rect: rect, title: title, windows: cgWindows.windows)
            let target = AXWindowTarget(element: element, app: app, id: id, captureNumber: capture)
            current.append(target); result.targets[id] = target
            result.records.append(WindowRecord(id: id, appIdentifier: descriptor.identifier, appName: descriptor.name, title: title, frame: rect, isMinimized: Self.attribute(element, kAXMinimizedAttribute, deadline: deadline) as? Bool ?? oldRecord?.isMinimized ?? false))
            if descriptor.process.pid == frontPID, let focused, CFEqual(focused, element) { result.focus = id }
            if let observer {
                for name in [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification] {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                    AXObserverAddNotification(observer, element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
                }
            }
        }
        state.previous = current
        state.records = Dictionary(uniqueKeysWithValues: result.records.map { ($0.id, $0) })
        return result
    }


    private func ensureObserver(state: ScanState, pid: pid_t, app: AXUIElement) -> AXObserver? {
        if let observer = state.observer { return observer }
        var created: AXObserver?
        let status = AXObserverCreate(pid, { _, _, _, context in
            guard let context else { return }
            Unmanaged<WindowWorker>.fromOpaque(context).takeUnretainedValue().onEvent?()
        }, &created)
        guard status == .success, let observer = created else { return nil }
        state.observer = observer
        for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        return observer
    }

    func focus(_ target: AXWindowTarget, intent: UInt64, completion: @escaping @Sendable (Bool) -> Void) {
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
            let raised = AXUIElementPerformAction(target.element, kAXRaiseAction as CFString)
            RuntimeDiagnostics.mark("AX focus stage=raise result=\(raised.rawValue)")
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

    func place(_ target: AXWindowTarget, frame: WindowRect, intent: UInt64, completion: @escaping @Sendable (WindowRect?, WindowRect?, String) -> Void) {
        submit(pid: target.id.process.pid, priority: .interactive, cancelled: { completion(nil, nil, "Layout superseded before execution.") }) { [self] in
            guard isCurrent(intent), Self.valid(target), let before = Self.frame(target.element) else {
                completion(nil, nil, "The window is no longer available."); return
            }
            var sizeSettable: DarwinBoolean = false
            var positionSettable: DarwinBoolean = false
            let sizeCapability = AXUIElementIsAttributeSettable(target.element, kAXSizeAttribute as CFString, &sizeSettable)
            let positionCapability = AXUIElementIsAttributeSettable(target.element, kAXPositionAttribute as CFString, &positionSettable)
            RuntimeDiagnostics.mark("AX placement capabilities size=\(sizeCapability.rawValue) position=\(positionCapability.rawValue)")
            guard sizeCapability == .success, positionCapability == .success else {
                completion(nil, before, "The application did not report its movement capabilities. Try again."); return
            }
            guard sizeSettable.boolValue, positionSettable.boolValue else { completion(nil, before, "This window does not support moving and resizing."); return }
            var position = CGPoint(x: frame.x, y: frame.y)
            var size = CGSize(width: frame.width, height: frame.height)
            guard let p = AXValueCreate(.cgPoint, &position), let s = AXValueCreate(.cgSize, &size) else { completion(nil, before, "Invalid window geometry."); return }
            var failures: [AXError] = []
            var actual: WindowRect?
            let deadline = ProcessInfo.processInfo.systemUptime + 1.5
            let shrinking = frame.width <= before.width && frame.height <= before.height
            let stages = shrinking
                ? [("size-before", kAXSizeAttribute, s), ("position", kAXPositionAttribute, p), ("size-after", kAXSizeAttribute, s)]
                : [("position-before", kAXPositionAttribute, p), ("size", kAXSizeAttribute, s), ("position-after", kAXPositionAttribute, p)]
            RuntimeDiagnostics.mark("AX placement strategy=\(shrinking ? "shrink-SPS" : "expand-PSP") requested=\(Self.geometryText(frame)) before=\(Self.geometryText(before))")
            for pass in 0..<2 {
                if ProcessInfo.processInfo.systemUptime >= deadline { break }
                // Shrink before moving to avoid temporarily extending an oversized frame offscreen.
                // Expand after moving, then correct position. Both sequences settle between writes.
                for (stage, name, value) in stages {
                    guard isCurrent(intent) else { completion(Self.frame(target.element), before, "Layout superseded."); return }
                    if ProcessInfo.processInfo.systemUptime >= deadline { break }
                    let error = AXUIElementSetAttributeValue(target.element, name as CFString, value)
                    if error != .success { failures.append(error) }
                    // AppKit may acknowledge an AX write before its queued frame mutation settles.
                    // A property match during animation is insufficient: the entire frame must
                    // remain stable across three readbacks before the next geometry write.
                    var matches = 0
                    var readback: WindowRect?
                    var previousReadback: WindowRect?
                    for _ in 0..<6 {
                        guard isCurrent(intent) else { completion(Self.frame(target.element), before, "Layout superseded."); return }
                        if ProcessInfo.processInfo.systemUptime >= deadline { break }
                        Thread.sleep(forTimeInterval: 0.035)
                        readback = Self.frame(target.element, deadline: deadline)
                        let propertyMatches = readback.map { value in
                            name == kAXSizeAttribute
                                ? abs(value.width - frame.width) < 2 && abs(value.height - frame.height) < 2
                                : abs(value.x - frame.x) < 2 && abs(value.y - frame.y) < 2
                        } ?? false
                        let stable = readback.flatMap { current in previousReadback.map { Self.sameFrame(current, $0) } } ?? false
                        matches = propertyMatches ? (stable ? matches + 1 : 1) : 0
                        previousReadback = readback
                        if matches >= 3 { break }
                    }
                    RuntimeDiagnostics.mark("AX placement pass=\(pass) stage=\(stage) result=\(error.rawValue) requested=\(Self.geometryText(frame)) actual=\(readback.map(Self.geometryText) ?? "unavailable")")
                    if ProcessInfo.processInfo.systemUptime >= deadline { break }
                }
                var confirmed = 0
                for _ in 0..<4 {
                    guard isCurrent(intent) else { completion(Self.frame(target.element), before, "Layout superseded."); return }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                    actual = Self.frame(target.element, deadline: deadline)
                    confirmed = actual.map { Self.sameFrame($0, frame) } == true ? confirmed + 1 : 0
                    if confirmed >= 3, let actual {
                        RuntimeDiagnostics.mark("AX placement stable-target actual=\(Self.geometryText(actual))")
                        completion(actual, before, "Layout applied. Undo is available."); return
                    }
                    Thread.sleep(forTimeInterval: 0.035)
                }
                if pass == 0 { Thread.sleep(forTimeInterval: 0.025) }
            }
            guard let actual else { completion(nil, before, "The application did not report its new geometry."); return }
            if let error = failures.last {
                let reason: String
                switch error {
                case .apiDisabled: reason = "Accessibility access is disabled."
                case .cannotComplete: reason = "The application did not complete a geometry write."
                case .attributeUnsupported, .notImplemented: reason = "The application does not support that geometry change."
                case .invalidUIElement: reason = "The window closed during placement."
                default: reason = "The application rejected part of the layout."
                }
                completion(actual, before, reason + " Partial placement can be undone.")
            } else {
                completion(actual, before, "The application accepted different geometry after correction. Undo is available.")
            }
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

    private static func sameFrame(_ actual: WindowRect, _ requested: WindowRect) -> Bool {
        abs(actual.x - requested.x) < 2 && abs(actual.y - requested.y) < 2 && abs(actual.width - requested.width) < 2 && abs(actual.height - requested.height) < 2
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

    private static func frame(_ element: AXUIElement, deadline: TimeInterval = .infinity) -> WindowRect? {
        guard let p = attribute(element, kAXPositionAttribute, deadline: deadline), let s = attribute(element, kAXSizeAttribute, deadline: deadline), CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return WindowRect(x: point.x, y: point.y, width: size.width, height: size.height)
    }

    private static func captureNumber(pid: pid_t, rect: WindowRect, title: String, windows: [[String: Any]]) -> UInt32? {
        let matches = windows.filter {
            guard ($0[kCGWindowOwnerPID as String] as? Int32) == pid, ($0[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = $0[kCGWindowBounds as String] as? [String: CGFloat], let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"] else { return false }
            return abs(x - rect.x) < 2 && abs(y - rect.y) < 2 && abs(w - rect.width) < 2 && abs(h - rect.height) < 2
        }
        let named = matches.filter { ($0[kCGWindowName as String] as? String) == title }
        let candidates = named.count == 1 ? named : matches
        guard candidates.count == 1 else { return nil }
        return candidates.first?[kCGWindowNumber as String] as? UInt32
    }
}
