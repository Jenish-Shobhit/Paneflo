import Foundation
import Testing
@testable import PanefloCore

private final class LateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func append(_ value: Int) { lock.lock(); values.append(value); lock.unlock() }
    var all: [Int] { lock.lock(); defer { lock.unlock() }; return values }
}

@MainActor struct DeadlineTests {
    @Test func fastOperationReturnsValueAndNeverCallsLate() async {
        let late = LateBox()
        let result = await Deadline.run(seconds: 1, operation: { 7 }, late: { if case .success(let v) = $0 { late.append(v) } })
        guard case .value(7) = result else { Issue.record("expected value"); return }
        await drainTasks()
        #expect(late.all.isEmpty)
    }

    @Test func hangTimesOutAndLateResultIsDeliveredExactlyOnce() async {
        let clock = ManualClock()
        let release = TestGate()
        let late = LateBox()
        async let outcome = Deadline.run(seconds: 0.05, sleep: clock.sleep, operation: {
            await release.wait()
            return 9
        }, late: { if case .success(let v) = $0 { late.append(v) } })
        let armed = await eventually { clock.pendingWakeTimes == [0.05] }
        #expect(armed, "the deadline timer is waiting")
        clock.advance(by: 0.05)
        let result = await outcome
        guard case .timedOut = result else { Issue.record("expected timeout"); return }
        // The operation is still blocked, so the caller resumed at the deadline, not at completion.
        #expect(late.all.isEmpty)
        release.open()
        let delivered = await eventually { late.all == [9] }
        #expect(delivered)
        await drainTasks()
        #expect(late.all == [9], "exactly once")
    }

    @Test func errorsPassThrough() async {
        struct Boom: Error {}
        let result = await Deadline.run(seconds: 1, operation: { () async throws -> Int in throw Boom() })
        guard case .failure(let error) = result, error is Boom else { Issue.record("expected failure"); return }
    }
}

struct CaptureCircuitBreakerTests {
    @Test func opensAfterThresholdWithCappedExponentialBackoff() {
        var breaker = CaptureCircuitBreaker(threshold: 3, baseDelay: 1, maximumDelay: 30)
        let first = breaker.recordFailure(now: 0), second = breaker.recordFailure(now: 0)
        #expect(!first && !second)
        #expect(breaker.allows(now: 0))
        let opened = breaker.recordFailure(now: 10)
        #expect(opened)
        #expect(breaker.retryAt == 11 && !breaker.allows(now: 10.5) && breaker.allows(now: 11))
        breaker.recordFailure(now: 11); #expect(breaker.retryAt == 13)
        breaker.recordFailure(now: 13); #expect(breaker.retryAt == 17)
        for _ in 0..<10 { breaker.recordFailure(now: 100) }
        #expect(breaker.retryAt == 130, "capped at 30 s")
        breaker.recordSuccess()
        #expect(breaker.allows(now: 100) && breaker.consecutiveFailures == 0 && breaker.retryAt == nil)
    }
}

struct SnapshotTimeoutSchedulingTests {
    private func request(_ n: UInt32) -> SnapshotRequest {
        SnapshotRequest(id: .init(process: .init(pid: 40, launchToken: 1), number: n, incarnation: 1), windowNumber: n)
    }

    @Test func timeoutFreesSlotAndLateCompletionIsDropped() {
        var scheduler = SnapshotScheduler(concurrencyLimit: 2, abandonedLimit: 2)
        scheduler.beginSession()
        scheduler.plan((0..<6).map(request), selectedIndex: 0)
        let first = scheduler.nextTickets()
        #expect(scheduler.timeout(first[0]) == .timedOut)
        #expect(scheduler.outstandingCount == 1 && scheduler.abandonedCount == 1)
        #expect(scheduler.nextTickets().count == 1, "the slot is free again")
        #expect(scheduler.timeout(first[0]) == .unknownTicket, "no double timeout")
        #expect(scheduler.complete(first[0]) == .lateAfterTimeout)
        #expect(scheduler.complete(first[0]) == .unknownTicket, "no double completion")
        #expect(scheduler.abandonedCount == 0)
    }

    @Test func abandonedRequestsCapNewWork() {
        var scheduler = SnapshotScheduler(concurrencyLimit: 2, abandonedLimit: 2)
        scheduler.beginSession()
        scheduler.plan((0..<10).map(request), selectedIndex: 0)
        for ticket in scheduler.nextTickets() { _ = scheduler.timeout(ticket) }
        #expect(scheduler.abandonedCount == 2)
        #expect(scheduler.nextTickets().isEmpty, "hung OS requests cannot accumulate")
        _ = scheduler.complete(scheduler.outstandingTickets.first ?? SnapshotTicket(request: request(99), serial: 0, epoch: 0))
        scheduler.markForRetry([request(0).id])
        scheduler.plan((0..<10).map(request), selectedIndex: 0)
        #expect(scheduler.queue.first?.id == request(0).id, "a retried window is eligible again")
    }
}

/// A fake capture backend: per-window behaviour, counted calls. A hang waits on a gate, never on wall-clock time.
@MainActor private final class FakeBackend {
    enum Behaviour { case succeed, fail, hang(TestGate) }
    var behaviour: [UInt32: Behaviour] = [:]
    var fallback: Behaviour = .succeed
    var calls = 0
    func capture(_ request: SnapshotRequest) async throws -> Int {
        calls += 1
        switch behaviour[request.windowNumber] ?? fallback {
        case .succeed: return Int(request.windowNumber)
        case .fail: throw SnapshotFailure.failed
        case .hang(let gate):
            await gate.wait()
            return Int(request.windowNumber)
        }
    }
}

@MainActor struct SnapshotRunnerTests {
    private func request(_ n: UInt32) -> SnapshotRequest {
        SnapshotRequest(id: .init(process: .init(pid: 50, launchToken: 1), number: n, incarnation: 1), windowNumber: n)
    }

    @Test func hangTimesOutFreesSlotAndLateResultIsNotStored() async {
        let clock = ManualClock()
        let fake = FakeBackend()
        let hang = TestGate()
        fake.behaviour[0] = .hang(hang)
        let runner = SnapshotRunner<Int>(scheduler: SnapshotScheduler(concurrencyLimit: 2), timeout: 0.05,
                                         clock: { clock.now }, sleep: clock.sleep) { try await fake.capture($0) }
        var stored: [Int] = [], timedOut: [UInt32] = [], late: [UInt32] = []
        runner.onOutcome = { ticket, completion, outcome in
            switch (completion, outcome) {
            case (.store, .captured(let value)): stored.append(value)
            case (.timedOut, .timedOut): timedOut.append(ticket.request.windowNumber)
            default: break
            }
        }
        runner.onLate = { ticket, _ in late.append(ticket.request.windowNumber) }
        runner.scheduler.beginSession()
        runner.scheduler.plan((0..<4).map(request), selectedIndex: 0)
        runner.pump()
        let othersDone = await eventually { stored.count == 3 && clock.pendingWakeTimes == [0.05] }
        #expect(othersDone, "the hang does not block the other windows")
        #expect(timedOut.isEmpty, "no timeout before the deadline")
        clock.advance(by: 0.05)
        let expired = await eventually { timedOut == [0] }
        #expect(expired)
        #expect(runner.scheduler.abandonedCount == 1 && runner.scheduler.outstandingCount == 0)
        hang.open()
        let arrived = await eventually { late == [0] }
        #expect(arrived)
        #expect(runner.scheduler.abandonedCount == 0)
        #expect(!stored.contains(0), "a late completion is dropped")
    }

    @Test func repeatedFailuresBackOffThenRecover() async {
        let clock = ManualClock()
        let fake = FakeBackend()
        fake.fallback = .fail
        let breaker = CaptureCircuitBreaker(threshold: 3, baseDelay: 0.15, maximumDelay: 1)
        let runner = SnapshotRunner<Int>(scheduler: SnapshotScheduler(concurrencyLimit: 3), breaker: breaker,
                                         timeout: 1, clock: { clock.now }, sleep: clock.sleep) { try await fake.capture($0) }
        var changes: [Bool] = [], stored: [Int] = [], failed = 0
        runner.onBreakerChange = { changes.append($0) }
        runner.onOutcome = { _, completion, outcome in
            if case (.store, .captured(let value)) = (completion, outcome) { stored.append(value) }
            if case .failed = outcome { failed += 1 }
        }
        runner.scheduler.beginSession()
        runner.scheduler.plan((0..<8).map(request), selectedIndex: 0)
        runner.pump()
        // Every issued request fails at once; the breaker opens (later in-flight failures may extend the backoff)
        // and its retry waits on test time.
        let opened = await eventually {
            runner.isBackingOff && runner.scheduler.outstandingCount == 0
                && runner.breaker.retryAt.map { clock.pendingWakeTimes == [$0] } == true
        }
        #expect(opened)
        let retryAt = runner.breaker.retryAt ?? 0
        let callsWhenOpened = fake.calls
        #expect(callsWhenOpened >= 3 && changes == [true])
        runner.pump()
        await drainTasks()
        #expect(fake.calls == callsWhenOpened, "no new requests while backing off")
        // The backend recovers; after the backoff one attempt succeeds and closes the breaker.
        fake.fallback = .succeed
        clock.advance(by: retryAt)
        let closed = await eventually { changes.contains(false) }
        #expect(closed)
        let remaining = await eventually { stored.count == 8 - failed }
        #expect(remaining, "the remaining queued windows are captured")
        #expect(runner.breaker.consecutiveFailures == 0 && !runner.isBackingOff)
    }

    @Test func notOnScreenDoesNotTripTheBreaker() async {
        let runner = SnapshotRunner<Int>(scheduler: SnapshotScheduler(concurrencyLimit: 4), timeout: 1) { _ in
            throw SnapshotFailure.notOnScreen
        }
        var resolved = 0
        runner.onOutcome = { _, _, _ in resolved += 1 }
        runner.scheduler.beginSession()
        runner.scheduler.plan((0..<6).map(request), selectedIndex: 0)
        runner.pump()
        let waited7 = await eventually { resolved == 6 }
        #expect(waited7)
        #expect(!runner.isBackingOff && runner.breaker.consecutiveFailures == 0)
    }
}
