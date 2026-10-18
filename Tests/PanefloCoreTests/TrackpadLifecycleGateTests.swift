import Testing
@testable import PanefloCore

struct TrackpadLifecycleGateTests {
    private func active() -> TrackpadLifecycleGate {
        var gate = TrackpadLifecycleGate()
        let effect = gate.send(.enable)
        #expect(effect == .start)
        _ = gate.send(.started)
        return gate
    }
    @Test func overlappingReasonsWaitForEveryWakeAndResumeOnce() {
        var gate = active()
        let stop = gate.send(.pause(.displaySleep))
        #expect(stop == .stop)
        #expect(gate.isEnabled)
        #expect(gate.send(.pause(.systemSleep)) == nil)
        #expect(gate.send(.pause(.sessionInactive)) == nil)
        #expect(gate.send(.stopped(clean: true)) == nil)
        #expect(gate.phase == .paused)
        #expect(gate.send(.wake(.displaySleep)) == nil)
        #expect(gate.send(.wake(.systemSleep)) == nil)
        let start = gate.send(.wake(.sessionInactive))
        #expect(start == .start)
        #expect(gate.send(.wake(.sessionInactive)) == nil)
        #expect(gate.send(.wake(.systemSleep)) == nil)
        _ = gate.send(.started)
        #expect(gate.phase == .active)
    }
    @Test func wakeBeforeStopCompletionWaitsForCleanPhysicalStop() {
        var gate = active()
        _ = gate.send(.pause(.systemSleep))
        #expect(gate.send(.wake(.systemSleep)) == nil)
        #expect(gate.phase == .stopping)
        let start = gate.send(.stopped(clean: true))
        #expect(start == .start)
        #expect(gate.send(.stopped(clean: true)) == nil)
    }
    @Test func disableDuringSuspensionPreventsResume() {
        for stopFinished in [false, true] {
            var gate = active()
            _ = gate.send(.pause(.displaySleep))
            if stopFinished { _ = gate.send(.stopped(clean: true)) }
            _ = gate.send(.disable)
            #expect(!gate.isEnabled)
            #expect(gate.send(.wake(.displaySleep)) == nil)
            #expect(gate.send(.stopped(clean: true)) == nil)
            #expect(gate.phase == .disabled)
        }
    }
    @Test func failedStopAndFailedResumeClearIntentAndNeverRetryOnWake() {
        var gate = active()
        _ = gate.send(.pause(.systemSleep))
        #expect(gate.send(.stopped(clean: false)) == nil)
        #expect(!gate.isEnabled)
        #expect(gate.phase == .failed)
        #expect(gate.send(.wake(.systemSleep)) == nil)
        gate = active()
        _ = gate.send(.pause(.systemSleep))
        _ = gate.send(.stopped(clean: true))
        _ = gate.send(.wake(.systemSleep))
        _ = gate.send(.startFailed)
        #expect(!gate.isEnabled)
        #expect(gate.phase == .failed)
        #expect(gate.send(.wake(.systemSleep)) == nil)
    }
    @Test func disablingAndReenablingDuringStopSerializesNewStart() {
        var gate = active()
        _ = gate.send(.disable)
        #expect(gate.send(.enable) == nil)
        #expect(gate.isEnabled)
        #expect(gate.phase == .stopping)
        let start = gate.send(.stopped(clean: true))
        #expect(start == .start)
    }
    @Test func pauseWhileStartingIgnoresLateStartAndEachNewCycleGetsOneAttempt() {
        var gate = TrackpadLifecycleGate()
        _ = gate.send(.enable)
        _ = gate.send(.pause(.systemSleep))
        _ = gate.send(.started)
        #expect(gate.phase == .stopping)
        _ = gate.send(.stopped(clean: true))
        let first = gate.send(.wake(.systemSleep))
        #expect(first == .start)
        _ = gate.send(.started)
        _ = gate.send(.pause(.displaySleep))
        _ = gate.send(.stopped(clean: true))
        let second = gate.send(.wake(.displaySleep))
        #expect(second == .start)
        #expect(gate.send(.wake(.displaySleep)) == nil)
    }
}

struct BoundedRetryGateTests {
    private func allowed(_ gate: inout BoundedRetryGate, _ now: Double) -> Bool { gate.permit(now: now) }

    @Test func spacesAndCapsAutomaticAttempts() {
        var gate = BoundedRetryGate(minimumSpacing: 10, maximumAttempts: 3)
        #expect(allowed(&gate, 0))
        #expect(!allowed(&gate, 5), "too soon: a wake storm cannot spin")
        #expect(allowed(&gate, 10))
        #expect(allowed(&gate, 25))
        #expect(gate.isExhausted && !allowed(&gate, 1_000), "bounded until reset")
        gate.reset()
        #expect(allowed(&gate, 1_001), "a success or the user's toggle starts over")
    }

    @Test func clockReversalDoesNotBlockForever() {
        var gate = BoundedRetryGate(minimumSpacing: 10, maximumAttempts: 5)
        #expect(allowed(&gate, 100))
        #expect(allowed(&gate, 50), "if the clock ever ran backwards, do not wait out the gap")
    }
}
