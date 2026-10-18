import AppKit
import ApplicationServices
import PanefloCore

/// Tiling latency bench. Drives the real `WindowService` against PanefloFixture windows only:
/// discovery is restricted to the fixture's PID, no event tap is installed and no input is posted.
/// Run the binary directly from a terminal that holds Accessibility access:
///
///   tile-bench <PanefloFixture.app> [--runs N] [--min-width W] [--max-width W]
///   tile-bench <PanefloFixture.app> --pair [--same-app] [--runs N]
///
/// `--pair` launches three single-window fixture instances (pair left, pair right, cover), tiles the pair into
/// the primary display's halves, covers it with the third window and measures opening the pair from a
/// simulated release (the same `PairActivator` path the switcher commit uses):
///   releaseToPairVisible   release until both pair windows are above the cover, the target's app is frontmost
///                          and the target is its app's focused window
///   releaseToPartnerRaised release until the partner is above the cover
///   releaseToTargetFocused release until the target app is frontmost with the target focused
///   plain focus (no partner) is measured alongside as the baseline. `--same-app` puts both pair windows in one
///   fixture instance.
///
/// Metrics (milliseconds, own-process windows):
///   tileToFinalFrame      tile request until the window's AX frame reaches and keeps its final value
///   tileCompletion        tile request until the service reports completion
///   releaseToFocus        immediate "release" after a tile request until the tiled window is the
///                         application's focused window (pending tile, same process)
/// Build with BENCH_LEGACY_GATE to emulate the pre-change SelectionCommitGate wiring.
@main
struct TileBench {
    @MainActor static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let path = arguments.first, !path.hasPrefix("--") else {
            print("Usage: tile-bench <PanefloFixture.app> [--runs N] [--min-width W] [--max-width W]")
            exit(2)
        }
        var runs = 10
        var minWidth: Int?
        var maxWidth: Int?
        let pairMode = arguments.contains("--pair")
        let sameApp = arguments.contains("--same-app")
        let options = arguments.filter { $0 != "--pair" && $0 != "--same-app" }
        var index = 1
        while index + 1 < options.count {
            switch options[index] {
            case "--runs": runs = Int(options[index + 1]) ?? runs
            case "--min-width": minWidth = Int(options[index + 1])
            case "--max-width": maxWidth = Int(options[index + 1])
            default: break
            }
            index += 2
        }
        guard AXIsProcessTrusted() else { print("Accessibility is not granted to this process."); exit(3) }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        Task { @MainActor in
            let code = pairMode ? await PairBench(path: path, runs: runs, sameApp: sameApp).run()
                : await Bench(path: path, runs: runs, minWidth: minWidth, maxWidth: maxWidth).run()
            exit(code)
        }
        application.run()
    }
}

// MARK: - Accessibility helpers (bench side, independent of the service under test)

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

private func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}

private func axSet(_ element: AXUIElement, _ rect: CGRect) {
    var size = rect.size, point = rect.origin
    if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s) }
    if let p = AXValueCreate(.cgPoint, &point) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p) }
    if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s) }
}

private func now() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }

private struct Sample { let time: Double; let frame: CGRect; let focused: Bool }

/// Polls one window's frame and whether it is the application's focused window.
private final class Poller: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var samples: [Sample] = []
    init(app: AXUIElement, window: AXUIElement) {
        let thread = Thread { [self] in
            while lock.withLock({ running }) {
                let frame = axFrame(window) ?? .zero
                let focused = attribute(app, kAXFocusedWindowAttribute).map { CFEqual($0, window) } ?? false
                let sample = Sample(time: now(), frame: frame, focused: focused)
                lock.withLock { samples.append(sample) }
                Thread.sleep(forTimeInterval: 0.0005)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }
    func stop() -> [Sample] { lock.withLock { running = false; return samples } }
}

private func close(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 2) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
        && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}

/// Independent expectation for a half-screen tile of a window starting at `window`
/// (Accessibility coordinates): the screen with the largest overlap, its visible frame, 8 pt gap.
private func expectedRect(_ zone: LayoutZone, window: CGRect) -> CGRect? {
    let screens = NSScreen.screens
    guard let primary = screens.first else { return nil }
    let height = primary.frame.height
    func ax(_ r: NSRect) -> WindowRect {
        DisplayCoordinates.accessibilityFrame(fromAppKit: WindowRect(x: r.minX, y: r.minY, width: r.width, height: r.height), primaryHeight: height)
    }
    let win = WindowRect(x: window.minX, y: window.minY, width: window.width, height: window.height)
    func overlap(_ r: WindowRect) -> Double {
        max(0, min(r.maxX, win.maxX) - max(r.x, win.x)) * max(0, min(r.maxY, win.maxY) - max(r.y, win.y))
    }
    guard let screen = screens.max(by: { overlap(ax($0.frame)) < overlap(ax($1.frame)) }),
          let rect = LayoutEngine.plan(zone: zone, in: ax(screen.visibleFrame), gap: 8, backingScale: screen.backingScaleFactor,
                                       currentSize: win.size).rect else { return nil }
    return CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
}

#if BENCH_LEGACY_GATE
@MainActor private final class GateBox { var gate = SelectionCommitGate() }
#endif

@MainActor
private final class Bench {
    let path: String, runs: Int, minWidth: Int?, maxWidth: Int?
    let service = WindowService()
    init(path: String, runs: Int, minWidth: Int?, maxWidth: Int?) {
        self.path = path; self.runs = runs; self.minWidth = minWidth; self.maxWidth = maxWidth
    }

    func sleep(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }

    func run() async -> Int32 {
        let previous = NSWorkspace.shared.frontmostApplication
        let configuration = NSWorkspace.OpenConfiguration()
        var arguments = ["--count", "2", "--label", "TileBench"]
        if let minWidth { arguments += ["--min-width", "\(minWidth)"] }
        if let maxWidth { arguments += ["--max-width", "\(maxWidth)"] }
        configuration.arguments = arguments
        configuration.createsNewApplicationInstance = true
        let fixture: NSRunningApplication
        do { fixture = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration) }
        catch { print("Could not launch the fixture: \(error)"); return 4 }
        defer {
            fixture.terminate()
            if let previous, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous.activate(options: []) }
        }
        let pid = fixture.processIdentifier
        service.nativeCheckProcessFilter = { $0 == pid }
        service.start()
        var records: [WindowRecord] = []
        for _ in 0..<100 {
            await sleep(100)
            records = service.snapshot.records.filter { $0.id.process.pid == pid }
            if records.count >= 2 { break }
            service.refresh()
        }
        guard let one = records.first(where: { $0.title.hasSuffix("One") }),
              let two = records.first(where: { $0.title.hasSuffix("Two") }) else {
            print("Fixture windows were not discovered."); return 5
        }
        let app = AXUIElementCreateApplication(pid)
        guard let elements = attribute(app, kAXWindowsAttribute) as? [AXUIElement],
              let elementA = elements.first(where: { (attribute($0, kAXTitleAttribute) as? String)?.hasSuffix("One") == true }),
              let elementB = elements.first(where: { (attribute($0, kAXTitleAttribute) as? String)?.hasSuffix("Two") == true }) else {
            print("Fixture AX windows not found."); return 5
        }
        let visible: WindowRect = NSScreen.screens.first.map { screen in
            DisplayCoordinates.accessibilityFrame(
                fromAppKit: WindowRect(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY, width: screen.visibleFrame.width, height: screen.visibleFrame.height),
                primaryHeight: screen.frame.height)
        } ?? WindowRect(x: 0, y: 0, width: 1200, height: 800)
        let startA = CGRect(x: visible.x + 60, y: visible.y + 80, width: 460, height: 300)
        let startB = CGRect(x: visible.x + 140, y: visible.y + 140, width: 460, height: 300)

        func reset() async {
            axSet(elementA, startA); axSet(elementB, startB)
            service.focus(one.id)
            await sleep(450)
        }

        var tileFinal: [Double] = [], tileCallback: [Double] = [], releaseFocus: [Double] = []
        var orderingFailures = 0, frameFailures = 0
        // Warm-up pass so first-use costs are not part of the samples.
        await reset()
        service.tile(two.id, zone: .leftHalf)
        await sleep(600)

        for run in 0..<runs {
            // 1. tile request until final frame
            await reset()
            let poller = Poller(app: app, window: elementB)
            await sleep(30)
            var callback: Double?
            let t0 = now()
            service.tile(two.id, zone: .rightHalf) { _ in callback = now() }
            await sleep(900)
            let series = poller.stop()
            if let last = series.last?.frame {
                var index = series.count - 1
                while index > 0, close(series[index - 1].frame, last, 1) { index -= 1 }
                tileFinal.append(series[index].time - t0)
                tileCallback.append((callback ?? .nan) - t0)
                let expected = expectedRect(.rightHalf, window: startB)
                if let expected, !close(last, expected, 3) && minWidth == nil && maxWidth == nil {
                    frameFailures += 1
                    if run == 0 { print("unexpected frame \(last) expected \(expected)") }
                }
            }

            // 2. tile, then release immediately: focus the tiled window while its tile is pending
            await reset()
            let focusPoller = Poller(app: app, window: elementB)
            await sleep(30)
            let tStart = now()
            #if BENCH_LEGACY_GATE
            let box = GateBox()
            let generation = box.gate.beginPlacement()
            service.tile(two.id, zone: .leftHalf) { [service] _ in
                if let focus = box.gate.finishPlacement(generation) { service.focus(focus) }
            }
            let tRelease = now()
            if let focus = box.gate.commit(two.id) { service.focus(focus) }
            #else
            service.tile(two.id, zone: .leftHalf)
            let tRelease = now()
            service.focus(two.id)
            #endif
            await sleep(1100)
            let focusSeries = focusPoller.stop()
            if let first = focusSeries.first(where: { $0.time >= tStart && $0.focused }) {
                releaseFocus.append(first.time - tRelease)
            }
            let tail = focusSeries.last
            let expected = expectedRect(.leftHalf, window: startB)
            let endFrameOK = tail.map { sample in expected.map { close(sample.frame, $0, 3) } ?? false } ?? false
            if tail?.focused != true || (!endFrameOK && minWidth == nil && maxWidth == nil) { orderingFailures += 1 }
            if minWidth != nil || maxWidth != nil, run == 0, let tail { print("limited-size frame: \(tail.frame), visible: \(visible)") }
        }

        func summary(_ name: String, _ values: [Double]) {
            let sorted = values.filter { !$0.isNaN }.sorted()
            guard !sorted.isEmpty else { print("\(name): no samples"); return }
            func p(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count) * q).rounded(.up)) - 1 < 0 ? 0 : Int((Double(sorted.count) * q).rounded(.up)) - 1)] }
            print(String(format: "%@ n=%d median=%.1f p90=%.1f min=%.1f max=%.1f", name, sorted.count, p(0.5), p(0.9), sorted.first!, sorted.last!))
        }
        #if BENCH_LEGACY_GATE
        print("variant: legacy gate")
        #else
        print("variant: decoupled focus")
        #endif
        summary("tileToFinalFrame ms", tileFinal)
        summary("tileCompletion ms", tileCallback)
        summary("releaseToFocus ms", releaseFocus)
        print("endStateFailures (final frame or focus wrong): ordering=\(orderingFailures) tileFrame=\(frameFailures)")
        return 0
    }
}

// MARK: - Pair opening

private struct PairSample { let time: Double; let partnerAbove: Bool; let targetAbove: Bool; let targetFront: Bool; let partnerFront: Bool }

/// Polls window-server stacking for the three fixture windows and the target app's frontmost and focused state.
private final class PairPoller: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var samples: [PairSample] = []
    init(partner: UInt32, target: UInt32, cover: UInt32, targetApp: AXUIElement, targetWindow: AXUIElement, partnerApp: AXUIElement) {
        let thread = Thread { [self] in
            while lock.withLock({ running }) {
                let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                let order = list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
                func index(_ n: UInt32) -> Int { order.firstIndex(of: n) ?? Int.max }
                let coverIndex = index(cover)
                let front = attribute(targetApp, kAXFrontmostAttribute) as? Bool ?? false
                let focused = attribute(targetApp, kAXFocusedWindowAttribute).map { CFEqual($0, targetWindow) } ?? false
                let sample = PairSample(time: now(), partnerAbove: index(partner) < coverIndex, targetAbove: index(target) < coverIndex,
                                        targetFront: front && focused, partnerFront: attribute(partnerApp, kAXFrontmostAttribute) as? Bool ?? false)
                lock.withLock { samples.append(sample) }
                Thread.sleep(forTimeInterval: 0.0005)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }
    func stop() -> [PairSample] { lock.withLock { running = false; return samples } }
}

@MainActor
private final class PairBench {
    let path: String, runs: Int
    let service = WindowService()
    let verbose = CommandLine.arguments.contains("--diagnostics")
    let sameApp: Bool
    init(path: String, runs: Int, sameApp: Bool) { self.path = path; self.runs = runs; self.sameApp = sameApp }

    func sleep(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }

    func launch(_ label: String, count: Int = 1) async -> NSRunningApplication? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--count", "\(count)", "--label", label]
        configuration.createsNewApplicationInstance = true
        return try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration)
    }

    func run() async -> Int32 {
        let previous = NSWorkspace.shared.frontmostApplication
        let both = sameApp ? await launch("PairBoth", count: 2) : nil
        guard let left = sameApp ? both : await launch("PairLeft"), let right = sameApp ? both : await launch("PairRight"),
              let cover = await launch("PairCover") else {
            print("Could not launch the fixtures."); return 4
        }
        let apps = sameApp ? [left, cover] : [left, right, cover]
        defer {
            for app in apps { app.terminate() }
            if let previous, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous.activate(options: []) }
        }
        let pids = Set(apps.map(\.processIdentifier))
        service.nativeCheckProcessFilter = { pids.contains($0) }
        service.start()
        var records: [WindowRecord] = []
        for _ in 0..<100 {
            await sleep(100)
            records = service.snapshot.records.filter { pids.contains($0.id.process.pid) }
            if records.count >= 3 && Set(records.map(\.id.process.pid)).count == apps.count { break }
            service.refresh()
        }
        func record(_ app: NSRunningApplication, _ suffix: String) -> WindowRecord? {
            records.first { $0.id.process.pid == app.processIdentifier && (!sameApp || app == cover || $0.title.hasSuffix(suffix)) }
        }
        guard let partnerRecord = record(left, "One"), let targetRecord = record(right, "Two"), let coverRecord = record(cover, "") else {
            print("Fixture windows were not discovered."); return 5
        }
        func element(_ app: NSRunningApplication, _ suffix: String) -> (AXUIElement, AXUIElement)? {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            let windows = attribute(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []
            let window = sameApp && app != cover
                ? windows.first { (attribute($0, kAXTitleAttribute) as? String)?.hasSuffix(suffix) == true } : windows.first
            return window.map { (ax, $0) }
        }
        guard let (partnerApp, partnerWindow) = element(left, "One"), let (targetApp, targetWindow) = element(right, "Two"),
              let (_, coverWindow) = element(cover, ""),
              let display = WindowService.displayAreas().first,
              let leftHalf = LayoutEngine.plan(zone: .leftHalf, in: display.visibleFrame, gap: 8, backingScale: display.backingScale).rect,
              let rightHalf = LayoutEngine.plan(zone: .rightHalf, in: display.visibleFrame, gap: 8, backingScale: display.backingScale).rect else {
            print("Fixture AX windows or display not found."); return 5
        }
        func cg(_ r: WindowRect) -> CGRect { CGRect(x: r.x, y: r.y, width: r.width, height: r.height) }
        axSet(partnerWindow, cg(leftHalf)); axSet(targetWindow, cg(rightHalf)); axSet(coverWindow, cg(display.visibleFrame))
        await sleep(600)
        service.refresh()
        await sleep(400)
        // Detection from real Accessibility frames, the way the app reconciles snapshots.
        var groups = TileGroupRegistry()
        groups.reconcile(records: service.snapshot.orderedRecords, displays: WindowService.displayAreas(),
                         now: ProcessInfo.processInfo.systemUptime)
        let detected = groups.partner(of: targetRecord.id) == partnerRecord.id
        print("pairDetectedFromFrames=\(detected) groups=\(groups.groups.count)")
        guard let partnerNumber = service.captureWindowNumber(for: partnerRecord.id),
              let targetNumber = service.captureWindowNumber(for: targetRecord.id),
              let coverNumber = service.captureWindowNumber(for: coverRecord.id) else {
            print("Window numbers unavailable."); return 5
        }

        var pairVisible: [Double] = [], partnerRaised: [Double] = [], targetFocused: [Double] = [], plainFocus: [Double] = []
        var orderViolations = 0, pairFailures = 0, plainPartnerVisible = 0
        func coverPair() async {
            service.focus(coverRecord.id)
            await sleep(500)
        }
        // Warm-up.
        await coverPair()
        PairActivator.open(targetRecord.id, partner: partnerRecord.id, executor: service) { delay, block in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { block() } }
        }
        await sleep(600)

        for _ in 0..<runs {
            await coverPair()
            let poller = PairPoller(partner: partnerNumber, target: targetNumber, cover: coverNumber, targetApp: targetApp, targetWindow: targetWindow, partnerApp: partnerApp)
            await sleep(30)
            let t0 = now()
            PairActivator.open(targetRecord.id, partner: partnerRecord.id, executor: service) { delay, block in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { block() } }
            }
            await sleep(900)
            let series = poller.stop().filter { $0.time >= t0 }
            let raised = series.first { $0.partnerAbove }
            let focused = series.first { $0.targetFront && $0.targetAbove }
            if let both = series.first(where: { $0.partnerAbove && $0.targetAbove && $0.targetFront }) { pairVisible.append(both.time - t0) }
            if let raised { partnerRaised.append(raised.time - t0) }
            if let focused { targetFocused.append(focused.time - t0) }
            if let raised, let focused, raised.time > focused.time { orderViolations += 1 }
            if let last = series.last, !(last.partnerAbove && last.targetAbove && last.targetFront) { pairFailures += 1 }
            if verbose {
                let pf = series.first { $0.partnerFront }.map { $0.time - t0 } ?? .nan
                print(String(format: "run partnerFront=%.1f partnerAbove=%.1f targetFront=%.1f end partnerAbove=%d", pf,
                             (raised?.time ?? .nan) - t0, (focused?.time ?? .nan) - t0, series.last?.partnerAbove == true ? 1 : 0))
            }

            // Baseline: plain focus of the same window, no partner.
            await coverPair()
            let plain = PairPoller(partner: partnerNumber, target: targetNumber, cover: coverNumber, targetApp: targetApp, targetWindow: targetWindow, partnerApp: partnerApp)
            await sleep(30)
            let p0 = now()
            service.focus(targetRecord.id)
            await sleep(900)
            let plainSeries = plain.stop().filter { $0.time >= p0 }
            if let focused = plainSeries.first(where: { $0.targetFront && $0.targetAbove }) { plainFocus.append(focused.time - p0) }
            if plainSeries.last?.partnerAbove == true { plainPartnerVisible += 1 }
        }

        func summary(_ name: String, _ values: [Double]) {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { print("\(name): no samples"); return }
            func p(_ q: Double) -> Double { sorted[max(0, min(sorted.count - 1, Int((Double(sorted.count) * q).rounded(.up)) - 1))] }
            print(String(format: "%@ n=%d median=%.1f p90=%.1f min=%.1f max=%.1f", name, sorted.count, p(0.5), p(0.9), sorted.first!, sorted.last!))
        }
        print("variant: pair open (partner raise, then focus); \(sameApp ? "same app" : "two apps"); runs=\(runs)")
        summary("releaseToPairVisible ms", pairVisible)
        summary("releaseToPartnerRaised ms", partnerRaised)
        summary("releaseToTargetFocused ms", targetFocused)
        summary("plainFocus releaseToTargetFocused ms", plainFocus)
        print("pairEndStateFailures=\(pairFailures) partnerRaisedAfterFocus=\(orderViolations) plainFocusLeftPartnerVisible=\(plainPartnerVisible)")
        return 0
    }
}
