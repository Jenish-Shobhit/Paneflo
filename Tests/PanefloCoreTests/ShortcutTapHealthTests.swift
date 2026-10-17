import Testing
@testable import PanefloCore

struct ShortcutTapHealthTests {
    private let second: UInt64 = 1_000_000_000
    private func reenable(_ budget: inout TapReenableBudget, _ now: UInt64) -> Bool { budget.shouldReenable(at: now) }

    @Test func reenablesThreeTimesPerWindowThenFails() {
        var budget = TapReenableBudget()
        #expect(reenable(&budget, 1 * second))
        #expect(reenable(&budget, 2 * second))
        #expect(reenable(&budget, 3 * second))
        #expect(!reenable(&budget, 4 * second))
    }

    @Test func oldDisablesLeaveTheWindow() {
        var budget = TapReenableBudget()
        for t: UInt64 in [1, 2, 3] { #expect(reenable(&budget, t * second)) }
        // 11 s: the 1 s entry is exactly 10 s old and expires; 2 s and 3 s remain.
        #expect(reenable(&budget, 11 * second))
        #expect(!reenable(&budget, 11 * second + 1))
        #expect(reenable(&budget, 30 * second))
    }

    @Test func clockReversalDoesNotKeepStaleEntries() {
        var budget = TapReenableBudget(limit: 1)
        #expect(reenable(&budget, 50 * second))
        #expect(reenable(&budget, 5 * second))
    }

    @Test func latencyPercentilesUseNearestRank() {
        var window = CallbackLatencyWindow(capacity: 100)
        #expect(window.summary == nil)
        for value in (1...100).reversed() { window.record(UInt64(value)) }
        let summary = window.summary
        #expect(summary?.p50Nanoseconds == 50)
        #expect(summary?.p95Nanoseconds == 95)
        #expect(summary?.maxNanoseconds == 100)
        #expect(summary?.callbacks == 100 && summary?.samples == 100)
    }

    @Test func latencyWindowKeepsRecentSamplesButSessionMaximum() {
        var window = CallbackLatencyWindow(capacity: 4)
        window.record(1_000)
        for _ in 0..<4 { window.record(10) }
        let summary = window.summary
        #expect(summary?.samples == 4)
        #expect(summary?.p95Nanoseconds == 10)
        #expect(summary?.maxNanoseconds == 1_000)
        #expect(summary?.callbacks == 5)
    }
}
