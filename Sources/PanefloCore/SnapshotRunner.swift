import Foundation

/// Why a capture backend could not produce a snapshot.
public enum SnapshotFailure: Error, Equatable, Sendable {
    /// Not listed on screen (other Space, hidden); does not count against the circuit breaker.
    case notOnScreen
    /// Screen Recording refused; handled as a permission change, not a breaker failure.
    case permissionDenied
    case failed
}

public enum SnapshotOutcome<Payload: Sendable>: Sendable {
    case captured(Payload)
    case failed(SnapshotFailure)
    case timedOut
}

/// Drives `SnapshotScheduler` tickets through a capture backend with a per-request deadline and a
/// circuit breaker. Platform-free so a fake backend can test hangs, late completions, and backoff.
@MainActor
public final class SnapshotRunner<Payload: Sendable> {
    public typealias Backend = @MainActor @Sendable (SnapshotRequest) async throws -> Payload

    public var scheduler: SnapshotScheduler
    public private(set) var breaker: CaptureCircuitBreaker
    public let timeout: Double
    /// Every resolved ticket, with the scheduler's verdict on whether its result may be stored.
    public var onOutcome: ((SnapshotTicket, SnapshotCompletion, SnapshotOutcome<Payload>) -> Void)?
    /// A timed-out request finally completed; its payload (if any) is handed over to be dropped.
    public var onLate: ((SnapshotTicket, Result<Payload, any Error>) -> Void)?
    /// The breaker opened or its backoff expired: refresh labels, and on expiry re-plan.
    public var onBreakerChange: ((_ open: Bool) -> Void)?

    private let backend: Backend
    private let clock: @MainActor () -> Double
    private let sleep: Deadline.Sleep
    private var retryTask: Task<Void, Never>?

    public init(scheduler: SnapshotScheduler = SnapshotScheduler(), breaker: CaptureCircuitBreaker = CaptureCircuitBreaker(),
                timeout: Double = 1.5, clock: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime },
                sleep: @escaping Deadline.Sleep = Deadline.systemSleep, backend: @escaping Backend) {
        self.scheduler = scheduler
        self.breaker = breaker
        self.timeout = max(0, timeout)
        self.clock = clock
        self.sleep = sleep
        self.backend = backend
    }

    isolated deinit { retryTask?.cancel() }

    public var isBackingOff: Bool { breaker.isOpen(now: clock()) }

    /// Issues tickets up to the scheduler's limits unless the breaker is backing off. After a
    /// backoff expires (half-open) only one probe request runs until it succeeds.
    public func pump() {
        guard breaker.allows(now: clock()) else { return }
        let halfOpen = breaker.retryAt != nil
        if halfOpen, scheduler.outstandingCount > 0 { return }
        for ticket in scheduler.nextTickets(maximum: halfOpen ? 1 : Int.max) {
            Task { await self.run(ticket) }
        }
    }

    /// For failures outside a ticket (for example a shared discovery timeout).
    public func noteFailure() {
        if breaker.recordFailure(now: clock()) { opened() }
    }

    public func noteSuccess() {
        let wasOpen = breaker.retryAt != nil
        breaker.recordSuccess()
        if wasOpen { retryTask?.cancel(); retryTask = nil; onBreakerChange?(false) }
    }

    private func run(_ ticket: SnapshotTicket) async {
        let backend = self.backend
        let request = ticket.request
        let result = await Deadline.run(seconds: timeout, sleep: sleep, operation: { try await backend(request) }, late: { [weak self] late in
            Task { @MainActor in
                guard let self else { return }
                _ = self.scheduler.complete(ticket)
                self.onLate?(ticket, late)
                self.pump()
            }
        })
        switch result {
        case .value(let payload):
            let completion = scheduler.complete(ticket)
            noteSuccess()
            onOutcome?(ticket, completion, .captured(payload))
        case .failure(let error):
            let completion = scheduler.complete(ticket)
            let failure = (error as? SnapshotFailure) ?? .failed
            if failure == .failed { noteFailure() }
            onOutcome?(ticket, completion, .failed(failure))
        case .timedOut:
            let completion = scheduler.timeout(ticket)
            noteFailure()
            onOutcome?(ticket, completion, .timedOut)
        }
        pump()
    }

    private func opened() {
        if retryTask == nil { onBreakerChange?(true) }
        guard let retryAt = breaker.retryAt else { return }
        retryTask?.cancel()
        let sleep = self.sleep
        retryTask = Task { @MainActor [weak self] in
            guard let delay = self.map({ retryAt - $0.clock() }) else { return }
            if delay > 0 { await sleep(delay) }
            guard let self else { return }
            guard !Task.isCancelled else { return }
            self.retryTask = nil
            self.onBreakerChange?(false)
            self.pump()
        }
    }
}
