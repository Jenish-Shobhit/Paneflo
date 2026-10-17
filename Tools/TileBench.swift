import AppKit
import ApplicationServices
import PanefloCore

/// Tiling latency bench. Drives the real `WindowService` against PanefloFixture windows only:
/// discovery is restricted to the fixture's PID, no event tap is installed and no input is posted.
/// Run the binary directly from a terminal that holds Accessibility access:
///
///   tile-bench <PanefloFixture.app> [--runs N] [--min-width W] [--max-width W]
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
        var index = 1
        while index + 1 < arguments.count {
            switch arguments[index] {
            case "--runs": runs = Int(arguments[index + 1]) ?? runs
            case "--min-width": minWidth = Int(arguments[index + 1])
            case "--max-width": maxWidth = Int(arguments[index + 1])
            default: break
            }
            index += 2
        }
        guard AXIsProcessTrusted() else { print("Accessibility is not granted to this process."); exit(3) }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        Task { @MainActor in
            let code = await Bench(path: path, runs: runs, minWidth: minWidth, maxWidth: maxWidth).run()
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
