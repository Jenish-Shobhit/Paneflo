import AppKit
import PanefloCore

/// Drag-to-edge snapping: drag a window by its title bar to an outer screen edge or corner, see where it will land,
/// release to tile it there (Settings › Tiling › Snap windows by dragging to screen edges).
///
/// Input is a listen-only global mouse monitor for the left button (press, drag, release); it never blocks, delays
/// or changes an event, and it only sees events bound for other apps, so Paneflo's own windows never snap. The drag
/// path does arithmetic only: the window under the press is found once from the window list (no Accessibility call),
/// and its frame is read a few times on a background queue only until it is clear the window moves (origin changed,
/// size unchanged) or not (a resize, a selection, a file drag). The decisions are `SnapDragTracker`'s. The monitor
/// exists only while the setting is on and Accessibility is granted; the preview panel exists from the first window drag.
@MainActor
final class DragSnapService {
    private let service: WindowService
    private weak var desktop: DesktopController?
    private let preview = SnapPreviewPanel()
    private var tracker = SnapDragTracker()
    private var monitor: Any?
    private var releaseCheck: Timer?
    /// Samples the pressed window on time while it has not been seen moving (`SnapDragTracker.nextSampleAt`).
    private var sampleTimer: Timer?
    private var sampleDue: Double?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    /// Displays in `WindowService.displayAreas()` order, and the primary display's height; nil after a display change.
    private var displayCache: (areas: [DisplayArea], primaryHeight: Double)?
    private var wanted = SurfacePreferences(defaults: .standard).dragToSnap
    private var accessibility = false
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let queue = DispatchQueue(label: "dev.paneflo.drag-snap", qos: .userInteractive)

    var isMonitoring: Bool { monitor != nil }

    init(service: WindowService, desktop: DesktopController) {
        self.service = service
        self.desktop = desktop
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let wanted = SurfacePreferences(defaults: .standard).dragToSnap
                guard wanted != self.wanted else { return }
                self.wanted = wanted
                self.updateMonitor()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displayCache = nil
                self?.cancel()
            }
        })
        // Lock, display or system sleep and a session switch end the drag: the release that follows is not seen (the
        // release check would infer it after unlock and snap a window the user no longer meant to move).
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            })
        }
        distributedObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        })
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        if let monitor { NSEvent.removeMonitor(monitor) }
        releaseCheck?.invalidate()
        sampleTimer?.invalidate()
    }

    /// The latest Accessibility reading (from the app's permission reconcile, never from the input path).
    func update(accessibility: Bool) {
        guard accessibility != self.accessibility else { return }
        self.accessibility = accessibility
        updateMonitor()
    }

    func stop() {
        wanted = false
        updateMonitor()
    }

    /// A tile landed (any tiling path): remember the window's frame from before, for a restore when it is dragged away.
    func noteTiled(_ id: WindowIdentity, before: WindowRect, after: WindowRect) {
        guard let number = service.windowNumber(for: id) else { return }
        tracker.book.noteTiled(number, before: before, after: after)
    }

    private func updateMonitor() {
        let active = wanted && accessibility && !RuntimeDiagnostics.benchNoInput
        if active, monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                // Global monitors run on the main thread; the event is only read. Its own location (screen
                // coordinates, as it has no window) is where the button went down or the drag was, even when the
                // monitor runs late and the cursor has moved on (a quick flick): `NSEvent.mouseLocation` would be
                // the cursor now, and a press read there can miss the title bar and ignore the whole drag.
                let type = event.type
                let location = event.locationInWindow
                MainActor.assumeIsolated { self?.handle(type, at: location) }
            }
            RuntimeDiagnostics.mark("dragSnap monitor=on")
        } else if !active, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            cancel()
            RuntimeDiagnostics.mark("dragSnap monitor=off wanted=\(wanted) accessibility=\(accessibility)")
        }
    }

    // MARK: Input (main thread, arithmetic only)

    private func handle(_ type: NSEvent.EventType, at location: NSPoint) {
        let displays = currentDisplays()
        let point = SnapPoint(x: location.x, y: displays.primaryHeight - location.y)
        if desktop?.isVisible == true { cancel(); return }
        switch type {
        case .leftMouseDown: apply(tracker.mouseDown(at: point, displays: displays.areas))
        case .leftMouseDragged: apply(tracker.mouseDragged(to: point, now: ProcessInfo.processInfo.systemUptime))
        case .leftMouseUp: apply(tracker.mouseUp())
        default: break
        }
    }

    private func cancel() {
        apply(tracker.cancel())
        preview.hide()
        stopReleaseCheck()
    }

    private func currentDisplays() -> (areas: [DisplayArea], primaryHeight: Double) {
        if let displayCache { return displayCache }
        let cache = (WindowService.displayAreas(), Double(NSScreen.screens.first?.frame.height ?? 0))
        displayCache = cache
        return cache
    }

    private func apply(_ effects: [SnapDragTracker.Effect]) {
        for effect in effects {
            switch effect {
            case let .resolveWindow(point, press): resolveWindow(at: point, press: press)
            case let .sampleFrame(number, press): sampleFrame(of: number, press: press)
            case let .restore(number, frame): restore(number, to: frame)
            case let .showPreview(target): showPreview(target)
            case .hidePreview: preview.hide(); stopReleaseCheck()
            case let .snap(number, target): snap(number, to: target)
            }
        }
        // A window seen moving may reach an edge next: have the outline ready so arming it only orders it in.
        if case .moving = tracker.phase { preview.prepare() }
        updateSampleTimer()
    }

    /// A flick can park the pointer at an edge before the window was seen to follow, and a parked pointer sends no
    /// drag events: while the decision is open the window is also sampled on time, by one timer set for exactly when
    /// the next check is due (`SnapDragTracker.nextSampleAt`).
    private func updateSampleTimer() {
        guard let due = tracker.nextSampleAt else {
            sampleTimer?.invalidate()
            sampleTimer = nil
            sampleDue = nil
            return
        }
        guard due != sampleDue else { return }
        sampleTimer?.invalidate()
        sampleDue = due
        let timer = Timer(timeInterval: max(0, due - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sampleTimer = nil
                self.sampleDue = nil
                guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
                self.apply(self.tracker.tick(now: ProcessInfo.processInfo.systemUptime))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sampleTimer = timer
    }

    // MARK: Window-server reads (background queue)

    private func resolveWindow(at point: SnapPoint, press: UInt64) {
        let own = ownPID
        queue.async { [weak self] in
            let window = Self.window(at: point, excluding: own)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.apply(self.tracker.windowResolved(window, press: press, now: ProcessInfo.processInfo.systemUptime))
                }
            }
        }
    }

    private func sampleFrame(of number: UInt32, press: UInt64) {
        queue.async { [weak self] in
            let frame = Self.frame(of: number)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.apply(self.tracker.frameSampled(frame, press: press, now: ProcessInfo.processInfo.systemUptime))
                }
            }
        }
    }

    /// The front-most standard (layer 0, visible) window under `point`, from the on-screen window list. Nil when it
    /// is Paneflo's own. Reads numbers, owners and bounds only, never titles. Anything in front of it (a menu, the
    /// Dock) is skipped: such a drag never moves the window, so it is ignored by the movement check.
    nonisolated private static func window(at point: SnapPoint, excluding ownPID: pid_t) -> DragWindow? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let frame = bounds(info), point.x >= frame.x, point.x < frame.maxX, point.y >= frame.y, point.y < frame.maxY
            else { continue }
            guard (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) != ownPID,
                  let number = info[kCGWindowNumber as String] as? Int, number > 0 else { return nil }
            return DragWindow(number: UInt32(number), frame: frame)
        }
        return nil
    }

    nonisolated private static func frame(of number: UInt32) -> WindowRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? Int) == Int(number) }) else { return nil }
        return bounds(info)
    }

    /// Window-server bounds use the same top-left global space as Accessibility.
    nonisolated private static func bounds(_ info: [String: Any]) -> WindowRect? {
        guard let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return nil }
        let frame = WindowRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        return frame.isValid ? frame : nil
    }

    // MARK: Effects

    private func showPreview(_ target: SnapTarget) {
        let displays = currentDisplays().areas
        let window = WindowRect(x: 0, y: 0, width: 1, height: 1) // only `.center` depends on the size; never a snap zone
        guard let plan = DisplayPlacement.planTile(zone: target.zone, window: window, displays: displays,
                                                   explicitDisplay: target.display, cycleDisplays: false) else {
            preview.hide(); return
        }
        preview.show(plan.rect)
        startReleaseCheck()
    }

    /// A release the monitor did not see (it went to Paneflo, or arrived while the monitor was being replaced) must
    /// not leave the preview up: while it shows, the button state is checked a few times a second.
    private func startReleaseCheck() {
        guard releaseCheck == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                RuntimeDiagnostics.mark("dragSnap release inferred")
                self.apply(self.tracker.mouseUp())
                self.preview.hide()
                self.stopReleaseCheck()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseCheck = timer
    }

    private func stopReleaseCheck() {
        releaseCheck?.invalidate()
        releaseCheck = nil
    }

    private func restore(_ number: UInt32, to frame: WindowRect) {
        guard let id = service.identity(forWindowNumber: number) else { return }
        RuntimeDiagnostics.mark("dragSnap restore size")
        service.place(id, frame: frame, recordsUndo: false)
    }

    /// Tiles the dropped window. One that is not in the registry yet is taken from the frontmost app, and only when it
    /// is the same window (the click that started the drag usually made it frontmost).
    private func snap(_ number: UInt32, to target: SnapTarget) {
        guard desktop?.isVisible != true else { return }
        if let id = service.identity(forWindowNumber: number) {
            desktop?.snapDraggedWindow(id, zone: target.zone, display: target.display)
            return
        }
        service.resolveFrontmostWindow { [weak self] resolved in
            guard let self, case let .window(id, _) = resolved, self.service.windowNumber(for: id) == number else {
                RuntimeDiagnostics.mark("dragSnap skipped reason=unknownWindow")
                return
            }
            self.desktop?.snapDraggedWindow(id, zone: target.zone, display: target.display)
        }
    }
}
