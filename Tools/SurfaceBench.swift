import AppKit
import PanefloCore
import Darwin

/// Own-window surface latency bench. It feeds synthetic own-process records to the real
/// `DesktopController`, never installs an event tap, never posts global input and never
/// requests a permission. Each launch writes one sample file; `--report <dir>` aggregates.
///
/// Usage:
///   surface-bench <output-dir> <card-count>        (launched through LaunchServices)
///   surface-bench --report <output-dir>             (prints median/p90/min/max per metric)
@main
struct SurfaceBench {
    @MainActor static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--report" {
            report(directory: arguments.count > 1 ? arguments[1] : FileManager.default.currentDirectoryPath)
            return
        }
        let output = arguments.first ?? NSTemporaryDirectory()
        let count = arguments.count > 1 ? Int(arguments[1]) ?? 20 : 20
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        Task { @MainActor in
            let recorder = Recorder(count: count)
            await run(count: count, recorder: recorder)
            recorder.write(to: URL(fileURLWithPath: output))
            exit(0)
        }
        application.run()
    }

    // MARK: - Sampling

    @MainActor final class Recorder {
        let count: Int
        var lines: [String] = []
        init(count: Int) { self.count = count }
        func add(_ metric: String, _ milliseconds: Double) { lines.append("\(count)\t\(metric)\t\(milliseconds)") }
        func write(to directory: URL) {
            let file = directory.appendingPathComponent("samples-\(count)-\(getpid()).tsv")
            try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Accumulates main run-loop time spent awake (between after-waiting and before-waiting).
    @MainActor final class BusyProbe {
        private var observer: CFRunLoopObserver?
        private var wokeAt: Double?
        private(set) var busy: Double = 0
        func start() {
            busy = 0; wokeAt = nil
            let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
            observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { [weak self] _, activity in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if activity == .afterWaiting { self.wokeAt = SurfaceBench.now() }
                    else if let start = self.wokeAt { self.busy += SurfaceBench.now() - start; self.wokeAt = nil }
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        func stop() -> Double {
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            observer = nil
            return busy
        }
    }

    static func now() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }
    @MainActor static func settle(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
    /// Time until the main queue drains once more: the presented frame's layout, drawing and commit.
    @MainActor static func nextTurn() async -> Double {
        let start = now()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        return now() - start
    }
    @MainActor static func timed(_ body: () -> Void) async -> (call: Double, turn: Double) {
        let start = now(); body(); let call = now() - start
        let turn = await nextTurn()
        return (call, call + turn)
    }

    static func syntheticRecords(_ count: Int, revision: Int = 0, rotation: Int = 0) -> [WindowRecord] {
        let owner = ProcessIdentity(pid: getpid(), launchToken: 1)
        let records = (0..<count).map { index in
            WindowRecord(id: WindowIdentity(process: owner, number: UInt32(index + 1), incarnation: 1),
                         appIdentifier: "org.paneflo.surface-bench.\(index % 6)", appName: "Synthetic app \(index % 6)",
                         title: index == 0 && revision > 0 ? "Synthetic document 1 · revision \(revision)" : "Synthetic document \(index + 1)",
                         frame: WindowRect(x: 0, y: 0, width: 800, height: 600))
        }
        let shift = rotation % max(1, count)
        return Array(records[shift...] + records[..<shift])
    }

    // MARK: - Scenario

    @MainActor static func run(count: Int, recorder: Recorder) async {
        let service = WindowService()
        let desktop = DesktopController(service: service)
        service.onChange = { desktop.updateSnapshot() }
        #if SURFACE_BENCH_MONITOR_HOOK
        // Never install a real global mouse monitor from the bench.
        desktop.nativeCheckReplaceOutsideClickMonitor(install: { _ in NSObject() }, remove: { _ in })
        #endif
        #if SURFACE_BENCH_PREVIEWS
        // As in the app with previews on: a provider that serves warm cached snapshots synchronously,
        // like the engine on open, so card-side preview work is part of every measurement.
        let previews = SyntheticPreviews()
        desktop.previews = previews
        #else
        // The real app always installs these hooks; without them the per-selection work is skipped.
        desktop.onPreviewSelection = { _, _, _ in }
        desktop.onThumbnailViewport = { _, _, _ in }
        #endif
        desktop.onVisibilityChanged = { _ in }
        desktop.onSurfaceVisibilityChanged = { _ in }
        desktop.onCompositionChanged = { _ in }

        var start = now()
        #if SURFACE_BENCH_PREWARM
        // As in the app: panels are pre-warmed at launch, before the first registry scan lands.
        desktop.prewarm()
        recorder.add("launch.prewarm.call", now() - start)
        await settle(300)
        #endif
        let launchProbe = BusyProbe(); launchProbe.start()
        start = now()
        service.nativeCheckInstall(syntheticRecords(count))
        recorder.add("hidden.install.call", now() - start)
        await settle(1500)
        recorder.add("hidden.install.busy1.5s", launchProbe.stop())

        let idle = BusyProbe(); idle.start()
        await settle(1000)
        recorder.add("hidden.idle.busy1s", idle.stop())

        // Held Command–Tab: cold present, first draw, then Tab steps.
        var sample = await timed { desktop.present(mode: .switcher, fromShortcut: true) }
        recorder.add("switcher.cold.call", sample.call); recorder.add("switcher.cold.turn", sample.turn)
        await settle(60)
        sample = await timed { desktop.switchStep(backwards: false) }
        recorder.add("switcher.firstStep.turn", sample.turn)
        for _ in 0..<15 {
            await settle(40)
            sample = await timed { desktop.switchStep(backwards: false) }
            recorder.add("switcher.step.call", sample.call); recorder.add("switcher.step.turn", sample.turn)
        }
        start = now()
        desktop.dismiss(restorePreviousApplication: false)
        recorder.add("switcher.dismiss.call", now() - start)
        let afterDismiss = BusyProbe(); afterDismiss.start()
        await settle(1000)
        recorder.add("hidden.afterDismiss.busy1s", afterDismiss.stop())

        // Later Command–Tab presses. The MRU order changes between presses, as in real use.
        for round in 1...8 {
            service.nativeCheckInstall(syntheticRecords(count, rotation: round))
            await settle(150)
            sample = await timed { desktop.present(mode: .switcher, fromShortcut: true) }
            recorder.add("switcher.warm.call", sample.call); recorder.add("switcher.warm.turn", sample.turn)
            await settle(80)
            desktop.dismiss(restorePreviousApplication: false)
            await settle(150)
        }
        service.nativeCheckInstall(syntheticRecords(count))
        await settle(1200)

        // Registry churn while hidden: one title change every 100 ms for two seconds.
        let churn = BusyProbe(); churn.start()
        for revision in 1...20 {
            start = now()
            service.nativeCheckInstall(syntheticRecords(count, revision: revision))
            recorder.add("hidden.change.call", now() - start)
            await settle(100)
        }
        recorder.add("hidden.churn.busy2s", churn.stop())
        await settle(1200)

        // Overview: first open, arrow steps, Escape through the panel, then warm opens.
        sample = await timed { desktop.focusOverview(); desktop.nativeCheckSuppressExternalRestore() }
        recorder.add("overview.first.call", sample.call); recorder.add("overview.first.turn", sample.turn)
        await settle(200)
        for _ in 0..<15 {
            sample = await timed { desktop.navigate(.forward) }
            recorder.add("overview.step.call", sample.call); recorder.add("overview.step.turn", sample.turn)
            await settle(30)
        }
        func escape() -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: desktop.nativeCheckWindow.windowNumber, context: nil, characters: "\u{1b}",
                             charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        }
        let firstEscape = escape()
        sample = await timed { NSApp.sendEvent(firstEscape) }
        if !desktop.isVisible { recorder.add("overview.escape.call", sample.call) }
        await settle(300)
        for _ in 0..<6 {
            sample = await timed { desktop.focusOverview(); desktop.nativeCheckSuppressExternalRestore() }
            recorder.add("overview.warm.call", sample.call); recorder.add("overview.warm.turn", sample.turn)
            await settle(150)
            let event = escape()
            sample = await timed { NSApp.sendEvent(event) }
            if !desktop.isVisible { recorder.add("overview.escape.call", sample.call) }
            await settle(200)
        }
        let final = BusyProbe(); final.start()
        await settle(1000)
        recorder.add("hidden.idle.busy1s", final.stop())
    }

    #if SURFACE_BENCH_PREVIEWS
    /// Mirrors the engine's synchronous behaviour: each visible card is emitted once per session
    /// (a cached snapshot), and a selection change relabels the outgoing card. No capture runs.
    @MainActor final class SyntheticPreviews: PreviewProvider {
        var onPreview: ((PreviewUpdate) -> Void)?
        private var emitted: Set<WindowIdentity> = []
        private var selected: WindowIdentity?
        private var visible = false
        private let image: CGImage? = {
            let context = CGContext(data: nil, width: 340, height: 152, bitsPerComponent: 8, bytesPerRow: 340 * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
            context?.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            context?.fill(CGRect(x: 0, y: 0, width: 340, height: 152))
            return context?.makeImage()
        }()

        func updateSurface(visible: Bool, cards: [PreviewCard], selected: WindowIdentity?, previewPixelSize: CGSize?) {
            guard visible else { self.visible = false; emitted.removeAll(); self.selected = nil; return }
            if !self.visible { self.visible = true; emitted.removeAll() }
            for card in cards where !emitted.contains(card.id) { emitted.insert(card.id); onPreview?(preview(for: card)) }
            if let previous = self.selected, previous != selected {
                onPreview?(PreviewUpdate(id: previous, content: .keep, presentation: .snapshot(capturedAt: ProcessInfo.processInfo.systemUptime, note: nil)))
            }
            self.selected = selected
        }

        func preview(for card: PreviewCard) -> PreviewUpdate {
            PreviewUpdate(id: card.id, content: image.map { .snapshot($0) } ?? .none,
                          presentation: .snapshot(capturedAt: ProcessInfo.processInfo.systemUptime - 3, note: nil))
        }
    }
    #endif

    // MARK: - Report

    static func report(directory: String) {
        let manager = FileManager.default
        let files = ((try? manager.contentsOfDirectory(atPath: directory)) ?? []).filter { $0.hasPrefix("samples-") && $0.hasSuffix(".tsv") }
        var samples: [String: [Double]] = [:]
        var order: [String] = []
        var runs: [Int: Int] = [:]
        for file in files.sorted() {
            guard let text = try? String(contentsOfFile: (directory as NSString).appendingPathComponent(file), encoding: .utf8) else { continue }
            var counted = false
            for line in text.split(separator: "\n") {
                let fields = line.split(separator: "\t")
                guard fields.count == 3, let count = Int(fields[0]), let value = Double(fields[2]) else { continue }
                if !counted { runs[count, default: 0] += 1; counted = true }
                let key = "\(count)\t\(fields[1])"
                if samples[key] == nil { order.append(key) }
                samples[key, default: []].append(value)
            }
        }
        guard !samples.isEmpty else { print("No samples in \(directory)"); return }
        func percentile(_ sorted: [Double], _ p: Double) -> Double {
            let rank = p * Double(sorted.count - 1)
            let low = Int(rank.rounded(.down)), high = Int(rank.rounded(.up))
            return sorted[low] + (sorted[high] - sorted[low]) * (rank - Double(low))
        }
        print("runs per card count: " + runs.keys.sorted().map { "\($0) cards=\(runs[$0]!)" }.joined(separator: ", "))
        print("cards  metric                          n    median      p90      min      max   (ms)")
        let keys = order.sorted { a, b in
            let ac = Int(a.split(separator: "\t")[0])!, bc = Int(b.split(separator: "\t")[0])!
            return ac != bc ? ac < bc : order.firstIndex(of: a)! < order.firstIndex(of: b)!
        }
        for key in keys {
            let parts = key.split(separator: "\t")
            let values = samples[key]!.sorted()
            let row = [percentile(values, 0.5), percentile(values, 0.9), values.first!, values.last!]
                .map { String(format: "%8.2f", $0) }.joined(separator: " ")
            let name = String(parts[1]).padding(toLength: 30, withPad: " ", startingAt: 0)
            let cards = String(repeating: " ", count: max(0, 5 - parts[0].count)) + parts[0]
            print("\(cards)  \(name) \(String(format: "%3d", values.count)) " + row)
        }
    }
}
