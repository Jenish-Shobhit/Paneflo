import AppKit
import ApplicationServices
import PanefloCore

/// Tiling latency bench. Drives the real `WindowService` against PanefloFixture windows only:
/// discovery is restricted to the fixture's PID, no event tap is installed and no input is posted.
/// Run the binary directly from a terminal that holds Accessibility access:
///
///   tile-bench <PanefloFixture.app> [--runs N] [--min-width W] [--max-width W]
///   tile-bench <PanefloFixture.app> --pair [--same-app] [--runs N]
///   tile-bench <PanefloFixture.app> --replace [--constrained] [--runs N]
///   tile-bench <PanefloFixture.app> --frontmost [--runs N]
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
/// `--replace` launches three single-window fixture instances (A, B, C), pairs A (left) and B (right) through the
/// app's own tiling coordinator (`TilePairController.tile`), then per run: C replaces A (⌘⌥← path), undo, and a swap
/// (A into B's half). Correctness after each step: every window's final AX frame and the registry's pair.
///   replaceToFinalFrame   C's tile request until C's frame is final in the left half
///   replaceToDisplacedHome  request until the displaced A is back at its pre-tile (home) frame
///   swapToBothFinal       swap request until both A (right) and B (left) are final
///   wrongFinalFrames / wrongPairs  end-state failures over all steps
/// `--constrained` gives C a minimum width of 62 % of the display: C keeps it against the left edge and B takes the
/// rest of the display (the pair stays complementary); undo and swap are skipped in that variant.
///
/// `--frontmost` drives the standalone ⌃⌥ path (`TilePairController.tileFrontWindow`, as the shortcut and the menu bar's
/// Tile Front Window do) with the fixture frontmost and focus notifications dropped, so the service's cached focus is
/// deliberately stale: each run focuses the other fixture window (bench-side AX), tiles a half, checks the focused
/// window landed and the other did not move, then undoes (⌃⌥Z path) and checks the window is back. A first "cold" run
/// tiles before any window scan finished (the window is adopted at keypress time).
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
        let replaceMode = arguments.contains("--replace")
        let frontmostMode = arguments.contains("--frontmost")
        let sameApp = arguments.contains("--same-app")
        let constrained = arguments.contains("--constrained")
        let options = arguments.filter { !["--pair", "--same-app", "--replace", "--constrained", "--frontmost"].contains($0) }
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
            #if BENCH_NO_REPLACE
            if replaceMode || frontmostMode { print("--replace and --frontmost need a tree with the pair coordinator."); exit(2) }
            #else
            if replaceMode { exit(await ReplaceBench(path: path, runs: runs, constrained: constrained).run()) }
            if frontmostMode { exit(await FrontmostBench(path: path, runs: runs).run()) }
            #endif
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

// MARK: - Pair replacement
#if !BENCH_NO_REPLACE

/// Polls several windows' frames.
private final class FramePoller: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var samples: [(time: Double, frames: [CGRect])] = []
    init(_ windows: [AXUIElement]) {
        let thread = Thread { [self] in
            while lock.withLock({ running }) {
                let sample = (time: now(), frames: windows.map { axFrame($0) ?? .zero })
                lock.withLock { samples.append(sample) }
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }
    func stop() -> [(time: Double, frames: [CGRect])] { lock.withLock { running = false; return samples } }
}

@MainActor
private final class ReplaceBench {
    let path: String, runs: Int, constrained: Bool
    let service = WindowService()
    let pairs: TilePairController
    let defaults: UserDefaults
    init(path: String, runs: Int, constrained: Bool) {
        self.path = path; self.runs = runs; self.constrained = constrained
        let suite = "org.paneflo.TileBench.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite) ?? .standard
        pairs = TilePairController(defaults: defaults)
    }

    func sleep(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }

    func launch(_ label: String, minWidth: Int? = nil) async -> NSRunningApplication? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--count", "1", "--label", label] + (minWidth.map { ["--min-width", "\($0)"] } ?? [])
        configuration.createsNewApplicationInstance = true
        return try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration)
    }

    /// Tiles through the coordinator and waits for its completion (bounded).
    func tile(_ id: WindowIdentity, _ zone: LayoutZone) async {
        var done = false
        pairs.tile(id, zone: zone, service: service, snapAssist: false) { _, _ in done = true }
        for _ in 0..<100 where !done { await sleep(10) }
    }

    func run() async -> Int32 {
        let previous = NSWorkspace.shared.frontmostApplication
        let minWidth = constrained ? WindowService.displayAreas().first.map { min(4000, max(200, Int($0.visibleFrame.width * 0.62))) } : nil
        guard let appA = await launch("RepA"), let appB = await launch("RepB"), let appC = await launch("RepC", minWidth: minWidth) else {
            print("Could not launch the fixtures."); return 4
        }
        let apps = [appA, appB, appC]
        defer {
            for app in apps { app.terminate() }
            if let previous, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous.activate(options: []) }
        }
        let pids = Set(apps.map(\.processIdentifier))
        service.nativeCheckProcessFilter = { pids.contains($0) }
        service.onChange = { [unowned self] in self.pairs.reconcile(self.service.snapshot, displays: WindowService.displayAreas()) }
        service.start()
        var records: [WindowRecord] = []
        for _ in 0..<100 {
            await sleep(100)
            records = service.snapshot.records.filter { pids.contains($0.id.process.pid) }
            if Set(records.map(\.id.process.pid)).count == 3 { break }
            service.refresh()
        }
        func record(_ app: NSRunningApplication) -> WindowRecord? { records.first { $0.id.process.pid == app.processIdentifier } }
        func element(_ app: NSRunningApplication) -> AXUIElement? {
            (attribute(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement])?.first
        }
        guard let a = record(appA)?.id, let b = record(appB)?.id, let c = record(appC)?.id,
              let ea = element(appA), let eb = element(appB), let ec = element(appC),
              let display = WindowService.displayAreas().first,
              let left = LayoutEngine.plan(zone: .leftHalf, in: display.visibleFrame, gap: 8, backingScale: display.backingScale).rect,
              let right = LayoutEngine.plan(zone: .rightHalf, in: display.visibleFrame, gap: 8, backingScale: display.backingScale).rect else {
            print("Fixture windows or display not found: records \(records.count) pids \(Set(records.map(\.id.process.pid)).count)"
                  + " elements \([appA, appB, appC].map { element($0) != nil })")
            return 5
        }
        let v = display.visibleFrame
        func cg(_ r: WindowRect) -> CGRect { CGRect(x: r.x, y: r.y, width: r.width, height: r.height) }
        let startA = CGRect(x: v.x + 60, y: v.y + 60, width: 520, height: 360)
        let startB = CGRect(x: v.x + 160, y: v.y + 120, width: 520, height: 360)
        let startC = CGRect(x: v.x + 260, y: v.y + 180, width: 520, height: 360)
        let leftRect = cg(left), rightRect = cg(right)

        var replaceFinal: [Double] = [], displacedHome: [Double] = [], swapFinal: [Double] = []
        var wrongFrames = 0, wrongPairs = 0, steps = 0
        func check(_ label: String, _ expected: [(AXUIElement, CGRect)], pair: (WindowIdentity, WindowIdentity)?) {
            steps += 1
            for (index, (window, rect)) in expected.enumerated() {
                let frame = axFrame(window) ?? .zero
                if !close(frame, rect, 3) { wrongFrames += 1; print("\(label): window \(index) at \(frame), expected \(rect)") }
            }
            let ok: Bool
            if let pair { ok = pairs.groups.group(containing: pair.0).map { $0.first == pair.0 && $0.second == pair.1 } ?? false }
            else { ok = true }
            if !ok { wrongPairs += 1; print("\(label): pairs \(pairs.groups.groups.map { ($0.first.number, $0.second.number) })") }
        }
        func settleSnapshot() async { await sleep(350); service.refresh(); await sleep(250) }

        // Warm-up and per-run reset: all three float; A then B tile through the coordinator and pair.
        func reset() async {
            axSet(ea, startA); axSet(eb, startB); axSet(ec, startC)
            await settleSnapshot()
            await tile(a, .leftHalf)
            await tile(b, .rightHalf)
            await settleSnapshot()
        }
        for run in 0...runs {
            await reset()
            if run > 0 { check("pair", [(ea, leftRect), (eb, rightRect)], pair: (a, b)) }
            // 1. C replaces A (left half): C+B pair, A back at its pre-tile frame, B untouched.
            let poller = FramePoller([ec, ea])
            await sleep(20)
            let t0 = now()
            await tile(c, .leftHalf)
            await sleep(700)
            let series = poller.stop()
            if run > 0, minWidth == nil {
                if let i = series.lastIndex(where: { !close($0.frames[0], leftRect, 1) }), i + 1 < series.count { replaceFinal.append(series[i + 1].time - t0) }
                else if close(series.first?.frames[0] ?? .zero, leftRect, 1) { replaceFinal.append(0) }
                if let i = series.lastIndex(where: { !close($0.frames[1], startA, 1) }), i + 1 < series.count { displacedHome.append(series[i + 1].time - t0) }
            }
            await settleSnapshot()
            if let minWidth {
                // C keeps its minimum width against the left edge; B takes exactly the rest.
                let cRect = CGRect(x: leftRect.minX, y: leftRect.minY, width: CGFloat(minWidth), height: leftRect.height)
                let bRect = CGRect(x: cRect.maxX + 8, y: rightRect.minY, width: rightRect.maxX - cRect.maxX - 8, height: rightRect.height)
                if run > 0 { check("replace constrained", [(ec, cRect), (ea, startA), (eb, bRect)], pair: (c, b)) }
                continue
            }
            if run > 0 { check("replace", [(ec, leftRect), (ea, startA), (eb, rightRect)], pair: (c, b)) }
            // 2. Undo C: C back to its start, A back to the left half, A+B re-formed.
            pairs.undo(preferring: c, service: service)
            await sleep(500)
            await settleSnapshot()
            if run > 0 { check("undo", [(ec, startC), (ea, leftRect), (eb, rightRect)], pair: (a, b)) }
            // 3. Swap: A into B's half; B takes A's.
            let swapPoller = FramePoller([ea, eb])
            await sleep(20)
            let s0 = now()
            await tile(a, .rightHalf)
            await sleep(700)
            let swapSeries = swapPoller.stop()
            if run > 0, let i = swapSeries.lastIndex(where: { !close($0.frames[0], rightRect, 1) || !close($0.frames[1], leftRect, 1) }),
               i + 1 < swapSeries.count { swapFinal.append(swapSeries[i + 1].time - s0) }
            await settleSnapshot()
            if run > 0 { check("swap", [(ea, rightRect), (eb, leftRect)], pair: (b, a)) }
        }
        func summary(_ name: String, _ values: [Double]) {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { print("\(name): no samples"); return }
            func p(_ q: Double) -> Double { sorted[max(0, min(sorted.count - 1, Int((Double(sorted.count) * q).rounded(.up)) - 1))] }
            print(String(format: "%@ n=%d median=%.1f p90=%.1f min=%.1f max=%.1f", name, sorted.count, p(0.5), p(0.9), sorted.first!, sorted.last!))
        }
        print("variant: pair replacement via TilePairController; three fixture apps\(constrained ? "; C min width \(minWidth ?? 0)" : ""); runs=\(runs)")
        summary("replaceToFinalFrame ms", replaceFinal)
        summary("replaceToDisplacedHome ms", displacedHome)
        summary("swapToBothFinal ms", swapFinal)
        print("checkedSteps=\(steps) wrongFinalFrames=\(wrongFrames) wrongPairs=\(wrongPairs)")
        return wrongFrames == 0 && wrongPairs == 0 ? 0 : 1
    }
}

// MARK: - Standalone (⌃⌥) path with a stale cached focus

@MainActor
private final class FrontmostBench {
    let path: String, runs: Int
    let service = WindowService()
    let pairs: TilePairController
    init(path: String, runs: Int) {
        self.path = path; self.runs = runs
        pairs = TilePairController(defaults: UserDefaults(suiteName: "org.paneflo.TileBench.front.\(UUID().uuidString)") ?? .standard)
    }

    func sleep(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }

    /// Runs the standalone tile and waits for its completion; returns the failure reason, if any.
    func tileFront(_ zone: LayoutZone) async -> String? {
        var done = false, failure: String?
        pairs.tileFrontWindow(zone, service: service, failed: { failure = $0.message; done = true }, completion: { _ in done = true })
        for _ in 0..<150 where !done { await sleep(10) }
        return done ? failure : "timeout"
    }

    func run() async -> Int32 {
        let previous = NSWorkspace.shared.frontmostApplication
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--count", "2", "--label", "FrontBench"]
        configuration.createsNewApplicationInstance = true
        guard let fixture = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration) else {
            print("Could not launch the fixture."); return 4
        }
        defer {
            fixture.terminate()
            if let previous, previous.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous.activate(options: []) }
        }
        let pid = fixture.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        var elements: [AXUIElement] = []
        for _ in 0..<100 {
            elements = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
            if elements.count >= 2 { break }
            await sleep(100)
        }
        guard let one = elements.first(where: { (attribute($0, kAXTitleAttribute) as? String)?.hasSuffix("One") == true }),
              let two = elements.first(where: { (attribute($0, kAXTitleAttribute) as? String)?.hasSuffix("Two") == true }),
              let display = WindowService.displayAreas().first else { print("Fixture AX windows not found."); return 5 }
        let v = display.visibleFrame
        let starts = [CGRect(x: v.x + 60, y: v.y + 80, width: 460, height: 300), CGRect(x: v.x + 200, y: v.y + 160, width: 460, height: 300)]
        let windows = [one, two]
        func focus(_ index: Int) async {
            AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, windows[index])
            AXUIElementSetAttributeValue(windows[index], kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(windows[index], kAXRaiseAction as CFString)
            fixture.activate(options: [])
            for _ in 0..<50 where NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { await sleep(10) }
            await sleep(150)
        }
        func reset() { for (window, start) in zip(windows, starts) { axSet(window, start) } }
        var failures = 0, staleRuns = 0, tileMs: [Double] = []
        func check(_ label: String, _ index: Int, _ expected: CGRect) {
            let frame = axFrame(windows[index]) ?? .zero
            let other = axFrame(windows[1 - index]) ?? .zero
            if !close(frame, expected, 3) || !close(other, starts[1 - index], 3) {
                failures += 1
                print("\(label): focused window \(index) at \(frame) expected \(expected); other at \(other) expected \(starts[1 - index])")
            }
        }

        // Cold: the chord arrives before any scan finished; the window is adopted at keypress time.
        reset()
        await focus(1)
        service.nativeCheckProcessFilter = { $0 == pid }
        service.nativeCheckDropFocusEvents = true
        service.start()
        let emptyBefore = service.snapshot.records.isEmpty
        if let reason = await tileFront(.leftHalf) { failures += 1; print("cold: failed \(reason)") }
        await sleep(400)
        if let expected = expectedRect(.leftHalf, window: starts[1]) { check("cold", 1, expected) }
        print("coldStartRegistryEmptyAtChord=\(emptyBefore)")
        await sleep(800)

        let zones: [LayoutZone] = [.leftHalf, .rightHalf, .topHalf, .bottomHalf]
        for run in 0..<runs {
            reset()
            let index = run % 2
            await focus(index)
            let ids = service.snapshot.records.filter { $0.id.process.pid == pid }
            let targetID = ids.first { ($0.title.hasSuffix("One") ? 0 : 1) == index }?.id
            if service.focusedID != targetID { staleRuns += 1 }
            let zone = zones[run % zones.count]
            let t0 = now()
            if let reason = await tileFront(zone) { failures += 1; print("run \(run): failed \(reason)"); continue }
            tileMs.append(now() - t0)
            await sleep(350)
            if let expected = expectedRect(zone, window: starts[index]) { check("run \(run) \(zone.rawValue)", index, expected) }
            // ⌃⌥Z on the same (still stale-cached) window.
            var undoFailed: String?
            pairs.undoFrontWindow(service: service) { undoFailed = $0 }
            await sleep(450)
            if let undoFailed { failures += 1; print("run \(run): undo failed \(undoFailed)") }
            else { check("run \(run) undo", index, starts[index]) }
        }
        let sorted = tileMs.sorted()
        if !sorted.isEmpty {
            print(String(format: "chordToCompletion ms n=%d median=%.1f p90=%.1f max=%.1f", sorted.count, sorted[sorted.count / 2],
                         sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))], sorted.last!))
        }
        print("variant: standalone ⌃⌥ path, focus notifications dropped; runs=\(runs) staleCachedFocusRuns=\(staleRuns) failures=\(failures)")
        return failures == 0 ? 0 : 1
    }
}
#endif
