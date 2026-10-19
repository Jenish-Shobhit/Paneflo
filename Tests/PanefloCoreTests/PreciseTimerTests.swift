import Foundation
import Testing
@testable import PanefloCore

@MainActor
struct PreciseTimerTests {
    private func wait(until condition: () -> Bool, timeout: Double = 2) async {
        let start = ProcessInfo.processInfo.systemUptime
        while !condition(), ProcessInfo.processInfo.systemUptime - start < timeout { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test
    func firesOnceNotBeforeItsDeadline() async {
        let timer = PreciseTimer()
        let start = ProcessInfo.processInfo.systemUptime
        var firedAt: [Double] = []
        timer.schedule(after: 0.03) { firedAt.append(ProcessInfo.processInfo.systemUptime) }
        #expect(timer.isScheduled)
        await wait(until: { !firedAt.isEmpty })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(firedAt.count == 1)
        #expect((firedAt.first ?? 0) - start >= 0.03)
        #expect(!timer.isScheduled)
    }

    @Test
    func reschedulingReplacesAndCancellingDrops() async {
        let timer = PreciseTimer()
        var fired: [String] = []
        timer.schedule(after: 0.02) { fired.append("first") }
        timer.schedule(after: 0.03) { fired.append("second") }
        await wait(until: { !fired.isEmpty })
        try? await Task.sleep(for: .milliseconds(40))
        #expect(fired == ["second"])
        timer.schedule(after: 0.01) { fired.append("cancelled") }
        timer.cancel()
        try? await Task.sleep(for: .milliseconds(40))
        #expect(fired == ["second"])
        #expect(!timer.isScheduled)
    }

    @Test
    func aPastDeadlineFiresAtOnce() async {
        let timer = PreciseTimer()
        var fired = false
        timer.schedule(after: -1) { fired = true }
        await wait(until: { fired })
        #expect(fired)
    }
}
