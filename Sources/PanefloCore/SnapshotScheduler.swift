/// One window a visible card wants a fresh one-shot snapshot of.
public struct SnapshotRequest: Hashable, Sendable {
    public let id: WindowIdentity
    public let windowNumber: UInt32
    public init(id: WindowIdentity, windowNumber: UInt32) {
        self.id = id
        self.windowNumber = windowNumber
    }
}

/// A physically issued screenshot. It stays outstanding until the OS callback completes.
public struct SnapshotTicket: Hashable, Sendable {
    public let request: SnapshotRequest
    public let serial: UInt64
    /// Purge epoch at issue time; a purge in between discards the result.
    public let epoch: UInt64
    public var id: WindowIdentity { request.id }
}

public enum SnapshotCompletion: Equatable, Sendable {
    /// Store in the cache. Selection or request-set changes never turn a completion into a discard.
    case store
    /// The window closed while the capture was in flight.
    case discardClosed
    /// A privacy or memory purge happened while the capture was in flight.
    case discardPurged
    /// Not an outstanding ticket (duplicate or forged completion).
    case unknownTicket
}

/// Refresh-on-open planner for one-shot snapshots.
///
/// - Each surface session refreshes every visible card once, prioritized around the selection.
/// - At most `concurrencyLimit` (2–4) screenshots are physically outstanding, across sessions:
///   a capture issued before a dismissal still counts until its callback arrives.
/// - Completed captures are stored even if the selection, request set, or session moved on;
///   only a closed window or a purge discards them.
public struct SnapshotScheduler: Sendable {
    public let concurrencyLimit: Int
    public private(set) var queue: [SnapshotRequest] = []
    public private(set) var epoch: UInt64 = 0
    public private(set) var sessionActive = false
    private var outstanding: [UInt64: SnapshotTicket] = [:]
    private var refreshed: Set<WindowIdentity> = []
    private var closedInFlight: Set<WindowIdentity> = []
    private var serial: UInt64 = 0

    public init(concurrencyLimit: Int = 3) {
        self.concurrencyLimit = min(4, max(2, concurrencyLimit))
    }

    public var outstandingCount: Int { outstanding.count }
    public var outstandingTickets: [SnapshotTicket] { outstanding.values.sorted { $0.serial < $1.serial } }
    public func isRefreshed(_ id: WindowIdentity) -> Bool { refreshed.contains(id) }

    /// A surface became visible: every visible card is eligible for one fresh capture again.
    public mutating func beginSession() {
        sessionActive = true
        refreshed.removeAll()
        queue.removeAll()
    }

    /// The surface hid: queued work is dropped; outstanding captures still complete and are cached.
    public mutating func endSession() {
        sessionActive = false
        queue.removeAll()
    }

    /// Replaces the queue with the visible requests that still need a refresh this session,
    /// ordered by distance from `selectedIndex` (selected first, then the next card, the previous
    /// card, and so on). `fresh` lists windows whose cached snapshot is recent enough to skip.
    public mutating func plan(_ requests: [SnapshotRequest], selectedIndex: Int?, fresh: Set<WindowIdentity> = []) {
        guard sessionActive else { queue.removeAll(); return }
        refreshed.formUnion(fresh)
        let inFlight = Set(outstanding.values.map(\.id))
        var seen: Set<WindowIdentity> = []
        let pivot = selectedIndex ?? 0
        queue = requests.enumerated()
            .filter { seen.insert($0.element.id).inserted }
            .filter { !refreshed.contains($0.element.id) && !inFlight.contains($0.element.id) }
            .sorted { lhs, rhs in
                let left = Self.rank(lhs.offset, pivot: pivot), right = Self.rank(rhs.offset, pivot: pivot)
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }

    /// Issues tickets until the concurrency limit; each issued window counts as refreshed.
    public mutating func nextTickets() -> [SnapshotTicket] {
        var issued: [SnapshotTicket] = []
        while sessionActive, outstanding.count < concurrencyLimit, !queue.isEmpty {
            let request = queue.removeFirst()
            serial &+= 1
            let ticket = SnapshotTicket(request: request, serial: serial, epoch: epoch)
            outstanding[serial] = ticket
            refreshed.insert(request.id)
            issued.append(ticket)
        }
        return issued
    }

    /// Call exactly once per issued ticket, when the OS request actually finished (success or error).
    public mutating func complete(_ ticket: SnapshotTicket) -> SnapshotCompletion {
        guard outstanding[ticket.serial] == ticket else { return .unknownTicket }
        outstanding.removeValue(forKey: ticket.serial)
        let closed = closedInFlight.contains(ticket.id)
        if closed, !outstanding.values.contains(where: { $0.id == ticket.id }) { closedInFlight.remove(ticket.id) }
        if ticket.epoch != epoch { return .discardPurged }
        return closed ? .discardClosed : .store
    }

    public mutating func windowClosed(_ id: WindowIdentity) {
        queue.removeAll { $0.id == id }
        refreshed.remove(id)
        if outstanding.values.contains(where: { $0.id == id }) { closedInFlight.insert(id) }
    }

    /// Privacy/memory purge: drops queued work and makes every in-flight result a discard.
    public mutating func purge() {
        epoch &+= 1
        queue.removeAll()
        refreshed.removeAll()
    }

    /// 0 for the pivot, then +1, -1, +2, -2, ...
    private static func rank(_ index: Int, pivot: Int) -> Int {
        let delta = index - pivot
        return delta > 0 ? delta * 2 - 1 : -delta * 2
    }
}

/// Starts the single live stream only after the selection has been stable for `delay` seconds,
/// and stops it immediately when the selection changes or the surface hides.
public struct StableSelectionGate<Key: Hashable & Sendable>: Sendable {
    public struct Decision: Equatable, Sendable {
        /// Stop (or never start) the stream for the previous key now.
        public var stopLive: Bool
        /// Call `fire(now:)` at or after this time.
        public var fireAt: Double?
    }

    public let delay: Double
    public private(set) var committed: Key?
    public private(set) var pending: Key?
    private var pendingSince = 0.0

    public init(delay: Double = 0.1) { self.delay = max(0, delay) }

    public mutating func update(_ key: Key?, now: Double) -> Decision {
        if let key, key == committed, pending == nil { return Decision(stopLive: false, fireAt: nil) }
        if let key, key == pending { return Decision(stopLive: false, fireAt: pendingSince + delay) }
        let hadLive = committed != nil
        committed = nil
        guard let key else {
            pending = nil
            return Decision(stopLive: hadLive, fireAt: nil)
        }
        pending = key
        pendingSince = now
        return Decision(stopLive: hadLive, fireAt: now + delay)
    }

    /// Commits and returns the pending key once it has been stable for `delay`.
    public mutating func fire(now: Double) -> Key? {
        guard let pending, now + 1e-9 >= pendingSince + delay else { return nil }
        committed = pending
        self.pending = nil
        return committed
    }

    /// Forgets the committed key so the next `update` with the same key restarts the stream
    /// (after a pause for pressure, sleep, or a failed start).
    public mutating func reset() {
        committed = nil
        pending = nil
    }
}
