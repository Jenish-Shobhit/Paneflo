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
