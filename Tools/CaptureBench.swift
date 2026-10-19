// Capture latency/memory bench for CaptureController, run against Paneflo fixture windows only.
// Tools/measure-capture.sh concatenates this after CaptureController.swift and launches
// build/PanefloFixture.app. Prints numbers only: no titles, no pixels, no images are written.
import AppKit
import Darwin
import PanefloCore

@MainActor private final class Recorder {
    var start = 0.0
    var firstSnapshot: Double?
    var snapshots: [WindowIdentity: Double] = [:]
    var firstLive: [WindowIdentity: Double] = [:]
    var synchronousSnapshots = 0
    var insideUpdate = false
    var frames: [WindowIdentity: LiveFrame] = [:]
    var lastLabels: [WindowIdentity: String] = [:]

    func reset() {
        start = ProcessInfo.processInfo.systemUptime
        firstSnapshot = nil; snapshots.removeAll(); firstLive.removeAll(); synchronousSnapshots = 0
    }

    func receive(_ update: PreviewUpdate) {
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        lastLabels[update.id] = update.label()
        switch update.content {
        case .snapshot:
            if insideUpdate { synchronousSnapshots += 1 }
            firstSnapshot = firstSnapshot ?? elapsed
            if snapshots[update.id] == nil { snapshots[update.id] = elapsed }
            frames[update.id] = nil
        case .live(let frame):
            if firstLive[update.id] == nil { firstLive[update.id] = elapsed }
            frames[update.id] = frame
        case .keep: break
        case .none: frames[update.id] = nil
        }
    }
}

@main struct CaptureBench {
    static func footprint() -> UInt64 {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { buffer in
            buffer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), Int32(RUSAGE_INFO_V2), $0) }
        }
        return result == 0 ? info.ri_phys_footprint : 0
    }

    static func ms(_ seconds: Double?) -> String { seconds.map { String(format: "%.1f", $0 * 1000) } ?? "n/a" }
    static func mib(_ bytes: Int) -> String { String(format: "%.2f", Double(bytes) / 1_048_576) }

    static func fixtureWindows(pid: pid_t) -> [UInt32] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
                  info[kCGWindowLayer as String] as? Int == 0 else { return nil }
            return (info[kCGWindowNumber as String] as? Int).map(UInt32.init)
        }.sorted()
    }

    @MainActor static func waitUntil(_ timeout: Double, _ condition: () -> Bool) async -> Double? {
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < timeout {
            if condition() { return ProcessInfo.processInfo.systemUptime - start }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition() ? ProcessInfo.processInfo.systemUptime - start : nil
    }

    @MainActor static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else { print("usage: capture-bench FIXTURE_EXECUTABLE [COUNT]"); exit(2) }
        let count = arguments.count >= 3 ? Int(arguments[2]) ?? 6 : 6
        guard CGPreflightScreenCaptureAccess() else {
            print("RESULT screenRecording=not-granted: capture measurements skipped (unit tests still apply)")
            exit(0)
        }
        _ = NSApplication.shared
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: arguments[1])
        fixture.arguments = ["--count", String(count), "--label", "Bench"]
        do { try fixture.run() } catch { print("could not launch fixture: \(error)"); exit(1) }
        defer { fixture.terminate() }
        let pid = fixture.processIdentifier
        guard await waitUntil(10, { fixtureWindows(pid: pid).count >= count }) != nil else {
            print("fixture windows did not appear"); fixture.terminate(); exit(1)
        }
        try? await Task.sleep(for: .milliseconds(500))
        let numbers = Array(fixtureWindows(pid: pid).prefix(count))
        let cards = numbers.map {
            PreviewCard(id: WindowIdentity(process: ProcessIdentity(pid: pid, launchToken: 1), number: $0, incarnation: 1),
                        windowNumber: $0, isMinimized: false)
        }
        let box = CGSize(width: 464, height: 204)
        let footprintStart = footprint()
        let capture = CaptureController()
        let recorder = Recorder()
        if arguments.contains("--prewarm") {
            capture.prewarm()
            try? await Task.sleep(for: .seconds(2))
        }
        capture.onPreview = { recorder.receive($0) }
        print("RESULT host pressure=\(capture.pressureLevel) screenRecording=\(capture.screenRecordingStatus) windows=\(cards.count) box=\(Int(box.width))x\(Int(box.height))")

        func open(selected: Int) {
            recorder.insideUpdate = true
            capture.updateSurface(visible: true, cards: cards, selected: cards[selected].id, previewPixelSize: box)
            recorder.insideUpdate = false
        }
        func close() { capture.updateSurface(visible: false, cards: [], selected: nil, previewPixelSize: nil) }

        // Cold open: empty cache, no shareable content yet.
        recorder.reset(); open(selected: 0)
        // The selected card shows live frames; its snapshot is cached but not emitted.
        let allCold = await waitUntil(5) { recorder.snapshots.count >= cards.count - 1 }
        let liveCold = await waitUntil(3) { recorder.firstLive[cards[0].id] != nil }
        print("RESULT cold firstSnapshotMs=\(ms(recorder.firstSnapshot)) allSnapshotsMs=\(ms(allCold.map { _ in recorder.snapshots.values.max() ?? 0 })) firstLiveFrameMs=\(ms(recorder.firstLive[cards[0].id])) liveObserved=\(liveCold != nil) cacheEntries=\(capture.cacheCount) cacheMiB=\(mib(capture.cacheBytes))")
        try? await Task.sleep(for: .milliseconds(500))

        // Selection change while visible: the next card goes live after the stable delay.
        let change = ProcessInfo.processInfo.systemUptime
        recorder.start = change
        open(selected: 1)
        _ = await waitUntil(3) { recorder.firstLive[cards[1].id] != nil }
        let label = recorder.lastLabels[cards[0].id] ?? "?"
        print("RESULT selectionChange liveFrameMs=\(ms(recorder.firstLive[cards[1].id])) previousCardLabelPrefix=\(label.hasPrefix("Snapshot") ? "Snapshot" : label) liveStreams=\(capture.liveStreamCount)")

        // Dismiss: zero live streams once the framework confirms the stop.
        let dismissed = ProcessInfo.processInfo.systemUptime
        close()
        recorder.frames.removeAll()
        let zero = await waitUntil(3) { capture.liveStreamCount == 0 }
        print("RESULT dismiss liveStreamsZeroAfterMs=\(ms(zero)) liveStreams=\(capture.liveStreamCount) outstandingSnapshots=\(capture.outstandingSnapshotCount) cacheEntriesKept=\(capture.cacheCount)")
        _ = dismissed

        // Warm open: cached snapshots are delivered synchronously inside updateSurface.
        try? await Task.sleep(for: .milliseconds(1_200))
        recorder.reset(); open(selected: 0)
        let syncCount = recorder.synchronousSnapshots
        recorder.snapshots.removeAll(); recorder.firstSnapshot = nil
        let refreshed = await waitUntil(5) { recorder.snapshots.count >= cards.count - 1 }
        _ = await waitUntil(3) { recorder.firstLive[cards[0].id] != nil }
        print("RESULT warm synchronousCachedSnapshots=\(syncCount)/\(cards.count) refreshAllMs=\(ms(refreshed.map { _ in recorder.snapshots.values.max() ?? 0 })) firstLiveFrameMs=\(ms(recorder.firstLive[cards[0].id]))")
        close(); recorder.frames.removeAll()
        _ = await waitUntil(3) { capture.liveStreamCount == 0 }

        // Memory pressure: critical stops live and purges; warning resumes degraded; normal restores.
        let realLevel = CaptureController.currentPressureLevel()
        recorder.reset(); open(selected: 2)
        _ = await waitUntil(3) { recorder.firstLive[cards[2].id] != nil }
        capture.applyPressure(.critical)
        let criticalZero = await waitUntil(3) { capture.liveStreamCount == 0 }
        let pausedLabel = recorder.lastLabels[cards[3].id] ?? "?"
        print("RESULT pressureCritical liveStreamsZeroAfterMs=\(ms(criticalZero)) cacheEntries=\(capture.cacheCount) label=\(pausedLabel)")
        recorder.reset(); recorder.frames.removeAll()
        capture.applyPressure(.warning)
        _ = await waitUntil(3) { recorder.firstLive[cards[2].id] != nil }
        _ = await waitUntil(5) { recorder.snapshots.count >= cards.count - 1 }
        print("RESULT pressureWarningResume firstLiveFrameMs=\(ms(recorder.firstLive[cards[2].id])) snapshotsRefreshed=\(recorder.snapshots.count) cacheMiB=\(mib(capture.cacheBytes)) liveFrameWidth=\(recorder.frames[cards[2].id]?.width ?? 0)")
        capture.applyPressure(.normal)
        close(); recorder.frames.removeAll()
        _ = await waitUntil(3) { capture.liveStreamCount == 0 }
        capture.applyPressure(realLevel)

        // Rapid churn: 50 open/select/close cycles faster than capture. Every third cycle (and the last one)
        // holds the selection past the stable delay so a live stream is starting or running when the
        // selection moves or the surface closes; the snapshot cache is let go stale first so refreshes are
        // in flight too. `settledMs` is the time from the last close until zero streams and zero outstanding
        // snapshots; it is only reported when something was still pending at that close (`pendingAtClose`).
        try? await Task.sleep(for: .milliseconds(Int(CaptureController.snapshotFreshAge * 1000) + 100))
        var maxStreams = 0
        var pendingAtClose = 0
        var closedAt = 0.0
        for cycle in 0..<50 {
            let holds = cycle % 3 == 0 || cycle == 49
            open(selected: cycle % cards.count)
            try? await Task.sleep(for: .milliseconds(holds ? 150 : 20))
            maxStreams = max(maxStreams, capture.liveStreamCount)
            // The last cycle closes straight from the held selection, so its live stream is still running.
            if cycle < 49 {
                open(selected: (cycle + 1) % cards.count)
                try? await Task.sleep(for: .milliseconds(10))
                maxStreams = max(maxStreams, capture.liveStreamCount)
            }
            closedAt = ProcessInfo.processInfo.systemUptime
            close(); recorder.frames.removeAll()
            pendingAtClose = capture.liveStreamCount + capture.outstandingSnapshotCount
        }
        let settledDone = await waitUntil(5) { capture.liveStreamCount == 0 && capture.outstandingSnapshotCount == 0 } != nil
        let settled: Double? = settledDone && pendingAtClose > 0 ? ProcessInfo.processInfo.systemUptime - closedAt : nil
        let footprintEnd = footprint()
        print("RESULT churn50 settledMs=\(ms(settled)) pendingAtClose=\(pendingAtClose) settled=\(settledDone ? 1 : 0) maxLiveStreams=\(maxStreams) liveStreams=\(capture.liveStreamCount) outstandingSnapshots=\(capture.outstandingSnapshotCount) cacheEntries=\(capture.cacheCount) cacheMiB=\(mib(capture.cacheBytes)) footprintStartMiB=\(mib(Int(footprintStart))) footprintEndMiB=\(mib(Int(footprintEnd)))")

        capture.stop()
        print("RESULT stop cacheEntries=\(capture.cacheCount) cacheBytes=\(capture.cacheBytes)")
        fixture.terminate()
        exit(0)
    }
}
