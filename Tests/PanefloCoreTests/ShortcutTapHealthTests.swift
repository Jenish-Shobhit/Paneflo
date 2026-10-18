import Testing
@testable import PanefloCore

struct TapRecoveryScheduleTests {
    @Test func timedRetriesBackOffAndStop() {
        var schedule = TapRecoverySchedule()
        #expect(schedule.scheduleAfterFailure(now: 100) == 130)
        schedule.noteAttempt(now: 130)
        #expect(schedule.scheduleAfterFailure(now: 131) == 191)
        schedule.noteAttempt(now: 191)
        #expect(schedule.scheduleAfterFailure(now: 192) == 312)
        schedule.noteAttempt(now: 312)
        #expect(schedule.scheduleAfterFailure(now: 313) == nil, "three timed retries, then only activation or manual")
        #expect(schedule.allowsActivationRetry(now: 323))
        #expect(!schedule.allowsActivationRetry(now: 315), "activation retries are spaced")
        schedule.noteAttempt(now: 323)
        schedule.noteAttempt(now: 400)
        #expect(schedule.isExhausted)
        #expect(!schedule.allowsActivationRetry(now: 10_000), "bounded: no endless retries")
        #expect(schedule.scheduleAfterFailure(now: 10_001) == nil)
    }

    @Test func aStableTapStartsAFreshStreakAndManualResetsToo() {
        var schedule = TapRecoverySchedule()
        for t in [0.0, 1, 2] { _ = schedule.scheduleAfterFailure(now: t); schedule.noteAttempt(now: t) }
        // A tap that keeps failing soon after each recovery does not regain budget.
        schedule.noteActive(now: 10)
        #expect(schedule.scheduleAfterFailure(now: 20) == nil)
        schedule.noteActive(now: 30)
        #expect(schedule.scheduleAfterFailure(now: 400) == 430, "five minutes of a working tap reset the streak")
        schedule.reset()
        #expect(schedule.attempts == 0 && schedule.scheduleAfterFailure(now: 500) == 530)
    }
}

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
