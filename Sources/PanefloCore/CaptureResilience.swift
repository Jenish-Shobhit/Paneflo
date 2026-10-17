import Foundation

public enum DeadlineResult<Value: Sendable>: Sendable {
    case value(Value)
    case failure(any Error)
    case timedOut
}

/// Races an OS request against a deadline. The caller resumes exactly once, with whichever comes
/// first. The request itself cannot be cancelled: if it finishes after the deadline, its result goes
/// to `late` (exactly once) so the owner can release whatever it carries.
public enum Deadline {
    public static func run<Value: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> Value,
        late: @escaping @Sendable (Result<Value, any Error>) -> Void = { _ in }
    ) async -> DeadlineResult<Value> {
        let gate = OneShot<Value>()
        return await withCheckedContinuation { continuation in
            gate.install(continuation)
            let timer = Task {
                try? await Task.sleep(for: .seconds(max(0, seconds)))
                if !Task.isCancelled { _ = gate.finish(.timedOut) }
            }
            gate.timer = timer
            Task {
                do {
                    let value = try await operation()
                    if !gate.finish(.value(value)) { late(.success(value)) }
                } catch {
                    if !gate.finish(.failure(error)) { late(.failure(error)) }
                }
            }
        }
    }
}

private final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DeadlineResult<Value>, Never>?
    private var finished = false
    var timer: Task<Void, Never>? {
        get { lock.lock(); defer { lock.unlock() }; return storedTimer }
        set {
            lock.lock()
            let cancel = finished
            storedTimer = newValue
            lock.unlock()
            if cancel { newValue?.cancel() }
        }
    }
    private var storedTimer: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<DeadlineResult<Value>, Never>) {
        lock.lock(); self.continuation = continuation; lock.unlock()
    }

    /// True for the first caller only.
    func finish(_ result: DeadlineResult<Value>) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let timer = storedTimer
        lock.unlock()
        timer?.cancel()
        continuation?.resume(returning: result)
        return true
    }
}

/// Opens after `threshold` consecutive failures and blocks new work with exponential backoff
/// (`baseDelay`, doubling, capped at `maximumDelay`). When the backoff expires one attempt is
/// allowed (half-open); a failure doubles the delay, a success closes the breaker.
public struct CaptureCircuitBreaker: Sendable {
    public let threshold: Int
    public let baseDelay: Double
    public let maximumDelay: Double
    public private(set) var consecutiveFailures = 0
    public private(set) var retryAt: Double?

    public init(threshold: Int = 3, baseDelay: Double = 1, maximumDelay: Double = 30) {
        self.threshold = max(1, threshold)
        self.baseDelay = max(0, baseDelay)
        self.maximumDelay = max(self.baseDelay, maximumDelay)
    }

    public func allows(now: Double) -> Bool { retryAt.map { now >= $0 } ?? true }
    public func isOpen(now: Double) -> Bool { !allows(now: now) }

    /// Returns true when this failure opened (or extended) the breaker.
    @discardableResult
    public mutating func recordFailure(now: Double) -> Bool {
        consecutiveFailures += 1
        guard consecutiveFailures >= threshold else { return false }
        let exponent = min(consecutiveFailures - threshold, 16)
        retryAt = now + min(maximumDelay, baseDelay * Double(1 << exponent))
        return true
    }

    public mutating func recordSuccess() {
        consecutiveFailures = 0
        retryAt = nil
    }
}
