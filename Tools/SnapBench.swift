// Drag-to-edge arm latency bench. It never moves a window, posts input or installs a monitor.
//
// 1. Measured: what one window-list read costs on this host (the window under a press, and one window's frame),
//    against a PanefloFixture window. Numbers only; no titles are read.
// 2. Modelled: `SnapDragTracker` (the real Core decisions) replayed against synthetic drags on a simulated clock.
//    Drag events arrive every 8 ms while the pointer moves; the dragged window starts following after a lag; reads
//    take the measured median plus one main-queue hop. The caller's sampling timer is emulated the way the build's
//    DragSnapService drives it (a repeating timer at `sampleInterval` from the moment the window is known, or with
//    SNAP_BENCH_NEXT_SAMPLE a one-shot timer at `nextSampleAt`).
//
// `armDelayMs` is the time from the moment both conditions hold (the pointer is in the zone and the window has
// started moving) until the tracker asks for the outline. It excludes drawing the outline (the surface bench times
// `SnapPreviewPanel`). The modelled values are deterministic for a given read latency.
//
//   snap-bench <PanefloFixture executable>     prints "RESULT <section> key=value ..." lines
import AppKit
import PanefloCore

@main struct SnapBench {
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    static func fixtureWindow(pid: pid_t) -> UInt32? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.lazy.compactMap { info -> UInt32? in
            guard (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid, info[kCGWindowLayer as String] as? Int == 0 else { return nil }
            return (info[kCGWindowNumber as String] as? Int).map(UInt32.init)
        }.first
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    /// Mirrors DragSnapService's reads: the full on-screen list for the press, one window for a frame sample.
    static func measureReads(window: UInt32) -> (resolve: Double, frame: Double) {
        var resolve: [Double] = [], frame: [Double] = []
        for _ in 0..<40 {
            var start = now()
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
            for info in list ?? [] { _ = info[kCGWindowBounds as String] }
            resolve.append((now() - start) * 1000)
            start = now()
            let one = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window)) as? [[String: Any]]
            _ = one?.first?[kCGWindowBounds as String]
            frame.append((now() - start) * 1000)
        }
        return (median(resolve), median(frame))
    }

    // MARK: Model

    struct Scenario {
        let name: String
        /// Pointer travel from the press to the edge, in ms; then it parks there.
        let travelMs: Double
        /// How long after the first drag event the window starts to follow.
        let lagMs: Double
    }

    enum Event { case drag(SnapPoint), resolved, sampled(issued: Double), timer(Double), release }

    static let display = DisplayArea(frame: WindowRect(x: 0, y: 0, width: 1440, height: 900),
                                     visibleFrame: WindowRect(x: 0, y: 24, width: 1440, height: 876), backingScale: 2)
    static let windowFrame = WindowRect(x: 300, y: 200, width: 800, height: 500)
    static let press = SnapPoint(x: 700, y: 210)
    static let edge = SnapPoint(x: 0, y: 400)

    /// Returns (armDelayMs, samples) or nil when the drag never armed.
    static func simulate(_ scenario: Scenario, readMs: Double, resolveMs: Double) -> (delay: Double, samples: Int)? {
        let hop = 1.0 // one main-queue hop back from the read queue
        var tracker = SnapDragTracker()
        var queue: [(time: Double, order: Int, event: Event)] = []
        var order = 0
        func push(_ time: Double, _ event: Event) { queue.append((time, order, event)); order += 1 }
        let interval = 8.0
        let firstDrag = interval
        var t = firstDrag
        while t < firstDrag + scenario.travelMs {
            let progress = (t - firstDrag) / scenario.travelMs
            push(t, .drag(SnapPoint(x: press.x + (edge.x - press.x) * progress, y: press.y + (edge.y - press.y) * progress)))
            t += interval
        }
        let arrival = firstDrag + scenario.travelMs
        push(arrival, .drag(edge))
        push(arrival + 800, .release)
        func pointer(at time: Double) -> SnapPoint {
            guard time > firstDrag else { return press }
            let progress = min(1, (time - firstDrag) / scenario.travelMs)
            return SnapPoint(x: press.x + (edge.x - press.x) * progress, y: press.y + (edge.y - press.y) * progress)
        }
        let movesAt = firstDrag + scenario.lagMs
        func frame(at time: Double) -> WindowRect {
            guard time >= movesAt else { return windowFrame }
            let cursor = pointer(at: time)
            return WindowRect(x: windowFrame.x + cursor.x - press.x, y: windowFrame.y + cursor.y - press.y,
                              width: windowFrame.width, height: windowFrame.height)
        }
        let settings = tracker.settings
        // When the pointer first enters the zone: the last drag event at or past the margin.
        var zoneAt = arrival
        var probe = firstDrag
        while probe <= arrival {
            if pointer(at: probe).x <= settings.edgeMargin { zoneAt = probe; break }
            probe += interval
        }
        let reference = max(zoneAt, movesAt)

        var samples = 0
        var armedAt: Double?
        var timerNext: Double?
        func handle(_ effects: [SnapDragTracker.Effect], at time: Double) {
            for effect in effects {
                switch effect {
                case .resolveWindow: push(time + resolveMs + hop, .resolved)
                case .sampleFrame: samples += 1; push(time + readMs + hop, .sampled(issued: time + readMs / 2))
                case .showPreview: if armedAt == nil { armedAt = time }
                default: break
                }
            }
            #if SNAP_BENCH_NEXT_SAMPLE
            if let due = tracker.nextSampleAt.map({ $0 * 1000 }), timerNext != due {
                timerNext = due; push(max(due, time), .timer(due))
            } else if tracker.nextSampleAt == nil { timerNext = nil }
            #else
            if tracker.awaitsMovement, timerNext == nil {
                timerNext = time + settings.sampleInterval * 1000; push(timerNext!, .timer(timerNext!))
            } else if !tracker.awaitsMovement { timerNext = nil }
            #endif
        }
        handle(tracker.mouseDown(at: press, displays: [display]), at: 0)
        while !queue.isEmpty {
            let index = queue.indices.min { queue[$0].time != queue[$1].time ? queue[$0].time < queue[$1].time : queue[$0].order < queue[$1].order }!
            let (time, _, event) = queue.remove(at: index)
            let seconds = time / 1000
            switch event {
            case .drag(let point): handle(tracker.mouseDragged(to: point, now: seconds), at: time)
            case .resolved:
                handle(tracker.windowResolved(DragWindow(number: 7, frame: windowFrame), press: tracker.press, now: seconds), at: time)
            case .sampled(let issued): handle(tracker.frameSampled(frame(at: issued), press: tracker.press, now: seconds), at: time)
            case .timer(let due):
                guard timerNext == due else { continue }
                #if SNAP_BENCH_NEXT_SAMPLE
                timerNext = nil
                handle(tracker.tick(now: seconds), at: time)
                #else
                timerNext = nil
                handle(tracker.tick(now: seconds), at: time)
                if tracker.awaitsMovement { timerNext = due + settings.sampleInterval * 1000; push(timerNext!, .timer(timerNext!)) }
                #endif
            case .release: _ = tracker.mouseUp(); queue.removeAll()
            }
        }
        guard let armedAt else { return nil }
        return (max(0, armedAt - reference), samples)
    }

    @MainActor static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else { print("usage: snap-bench FIXTURE_EXECUTABLE"); exit(2) }
        _ = NSApplication.shared
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: arguments[1])
        fixture.arguments = ["--count", "1", "--label", "Bench"]
        do { try fixture.run() } catch { print("could not launch fixture: \(error)"); exit(1) }
        var number: UInt32?
        let deadline = now() + 10
        while number == nil, now() < deadline {
            number = fixtureWindow(pid: fixture.processIdentifier)
            if number == nil { usleep(20_000) }
        }
        guard let number else { print("fixture window did not appear"); fixture.terminate(); exit(1) }
        let reads = measureReads(window: number)
        fixture.terminate()
        print(String(format: "RESULT reads resolveMs=%.3f frameMs=%.3f", reads.resolve, reads.frame))

        // Short travel: a flick, or a press near the edge. Lag: how far the window trails the first drag event.
        var scenarios: [Scenario] = []
        for travel in [24.0, 48, 120] {
            for lag in [0.0, 10, 30, 50] { scenarios.append(Scenario(name: "travel\(Int(travel))Lag\(Int(lag))", travelMs: travel, lagMs: lag)) }
        }
        var delays: [Double] = []
        for scenario in scenarios {
            guard let result = simulate(scenario, readMs: reads.frame, resolveMs: reads.resolve) else {
                print("RESULT model.\(scenario.name) armed=0"); continue
            }
            delays.append(result.delay)
            print(String(format: "RESULT model.%@ armed=1 armDelayMs=%.1f samples=%d", scenario.name, result.delay, result.samples))
        }
        print(String(format: "RESULT model armDelayMeanMs=%.1f armDelayMaxMs=%.1f", delays.reduce(0, +) / Double(max(1, delays.count)), delays.max() ?? 0))
        exit(0)
    }
}
