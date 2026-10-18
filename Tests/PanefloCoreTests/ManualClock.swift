import Foundation

/// Test time that only moves when a test calls `advance`. Its `sleep` matches `Deadline.Sleep`, so deadlines,
/// backoffs and grace periods run in a fixed order without wall-clock races. A cancelled sleep returns at once.
final class ManualClock: @unchecked Sendable {
    private struct Sleeper {
        let id: UInt64
        let wake: Double
        let continuation: CheckedContinuation<Void, Never>
    }
    private let lock = NSLock()
    private var current: Double = 0
    private var sleepers: [Sleeper] = []
    private var cancelled: Set<UInt64> = []
    private var nextID: UInt64 = 0

    var now: Double { lock.withLock { current } }
    /// Wake times of the sleeps still waiting, earliest first.
    var pendingWakeTimes: [Double] { lock.withLock { sleepers.map(\.wake).sorted() } }

    /// `Deadline.Sleep` for injection. The method has a different name so this closure can never call itself.
    var sleep: @Sendable (Double) async -> Void { { [self] seconds in await self.suspend(for: seconds) } }

    func suspend(for seconds: Double) async {
        let id = lock.withLock { nextID &+= 1; return nextID }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if cancelled.remove(id) != nil || seconds <= 0 { return true }
                    sleepers.append(Sleeper(id: id, wake: current + seconds, continuation: continuation))
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else { cancelled.insert(id); return nil }
                return sleepers.remove(at: index).continuation
            }
            waiting?.resume()
        }
    }

    func advance(by seconds: Double) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            current += seconds
            let ready = sleepers.filter { $0.wake <= current + 1e-9 }
            sleepers.removeAll { $0.wake <= current + 1e-9 }
            return ready.map(\.continuation)
        }
        for continuation in due { continuation.resume() }
    }
}

/// A one-way latch an async test operation can wait on.
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if opened { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true
            defer { waiters.removeAll() }
            return waiters
        }
        for continuation in pending { continuation.resume() }
    }
}

/// Waits for asynchronous work to reach a state. Ordering in these tests comes from `ManualClock` and `TestGate`;
/// the wall-clock bound only turns a hang into a failure and never decides an outcome.
@MainActor func eventually(_ condition: () -> Bool) async -> Bool {
    let limit = Date().addingTimeInterval(20)
    var spins = 0
    while !condition() {
        if Date() > limit { return false }
        spins += 1
        if spins < 2_000 { await Task.yield() } else { try? await Task.sleep(for: .milliseconds(1)) }
    }
    return true
}

/// Lets already-runnable tasks finish before a negative assertion.
@MainActor func drainTasks(_ rounds: Int = 200) async {
    for _ in 0..<rounds { await Task.yield() }
}
