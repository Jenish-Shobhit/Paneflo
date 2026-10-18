/// Bounded recovery for an event tap that macOS disables (callback timeout or user input).
/// Up to `limit` re-enables are allowed inside a sliding `window`; one more means failure.
public struct TapReenableBudget: Sendable {
    public let limit: Int
    public let windowNanoseconds: UInt64
    private var recent: [UInt64] = []
    public init(limit: Int = 3, windowNanoseconds: UInt64 = 10_000_000_000) {
        self.limit = limit; self.windowNanoseconds = windowNanoseconds
    }

    /// Records a disable at `now` and returns true when the tap should be re-enabled.
    public mutating func shouldReenable(at now: UInt64) -> Bool {
        recent.removeAll { $0 > now || now - $0 >= windowNanoseconds }
        recent.append(now)
        return recent.count <= limit
    }
}

/// Automatic recovery after macOS keeps disabling the shortcut tap. The user's enable intent is kept;
/// re-installs are bounded so a tap that keeps failing never spins.
///
/// - Timed retries follow `delays` (30 s, 60 s, 120 s by default).
/// - Returning to Paneflo may also retry, no sooner than `activationSpacing` after the last attempt.
/// - At most `maximumAttempts` automatic attempts per failure streak; after that only the user's
///   manual re-enable retries.
/// - A streak ends once the tap has stayed installed for `stablePeriod`.
public struct TapRecoverySchedule: Sendable {
    public let delays: [Double]
    public let activationSpacing: Double
    public let maximumAttempts: Int
    public let stablePeriod: Double
    public private(set) var attempts = 0
    private var timedRetries = 0
    private var lastAttempt: Double?
    private var activeSince: Double?

    public init(delays: [Double] = [30, 60, 120], activationSpacing: Double = 10, maximumAttempts: Int = 5,
                stablePeriod: Double = 300) {
        self.delays = delays.map { max(1, $0) }
        self.activationSpacing = max(1, activationSpacing)
        self.maximumAttempts = max(0, maximumAttempts)
        self.stablePeriod = max(0, stablePeriod)
    }

    public var isExhausted: Bool { attempts >= maximumAttempts }

    /// The tap is installed and working.
    public mutating func noteActive(now: Double) { activeSince = now }

    /// The tap was lost at `now`. Returns when to retry automatically, or nil when only activation or
    /// a manual re-enable may retry.
    public mutating func scheduleAfterFailure(now: Double) -> Double? {
        if let since = activeSince, now - since >= stablePeriod { attempts = 0; timedRetries = 0; lastAttempt = nil }
        activeSince = nil
        guard !isExhausted, timedRetries < delays.count else { return nil }
        let at = now + delays[timedRetries]
        timedRetries += 1
        return at
    }

    /// Paneflo became active while recovering.
    public func allowsActivationRetry(now: Double) -> Bool {
        guard !isExhausted else { return false }
        return lastAttempt.map { now - $0 >= activationSpacing } ?? true
    }

    public mutating func noteAttempt(now: Double) {
        attempts += 1
        lastAttempt = now
    }

    /// The user turned shortcuts on or off: a fresh streak.
    public mutating func reset() {
        attempts = 0; timedRetries = 0; lastAttempt = nil; activeSince = nil
    }
}

/// Fixed-capacity record of recent callback durations for diagnostics. No event content is kept.
public struct CallbackLatencyWindow: Sendable {
    public struct Summary: Equatable, Sendable {
        public let callbacks: UInt64
        public let samples: Int
        public let p50Nanoseconds: UInt64
        public let p95Nanoseconds: UInt64
        public let maxNanoseconds: UInt64
    }
    public let capacity: Int
    private var ring: [UInt64] = []
    private var next = 0
    public private(set) var callbacks: UInt64 = 0
    private var maximum: UInt64 = 0
    public init(capacity: Int = 1024) { self.capacity = max(1, capacity); ring.reserveCapacity(self.capacity) }

    public mutating func record(_ nanoseconds: UInt64) {
        callbacks &+= 1
        maximum = max(maximum, nanoseconds)
        if ring.count < capacity { ring.append(nanoseconds) } else { ring[next] = nanoseconds }
        next = (next + 1) % capacity
    }

    /// Nearest-rank percentiles over the retained samples; the maximum covers the whole session.
    public var summary: Summary? {
        guard !ring.isEmpty else { return nil }
        let sorted = ring.sorted()
        func rank(_ percentile: Int) -> UInt64 {
            let index = (percentile * sorted.count + 99) / 100 - 1
            return sorted[min(max(index, 0), sorted.count - 1)]
        }
        return Summary(callbacks: callbacks, samples: sorted.count, p50Nanoseconds: rank(50),
                       p95Nanoseconds: rank(95), maxNanoseconds: maximum)
    }
}
