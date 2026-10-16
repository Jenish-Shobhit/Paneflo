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

    func start() {
        guard workspaceObservers.isEmpty else { refresh(); return }
        worker.onEvent = { [weak self] in Task { @MainActor in self?.scheduleRefresh() } }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
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

    func captureWindowNumber(for id: WindowIdentity) -> UInt32? { targets[id]?.captureNumber }

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
        for process in Set(snapshot.records.map { $0.id.process }) where !live.contains(process) { registry.processEnded(process) }
        targets = targets.filter { live.contains($0.key.process) }
        scanInFlight = true
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        worker.discover(apps: apps, frontPID: frontPID) { [weak self] result in
            Task { @MainActor in self?.apply(result) }
        }
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func apply(_ result: DiscoveryResult) {
        let current = Set(result.records.map(\.id))
        for record in snapshot.records where result.completed.contains(record.id.process) && !current.contains(record.id) {
            registry.remove(record.id)
            targets.removeValue(forKey: record.id)
        }
        for record in result.records { registry.upsert(record) }
        targets.merge(result.targets) { _, new in new }
        if let focus = result.focus, NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.process.pid { focusedID = focus; registry.commitFocus(focus) }
        snapshot = registry.snapshot
        scanInFlight = false
        onChange?()
        if needsRescan { needsRescan = false; scheduleRefresh() }
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
                self.onStatus?(success ? "Window activated." : "The application could not focus that window.")
                self.scheduleRefresh()
            }
        }
    }

    func tile(_ id: WindowIdentity? = nil, zone: LayoutZone, screenIndex: Int? = nil, gap: Double = 8) {
        if id == nil, focusedID?.process.pid != NSWorkspace.shared.frontmostApplication?.processIdentifier {
            onStatus?("The frontmost window changed. Try again after its focus is confirmed.")
            scheduleRefresh(); return
        }
        guard hasAccessibility, let id = id ?? focusedID, validLifetime(id), let record = snapshot.records.first(where: { $0.id == id }), let target = targets[id] else {
            onStatus?("Select a window before arranging it."); return
        }
        let screens = NSScreen.screens
        guard let primary = screens.first else { return }
        let usable: [(NSScreen, WindowRect)] = screens.map { screen in
            let f = screen.visibleFrame
            return (screen, DisplayCoordinates.accessibilityFrame(fromAppKit: WindowRect(x: f.minX, y: f.minY, width: f.width, height: f.height), primaryHeight: primary.frame.height))
        }
        let chosen: (NSScreen, WindowRect)
        if let screenIndex, usable.indices.contains(screenIndex) { chosen = usable[screenIndex] }
        else { chosen = usable.max(by: { Self.intersection($0.1, record.frame) < Self.intersection($1.1, record.frame) })! }
        guard let proposed = LayoutEngine.plan(zone: zone, in: chosen.1, gap: gap, backingScale: chosen.0.backingScaleFactor, currentSize: record.frame.size).rect else {
            onStatus?("The layout does not fit this display."); return
        }
        let intent = worker.beginIntent()
        worker.place(target, frame: proposed, intent: intent) { [weak self] actual, before, message in
            Task { @MainActor in
                guard let self else { return }
                if let actual, let before { self.undoHistory.record([GeometryChange(id: id, before: before, after: actual)]) }
                self.onStatus?(message); self.scheduleRefresh()
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
    private let scanQueue = DispatchQueue(label: "dev.paneflo.discovery", qos: .utility)
    private let actionQueue = DispatchQueue(label: "dev.paneflo.actions", qos: .userInitiated)
    private var previous: [ProcessIdentity: [AXWindowTarget]] = [:]
    private var previousRecords: [WindowIdentity: WindowRecord] = [:]
    private var nextNumber: UInt32 = 0
    private var observers: [pid_t: AXObserver] = [:]
    private let intentLock = NSLock()
    private var latestIntent: UInt64 = 0
    var onEvent: (@Sendable () -> Void)?

    func beginIntent() -> UInt64 { intentLock.withLock { latestIntent += 1; return latestIntent } }
    private func isCurrent(_ intent: UInt64) -> Bool { intentLock.withLock { latestIntent == intent } }

    func discover(apps: [AppDescriptor], frontPID: pid_t?, completion: @escaping @Sendable (DiscoveryResult) -> Void) {
        scanQueue.async { [self] in
            var result = DiscoveryResult(records: [], targets: [:], completed: [], focus: nil)
            let cgWindows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let livePIDs = Set(apps.map { $0.process.pid })
            for (pid, observer) in observers where !livePIDs.contains(pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                observers.removeValue(forKey: pid)
            }
            previous = previous.filter { key, _ in apps.contains { $0.process == key } }
            for descriptor in apps {
                let app = AXUIElementCreateApplication(descriptor.process.pid)
                AXUIElementSetMessagingTimeout(app, 0.2)
                guard let elements = Self.attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { continue }
                result.completed.insert(descriptor.process)
                let observer = ensureObserver(pid: descriptor.process.pid, app: app)
                let focused = Self.attribute(app, kAXFocusedWindowAttribute)
                var current: [AXWindowTarget] = []
                for element in elements.prefix(256) {
                    AXUIElementSetMessagingTimeout(element, 0.2)
                    guard let rect = Self.frame(element) else {
                        // An AX timeout is not a close; retain the previous identity and metadata.
                        if let old = previous[descriptor.process]?.first(where: { CFEqual($0.element, element) }), let record = previousRecords[old.id] {
                            current.append(old); result.targets[old.id] = old; result.records.append(record)
                        }
                        continue
                    }
                    guard rect.width >= 40, rect.height >= 30 else { continue }
                    let role = Self.attribute(element, kAXRoleAttribute) as? String
                    if role == nil {
                        if let old = previous[descriptor.process]?.first(where: { CFEqual($0.element, element) }), let record = previousRecords[old.id] {
                            current.append(old); result.targets[old.id] = old; result.records.append(record)
                        }
                        continue
                    }
                    guard role == kAXWindowRole else { continue }
                    let subrole = Self.attribute(element, kAXSubroleAttribute) as? String
                    guard subrole != kAXSystemDialogSubrole else { continue }
                    let oldRecord = previous[descriptor.process]?.first(where: { CFEqual($0.element, element) }).flatMap { previousRecords[$0.id] }
                    let title = Self.attribute(element, kAXTitleAttribute) as? String ?? oldRecord?.title ?? "Untitled window"
                    let id: WindowIdentity
                    if let old = previous[descriptor.process]?.first(where: { CFEqual($0.element, element) }) { id = old.id }
                    else {
                        nextNumber &+= 1
                        id = WindowIdentity(process: descriptor.process, number: nextNumber, incarnation: 1)
                    }
                    let capture = Self.captureNumber(pid: descriptor.process.pid, rect: rect, title: title, windows: cgWindows)
                    let target = AXWindowTarget(element: element, app: app, id: id, captureNumber: capture)
                    current.append(target); result.targets[id] = target
                    result.records.append(WindowRecord(id: id, appIdentifier: descriptor.identifier, appName: descriptor.name, title: title, frame: rect, isMinimized: Self.attribute(element, kAXMinimizedAttribute) as? Bool ?? oldRecord?.isMinimized ?? false))
                    if descriptor.process.pid == frontPID, let focused, CFEqual(focused, element) { result.focus = id }
                    if let observer {
                        for name in [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification] {
                            AXObserverAddNotification(observer, element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
                        }
                    }
                }
                previous[descriptor.process] = current
            }
            let surviving = Set(previous.values.flatMap { $0.map(\.id) })
            previousRecords = previousRecords.filter { surviving.contains($0.key) }
            for record in result.records { previousRecords[record.id] = record }
            completion(result)
        }
    }

    private func ensureObserver(pid: pid_t, app: AXUIElement) -> AXObserver? {
        if let observer = observers[pid] { return observer }
        var created: AXObserver?
        let status = AXObserverCreate(pid, { _, _, _, context in
            guard let context else { return }
            Unmanaged<WindowWorker>.fromOpaque(context).takeUnretainedValue().onEvent?()
        }, &created)
        guard status == .success, let observer = created else { return nil }
        observers[pid] = observer
        for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        return observer
    }

    func focus(_ target: AXWindowTarget, intent: UInt64, completion: @escaping @Sendable (Bool) -> Void) {
        actionQueue.async { [self] in
            guard isCurrent(intent), Self.valid(target) else { completion(false); return }
            if Self.attribute(target.element, kAXMinimizedAttribute) as? Bool == true {
                guard isCurrent(intent) else { completion(false); return }
                AXUIElementSetAttributeValue(target.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            guard isCurrent(intent) else { completion(false); return }
            AXUIElementSetAttributeValue(target.app, kAXFocusedWindowAttribute as CFString, target.element)
            guard isCurrent(intent) else { completion(false); return }
            AXUIElementSetAttributeValue(target.element, kAXMainAttribute as CFString, kCFBooleanTrue)
            guard isCurrent(intent) else { completion(false); return }
            let raised = AXUIElementPerformAction(target.element, kAXRaiseAction as CFString)
            guard raised == .success, isCurrent(intent) else { completion(false); return }
            // A successful Raise is not itself proof that the requested window is focused.
            for attempt in 0..<3 {
                guard isCurrent(intent) else { completion(false); return }
                if let focused = Self.attribute(target.app, kAXFocusedWindowAttribute), CFEqual(focused, target.element) { completion(true); return }
                if attempt < 2 { Thread.sleep(forTimeInterval: 0.04) }
            }
            completion(false)
        }
    }

    func place(_ target: AXWindowTarget, frame: WindowRect, intent: UInt64, completion: @escaping @Sendable (WindowRect?, WindowRect?, String) -> Void) {
        actionQueue.async { [self] in
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
            for pass in 0..<2 {
                // Move before expanding so the existing screen edge cannot clamp the new size.
                // Reapply position after resizing; some applications anchor or adjust it.
                for (stage, name, value) in [("position-before", kAXPositionAttribute, p), ("size", kAXSizeAttribute, s), ("position-after", kAXPositionAttribute, p)] {
                    guard isCurrent(intent) else { completion(Self.frame(target.element), before, "Layout superseded."); return }
                    let error = AXUIElementSetAttributeValue(target.element, name as CFString, value)
                    RuntimeDiagnostics.mark("AX placement pass=\(pass) stage=\(stage) result=\(error.rawValue)")
                    if error != .success { failures.append(error) }
                }
                actual = Self.frame(target.element)
                if let actual, Self.sameFrame(actual, frame) {
                    completion(actual, before, "Layout applied. Undo is available."); return
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
        actionQueue.async {
            if Self.valid(target) { AXUIElementSetAttributeValue(target.element, kAXMinimizedAttribute as CFString, value ? kCFBooleanTrue : kCFBooleanFalse) }
            completion()
        }
    }

    private static func sameFrame(_ actual: WindowRect, _ requested: WindowRect) -> Bool {
        abs(actual.x - requested.x) < 2 && abs(actual.y - requested.y) < 2 && abs(actual.width - requested.width) < 2 && abs(actual.height - requested.height) < 2
    }

    private static func valid(_ target: AXWindowTarget) -> Bool {
        var pid: pid_t = 0
        return AXUIElementGetPid(target.element, &pid) == .success && pid == target.id.process.pid
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func frame(_ element: AXUIElement) -> WindowRect? {
        guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute), CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
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
